# Hushover

*Your music makes room when someone speaks.*

Hushover is a small menu bar app for macOS that gives every app its own volume – and turns your music down automatically whenever someone talks in a call.

Picture this: music is playing while you work. An online meeting starts. As soon as you or anyone else speaks, the music fades into the background. When the conversation pauses, it comes back up. No reaching for the volume keys, no forgetting to pause the music.

---

## Features

- **Volume per app** – a slider for every app that plays audio, independent of the system volume.
- **Automatic ducking** – rules like *"make my music quieter when someone speaks in my meeting app"*.
- **Knows who's talking** – reacts to your own voice (microphone) and to the other participants (the call app's audio).
- **Only during calls** – rules kick in only while the call app actually uses the microphone, so a notification sound from your meeting app won't dim your music.
- **Smooth, not jumpy** – the music drops quickly when speech starts and fades back up gently after a short pause.
- **Works with any app** – music and podcast players, browsers, video calls, chat apps – anything that plays audio.

## Using Hushover

Hushover lives in the menu bar – there's no Dock icon. The bars icon dips and shows a small speech bubble while music is being lowered.

Can't see the icon? With many menu bar items it can end up hidden behind the notch. Open Hushover again from Finder or Spotlight while it's running, and the rules window appears.

**The menu** shows every app that's playing audio with its own volume slider and level meter, the state of your rules (*Waiting*, *Meeting – quiet*, *You're speaking*, *Someone is speaking*), a switch to pause all automation and the *Launch at login* option. The ⓘ button next to *Quit* shows the version.

**Rules** are edited in the rules window (*Edit Rules…*). Hushover starts without any rules – it can't know which apps you use. Choose *Create First Rule…* in the menu, then pick the app to make quieter (e.g. your music player) and the app whose calls it should react to (e.g. your meeting app). Once both are chosen, you can fine-tune the rule:

| Setting | What it does |
| --- | --- |
| Volume while someone speaks | How quiet the music gets during speech (relative to its normal volume) |
| Volume during pauses | How loud it is during pauses in a call – 100 % means back to normal |
| React to my voice | Use your microphone to detect when *you* speak |
| React to other participants | Use the call app's audio to detect when *others* speak |
| Thresholds | How loud something has to be to count as speech; live meters help you set them |
| Stay quiet after speech for | How long the music stays down after the last word |
| Get louder again over | How long the fade back up takes |

**Tip:** if your microphone can hear the music coming out of your speakers, it may mistake it for speech. Raise the microphone threshold if the music keeps dipping.

## Privacy & permissions

On first launch macOS asks for two permissions:

- **Microphone** – to measure how loud you're speaking.
- **System audio recording** – to control each app's volume and to hear when others speak in a call.

Hushover only measures levels and passes audio through to your speakers. **Nothing is recorded, stored or sent anywhere.** The microphone is only in use while a call is running (or while the rules window is open for calibration) – you'll see macOS' orange indicator whenever it is.

If Hushover quits or crashes, every app immediately plays at its normal volume again.

## Installation

Hushover isn't distributed as a download yet; you build it from source. That takes about a minute and doesn't need Xcode.

