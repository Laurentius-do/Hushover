import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// State shared with the real-time IO thread. Everything is atomic, and the IO block keeps this object
/// alive until the IOProc is destroyed, so there is no manual memory management.
private final class TapShared: Sendable {
    let targetGain: AtomicFloat
    /// Only touched by the IO thread; atomic so the class can be shared safely.
    let currentGain: AtomicFloat
    let rampCoefficient: AtomicFloat
    /// Measured before gain.
    let level = LevelHandoff()
    /// Set when the stream layout no longer matches what the tap was built for.
    let layoutChanged = Atomic<Bool>(false)

    init(gain: Float) {
        targetGain = AtomicFloat(gain)
        currentGain = AtomicFloat(gain)
        rampCoefficient = AtomicFloat(1)
    }
}

/// Taps the audio of one app via a Core Audio process tap (macOS 14.2+).
///
/// - `.render`: the app is muted by the tap and we play its audio ourselves with our own gain.
/// - `.meter`: the app keeps playing normally; we only measure its level.
///
/// Both modes run through a private aggregate device consisting of the current output device plus the tap.
/// Taps and aggregate devices are owned by our process, so if Hushover quits or crashes,
/// the app's audio immediately returns to normal.
final class AppAudioTap: ManagedTap {
    let appID: String
    let processObjects: [AudioObjectID]
    let mode: TapMode
    let output: TapOutputDevice

    private let shared: TapShared
    private var levelHold = LevelHold()
    private var tapID = CA.unknown
    private var aggregateID = CA.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var expectedInputStreams = 0

    init(_ configuration: TapConfiguration) {
        appID = configuration.appID
        processObjects = configuration.processObjects
        mode = configuration.mode
        output = configuration.output
        shared = TapShared(gain: configuration.gain)
    }

    deinit {
        stop()
    }

    var gain: Float {
        get { shared.targetGain.load() }
        set { shared.targetGain.store(max(0, min(newValue, 1))) }
    }

    var needsRebuild: Bool {
        shared.layoutChanged.load(ordering: .relaxed)
    }

    func readLevel() -> Float {
        levelHold.update(shared.level.take())
    }

    /// The output device can change its sample rate (gain smoothing is ~15 ms, so its coefficient depends
    /// on it) and its stream layout (e.g. an input stream appears) while running.
    func refreshDeviceState() {
        guard aggregateID != CA.unknown else { return }
        let sampleRate = max(CA.sampleRate(aggregateID), 8000)
        shared.rampCoefficient.store(Float(1 - exp(-1 / (0.015 * sampleRate))))
        if CA.streamCount(aggregateID, kAudioObjectPropertyScopeInput) != expectedInputStreams {
            shared.layoutChanged.store(true, ordering: .relaxed)
        }
    }

    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "Hushover \(appID)"
        description.isPrivate = true
        description.muteBehavior = mode == .render ? .mutedWhenTapped : .unmuted

        var tap = CA.unknown
        try caCheck(AudioHardwareCreateProcessTap(description, &tap), L10n.createTap(for: appID))
        tapID = tap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hushover \(appID)",
            kAudioAggregateDeviceUIDKey: "laurentius.Hushover.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = CA.unknown
        try caCheck(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                    L10n.createAggregate(for: appID))
        aggregateID = aggregate

        let tapStream = try locateTapStream()
        let expectedInputs = tapStream + 1
        expectedInputStreams = expectedInputs
        if mode == .render {
            guard CA.streams(aggregate, kAudioObjectPropertyScopeOutput).allSatisfy({ CA.float32Format($0) != nil }) else {
                throw CoreAudioError(L10n.outputUnsupportedFormat)
            }
        }
        refreshDeviceState()

