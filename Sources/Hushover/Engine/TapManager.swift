import CoreAudio
import Foundation
import Observation
import os

private let log = Logger(subsystem: "laurentius.Hushover", category: "taps")

enum TapMode { case render, meter }

struct TapOutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
}

struct TapConfiguration {
    let appID: String
    let processObjects: [AudioObjectID]
    let mode: TapMode
    let output: TapOutputDevice
    let gain: Float
}

/// What `TapManager` needs from a tap. `AppAudioTap` is the real one; tests use a fake.
protocol ManagedTap: AnyObject {
    var processObjects: [AudioObjectID] { get }
    var output: TapOutputDevice { get }
    var gain: Float { get set }
    /// The device's stream layout changed underneath the tap; it outputs silence and must be replaced.
    var needsRebuild: Bool { get }
    func start() throws
    func stop()
    /// Current level (linear RMS) of the tapped app, before gain.
    func readLevel() -> Float
    /// Re-reads sample rate and stream layout of the device, which can change while running.
    func refreshDeviceState()
}

/// Creates, replaces and removes the process taps the engine asks for.
@MainActor
@Observable
final class TapManager {
    /// If an app plays but its tap delivers only silence for this long – and no tap has ever received
    /// audio – system audio capture is most likely not permitted.
    static let silenceTimeout: TimeInterval = 5

    private(set) var errors: [String: String] = [:]
    /// Apps whose taps were removed because they only delivered silence, so the apps are audible again.
    /// They stay untapped until the user retries.
    private(set) var suspended: Set<String> = []

    @ObservationIgnored private let makeTap: (TapConfiguration) -> any ManagedTap
    @ObservationIgnored private var renderTaps: [String: any ManagedTap] = [:]
    @ObservationIgnored private var meterTaps: [String: any ManagedTap] = [:]
    @ObservationIgnored private var failures: [String: Failure] = [:]
    @ObservationIgnored private var output: TapOutputDevice?
    @ObservationIgnored private var silentSince: [String: TimeInterval] = [:]
    @ObservationIgnored private var reportedRebuilds: Set<ObjectIdentifier> = []
    /// Set once any tap received real audio: capturing works, so silence from now on is genuine silence.
    @ObservationIgnored private var captureVerified = false

    private struct Failure {
        var processes: [AudioObjectID]
        var backoff = Backoff()
    }

    init(makeTap: @escaping (TapConfiguration) -> any ManagedTap) {
        self.makeTap = makeTap
    }

    var isEmpty: Bool { renderTaps.isEmpty && meterTaps.isEmpty }

    func update(render: [String: [AudioObjectID]], meter: [String: [AudioObjectID]],
                output: TapOutputDevice, gain: (String) -> Float, now: TimeInterval) {
        if output != self.output {
            // Existing taps keep running until their replacements on the new device are up (see `sync`).
            failures = [:]
            self.output = output
        }

        sync(&renderTaps, wanted: render.filter { !suspended.contains($0.key) }, mode: .render, gain: gain, now: now)
        sync(&meterTaps, wanted: meter, mode: .meter, gain: { _ in 1 }, now: now)

        let wanted = Set(render.keys).union(meter.keys)
        for id in errors.keys where !wanted.contains(id) { errors[id] = nil }
        failures = failures.filter { wanted.contains($0.key) }
        suspended = suspended.filter { render[$0] != nil }
        let live = Set(allTaps.map { ObjectIdentifier($0) })
        reportedRebuilds = reportedRebuilds.filter { live.contains($0) }
    }

    /// Current levels in dB of all tapped apps. Also detects taps that only deliver silence.
    func readLevels(playingApps: Set<String>, now: TimeInterval) -> [String: Float] {
        var levels: [String: Float] = [:]
        for (id, tap) in renderTaps.merging(meterTaps, uniquingKeysWith: { render, _ in render }) {
            let level = tap.readLevel()
            if level > 0 { captureVerified = true }
            levels[id] = decibels(level)
        }
        suspendSilentTaps(levels: levels, playingApps: playingApps, now: now)
        return levels
    }

    /// True once for every tap that newly needs a rebuild, so the caller can trigger a single update.
    func takeRebuildRequests() -> Bool {
        let pending = allTaps.filter { $0.needsRebuild && !reportedRebuilds.contains(ObjectIdentifier($0)) }
        for tap in pending { reportedRebuilds.insert(ObjectIdentifier(tap)) }
        return !pending.isEmpty
    }

    func applyGains(_ gain: (String) -> Float) {
        for (id, tap) in renderTaps { tap.gain = gain(id) }
    }

    func refreshDeviceState() {
        allTaps.forEach { $0.refreshDeviceState() }
    }

    func retrySuspended() {
        suspended = []
        silentSince = [:]
        failures = [:]
    }

    func stopAll() {
        allTaps.forEach { $0.stop() }
        renderTaps = [:]
        meterTaps = [:]
        silentSince = [:]
    }

    // MARK: - Private

    private var allTaps: [any ManagedTap] {
        Array(renderTaps.values) + Array(meterTaps.values)
    }

    private func sync(_ taps: inout [String: any ManagedTap], wanted: [String: [AudioObjectID]],
                      mode: TapMode, gain: (String) -> Float, now: TimeInterval) {
        for (id, tap) in taps where wanted[id] == nil {
            tap.stop()
            taps[id] = nil
        }
        guard let output else { return }

        for (id, processes) in wanted {
            let existing = taps[id]
            if let existing, existing.processObjects == processes, existing.output == output, !existing.needsRebuild { continue }
            // Retry right away if the app's processes changed, otherwise wait for the backoff.
            if let failure = failures[id], failure.processes == processes, !failure.backoff.canRetry(at: now) { continue }

            // Make before break: the old tap keeps the app muted until the new one runs. Stopping it first
            // would let the app play at full volume for a moment, e.g. when switching to headphones.
            let tap = makeTap(TapConfiguration(appID: id, processObjects: processes, mode: mode, output: output, gain: gain(id)))
            do {
                try tap.start()
                existing?.stop()
                taps[id] = tap
                failures[id] = nil
                errors[id] = nil
            } catch {
                tap.stop()
                var failure = failures[id].flatMap { $0.processes == processes ? $0 : nil } ?? Failure(processes: processes)
                failure.backoff.recordFailure(at: now)
                failures[id] = failure
                errors[id] = String(describing: error)
                log.error("Tap for \(id, privacy: .public) failed (\(failure.backoff.failures)×): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A muted app whose tap delivers nothing would stay silent. Until capturing is proven to work,
    /// remove such taps so the app is audible again, and tell the user.
    private func suspendSilentTaps(levels: [String: Float], playingApps: Set<String>, now: TimeInterval) {
        guard !captureVerified else {
            silentSince = [:]
            return
        }
        var stillSilent: [String: TimeInterval] = [:]
        for id in renderTaps.keys where playingApps.contains(id) && (levels[id] ?? silenceDB) <= silenceDB {
            stillSilent[id] = silentSince[id] ?? now
        }
        silentSince = stillSilent

        for (id, since) in stillSilent where now - since > Self.silenceTimeout {
            renderTaps[id]?.stop()
            renderTaps[id] = nil
            silentSince[id] = nil
            suspended.insert(id)
            log.notice("Tap for \(id, privacy: .public) suspended: only silence received, capture permission is probably missing")
        }
    }
}
