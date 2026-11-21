import LoudnessKernel

/// One completed 100 ms sub-block from the kernel, as a Swift value.
public struct SubBlock: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let playing = Flags(rawValue: UInt32(LK_BLOCK_PLAYING))
        public static let jumpBefore = Flags(rawValue: UInt32(LK_BLOCK_JUMP_BEFORE))
        public static let jumpInside = Flags(rawValue: UInt32(LK_BLOCK_JUMP_INSIDE))
        public static let hasBeat = Flags(rawValue: UInt32(LK_BLOCK_HAS_BEAT))
        public static let hasTempo = Flags(rawValue: UInt32(LK_BLOCK_HAS_TEMPO))
        public static let hasMeter = Flags(rawValue: UInt32(LK_BLOCK_HAS_METER))
        public static let hasDownbeat = Flags(rawValue: UInt32(LK_BLOCK_HAS_DOWNBEAT))
        public static let hasTransport = Flags(rawValue: UInt32(LK_BLOCK_HAS_TRANSPORT))
        public static let recording = Flags(rawValue: UInt32(LK_BLOCK_RECORDING))
        public static let cycling = Flags(rawValue: UInt32(LK_BLOCK_CYCLING))
    }

    public var index: UInt64
    public var startFrame: UInt64
    public var frames: Int
    public var flags: Flags
    public var beatPosition: Double?
    public var tempoBPM: Double?
    public var meter: Meter?
    public var measureDownbeat: Double?
    /// Sum over channels of G_i * z_i.
    public var weightedMeanSquare: Double
    /// The loudest 400 ms window ending in this sub-block, slid in 10 ms steps (weighted mean
    /// square; 0 = none). See `lk_subblock.max_momentary_mean_square`.
    public var maxMomentaryMeanSquare: Double
    public var channelMeanSquares: [Double]
    public var channelSamplePeaks: [Float]
    public var channelTruePeaks: [Float]

    public var samplePeak: Float { channelSamplePeaks.max() ?? 0 }
    public var truePeak: Float { channelTruePeaks.max() ?? 0 }
    public var playing: Bool { flags.contains(.playing) }

    public init(
        index: UInt64, startFrame: UInt64 = 0, frames: Int, flags: Flags = [], beatPosition: Double? = nil,
        tempoBPM: Double? = nil, meter: Meter? = nil, measureDownbeat: Double? = nil,
        weightedMeanSquare: Double, maxMomentaryMeanSquare: Double = 0, channelMeanSquares: [Double] = [],
        channelSamplePeaks: [Float] = [], channelTruePeaks: [Float] = []
    ) {
        self.index = index
        self.startFrame = startFrame
        self.frames = frames
        self.flags = flags
        self.beatPosition = beatPosition
        self.tempoBPM = tempoBPM
        self.meter = meter
        self.measureDownbeat = measureDownbeat
        self.weightedMeanSquare = weightedMeanSquare
        self.maxMomentaryMeanSquare = maxMomentaryMeanSquare
        self.channelMeanSquares = channelMeanSquares
        self.channelSamplePeaks = channelSamplePeaks
        self.channelTruePeaks = channelTruePeaks
    }

    init(_ record: lk_subblock) {
        var record = record
        let channels = Int(min(record.channels, UInt32(LK_MAX_CHANNELS)))
        let flags = Flags(rawValue: record.flags)
        self.init(
            index: record.index,
            startFrame: record.start_frame,
            frames: Int(record.frames),
            flags: flags,
            beatPosition: flags.contains(.hasBeat) ? record.beat_position : nil,
            tempoBPM: flags.contains(.hasTempo) ? record.tempo_bpm : nil,
            meter: flags.contains(.hasMeter) ? Meter(Int(record.meter_numerator), Int(record.meter_denominator)) : nil,
            measureDownbeat: flags.contains(.hasDownbeat) ? record.measure_downbeat : nil,
            weightedMeanSquare: record.weighted_mean_square,
            maxMomentaryMeanSquare: record.max_momentary_mean_square,
            channelMeanSquares: (0..<channels).map { lk_subblock_channel_mean_square(&record, UInt32($0)) },
            channelSamplePeaks: (0..<channels).map { lk_subblock_channel_sample_peak(&record, UInt32($0)) },
            channelTruePeaks: (0..<channels).map { lk_subblock_channel_true_peak(&record, UInt32($0)) }
        )
    }
}

