import AppKit
import CoreAudio
import Observation

/// Connects the pieces: watches the audio system, decides which taps and which mic are needed,
/// feeds levels into the `RuleEvaluator` and applies the resulting gains.
@MainActor
@Observable
final class DuckingEngine {
    enum Tuning {
        /// While something is happening (call, fade, open UI).
        static let liveTickInterval: TimeInterval = 1.0 / 30
        /// While taps run but nothing changes; keeps silence detection and sample rates up to date.
        static let idleTickInterval: TimeInterval = 1
        static let maxDeltaTime: TimeInterval = 0.25
        /// The output device's sample rate and stream layout can change while running.
        static let deviceCheckInterval: TimeInterval = 1
        static let saveDelay: Duration = .milliseconds(500)
        static let reconcileDelay: Duration = .milliseconds(100)
        /// How fast the level meters fall back.
        static let meterFallDBPerSecond: Float = 45
        /// Below this factor the menu bar shows the ducking icon.
        static let duckingIndicatorFactor: Float = 0.95
    }

    let monitor = AudioSystemMonitor()
    let taps = TapManager { AppAudioTap($0) }

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            setNeedsReconcile()
        }
    }

    /// Set while the rules window is open: keeps meters running so thresholds can be calibrated.
    var calibrating = false {
        didSet { if calibrating != oldValue { setNeedsReconcile() } }
    }

    /// Set while the menu is open: level meters are visible and need live updates.
    var menuVisible = false {
        didSet { if menuVisible != oldValue { updateTimer() } }
    }

    private(set) var micLevelDB: Float = silenceDB
    private(set) var appLevelDB: [String: Float] = [:]
    private(set) var ruleStates: [UUID: RuleState] = [:]
    /// Current (smoothed) duck factor per app; missing means 1.0.
    private(set) var duckFactors: [String: Float] = [:]
    private(set) var micError: String?
    private(set) var micRunning = false

    /// Well-known apps that are installed on this Mac, offered in the rule pickers.
    @ObservationIgnored private let installedPresets = KnownApps.presets.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.key) != nil
    }
    @ObservationIgnored private var evaluator = RuleEvaluator()
    @ObservationIgnored private let mic = MicLevelMonitor()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var timerInterval: TimeInterval?
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var lastDeviceCheck: TimeInterval = 0
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init() {
        settings = AppSettings.load()
        monitor.onChange = { [weak self] in self?.setNeedsReconcile() }
        monitor.start()

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        mic.onAccessGranted = { [weak self] in self?.setNeedsReconcile() }
        if settings.rules.contains(where: { $0.useMicrophone }) {
            mic.requestAccessIfNeeded()
        }
        reconcile()
    }

    // MARK: - Public API for the UI

    func volume(for appID: String) -> Double {
        settings.volumes[appID] ?? 1
    }

    func setVolume(_ value: Double, for app: AudioApp) {
        settings.knownApps[app.id] = app.name
        settings.volumes[app.id] = value >= AppSettings.fullVolume ? nil : value
    }

    func name(for appID: String) -> String {
        monitor.app(appID)?.name ?? settings.knownApps[appID] ?? KnownApps.presets[appID] ?? appID
    }

    var visibleApps: [AudioApp] {
        monitor.apps.filter { app in
            (settings.showAllApps && app.isRegularApp)
                || app.isPlaying
                || settings.volumes[app.id] != nil
                || settings.rules.contains { $0.targetAppID == app.id }
        }
    }

    /// Choices for the rule pickers: running regular apps, remembered apps and installed well-known apps.
    var appChoices: [(id: String, name: String)] {
        var names = installedPresets
        for (id, name) in settings.knownApps { names[id] = name }
        for app in monitor.apps where app.isRegularApp { names[app.id] = app.name }
        for rule in settings.rules {
            for id in [rule.targetAppID, rule.triggerAppID] where !id.isEmpty {
                names[id] = names[id] ?? id
            }
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var isDucking: Bool {
        duckFactors.values.contains { $0 < Tuning.duckingIndicatorFactor }
    }

    /// Adds an empty rule; the user picks both apps in the rules window.
    func addRule() {
        settings.rules.append(DuckRule(targetAppID: "", triggerAppID: ""))
    }

    func deleteRule(_ id: UUID) {
        settings.rules.removeAll { $0.id == id }
    }

    func retrySuspendedTaps() {
        taps.retrySuspended()
        setNeedsReconcile()
    }

    // MARK: - Tick

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let deltaTime = min(now - (lastTick ?? now - (timerInterval ?? Tuning.liveTickInterval)), Tuning.maxDeltaTime)
        lastTick = now

        let rawMic = micRunning ? decibels(mic.readLevel()) : nil
        let playing = Set(monitor.apps.filter(\.isPlaying).map(\.id))
        let rawLevels = taps.readLevels(playingApps: playing, now: now)
        updateDisplayLevels(mic: rawMic, apps: rawLevels, deltaTime: deltaTime)

        evaluator.step(.init(
            automationEnabled: settings.automationEnabled,
            rules: settings.rules,
            activeRuleIDs: Set(activeRules.map(\.id)),
            micDB: rawMic,
            appLevelDB: rawLevels,
            now: now,
            deltaTime: deltaTime
        ))
        if evaluator.states != ruleStates { ruleStates = evaluator.states }
        if evaluator.duckFactors != duckFactors { duckFactors = evaluator.duckFactors }

        taps.applyGains(effectiveGain)
        if now - lastDeviceCheck >= Tuning.deviceCheckInterval {
            taps.refreshDeviceState()
            lastDeviceCheck = now
        }
        if taps.takeRebuildRequests() { setNeedsReconcile() }
        updateTimer()
    }

    private func updateDisplayLevels(mic: Float?, apps: [String: Float], deltaTime: TimeInterval) {
        let fall = Tuning.meterFallDBPerSecond * Float(deltaTime)
        let newMic = max(mic ?? silenceDB, micLevelDB - fall)
        if abs(newMic - micLevelDB) > 0.1 { micLevelDB = newMic }

        var display: [String: Float] = [:]
        for (id, level) in apps { display[id] = max(level, (appLevelDB[id] ?? silenceDB) - fall) }
        if display != appLevelDB { appLevelDB = display }
    }

    /// Fast ticks while something visibly happens, slow ticks while taps only need supervision,
    /// no ticks at all otherwise.
    private func updateTimer() {
        let live = calibrating || menuVisible || !activeRules.isEmpty || !evaluator.duckFactors.isEmpty
        let interval: TimeInterval? = live ? Tuning.liveTickInterval
            : (taps.isEmpty && !mic.isRunning ? nil : Tuning.idleTickInterval)
        guard interval != timerInterval else { return }

        timer?.invalidate()
        timer = nil
        timerInterval = interval
        lastTick = nil
        guard let interval else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Rules that are enabled and whose trigger app is currently in a call (or playing).
    private var activeRules: [DuckRule] {
        guard settings.automationEnabled else { return [] }
        return settings.rules.filter { $0.isUsable && isTriggerActive($0) }
    }

    private func isTriggerActive(_ rule: DuckRule) -> Bool {
        guard let trigger = monitor.app(rule.triggerAppID) else { return false }
        return rule.requireTriggerMic ? trigger.isUsingMic : (trigger.isUsingMic || trigger.isPlaying)
    }

    /// Slider position -> amplitude. Squaring makes the slider feel roughly linear in loudness.
    private func effectiveGain(for appID: String) -> Float {
        let position = Float(volume(for: appID)) * (duckFactors[appID] ?? 1)
        return position * position
    }

    // MARK: - Reconcile

    /// Coalesces bursts of changes (slider drags, several processes starting) into one reconcile.
    private func setNeedsReconcile() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: Tuning.reconcileDelay)
            self?.reconcile()
        }
    }

    /// Brings taps and the mic monitor in line with the settings and the current audio system.
    private func reconcile() {
        reconcileTask = nil
        let enabledRules = settings.automationEnabled ? settings.rules.filter(\.isUsable) : []
        // While calibrating, meter what the enabled rules would use – even with automation switched off.
        let calibrationRules = calibrating ? settings.rules.filter(\.isUsable) : []

        if let outputID = CA.defaultOutputDevice, let uid = CA.deviceUID(outputID) {
            var wantedRender: [String: [AudioObjectID]] = [:]
            for app in monitor.apps
            where volume(for: app.id) < AppSettings.fullVolume || enabledRules.contains(where: { $0.targetAppID == app.id }) {
                wantedRender[app.id] = app.processObjects
            }

            var wantedMeter: [String: [AudioObjectID]] = [:]
            for rule in (calibrating ? calibrationRules : enabledRules) where rule.useTriggerAudio {
                guard let app = monitor.app(rule.triggerAppID), wantedRender[app.id] == nil,
                      calibrating || isTriggerActive(rule) else { continue }
                wantedMeter[app.id] = app.processObjects
            }

            taps.update(render: wantedRender, meter: wantedMeter,
                        output: .init(id: outputID, uid: uid), gain: effectiveGain,
                        now: ProcessInfo.processInfo.systemUptime)
        }

        let micDeviceID = micDevice(callRules: activeRules.filter(\.useMicrophone),
                                    calibrating: calibrationRules.contains(where: \.useMicrophone))
        if let micDeviceID {
            mic.start(device: micDeviceID)
        } else if mic.isRunning {
            mic.stop()
        }
        if micRunning != mic.isRunning { micRunning = mic.isRunning }
        if micError != mic.lastError { micError = mic.lastError }

        updateTimer()
    }

    /// The mic to measure: the one the call app is recording from, otherwise (e.g. while calibrating
    /// outside a call) the default input.
    private func micDevice(callRules: [DuckRule], calibrating: Bool) -> AudioDeviceID? {
        for rule in callRules {
            if let app = monitor.app(rule.triggerAppID), let device = CA.inputDevice(usedBy: app) {
                return device
            }
        }
        guard !callRules.isEmpty || calibrating else { return nil }
        return CA.defaultInputDevice
    }

    // MARK: - Persistence & shutdown

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Tuning.saveDelay)
            guard !Task.isCancelled, let self else { return }
            settings.save()
            saveTask = nil
        }
    }

    private func shutdown() {
        if saveTask != nil {
            saveTask?.cancel()
            settings.save()
        }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        timer?.invalidate()
        taps.stopAll()
        mic.stop()
    }
}
