import AVFoundation
import CoreAudio

/// Measures the level of one input device. Nothing is recorded or stored.
final class MicLevelMonitor {
    private(set) var deviceID: AudioDeviceID?
    private(set) var lastError: String?

    var isRunning: Bool { deviceID != nil }

    /// Called once the user has granted microphone access, so measuring can start right away.
    var onAccessGranted: (@MainActor @Sendable () -> Void)?

    private var ioProcID: AudioDeviceIOProcID?
    private let meter = LevelHandoff()
    private var levelHold = LevelHold()

    deinit {
        stop()
    }

    func requestAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        let onAccessGranted = onAccessGranted
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else { return }
            Task { @MainActor in onAccessGranted?() }
        }
    }

    /// Starts measuring `device`, switching over if another device is being measured.
    func start(device: AudioDeviceID) {
        guard device != deviceID else { return }
        stop()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            requestAccessIfNeeded()
            return
        default:
            lastError = L10n.micNoAccess
            return
        }

        guard let stream = CA.streams(device, kAudioObjectPropertyScopeInput).first, CA.float32Format(stream) != nil else {
            lastError = L10n.micUnsupportedFormat
            return
        }

        let meter = meter
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let first = buffers.first, let rms = bufferRMS(first) { meter.push(rms) }
        }
        guard status == noErr, let procID else {
            lastError = L10n.micCouldNotOpen
            return
        }

        do {
            // Only listen – don't run the device's output side, if it has one.
            try CA.setStreamUsage(device, procID, scope: kAudioObjectPropertyScopeOutput) { _ in false }
            try caCheck(AudioDeviceStart(device, procID), L10n.startMicrophone)
        } catch {
            AudioDeviceDestroyIOProcID(device, procID)
            lastError = L10n.micCouldNotStart
            return
        }

        ioProcID = procID
        deviceID = device
        lastError = nil
    }

    func stop() {
        if let deviceID, let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
        deviceID = nil
    }

    /// Current level (linear RMS) of the microphone.
    func readLevel() -> Float {
        levelHold.update(meter.take())
    }
}
