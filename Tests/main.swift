// Unit tests for Hushover's logic (no real audio devices, no UI). Run with ./test.sh.
import CoreAudio
import Foundation

// MARK: - Minimal harness

var failures = 0
var currentTest = ""

@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    guard !condition else { return }
    failures += 1
    print("  ✗ \(currentTest) (line \(line)) \(message())")
}

@MainActor func expectNear(_ value: Float, _ expected: Float, accuracy: Float = 0.001, line: Int = #line) {
    expect(abs(value - expected) <= accuracy, "\(value) ≠ \(expected)", line: line)
}

@MainActor func test(_ name: String, _ body: @MainActor () throws -> Void) {
    currentTest = name
    let before = failures
    do { try body() } catch { failures += 1; print("  ✗ \(name): \(error)") }
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

// MARK: - Helpers

let tick: TimeInterval = 1.0 / 30

func rule(target: String = "music", trigger: String = "call") -> DuckRule {
    DuckRule(targetAppID: target, triggerAppID: trigger)
}

/// Runs the evaluator for `seconds` with constant inputs and returns the time after the run.
@discardableResult
func run(_ evaluator: inout RuleEvaluator, rules: [DuckRule], active: Bool = true, micDB: Float? = nil,
         remoteDB: Float? = nil, from start: TimeInterval, seconds: TimeInterval, automationEnabled: Bool = true) -> TimeInterval {
    var now = start
    let steps = max(Int((seconds / tick).rounded()), 1)
    for _ in 0..<steps {
        now += tick
        var levels: [String: Float] = [:]
        for rule in rules { levels[rule.triggerAppID] = remoteDB ?? silenceDB }
        evaluator.step(.init(automationEnabled: automationEnabled, rules: rules,
                             activeRuleIDs: active ? Set(rules.map(\.id)) : [],
                             micDB: micDB, appLevelDB: levels, now: now, deltaTime: tick))
    }
    return now
}

// MARK: - Levels

test("decibels") {
    expectNear(decibels(1), 0)
    expectNear(decibels(0.1), -20)
    expectNear(decibels(0), silenceDB)
}

test("LevelHandoff returns the maximum since the last read") {
    let handoff = LevelHandoff()
    handoff.push(0.2)
    handoff.push(0.5)
    handoff.push(0.1)
    let first = handoff.take()
    expectNear(first.peak, 0.5)
    expect(first.blocks == 3)
    let second = handoff.take()
    expect(second.peak == 0 && second.blocks == 0)
}

test("LevelHandoff: silent blocks count even without a level") {
    let handoff = LevelHandoff()
    handoff.push(0)
    handoff.push(.nan)
    let sample = handoff.take()
    expect(sample.blocks == 2 && sample.peak == 0, "\(sample)")
}

test("LevelHold repeats the value until nothing arrives for too long") {
    var hold = LevelHold()
    expectNear(hold.update(LevelSample(peak: 0.4, blocks: 1)), 0.4)
    for _ in 0..<LevelHold.maxStaleReads {
        expectNear(hold.update(LevelSample(peak: 0, blocks: 0)), 0.4)
    }
    expectNear(hold.update(LevelSample(peak: 0, blocks: 0)), 0)
}

test("LevelHold: real silence applies immediately") {
    var hold = LevelHold()
    _ = hold.update(LevelSample(peak: 0.4, blocks: 1))
    expectNear(hold.update(LevelSample(peak: 0, blocks: 2)), 0)
}

// MARK: - ChannelMapping

test("Stereo to stereo keeps the channels") {
    let input: [Float] = [0.1, 0.9, 0.2, 0.8]  // two frames, L R
    input.withUnsafeBufferPointer { buffer in
        let p = buffer.baseAddress!
        expectNear(ChannelMapping.sample(p, frame: 1, inChannels: 2, outChannel: 0, totalOutChannels: 2), 0.2)
        expectNear(ChannelMapping.sample(p, frame: 1, inChannels: 2, outChannel: 1, totalOutChannels: 2), 0.8)
    }
}

test("Mono output mixes both channels") {
    let input: [Float] = [1, 0]  // hard left
    input.withUnsafeBufferPointer { buffer in
        expectNear(ChannelMapping.sample(buffer.baseAddress!, frame: 0, inChannels: 2, outChannel: 0, totalOutChannels: 1), 0.5)
    }
}

test("Multichannel output repeats L R") {
    let input: [Float] = [0.3, 0.7]
    input.withUnsafeBufferPointer { buffer in
        let p = buffer.baseAddress!
        expectNear(ChannelMapping.sample(p, frame: 0, inChannels: 2, outChannel: 2, totalOutChannels: 4), 0.3)
        expectNear(ChannelMapping.sample(p, frame: 0, inChannels: 2, outChannel: 3, totalOutChannels: 4), 0.7)
    }
}

// MARK: - Backoff

test("Backoff doubles the delay up to 5 minutes") {
    var backoff = Backoff()
    expect(backoff.canRetry(at: 0))
    backoff.recordFailure(at: 100)
    expect(backoff.retryAt == 105)
    expect(!backoff.canRetry(at: 104) && backoff.canRetry(at: 105))
    backoff.recordFailure(at: 105)
    expect(backoff.retryAt == 115)
    for _ in 0..<20 { backoff.recordFailure(at: 1000) }
    expect(backoff.retryAt == 1000 + Backoff.maximumDelay)
}

// MARK: - RuleEvaluator

test("Without an active call the rule waits and nothing is lowered") {
    var evaluator = RuleEvaluator()
    let r = rule()
    run(&evaluator, rules: [r], active: false, micDB: -10, from: 0, seconds: 1)
    expect(evaluator.states[r.id] == .idle)
    expect(evaluator.duckFactors.isEmpty)
}

test("Automation off disables the rule") {
    var evaluator = RuleEvaluator()
    let r = rule()
    run(&evaluator, rules: [r], micDB: -10, from: 0, seconds: 1, automationEnabled: false)
    expect(evaluator.states[r.id] == .disabled)
    expect(evaluator.duckFactors.isEmpty)
}

test("A single click doesn't count as speech") {
    var evaluator = RuleEvaluator()
    let r = rule()
    let now = run(&evaluator, rules: [r], micDB: -10, from: 0, seconds: tick)
    run(&evaluator, rules: [r], micDB: silenceDB, from: now, seconds: tick)
    expect(evaluator.states[r.id] == .listening)
}

test("Own voice lowers the target to the speech volume") {
    var evaluator = RuleEvaluator()
    let r = rule()
    run(&evaluator, rules: [r], micDB: -20, from: 0, seconds: 2)
    expect(evaluator.states[r.id] == .speaking(bySelf: true))
    expectNear(evaluator.duckFactors["music"] ?? 1, Float(r.speechLevel), accuracy: 0.01)
}

test("Other participants (the app's audio) lower the target") {
    var evaluator = RuleEvaluator()
    let r = rule()
    run(&evaluator, rules: [r], remoteDB: -20, from: 0, seconds: 1)
    expect(evaluator.states[r.id] == .speaking(bySelf: false))
    expect((evaluator.duckFactors["music"] ?? 1) < 0.5)
}

test("Nothing happens below the threshold") {
    var evaluator = RuleEvaluator()
    let r = rule()
    run(&evaluator, rules: [r], micDB: Float(r.micThresholdDB) - 1, remoteDB: Float(r.triggerThresholdDB) - 1, from: 0, seconds: 1)
    expect(evaluator.states[r.id] == .listening)
    expect(evaluator.duckFactors.isEmpty)
}

test("After the hold time the rule switches to the pause volume") {
    var evaluator = RuleEvaluator()
    var r = rule()
    r.pauseLevel = 0.6
    var now = run(&evaluator, rules: [r], micDB: -20, from: 0, seconds: 1)
    now = run(&evaluator, rules: [r], micDB: silenceDB, from: now, seconds: r.holdSeconds - 0.2)
    expect(evaluator.states[r.id] == .speaking(bySelf: true), "still within the hold time")
    run(&evaluator, rules: [r], micDB: silenceDB, from: now, seconds: 0.4 + r.releaseSeconds * 3)
    expect(evaluator.states[r.id] == .listening)
    expectNear(evaluator.duckFactors["music"] ?? 1, 0.6, accuracy: 0.02)
}

test("After the call the target returns to full volume") {
    var evaluator = RuleEvaluator()
    let r = rule()
    let now = run(&evaluator, rules: [r], micDB: -20, from: 0, seconds: 1)
    run(&evaluator, rules: [r], active: false, from: now, seconds: r.releaseSeconds * 4)
    expect(evaluator.duckFactors.isEmpty, "\(evaluator.duckFactors)")
}

test("Lowering is faster than raising") {
    var down = RuleEvaluator()
    let r = rule()
    run(&down, rules: [r], micDB: -20, from: 0, seconds: 0.3)
    let loweredBy = 1 - (down.duckFactors["music"] ?? 1)

    var up = RuleEvaluator()
    let now = run(&up, rules: [r], micDB: -20, from: 0, seconds: 2)
    let lowest = up.duckFactors["music"] ?? 1
    run(&up, rules: [r], active: false, from: now, seconds: 0.3)
    let raisedBy = (up.duckFactors["music"] ?? 1) - lowest
    expect(loweredBy > raisedBy * 2, "down \(loweredBy), up \(raisedBy)")
}

test("Several rules for the same app: the quietest wins") {
    var evaluator = RuleEvaluator()
    var quiet = rule(trigger: "teams")
    quiet.speechLevel = 0.1
    var loud = rule(trigger: "zoom")
    loud.speechLevel = 0.8
    run(&evaluator, rules: [quiet, loud], micDB: -20, from: 0, seconds: 2)
    expectNear(evaluator.duckFactors["music"] ?? 1, 0.1, accuracy: 0.01)
}

test("A rule with the same app as target and trigger stays inactive") {
    var evaluator = RuleEvaluator()
    let r = rule(target: "chrome", trigger: "chrome")
    expect(r.targetsItself && !r.isUsable)
    run(&evaluator, rules: [r], micDB: -10, from: 0, seconds: 1)
    expect(evaluator.states[r.id] == .disabled)
    expect(evaluator.duckFactors.isEmpty)
}

test("A new rule without apps stays inactive until both are chosen") {
    var evaluator = RuleEvaluator()
    var r = rule(target: "", trigger: "")
    expect(!r.isComplete && !r.targetsItself && !r.isUsable)
    run(&evaluator, rules: [r], micDB: -10, from: 0, seconds: 1)
    expect(evaluator.states[r.id] == .disabled)

    r.targetAppID = "music"
    expect(!r.isComplete, "trigger still missing")
    r.triggerAppID = "call"
    expect(r.isComplete && r.isUsable)
}

test("Sanitizing keeps rules that aren't set up yet") {
    var settings = AppSettings()
    settings.rules = [rule(target: "", trigger: "")]
    settings.sanitize()
    expect(settings.rules.count == 1)
}

test("State of deleted rules is forgotten") {
    var evaluator = RuleEvaluator()
    let r = rule()
    let now = run(&evaluator, rules: [r], micDB: -20, from: 0, seconds: 1)
    run(&evaluator, rules: [], from: now, seconds: tick)
    expect(evaluator.states[r.id] == nil)
}

// MARK: - Settings

test("Missing fields get default values") {
    let json = #"{"rules":[{"targetAppID":"a","triggerAppID":"b"}]}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    expect(settings.automationEnabled)
    expect(settings.rules.count == 1)
    expect(settings.rules.first?.speechLevel == DuckRule(targetAppID: "a", triggerAppID: "b").speechLevel)
}

test("Unknown fields and broken rules don't cost the other settings") {
    let json = #"""
    {"automationEnabled": false, "futureField": 42,
     "volumes": {"x": 0.5},
     "rules": [{"targetAppID": "a", "triggerAppID": "b", "speechLevel": "broken"},
               {"triggerAppID": "no target"},
               {"targetAppID": "c", "triggerAppID": "d"}]}
    """#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    expect(!settings.automationEnabled)
    expect(settings.volumes["x"] == 0.5)
    expect(settings.rules.map(\.targetAppID) == ["a", "c"], "\(settings.rules.map(\.targetAppID))")
    expect(settings.rules.first?.speechLevel == 0.3, "broken field -> default value")
}

test("Out-of-range values are clamped") {
    var settings = AppSettings()
    var r = rule()
    r.speechLevel = 7
    r.pauseLevel = -1
    r.micThresholdDB = 20
    r.holdSeconds = .infinity
    settings.rules = [r]
    settings.volumes = ["a": 2, "b": 0.5, "c": -3]
    settings.sanitize()
    let s = settings.rules[0]
    expect(s.speechLevel == 1 && s.pauseLevel == 0)
    expect(s.micThresholdDB == DuckRule.thresholdRange.upperBound)
    expect(s.holdSeconds == DuckRule.secondsRange.lowerBound)
    expect(settings.volumes == ["b": 0.5, "c": 0], "\(settings.volumes)")
}

test("Saving and loading round-trips the settings") {
    let suite = "laurentius.Hushover.tests.\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var settings = AppSettings()
    settings.rules = [rule(target: "a", trigger: "b"), rule(target: "", trigger: "")]
    settings.volumes = ["x": 0.4]
    settings.save(to: defaults)
    expect(AppSettings.load(from: defaults) == settings)
}

test("A fresh install starts without rules") {
    let suite = "laurentius.Hushover.tests.\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings.load(from: defaults)
    expect(settings.rules.isEmpty)
    expect(settings.automationEnabled)
}

test("Unreadable settings are kept instead of overwritten") {
    let suite = "laurentius.Hushover.tests.\(UUID().uuidString)"
    let defaults = try unwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let garbage = Data("not JSON".utf8)
    defaults.set(garbage, forKey: AppSettings.storageKey)
    let loaded = AppSettings.load(from: defaults)
    expect(loaded.rules.isEmpty, "falls back to no rules")
    expect(defaults.data(forKey: AppSettings.unreadableKey) == garbage, "backup")
}

// MARK: - TapManager

struct TapStartFailed: Error {}

/// Records what the TapManager does with its taps, in order.
@MainActor final class TapFactory {
    var events: [String] = []
    var taps: [FakeTap] = []
    var failing: Set<String> = []

    func make(_ configuration: TapConfiguration) -> any ManagedTap {
        let tap = FakeTap(configuration, factory: self)
        taps.append(tap)
        return tap
    }
}

@MainActor final class FakeTap: @MainActor ManagedTap {
    let configuration: TapConfiguration
    unowned let factory: TapFactory
    var gain: Float
    var needsRebuild = false
    var level: Float = 0
    private(set) var isRunning = false

    init(_ configuration: TapConfiguration, factory: TapFactory) {
        self.configuration = configuration
        self.factory = factory
        gain = configuration.gain
    }

    var processObjects: [AudioObjectID] { configuration.processObjects }
    var output: TapOutputDevice { configuration.output }
    var name: String { "\(configuration.appID)@\(configuration.output.uid)/\(processObjects)" }

    func start() throws {
        if factory.failing.contains(configuration.appID) { throw TapStartFailed() }
        isRunning = true
        factory.events.append("start \(name)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        factory.events.append("stop \(name)")
    }

    func readLevel() -> Float { level }
    func refreshDeviceState() {}
}

let speakers = TapOutputDevice(id: 1, uid: "speakers")
let headphones = TapOutputDevice(id: 2, uid: "headphones")

@MainActor func makeManager() -> (TapManager, TapFactory) {
    let factory = TapFactory()
    return (TapManager { factory.make($0) }, factory)
}

@MainActor func update(_ manager: TapManager, render: [String: [AudioObjectID]] = [:], meter: [String: [AudioObjectID]] = [:],
                       output: TapOutputDevice = speakers, now: TimeInterval = 0) {
    manager.update(render: render, meter: meter, output: output, gain: { _ in 0.5 }, now: now)
}

test("TapManager creates wanted taps and removes unneeded ones") {
    let (manager, factory) = makeManager()
    update(manager, render: ["spotify": [10]], meter: ["teams": [20]])
    expect(factory.events == ["start spotify@speakers/[10]", "start teams@speakers/[20]"]
        || factory.events == ["start teams@speakers/[20]", "start spotify@speakers/[10]"], "\(factory.events)")
    expect(factory.taps.first { $0.configuration.appID == "spotify" }?.configuration.mode == .render)
    expect(factory.taps.first { $0.configuration.appID == "teams" }?.configuration.mode == .meter)

    factory.events = []
    update(manager, render: ["spotify": [10]])
    expect(factory.events == ["stop teams@speakers/[20]"], "\(factory.events)")
}

test("Device change: the new tap starts before the old one stops") {
    let (manager, factory) = makeManager()
    update(manager, render: ["spotify": [10]])
    factory.events = []
    update(manager, render: ["spotify": [10]], output: headphones)
    expect(factory.events == ["start spotify@headphones/[10]", "stop spotify@speakers/[10]"], "\(factory.events)")
}

test("New app processes: the new tap starts before the old one stops") {
    let (manager, factory) = makeManager()
    update(manager, render: ["chrome": [10]])
    factory.events = []
    update(manager, render: ["chrome": [10, 11]])
    expect(factory.events == ["start chrome@speakers/[10, 11]", "stop chrome@speakers/[10]"], "\(factory.events)")
}

test("Changed stream layout: the tap is reported once and replaced") {
    let (manager, factory) = makeManager()
    update(manager, render: ["spotify": [10]])
    expect(!manager.takeRebuildRequests())
    factory.taps[0].needsRebuild = true
    expect(manager.takeRebuildRequests())
    expect(!manager.takeRebuildRequests(), "report only once")

    factory.events = []
    update(manager, render: ["spotify": [10]])
    expect(factory.events == ["start spotify@speakers/[10]", "stop spotify@speakers/[10]"], "\(factory.events)")
}

test("Failed tap: error is visible, retry only after the backoff") {
    let (manager, factory) = makeManager()
    factory.failing = ["spotify"]
    update(manager, render: ["spotify": [10]], now: 100)
    expect(manager.errors["spotify"] != nil)
    let attempts = factory.taps.count

    update(manager, render: ["spotify": [10]], now: 102)
    expect(factory.taps.count == attempts, "no attempt during the backoff")

    update(manager, render: ["spotify": [10, 11]], now: 102)
    expect(factory.taps.count == attempts + 1, "new processes -> retry right away")

    factory.failing = []
    update(manager, render: ["spotify": [10, 11]], now: 200)
    expect(manager.errors["spotify"] == nil)
    expect(factory.taps.last?.isRunning == true)
}

test("Only silence from a playing app: the tap is suspended until retried") {
    let (manager, factory) = makeManager()
    update(manager, render: ["spotify": [10]])
    _ = manager.readLevels(playingApps: ["spotify"], now: 0)
    _ = manager.readLevels(playingApps: ["spotify"], now: TapManager.silenceTimeout + 1)
    expect(manager.suspended == ["spotify"])
    expect(factory.taps[0].isRunning == false, "app audible again")

    update(manager, render: ["spotify": [10]])
    expect(factory.taps.count == 1, "suspended stays suspended")

    manager.retrySuspended()
    update(manager, render: ["spotify": [10]])
    expect(factory.taps.count == 2 && factory.taps[1].isRunning)
}

test("Once capture has worked, silence is real silence") {
    let (manager, factory) = makeManager()
    update(manager, render: ["spotify": [10]], meter: ["teams": [20]])
    factory.taps.first { $0.configuration.appID == "teams" }?.level = 0.2
    _ = manager.readLevels(playingApps: ["spotify"], now: 0)
    _ = manager.readLevels(playingApps: ["spotify"], now: TapManager.silenceTimeout + 1)
    expect(manager.suspended.isEmpty)
}

// MARK: - Localization

let stringsSource = "Sources/Hushover/Localization/Strings.swift"

/// Keys as Foundation builds them: string interpolations become `%@`.
func localizationKeys(inSwift source: String) -> Set<String> {
    let literal = try! NSRegularExpression(pattern: #"String\(localized:\s*"((?:[^"\\]|\\.)*)""#)
    let interpolation = try! NSRegularExpression(pattern: #"\\\([^)]*\)"#)
    var keys = Set<String>()
    for match in literal.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
        let raw = String(source[Range(match.range(at: 1), in: source)!])
        keys.insert(interpolation.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "%@"))
    }
    return keys
}

func loadStrings(_ path: String) throws -> [String: String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try unwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
}

func placeholderCount(_ text: String) -> Int {
    text.components(separatedBy: "%@").count - 1
}

test("Every user-facing text has a German translation") {
    let keys = localizationKeys(inSwift: try String(contentsOfFile: stringsSource, encoding: .utf8))
    let german = try loadStrings("Resources/de.lproj/Localizable.strings")
    expect(keys.count > 50, "only \(keys.count) keys found – broken pattern?")
    for key in keys.sorted() {
        guard let translation = german[key] else { expect(false, "missing: \(key)"); continue }
        expect(!translation.isEmpty, "empty: \(key)")
        expect(placeholderCount(translation) == placeholderCount(key), "placeholders don't match: \(key)")
    }
    for key in german.keys.sorted() where !keys.contains(key) {
        expect(false, "unused: \(key)")
    }
}

test("Translations are found at runtime, including placeholders") {
    let german = try unwrap(Bundle(path: "Resources/de.lproj"))
    let app = "Spotify"
    expect(String(localized: "Quit", bundle: german) == "Beenden")
    expect(String(localized: "Volume \(app)", bundle: german) == "Lautstärke Spotify")
    expect(String(localized: "\(app) ↓ during \("Teams")", bundle: german) == "Spotify ↓ bei Teams")
}

test("The other language files are valid") {
    let permissions = try loadStrings("Resources/de.lproj/InfoPlist.strings")
    expect(permissions.keys.sorted() == ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"])
    expect(try loadStrings("Resources/en.lproj/Localizable.strings").isEmpty)
}

test("User-facing texts live only in Strings.swift") {
    let uiLiteral = try NSRegularExpression(pattern:
        #"\b(Text|Button|Toggle|Label|Picker|LabeledContent|Window|Section)\(\s*"|\.(help|accessibilityLabel|accessibilityValue)\(\s*"|String\(localized:"#)
    let files = try unwrap(FileManager.default.enumerator(atPath: "Sources/Hushover")).compactMap { $0 as? String }
    for file in files where file.hasSuffix(".swift") && !stringsSource.hasSuffix(file) {
        let source = try String(contentsOfFile: "Sources/Hushover/\(file)", encoding: .utf8)
        for match in uiLiteral.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let line = source[..<Range(match.range, in: source)!.lowerBound].components(separatedBy: "\n").count
            expect(false, "\(file):\(line) – move this text to Strings.swift")
        }
    }
}

struct Missing: Error {}
func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
}

// MARK: - Result

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