**Requirements:** macOS 15 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/Laurentius-do/Hushover.git
cd Hushover
./Tools/create-signing-identity.sh   # once – lets macOS remember the permissions across updates
./install.sh                         # builds, installs to /Applications and starts Hushover
```

Then open Hushover's menu and create your first rule. To start Hushover automatically, switch on *Launch at login* in its menu. To update, pull the latest changes and run `./install.sh` again.

## Limitations

- Speech is detected by loudness. Typing, coughing or music from speakers can occasionally count as speech; adjust the thresholds if that happens.
- Volume is controlled per app, not per tab or per call – a rule can't lower a video in one browser tab while keeping a browser-based meeting in another tab at full volume.
- Hushover can't make an app louder than its own volume setting.

<br>

---
---

# For developers

Everything below is about how Hushover works inside and how to build, test and extend it.

## Architecture

Hushover is a SwiftUI menu bar app (`LSUIElement`) built directly with `swiftc` in Swift 6 language mode – no Xcode project, no SwiftPM, no dependencies.

**Per-app volume.** For each controlled app, Hushover creates a Core Audio *process tap* (macOS 14.2+) with `mutedWhenTapped`, plus a private aggregate device made of the current output device and the tap. A real-time IO callback reads the tap stream and writes it to the output device with a smoothed gain. Taps and aggregate devices belong to Hushover's process, so the system removes them – and the apps are audible again – the moment Hushover exits.

**Detecting speech.**

- *Call active:* the trigger app's process reports `kAudioProcessPropertyIsRunningInput`.
- *Others speaking:* a second, unmuted tap measures the trigger app's output level.
- *You speaking:* an IOProc on the input device the call app actually uses (looking through voice-processing aggregates) measures the microphone level.

**Rule evaluation.** 30 times a second (only while something is happening) the levels go into the `RuleEvaluator`. It requires two consecutive ticks above a threshold before something counts as speech, applies the hold time, and smooths the resulting factor: fast attack (~0.12 s), configurable release.

**Only the streams that are needed.** An aggregate device would normally also start the output device's own input streams. Hushover sets `kAudioDevicePropertyIOProcStreamUsage` so only the tap stream runs – playing audio through a device never switches on its microphone, and a microphone is never played back.

**Robustness.**

- New taps start before old ones stop (*make before break*), so a device change never lets an app blast at full volume.
- Stream layout changes (e.g. the output device gaining an input stream) are detected; the tap outputs silence and is rebuilt.
- A tap that only ever delivers silence is removed after 5 s, since capture permission is probably missing.
- Failed taps are retried with exponential backoff.
- The app reacts to Core Audio change notifications instead of polling, with a 10 s safety net.

**Threading.** The real-time callbacks share only atomics with the main thread (`Synchronization.Atomic`); no locks, allocations or reference counting on the audio thread.

## Project structure

```
Sources/Hushover/
├── HushoverApp.swift            App entry, menu bar extra, app delegate (reopen → rules window), SIGTERM handling
├── Audio/
│   ├── AppAudioTap.swift        Process tap + aggregate device + real-time callback
│   ├── AudioSystemMonitor.swift Apps using audio, their play/record state, default devices
│   ├── MicLevelMonitor.swift    Microphone level via an IOProc on the input device
│   ├── Levels.swift             Lock-free level/gain hand-off between threads
│   ├── ChannelMapping.swift     Stereo tap → output channels (mono downmix for mono devices)
│   └── CoreAudioHelpers.swift   Thin wrappers around the Core Audio C API
├── Engine/
│   ├── DuckingEngine.swift      Coordination: which taps and mic are needed, update loop
│   ├── RuleEvaluator.swift      Pure rule logic: speech detection, smoothing
│   ├── TapManager.swift         Tap lifecycle, backoff, rebuilds, silence detection
│   ├── Backoff.swift            Retry delays
│   ├── Settings.swift           Rules & volumes in UserDefaults, tolerant decoding
│   └── LaunchAtLogin.swift      Login item via SMAppService
├── Localization/Strings.swift   Every user-facing text
└── Views/                       Menu, rules window (AppKit window hosting SwiftUI), meters, menu bar icon
Resources/                       Info.plist, entitlements, app icon, translations (*.lproj)
Tests/main.swift                 Unit tests (see below)
Tools/                           Signing identity setup, icon generator
```

## Building

| Command | What it does |
| --- | --- |
| `./build.sh` | Builds `build/Hushover.app` |
| `./install.sh` | Builds, quits the running instance, installs to `/Applications`, starts it |
| `./test.sh` | Builds and runs the unit tests |
| `./Tools/make-icon.sh` | Regenerates `Resources/AppIcon.icns` from `Tools/make-icon.swift` |

With only the Command Line Tools installed, `build.sh` uses the macOS 26 SDK: SwiftUI in the macOS 27 SDK needs a macro plugin that ships only with Xcode. Override with `SDK=/path/to/sdk ./build.sh`.

## Code signing

The app is always signed with the **hardened runtime** and a single entitlement (`com.apple.security.device.audio-input`). This blocks code injection such as `DYLD_INSERT_LIBRARIES`, which would otherwise inherit Hushover's microphone and audio capture permissions.

macOS ties those permissions to the signature. Ad-hoc signatures change with every build, so `./Tools/create-signing-identity.sh` creates a stable, self-signed identity instead. It lives in its **own keychain** (`~/Library/Keychains/hushover-signing.keychain-db`), not the login keychain. Anything that can use the key can sign itself as Hushover and inherit its permissions, so `build.sh` unlocks that keychain only while signing – asking for its password – and locks it again afterwards.

Without the identity, or without a terminal to enter the password, `build.sh` falls back to ad-hoc signing.

## Tests

`./test.sh` compiles everything that doesn't need real audio devices or UI together with `Tests/main.swift`, a small self-contained test runner (the Command Line Tools make XCTest awkward to use). The tests cover:

- rule evaluation – speech detection, hold, attack/release, several rules per app
- level hand-off and channel mapping
- backoff timing
- settings decoding, sanitizing and recovery from unreadable data
- `TapManager` with a fake tap factory – make-before-break, rebuilds, backoff, suspension
- localization – every text translated, no orphans, placeholders intact, no texts bypassing `Strings.swift`

Core Audio itself (taps, devices, IOProcs) isn't covered and needs manual testing.

## Localization

English is the source language. All user-facing texts are defined in `Sources/Hushover/Localization/Strings.swift` via `String(localized:)`; views never contain literal texts.

- German: `Resources/de.lproj/Localizable.strings`, permission prompts in `Resources/de.lproj/InfoPlist.strings`.
- Placeholders are always strings (`%@`) – format numbers before passing them in.
- To add a language, create `Resources/<code>.lproj/` with both files and add the code to `CFBundleLocalizations` in `Resources/Info.plist`. The tests check German only; extend them for new languages.

## Version & About panel

The About panel (ⓘ in the menu) reads everything from `Resources/Info.plist`: the version from `CFBundleShortVersionString`, the copyright from `NSHumanReadableCopyright` and the source code link from `HushoverRepositoryURL`. Without that last key the panel shows no link.

## Debugging

Hushover logs tap failures and suspensions to the unified log:

```bash
log stream --predicate 'subsystem == "laurentius.Hushover"'
```

Settings are stored as JSON under the key `settings.v1` in `laurentius.Hushover`'s user defaults. If they can't be read, a copy is kept under `settings.v1.unreadable` before Hushover starts over with empty settings.
