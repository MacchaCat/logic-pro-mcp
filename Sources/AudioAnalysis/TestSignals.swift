import Foundation

/// One stretch of a synthesized test signal: a sine at `frequency` with a per-channel peak level
/// (dBFS of the sine's amplitude; nil = that channel is silent).
public struct ToneSegment: Sendable, Equatable {
    public var seconds: Double
    public var levelsDBFS: [Double?]
    public var frequency: Double

    public init(seconds: Double, levelsDBFS: [Double?], frequency: Double = 1000) {
        self.seconds = seconds
        self.levelsDBFS = levelsDBFS
        self.frequency = frequency
    }

    /// The same level on `channels` channels (in phase).
    public init(seconds: Double, dBFS: Double?, channels: Int, frequency: Double = 1000) {
        self.init(seconds: seconds, levelsDBFS: Array(repeating: dBFS, count: channels), frequency: frequency)
    }
}

/// Deterministic synthesized signals for tests and the fake plug-in (no recorded material).
public enum TestSignals {
    /// Renders consecutive segments as planar chunks of at most `chunk` frames. The sine phase is
    /// computed from the absolute sample index, so it is continuous across segments and chunks.
    /// `fadeInSeconds` / `fadeOutSeconds` taper the very start / end with a raised-cosine fade
    /// (EBU Tech 3341 Table 1 case 15: "tapered with a 10 ms fade-in and fade-out"; it avoids the
    /// band-limited overshoot of an abrupt onset or end in true-peak tests).
    public static func render(
        _ segments: [ToneSegment], sampleRate: Double, channels: Int, chunk: Int = 4096,
        phaseDegrees: Double = 0, fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0, _ body: ([[Float]]) -> Void
    ) {
        let fadeFrames = Int((fadeInSeconds * sampleRate).rounded())
        let fadeOutFrames = Int((fadeOutSeconds * sampleRate).rounded())
        let totalFrames = segments.reduce(0) { $0 + Int(($1.seconds * sampleRate).rounded()) }
        let phase = phaseDegrees * .pi / 180
        var absolute = 0
        for segment in segments {
            let frames = Int((segment.seconds * sampleRate).rounded())
            let amplitudes = (0..<channels).map { channel -> Double in
                guard channel < segment.levelsDBFS.count, let level = segment.levelsDBFS[channel] else { return 0 }
                return pow(10, level / 20)
            }
            let omega = 2 * Double.pi * segment.frequency / sampleRate
            var done = 0
            while done < frames {
                let n = min(chunk, frames - done)
                var buffers = Array(repeating: [Float](repeating: 0, count: n), count: channels)
                for i in 0..<n {
                    let index = absolute + done + i
                    var value = sin(omega * Double(index) + phase)
                    if index < fadeFrames {
                        value *= 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fadeFrames))
                    }
                    let fromEnd = totalFrames - 1 - index
                    if fromEnd < fadeOutFrames {
                        value *= 0.5 - 0.5 * cos(Double.pi * Double(fromEnd) / Double(fadeOutFrames))
                    }
                    for channel in 0..<channels where amplitudes[channel] != 0 {
                        buffers[channel][i] = Float(amplitudes[channel] * value)
                    }
                }
                body(buffers)
                done += n
            }
            absolute += frames
        }
    }

    /// Runs `segments` through a fresh kernel in render-sized chunks and returns every sub-block.
    public static func measure(
        _ segments: [ToneSegment], sampleRate: Double = 48000, channels: Int, truePeak: Bool = false,
        weights: [Double]? = nil, chunk: Int = 512, phaseDegrees: Double = 0, fadeInSeconds: Double = 0,
        fadeOutSeconds: Double = 0
    ) -> [SubBlock] {
        guard let kernel = MeterKernel(.init(sampleRate: sampleRate, channels: channels, weights: weights,
                                             truePeak: truePeak, blockCapacity: 64)) else { return [] }
        var blocks: [SubBlock] = []
        render(segments, sampleRate: sampleRate, channels: channels, chunk: chunk,
               phaseDegrees: phaseDegrees, fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds) { buffers in
            kernel.process(planar: buffers)
            blocks += kernel.drain()
        }
        return blocks + kernel.drain()
    }
}
