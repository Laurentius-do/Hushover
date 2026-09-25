import Foundation

/// Every user-facing text. English is the source language; translations live in
/// `Resources/<language>.lproj/Localizable.strings`. `./test.sh` checks that each key here is translated
/// and that views don't bypass this file.
///
/// Placeholders are always strings (`%@`): format numbers before passing them in.
enum L10n {
    // MARK: App & menu

    static let rulesWindowTitle = String(localized: "Automation Rules")
    static let automation = String(localized: "Automation")
    static let volumePerApp = String(localized: "Volume per App")
    static let noAppPlaying = String(localized: "No app is playing audio right now.")
    static let showAllApps = String(localized: "Show all apps with audio")
    static let noRules = String(localized: "No rules yet. A rule lowers an app automatically while someone speaks in a meeting.")
    static let createFirstRule = String(localized: "Create First Rule…")
    static let newRuleNotSetUp = String(localized: "New rule – not set up yet")
    static let editRules = String(localized: "Edit Rules…")
    static let quit = String(localized: "Quit")
    static let about = String(localized: "About Hushover")
    static let tagline = String(localized: "Your music makes room when someone speaks.")
    static let sourceCode = String(localized: "Source code on GitHub")
    static let beingLowered = String(localized: "Currently lowered automatically")
    static let microphoneLevel = String(localized: "Microphone level")
    static let launchAtLogin = String(localized: "Launch at login")
    static let loginItemNeedsApproval = String(localized: "Still needs to be allowed in Login Items.")
    static let open = String(localized: "Open")
    static let menuBarLowered = String(localized: "Hushover – music lowered")

    static func volume(of app: String) -> String {
        String(localized: "Volume \(app)")
    }

    static func level(of app: String) -> String {
        String(localized: "Level \(app)")
    }

    // MARK: Capture problems

    static let captureFailedTitle = String(localized: "Couldn't capture an app's audio")
    static let captureFailedHint = String(localized: "Check under Privacy & Security → Screen & System Audio Recording whether Hushover may record system audio.")
    static let openSystemSettings = String(localized: "Open System Settings")
    static let tryAgain = String(localized: "Try Again")

    static func pausedApps(_ apps: String) -> String {
        String(localized: "Paused so they stay audible: \(apps)")
    }

    // MARK: Level meters

    static let level = String(localized: "Level")
    static let silence = String(localized: "Silence")

    static func aboveThreshold(_ level: String) -> String {
        String(localized: "\(level), above the threshold")
    }

    static func belowThreshold(_ level: String) -> String {
        String(localized: "\(level), below the threshold")
    }

    // MARK: Rule states

    static let stateOff = String(localized: "Off", comment: "Rule state: rule or automation is switched off")
    static let stateWaiting = String(localized: "Waiting", comment: "Rule state: trigger app isn't in a call")
    static let stateMeetingQuiet = String(localized: "Meeting – quiet")
    static let stateYouSpeak = String(localized: "You're speaking")
    static let stateSomeoneSpeaks = String(localized: "Someone is speaking")

    // MARK: Rules window

    static let rulesIntro = String(localized: "A rule automatically lowers one app (e.g. your music player) as soon as someone speaks in another app (e.g. your meeting app) – you (microphone) or other participants (the app's audio). During pauses it gets louder again.")
    static let addRule = String(localized: "Add Rule")
    static let newRule = String(localized: "New Rule")
    static let chooseApp = String(localized: "Choose an app…")
    static let chooseBothApps = String(localized: "Choose both apps to set up the rule.")
    static let ruleEnabled = String(localized: "Rule enabled")
    static let makeQuieter = String(localized: "Make quieter")
    static let whenSpeakingIn = String(localized: "When someone speaks in")
    static let targetsItselfWarning = String(localized: "Target and trigger are the same app. The conversation itself would get quieter too, so the rule stays inactive.")
    static let speechVolume = String(localized: "Volume while someone speaks")
    static let pauseVolume = String(localized: "Volume during pauses")
    static let reactToMyVoice = String(localized: "React to my voice (microphone)")
    static let microphoneThreshold = String(localized: "Microphone threshold")
    static let holdAfterSpeech = String(localized: "Stay quiet after speech for")
    static let releaseOver = String(localized: "Get louder again over")
    static let deleteRule = String(localized: "Delete Rule")
    static let thresholdHelp = String(localized: "Green = above the threshold (counts as speech). Set the threshold just above the background noise. The level appears once the app is running or the microphone is active.")

    static func onlyDuringCalls(_ app: String) -> String {
        String(localized: "Only during calls (\(app) uses the microphone)")
    }

    static func reactToOthers(_ app: String) -> String {
        String(localized: "React to other participants (audio from \(app))")
    }

    static func threshold(of app: String) -> String {
        String(localized: "\(app) threshold")
    }

    static func ruleHeader(target: String, trigger: String) -> String {
        String(localized: "\(target) ↓ during \(trigger)")
    }

    static func seconds(_ value: String) -> String {
        String(localized: "\(value) s", comment: "Duration in seconds")
    }

    // MARK: Microphone

    static let micNoAccess = String(localized: "No microphone access – allow it under Privacy & Security → Microphone.")
    static let micUnsupportedFormat = String(localized: "The microphone uses an unsupported audio format")
    static let micCouldNotOpen = String(localized: "Couldn't open the microphone")
    static let micCouldNotStart = String(localized: "Couldn't start the microphone")

    // MARK: Core Audio errors

    static let readProperty = String(localized: "Read property")
    static let setStreamUsage = String(localized: "Set stream usage")
    static let streamUsageUnavailable = String(localized: "Couldn't set stream usage")
    static let outputUnsupportedFormat = String(localized: "The output device uses an unsupported audio format")
    static let startMicrophone = String(localized: "Start microphone")

    static func failed(_ action: String, status: String) -> String {
        String(localized: "\(action) failed (OSStatus \(status))")
    }

    static func createTap(for app: String) -> String {
        String(localized: "Create process tap for \(app)")
    }

    static func createAggregate(for app: String) -> String {
        String(localized: "Create aggregate device for \(app)")
    }

    static func createCallback(for app: String) -> String {
        String(localized: "Create audio callback for \(app)")
    }

    static func startAudio(for app: String) -> String {
        String(localized: "Start audio for \(app)")
    }

    static func unexpectedStreamLayout(for app: String, found: String, expected: String) -> String {
        String(localized: "Unexpected stream layout for \(app) (\(found) instead of \(expected))")
    }

    static func unexpectedTapFormat(for app: String) -> String {
        String(localized: "Tap stream for \(app) has an unexpected format")
    }

    // MARK: App names

    static let appleMusic = String(localized: "Music", comment: "Name of Apple's Music app")
}
