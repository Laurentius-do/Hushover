import Foundation
import os

private let log = Logger(subsystem: "laurentius.Hushover", category: "settings")

/// "Make `target` quieter while someone is speaking in `trigger`."
struct DuckRule: Codable, Identifiable, Equatable {
    static let levelRange = 0.0...1.0
    static let thresholdRange = -70.0 ... -10.0
    static let secondsRange = 0.2...6.0

    var id = UUID()
    var isEnabled = true
    var targetAppID: String
    var triggerAppID: String

    /// Only active while the trigger app uses the microphone (i.e. a call is running).
    var requireTriggerMic = true

    /// Volume of the target while speech is detected, relative to its normal volume.
    var speechLevel: Double = 0.3
    /// Volume of the target during pauses in the call, relative to its normal volume.
    var pauseLevel: Double = 1.0

    var useMicrophone = true
    var micThresholdDB: Double = -42
    var useTriggerAudio = true
    var triggerThresholdDB: Double = -45

    /// Keep ducking this long after the last detected speech.
    var holdSeconds: Double = 1.5
    /// Time to fade back up after the hold time ended.
    var releaseSeconds: Double = 2.0

    /// New rules start without apps; the user picks both in the rules window.
    var isComplete: Bool { !targetAppID.isEmpty && !triggerAppID.isEmpty }

    /// Target and trigger must differ: taps work per app, so ducking the trigger app would lower the call itself.
    var targetsItself: Bool { isComplete && targetAppID == triggerAppID }

    var isUsable: Bool { isEnabled && isComplete && !targetsItself }

    init(targetAppID: String, triggerAppID: String) {
        self.targetAppID = targetAppID
        self.triggerAppID = triggerAppID
    }

    /// Tolerant decoding: missing or malformed fields fall back to their defaults, so adding a field
    /// in a future version doesn't throw away the user's rules.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(targetAppID: try c.decode(String.self, forKey: .targetAppID),
                  triggerAppID: try c.decode(String.self, forKey: .triggerAppID))
        id = c.value(.id, default: id)
        isEnabled = c.value(.isEnabled, default: isEnabled)
        requireTriggerMic = c.value(.requireTriggerMic, default: requireTriggerMic)
        speechLevel = c.value(.speechLevel, default: speechLevel)
        pauseLevel = c.value(.pauseLevel, default: pauseLevel)
        useMicrophone = c.value(.useMicrophone, default: useMicrophone)
        micThresholdDB = c.value(.micThresholdDB, default: micThresholdDB)
        useTriggerAudio = c.value(.useTriggerAudio, default: useTriggerAudio)
        triggerThresholdDB = c.value(.triggerThresholdDB, default: triggerThresholdDB)
        holdSeconds = c.value(.holdSeconds, default: holdSeconds)
        releaseSeconds = c.value(.releaseSeconds, default: releaseSeconds)
    }

    /// Keeps every value in the range the UI offers.
    mutating func sanitize() {
        speechLevel = speechLevel.clamped(to: Self.levelRange)
        pauseLevel = pauseLevel.clamped(to: Self.levelRange)
        micThresholdDB = micThresholdDB.clamped(to: Self.thresholdRange)
        triggerThresholdDB = triggerThresholdDB.clamped(to: Self.thresholdRange)
        holdSeconds = holdSeconds.clamped(to: Self.secondsRange)
        releaseSeconds = releaseSeconds.clamped(to: Self.secondsRange)
    }
}

struct AppSettings: Codable, Equatable {
    /// Volumes at or above this count as 100 % and are not stored.
    static let fullVolume = 0.995

    var automationEnabled = true
    /// Normal volume per app (0...1). Apps not listed play at 100 %.
    var volumes: [String: Double] = [:]
    var rules: [DuckRule] = []
    /// Names of apps we've seen, so rules stay readable while an app isn't running.
    var knownApps: [String: String] = [:]
    var showAllApps = false

    static let storageKey = "settings.v1"
    static let unreadableKey = "settings.v1.unreadable"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automationEnabled = c.value(.automationEnabled, default: automationEnabled)
        volumes = c.value(.volumes, default: volumes)
        // Decode rules one by one so a single broken rule doesn't take the others with it.
        rules = c.value(.rules, default: [LossyRule]()).compactMap(\.rule)
        knownApps = c.value(.knownApps, default: knownApps)
        showAllApps = c.value(.showAllApps, default: showAllApps)
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        // A fresh install starts without rules: we can't know which apps the user has.
        guard let data = defaults.data(forKey: storageKey) else { return AppSettings() }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.sanitize()
            return settings
        } catch {
            // Keep the unreadable data instead of silently overwriting it with defaults.
            log.error("Settings unreadable, kept a copy under \(unreadableKey): \(error)")
            defaults.set(data, forKey: unreadableKey)
            return AppSettings()
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
        } catch {
            log.error("Couldn't save settings: \(error)")
        }
    }

    mutating func sanitize() {
        volumes = volumes
            .mapValues { $0.clamped(to: DuckRule.levelRange) }
            .filter { $0.value < Self.fullVolume }
        for index in rules.indices { rules[index].sanitize() }
    }
}

private struct LossyRule: Decodable {
    let rule: DuckRule?

    init(from decoder: Decoder) throws {
        rule = try? DuckRule(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

extension Double {
    /// Clamps to `range`; NaN and infinity become the lower bound.
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

enum KnownApps {
    /// Offered in the pickers when installed, even while the app isn't running.
    static let presets: [String: String] = [
        "com.spotify.client": "Spotify",
        "com.apple.Music": L10n.appleMusic,
        "com.apple.podcasts": "Podcasts",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.teams2": "Microsoft Teams",
        "us.zoom.xos": "Zoom",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
    ]
}