/// Swift owner of one loudness kernel and its rings, for tests, the fake plug-in and any Swift
/// host. Producer and consumer calls must not run concurrently with each other through this
/// wrapper (the C rings themselves are SPSC-safe; a real plug-in calls `lk_process_*` from its
/// render thread directly and drains from a background thread).
public final class MeterKernel {
    public struct Configuration: Sendable {
        public var sampleRate: Double
        public var channels: Int
        /// BS.1770 channel weights; nil = the standard layout for `channels` (see `defaultWeights`).
        public var weights: [Double]?
        public var truePeak: Bool
        public var blockCapacity: Int
        /// Mono tap ring capacity in samples (power of two); nil = no tap.
        public var tapCapacity: Int?
        public var beatJumpTolerance: Double

        public init(
            sampleRate: Double, channels: Int, weights: [Double]? = nil, truePeak: Bool = true,
            blockCapacity: Int = 128, tapCapacity: Int? = nil, beatJumpTolerance: Double = 0.02
        ) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.weights = weights
            self.truePeak = truePeak
            self.blockCapacity = blockCapacity
            self.tapCapacity = tapCapacity
            self.beatJumpTolerance = beatJumpTolerance
        }
    }

    /// BS.1770-5 channel weights G_i. Annex 1 Table 3: 1.0 for L, R, C and 1.41 for Ls, Rs; the
    /// LFE is not measured (weight 0). Annex 3 Tables 4 and 5: 1.41 only for loudspeakers at
    /// 60-120 degrees azimuth (M+-090 and M+-110), 1.0 elsewhere, so the rear pair of 7.1
    /// (0+7+0, M+-135) is weighted 1.0.
    ///
    /// The channel order is an assumption about the host's layout (not checked against Logic):
    /// five channels as L R C Ls Rs, six as L R C LFE Ls Rs, eight as L R C LFE Lss Rss Lrs Rrs
    /// (side pair before rear pair). A host that reports another order needs explicit `weights`.
    /// Other counts weight every channel 1.0.
    public static func defaultWeights(channels: Int) -> [Double] {
        switch channels {
        case 5: return [1, 1, 1, 1.41, 1.41]
        case 6: return [1, 1, 1, 0, 1.41, 1.41]
        case 8: return [1, 1, 1, 0, 1.41, 1.41, 1, 1]
        default: return Array(repeating: 1, count: max(channels, 0))
        }
    }

    public let configuration: Configuration
    private let stateMemory: UnsafeMutableRawPointer
    private let blockMemory: UnsafeMutableRawPointer
    private let tapMemory: UnsafeMutableRawPointer?
    private let state: OpaquePointer
    private let blocks: OpaquePointer
    private let tap: OpaquePointer?
    private var scratch = lk_subblock()

    public init?(_ configuration: Configuration) {
        self.configuration = configuration
        guard (1...Int(LK_MAX_CHANNELS)).contains(configuration.channels),
              configuration.blockCapacity >= 2, configuration.blockCapacity <= 65536,
              configuration.blockCapacity.nonzeroBitCount == 1
        else { return nil }
        let weights = configuration.weights ?? Self.defaultWeights(channels: configuration.channels)
        guard weights.count == configuration.channels else { return nil }

        let blockBytes = lk_block_ring_bytes(UInt32(configuration.blockCapacity))
        guard blockBytes > 0 else { return nil }
        blockMemory = .allocate(byteCount: blockBytes, alignment: 64)
        guard let blocks = lk_block_ring_init(blockMemory, blockBytes, UInt32(configuration.blockCapacity)) else {
            blockMemory.deallocate()
            return nil
        }
        self.blocks = blocks

        if let capacity = configuration.tapCapacity {
            let bytes = capacity > 0 && capacity.nonzeroBitCount == 1 && capacity <= 1 << 20
                ? lk_sample_ring_bytes(UInt32(capacity)) : 0
            guard bytes > 0 else {
                blockMemory.deallocate()
                return nil
            }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
            tapMemory = memory
            tap = lk_sample_ring_init(memory, bytes, UInt32(capacity))
        } else {
            tapMemory = nil
            tap = nil
        }

        var config = lk_config()
        config.sample_rate = configuration.sampleRate
        config.channels = UInt32(configuration.channels)
        config.options = configuration.truePeak ? 0 : UInt32(LK_OPTION_NO_TRUE_PEAK)
        config.beat_jump_tolerance = configuration.beatJumpTolerance
        withUnsafeMutableBytes(of: &config.channel_weights) { raw in
            let buffer = raw.bindMemory(to: Double.self)
            for (index, weight) in weights.enumerated() { buffer[index] = weight }
        }
        let bytes = lk_state_bytes()
        stateMemory = .allocate(byteCount: bytes, alignment: 64)
        guard let state = lk_state_init(stateMemory, bytes, &config, blocks, tap) else {
            stateMemory.deallocate()
            blockMemory.deallocate()
            tapMemory?.deallocate()
            return nil
        }
        self.state = state
    }

    deinit {
        stateMemory.deallocate()
        blockMemory.deallocate()
        tapMemory?.deallocate()
    }

    /// The C kernel state (`lk_state *`), for a real-time render callback written in C that calls
    /// `lk_process_planar` directly (no Swift on the audio thread). Valid while this object lives;
    /// only one thread may process at a time, and `drain` / `drainTap` may run concurrently on
    /// one other thread (the rings are single-producer, single-consumer).
    public var unsafeKernelState: UnsafeMutableRawPointer { UnsafeMutableRawPointer(state) }

    public var subBlockFrames: Int { Int(lk_state_subblock_frames(state)) }
    public var oversampling: Int { Int(lk_state_oversampling(state)) }
    public var droppedSubBlocks: UInt64 { lk_block_ring_dropped(blocks) }
    public var droppedTapSamples: UInt64 { tap.map { lk_sample_ring_dropped($0) } ?? 0 }
    public var pendingSubBlocks: Int { Int(lk_block_ring_count(blocks)) }

    public func reset() { lk_reset(state) }

    /// Processes planar audio: one array per channel, all the same length.
    public func process(planar channels: [[Float]], context: HostContext? = nil) {
        guard channels.count == configuration.channels, let frames = channels.first?.count,
              channels.allSatisfy({ $0.count == frames }), frames > 0 else { return }
        var kernelContext = context?.kernelContext ?? lk_host_context()
        let hasContext = context != nil
        withPlanarPointers(channels) { pointers in
            pointers.withUnsafeBufferPointer { list in
                if hasContext {
                    lk_process_planar(state, list.baseAddress, UInt32(frames), &kernelContext)
                } else {
                    lk_process_planar(state, list.baseAddress, UInt32(frames), nil)
                }
            }
        }
    }

    /// Processes interleaved audio (`samples.count` must be a multiple of the channel count).
    public func process(interleaved samples: [Float], context: HostContext? = nil) {
        let channels = configuration.channels
        guard samples.count % channels == 0, !samples.isEmpty else { return }
        var kernelContext = context?.kernelContext ?? lk_host_context()
        let hasContext = context != nil
        samples.withUnsafeBufferPointer { buffer in
            if hasContext {
                lk_process_interleaved(state, buffer.baseAddress, UInt32(samples.count / channels), &kernelContext)
            } else {
                lk_process_interleaved(state, buffer.baseAddress, UInt32(samples.count / channels), nil)
            }
        }
    }

    /// Takes every completed sub-block out of the ring, oldest first.
    public func drain() -> [SubBlock] {
        var result: [SubBlock] = []
        while lk_block_ring_pop(blocks, &scratch) {
            result.append(SubBlock(scratch))
        }
        return result
    }

    /// Takes up to `max` mono tap samples.
    public func drainTap(max: Int = 1 << 20) -> [Float] {
        guard let tap else { return [] }
        let available = min(Int(lk_sample_ring_count(tap)), max)
        guard available > 0 else { return [] }
        var samples = [Float](repeating: 0, count: available)
        let read = samples.withUnsafeMutableBufferPointer { buffer in
            Int(lk_sample_ring_read(tap, buffer.baseAddress, UInt32(available)))
        }
        samples.removeLast(available - read)
        return samples
    }
}

