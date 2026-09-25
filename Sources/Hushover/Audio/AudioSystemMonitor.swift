import AppKit
import CoreAudio
import Darwin
import Observation

/// An app (identified by its outermost .app bundle) together with all of its
/// processes that Core Audio knows about – e.g. Chrome/Teams play audio from helper processes.
struct AudioApp: Identifiable, Equatable {
    let id: String
    var name: String
    var bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var isUsingMic: Bool
    /// A normal app with a Dock icon, as opposed to background and system processes that use audio.
    var isRegularApp: Bool
}

/// Tracks which apps use audio and reports changes of apps and default devices.
/// Driven by Core Audio change notifications instead of polling.
@MainActor
@Observable
final class AudioSystemMonitor {
    private(set) var apps: [AudioApp] = []

    /// Called after every refresh caused by a change (apps, playing/recording state, default devices).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var identityCache: [pid_t: AppIdentity] = [:]
    @ObservationIgnored private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var safetyTimer: Timer?
    @ObservationIgnored private let ownPID = getpid()

    private static let systemSelectors = [
        kAudioHardwarePropertyProcessObjectList,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
    ]
    private static let processSelectors = [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyIsRunningInput]
    /// Only a safety net in case a notification gets lost; the listeners do the real work.
    private static let safetyInterval: TimeInterval = 10

    func start() {
        let listener = makeListener()
        for selector in Self.systemSelectors {
            CA.addListener(CA.systemObject, selector, listener)
        }
        refresh()

        let timer = Timer(timeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    func app(_ id: String) -> AudioApp? {
        apps.first { $0.id == id }
    }

    private func makeListener() -> AudioObjectPropertyListenerBlock {
        { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    /// Notifications often come in bursts (several processes at once); coalesce them.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            refreshScheduled = false
            refresh()
            onChange?()
        }
    }

    private func refresh() {
        var grouped: [String: AudioApp] = [:]
        var seenPIDs = Set<pid_t>()
        var seenObjects = Set<AudioObjectID>()
        // Helper processes (e.g. a browser's audio helper) count as regular if their app bundle is one.
        let regularAppPaths = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.standardizedFileURL.path })

        for object in CA.objectIDs(CA.systemObject, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? CA.value(object, kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid > 0, pid != ownPID else { continue }
            seenPIDs.insert(pid)
            seenObjects.insert(object)

            let identity: AppIdentity
            if let cached = identityCache[pid] {
                identity = cached
            } else if let resolved = AppIdentity.resolve(pid: pid, reportedBundleID: CA.string(object, kAudioProcessPropertyBundleID)) {
                identity = resolved
                identityCache[pid] = resolved
            } else {
                continue
            }

            let isRegularApp = identity.bundlePath.map { regularAppPaths.contains(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? false
            var app = grouped[identity.id] ?? AudioApp(id: identity.id, name: identity.name, bundlePath: identity.bundlePath,
                                                       processObjects: [], isPlaying: false, isUsingMic: false,
                                                       isRegularApp: false)
            // An app's processes may resolve differently; the best information from any of them wins.
            if app.bundlePath == nil, let bundlePath = identity.bundlePath {
                app.bundlePath = bundlePath
                app.name = identity.name
            }
            app.isRegularApp = app.isRegularApp || isRegularApp
            app.processObjects.append(object)
            app.isPlaying = app.isPlaying || CA.bool(object, kAudioProcessPropertyIsRunningOutput)
            app.isUsingMic = app.isUsingMic || CA.bool(object, kAudioProcessPropertyIsRunningInput)
            grouped[identity.id] = app
        }

        identityCache = identityCache.filter { seenPIDs.contains($0.key) }
        updateProcessListeners(seenObjects)

        let updated = grouped.values
            .map { app -> AudioApp in
                var app = app
                app.processObjects.sort()
                return app
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if updated != apps { apps = updated }
    }

    /// Watch each process for starting/stopping playback or recording (e.g. a call starting in Teams).
    private func updateProcessListeners(_ objects: Set<AudioObjectID>) {
        for (object, listener) in processListeners where !objects.contains(object) {
            for selector in Self.processSelectors { CA.removeListener(object, selector, listener) }
            processListeners[object] = nil
        }
        for object in objects where processListeners[object] == nil {
            let listener = makeListener()
            for selector in Self.processSelectors { CA.addListener(object, selector, listener) }
            processListeners[object] = listener
        }
    }
}

struct AppIdentity {
    let id: String
    let name: String
    let bundlePath: String?

    /// Maps a process to the app the user thinks of: the outermost `.app` bundle in its executable path.
    @MainActor
    static func resolve(pid: pid_t, reportedBundleID: String?) -> AppIdentity? {
        let reported = reportedBundleID.flatMap { $0.isEmpty ? nil : $0 }
        let path = executablePath(of: pid)

        if let path, let identity = bundleIdentity(containing: path) {
            return identity
        }
        // Not inside a recognizable app bundle – sandboxed helpers hide their path, and Chrome runs its main
        // executable from a temporary "….app.bundle" clone. Locate the app by the bundle ID Core Audio reports.
        if let reported, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: reported),
           let identity = bundleIdentity(containing: url.path + "/") {
            return identity
        }
        if let path {
            return AppIdentity(id: reported ?? "exe:\(path)", name: (path as NSString).lastPathComponent, bundlePath: nil)
        }
        return reported.map { AppIdentity(id: $0, name: $0, bundlePath: nil) }
    }

    private static func bundleIdentity(containing path: String) -> AppIdentity? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let bundle = Bundle(path: bundlePath)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        return AppIdentity(id: bundle?.bundleIdentifier ?? bundlePath, name: name, bundlePath: bundlePath)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    /// Bundle ID -> icon, including a fallback for apps that aren't installed (so the lookup runs only once).
    private static var cacheByBundleID: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return icon(forBundlePath: nil) }
        if let cached = cacheByBundleID[bundleID] { return cached }
        let icon = icon(forBundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path)
        cacheByBundleID[bundleID] = icon
        return icon
    }

    static func icon(forBundlePath path: String?) -> NSImage {
        guard let path else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage() }
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}
