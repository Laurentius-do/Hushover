import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus?
    let context: String

    init(status: OSStatus? = nil, _ context: String) {
        self.status = status
        self.context = context
    }

    var description: String {
        status.map { L10n.failed(context, status: String($0)) } ?? context
    }
}

func caCheck(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, context()) }
}

/// Thin wrappers around the C property API.
enum CA {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// For plain value properties (IDs, flags, sample rates, stream formats) only.
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        let status = withUnsafeMutableBytes(of: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
        try caCheck(status, L10n.readProperty)
        return result
    }

    static func bool(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        ((try? value(object, selector, initial: UInt32(0))) ?? 0) != 0
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    // MARK: Devices

    static var defaultOutputDevice: AudioDeviceID? {
        let id = (try? value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown)) ?? unknown
        return id == unknown ? nil : id
    }

    static var defaultInputDevice: AudioDeviceID? {
        let id = (try? value(systemObject, kAudioHardwarePropertyDefaultInputDevice, initial: unknown)) ?? unknown
        return id == unknown ? nil : id
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func sampleRate(_ device: AudioDeviceID) -> Double {
        (try? value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
    }

    static func streams(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope)
    }

    static func streamCount(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        streams(device, scope).count
    }

    /// The format the IOProc sees for this stream, if it's 32-bit float PCM – the only format we process.
    static func float32Format(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        guard let format = try? value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return nil }
        return format
    }

    /// The physical input device an app is currently recording from, e.g. the mic Teams uses in a call.
    static func inputDevice(usedBy app: AudioApp) -> AudioDeviceID? {
        for process in app.processObjects {
            for device in objectIDs(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) {
                // Voice processing records through a private aggregate device; look through it.
                let candidates = [device] + objectIDs(device, kAudioAggregateDevicePropertyActiveSubDeviceList)
                if let physical = candidates.first(where: { isPhysicalInput($0) }) { return physical }
            }
        }
        return nil
    }

    private static func isPhysicalInput(_ device: AudioDeviceID) -> Bool {
        let transport = (try? value(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        return transport != kAudioDeviceTransportTypeAggregate && streamCount(device, kAudioObjectPropertyScopeInput) > 0
    }

    /// Tells the HAL which streams an IOProc actually uses. Streams nobody uses aren't started at all,
    /// so Hushover never switches on a device's microphone just because it plays audio through that device.
    static func setStreamUsage(_ device: AudioDeviceID, _ procID: AudioDeviceIOProcID, scope: AudioObjectPropertyScope,
                               isOn: (_ index: Int) -> Bool) throws {
        let count = streamCount(device, scope)
        guard count > 0 else { return }
        guard let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams),
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) else {
            throw CoreAudioError(L10n.streamUsageUnavailable)
        }

        let size = flagsOffset + count * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), toByteOffset: 0, as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(count), toByteOffset: countOffset, as: UInt32.self)
        for index in 0..<count {
            raw.storeBytes(of: isOn(index) ? 1 : 0, toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }

        var addr = address(kAudioDevicePropertyIOProcStreamUsage, scope)
        try caCheck(AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(size), raw), L10n.setStreamUsage)
    }

    // MARK: Change notifications

    /// Listener blocks are delivered on the main queue.
    @discardableResult
    static func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ block: @escaping AudioObjectPropertyListenerBlock) -> Bool {
        var addr = address(selector)
        return AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr
    }

    static func removeListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector)
        AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
    }
}

/// RMS over all samples of a Float32 buffer.
func bufferRMS(_ buffer: AudioBuffer) -> Float? {
    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mDataByteSize > 0 else { return nil }
    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    var sum: Float = 0
    for i in 0..<count { sum += data[i] * data[i] }
    return sqrtf(sum / Float(count))
}
