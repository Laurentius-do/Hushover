import Foundation
import Synchronization

/// A Float shared between the real-time IO thread and the main thread, stored as its bit pattern.
struct AtomicFloat: ~Copyable, Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) {
        bits = Atomic(value.bitPattern)
    }

    func load() -> Float {
        Float(bitPattern: bits.load(ordering: .relaxed))
    }

    func store(_ value: Float) {
        bits.store(value.bitPattern, ordering: .relaxed)
    }
}

/// Lock-free hand-off of audio levels from an IO thread to the main thread.
/// Peak and block count share one 64-bit word, so a read never sees a block's count without its peak.
final class LevelHandoff: Sendable {
    /// High 32 bits: peak RMS as Float bits. Low 32 bits: number of blocks.
    private let state = Atomic<UInt64>(0)

    /// IO thread: records one block's RMS.
    func push(_ rms: Float) {
        let rms = rms.isFinite ? rms : 0
        var current = state.load(ordering: .relaxed)
        while true {
            let sample = Self.unpack(current)
            let desired = Self.pack(peak: max(sample.peak, rms), blocks: sample.blocks &+ 1)
            let (exchanged, original) = state.compareExchange(expected: current, desired: desired, ordering: .releasing)
            if exchanged { return }
            current = original
        }
    }

    /// Main thread: the highest RMS since the last call and how many blocks arrived in between.
    func take() -> LevelSample {
        Self.unpack(state.exchange(0, ordering: .acquiring))
    }

    private static func pack(peak: Float, blocks: UInt32) -> UInt64 {
        UInt64(peak.bitPattern) << 32 | UInt64(blocks)
    }

    private static func unpack(_ value: UInt64) -> LevelSample {
        LevelSample(peak: Float(bitPattern: UInt32(truncatingIfNeeded: value >> 32)),
                    blocks: UInt32(truncatingIfNeeded: value))
    }
}

struct LevelSample {
    var peak: Float
    var blocks: UInt32
}

/// Audio blocks and UI ticks don't line up (a block may span several ticks), so a tick without a new
/// block repeats the previous value – until nothing has arrived for a while, then it reads as silence.
struct LevelHold {
    static let maxStaleReads = 10

    private var value: Float = 0
    private var staleReads = 0

    mutating func update(_ sample: LevelSample) -> Float {
        if sample.blocks > 0 || sample.peak > 0 {
            value = sample.peak
            staleReads = 0
        } else {
            staleReads += 1
            if staleReads > Self.maxStaleReads { value = 0 }
        }
        return value
    }
}

/// Linear RMS -> dBFS, floored at `silenceDB`.
let silenceDB: Float = -100

func decibels(_ linear: Float) -> Float {
    linear > 0.00001 ? max(20 * log10f(linear), silenceDB) : silenceDB
}