/// Calls `body` with a pointer per channel, valid for the duration of the call.
private func withPlanarPointers<R>(_ channels: [[Float]], _ body: ([UnsafePointer<Float>?]) -> R) -> R {
    func recurse(_ index: Int, _ pointers: [UnsafePointer<Float>?]) -> R {
        guard index < channels.count else { return body(pointers) }
        return channels[index].withUnsafeBufferPointer { buffer in
            recurse(index + 1, pointers + [buffer.baseAddress])
        }
    }
    return recurse(0, [])
}

/// K-weighting coefficients derived by the kernel for `sampleRate` (b0, b1, b2, a1, a2 per stage).
public func kWeightingCoefficients(sampleRate: Double) -> (stage1: [Double], stage2: [Double])? {
    var s1 = lk_biquad_coefficients()
    var s2 = lk_biquad_coefficients()
    guard lk_kweighting_coefficients(sampleRate, &s1, &s2) else { return nil }
    return ([s1.b0, s1.b1, s1.b2, s1.a1, s1.a2], [s2.b0, s2.b1, s2.b2, s2.a1, s2.a2])
}

/// True-peak oversampling factor the kernel uses at `sampleRate`.
public func truePeakOversampling(sampleRate: Double) -> Int {
    Int(lk_true_peak_oversampling(sampleRate))
}
