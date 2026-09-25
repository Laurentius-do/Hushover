import Foundation

enum RuleState: Equatable {
    case disabled
    /// Trigger app isn't in a call.
    case idle
    /// In a call, nobody is speaking.
    case listening
    case speaking(bySelf: Bool)

    var label: String {
        switch self {
        case .disabled: L10n.stateOff
        case .idle: L10n.stateWaiting
        case .listening: L10n.stateMeetingQuiet
        case .speaking(let bySelf): bySelf ? L10n.stateYouSpeak : L10n.stateSomeoneSpeaks
        }
    }
}

/// Turns the rules plus the current levels into a smoothed duck factor per target app.
/// Pure logic without audio or UI dependencies, so it can be unit-tested.
struct RuleEvaluator {
    enum Tuning {
        /// Consecutive ticks above a threshold before it counts as speech (filters clicks and typing).
        static let speechTicksRequired = 2
        /// Time constant for getting quieter.
        static let attackSeconds: Double = 0.12
        /// The release time of a rule spans about three time constants.
        static let releaseTimeConstants: Double = 3
        static let minimumTimeConstant: Double = 0.05
        /// A duck factor this close to 1 counts as fully restored.
        static let restoredFactor: Float = 0.995
    }

    struct Input {
        var automationEnabled: Bool
        var rules: [DuckRule]
        /// Rules whose trigger app is currently in a call (or playing, depending on the rule).
        var activeRuleIDs: Set<UUID>
        /// `nil` while the microphone isn't measured.
        var micDB: Float?
        var appLevelDB: [String: Float]
        var now: TimeInterval
        var deltaTime: TimeInterval
    }

    private struct Speech {
        var time: TimeInterval
        var bySelf: Bool
    }

    private(set) var states: [UUID: RuleState] = [:]
    /// Smoothed factor per target app; apps back at full volume are absent.
    private(set) var duckFactors: [String: Float] = [:]

    private var speechTicks: [UUID: Int] = [:]
    private var lastSpeech: [UUID: Speech] = [:]
    /// Release time per target app, remembered so the fade-up after a call keeps using the rule's setting.
    private var releaseSeconds: [String: Double] = [:]

    mutating func step(_ input: Input) {
        var targets: [String: Float] = [:]
        var activeRelease: [String: Double] = [:]
        var states: [UUID: RuleState] = [:]

        for rule in input.rules {
            guard input.automationEnabled, rule.isUsable else {
                states[rule.id] = .disabled
                continue
            }
            guard input.activeRuleIDs.contains(rule.id) else {
                states[rule.id] = .idle
                speechTicks[rule.id] = nil
                lastSpeech[rule.id] = nil
                continue
            }

            let micHit = rule.useMicrophone && (input.micDB ?? silenceDB) > Float(rule.micThresholdDB)
            let remoteHit = rule.useTriggerAudio && (input.appLevelDB[rule.triggerAppID] ?? silenceDB) > Float(rule.triggerThresholdDB)
            let ticks = (micHit || remoteHit) ? (speechTicks[rule.id] ?? 0) + 1 : 0
            speechTicks[rule.id] = ticks
            if ticks >= Tuning.speechTicksRequired {
                lastSpeech[rule.id] = Speech(time: input.now, bySelf: micHit)
            }

            let factor: Double
            if let speech = lastSpeech[rule.id], input.now - speech.time < rule.holdSeconds {
                states[rule.id] = .speaking(bySelf: speech.bySelf)
                factor = rule.speechLevel
            } else {
                states[rule.id] = .listening
                factor = rule.pauseLevel
            }
            targets[rule.targetAppID] = min(targets[rule.targetAppID] ?? 1, Float(factor))
            activeRelease[rule.targetAppID] = max(activeRelease[rule.targetAppID] ?? 0, rule.releaseSeconds)
        }

        // Forget state of deleted rules.
        let ruleIDs = Set(input.rules.map(\.id))
        speechTicks = speechTicks.filter { ruleIDs.contains($0.key) }
        lastSpeech = lastSpeech.filter { ruleIDs.contains($0.key) }
        self.states = states
        releaseSeconds.merge(activeRelease) { $1 }

        // Smooth: duck fast, recover slowly.
        var factors: [String: Float] = [:]
        for app in Set(duckFactors.keys).union(targets.keys) {
            let target = targets[app] ?? 1
            let current = duckFactors[app] ?? 1
            let timeConstant = target < current
                ? Tuning.attackSeconds
                : max((releaseSeconds[app] ?? DuckRule.secondsRange.upperBound) / Tuning.releaseTimeConstants, Tuning.minimumTimeConstant)
            let next = current + (target - current) * Float(1 - exp(-input.deltaTime / timeConstant))
            if !(target == 1 && next > Tuning.restoredFactor) { factors[app] = next }
        }
        duckFactors = factors
        releaseSeconds = releaseSeconds.filter { factors[$0.key] != nil || activeRelease[$0.key] != nil }
    }
}
