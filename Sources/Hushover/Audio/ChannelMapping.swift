/// How the tap's channels (a stereo mixdown) are spread over the output device's channels.
enum ChannelMapping {
    /// The sample for output channel `outChannel` (counted across all output buffers) in `frame`.
    ///
    /// A mono output device gets a mix of all input channels instead of only the left one.
    /// Otherwise channels repeat (L R L R … on multichannel devices).
    @inline(__always)
    static func sample(_ input: UnsafePointer<Float>, frame: Int, inChannels: Int,
                       outChannel: Int, totalOutChannels: Int) -> Float {
        let base = frame * inChannels
        guard totalOutChannels == 1, inChannels > 1 else {
            return input[base + outChannel % inChannels]
        }
        var sum: Float = 0
        for channel in 0..<inChannels { sum += input[base + channel] }
        return sum / Float(inChannels)
    }
}