        let shared = shared
        let render = mode == .render
        var procID: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            AppAudioTap.process(input: input, output: output, tapStream: tapStream, expectedInputs: expectedInputs,
                                shared: shared, render: render)
        }, L10n.createCallback(for: appID))
        guard let procID else { throw CoreAudioError(L10n.createCallback(for: appID)) }
        ioProcID = procID

        // Only the tap stream is needed. The output device's own inputs stay off, so its microphone is never
        // started – nor ever played back.
        try CA.setStreamUsage(aggregate, procID, scope: kAudioObjectPropertyScopeInput) { $0 == tapStream }
        if mode == .meter {
            try CA.setStreamUsage(aggregate, procID, scope: kAudioObjectPropertyScopeOutput) { _ in false }
        }

        try caCheck(AudioDeviceStart(aggregate, procID), L10n.startAudio(for: appID))
    }

    /// The aggregate lists the output device's own input streams first (e.g. a built-in mic), then the tap.
    /// Anything else is unexpected, and we refuse to run rather than risk playing back the wrong stream.
    private func locateTapStream() throws -> Int {
        let deviceInputs = CA.streamCount(output.id, kAudioObjectPropertyScopeInput)
        let aggregateInputs = CA.streams(aggregateID, kAudioObjectPropertyScopeInput)
        guard aggregateInputs.count == deviceInputs + 1 else {
            throw CoreAudioError(L10n.unexpectedStreamLayout(for: appID, found: String(aggregateInputs.count), expected: String(deviceInputs + 1)))
        }
        // A stereo mixdown tap has two channels.
        let tapChannels = (try? CA.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()))?.mChannelsPerFrame ?? 2
        guard let streamFormat = CA.float32Format(aggregateInputs[deviceInputs]),
              streamFormat.mChannelsPerFrame == tapChannels else {
            throw CoreAudioError(L10n.unexpectedTapFormat(for: appID))
        }
        return deviceInputs
    }

    func stop() {
        if aggregateID != CA.unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != CA.unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = CA.unknown
        tapID = CA.unknown
    }

    // MARK: - Real-time

    private static func process(input: UnsafePointer<AudioBufferList>,
                                output: UnsafeMutablePointer<AudioBufferList>,
                                tapStream: Int,
                                expectedInputs: Int,
                                shared: TapShared,
                                render: Bool) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        // If the device reconfigured (e.g. an input stream appeared), `tapStream` may now point at a
        // different stream – possibly the microphone. Play nothing and let the tap be rebuilt.
        guard inputs.count == expectedInputs else {
            shared.layoutChanged.store(true, ordering: .relaxed)
            silence(outputs)
            return
        }
        guard let tapData = inputs[tapStream].mData?.assumingMemoryBound(to: Float.self) else {
            silence(outputs)
            return
        }
        let tapBuffer = inputs[tapStream]
        let inChannels = max(Int(tapBuffer.mNumberChannels), 1)
        let inFrames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
        if let rms = bufferRMS(tapBuffer) { shared.level.push(rms) }

        guard render else {
            silence(outputs)
            return
        }

        let target = shared.targetGain.load()
        let rampCoefficient = shared.rampCoefficient.load()
        let startGain = shared.currentGain.load()
        var endGain = startGain
        var channelOffset = 0
        var totalOutChannels = 0
        for buffer in outputs { totalOutChannels += max(Int(buffer.mNumberChannels), 1) }

        for buffer in outputs {
            guard let outData = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = max(Int(buffer.mNumberChannels), 1)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)
            let frames = min(outFrames, inFrames)

            var gain = startGain
            for frame in 0..<frames {
                gain += (target - gain) * rampCoefficient
                for channel in 0..<outChannels {
                    let sample = ChannelMapping.sample(tapData, frame: frame, inChannels: inChannels,
                                                       outChannel: channelOffset + channel, totalOutChannels: totalOutChannels)
                    outData[frame * outChannels + channel] = sample * gain
                }
            }
            if frames < outFrames {
                (outData + frames * outChannels).update(repeating: 0, count: (outFrames - frames) * outChannels)
            }
            channelOffset += outChannels
            endGain = gain
        }
        shared.currentGain.store(endGain)
    }

    private static func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
    }
}
