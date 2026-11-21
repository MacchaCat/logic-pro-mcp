import Foundation

/// The part of a sub-block that loudness and peak statistics need.
public struct MeasuredBlock: Sendable, Equatable {
    /// Sum over channels of G_i * z_i.
    public var weightedMeanSquare: Double
    public var frames: Int
    public var samplePeak: Double
    public var truePeak: Double
    /// The loudest 400 ms window ending in this sub-block on the kernel's 10 ms grid (weighted
    /// mean square; 0 = not reported). Used only where the four sub-blocks before it are in the
    /// same run (see `LoudnessSummary`).
    public var maxMomentaryMeanSquare: Double

    public init(weightedMeanSquare: Double, frames: Int, samplePeak: Double = 0, truePeak: Double = 0,
                maxMomentaryMeanSquare: Double = 0) {
        self.weightedMeanSquare = weightedMeanSquare
        self.frames = frames
        self.samplePeak = samplePeak
        self.truePeak = truePeak
        self.maxMomentaryMeanSquare = maxMomentaryMeanSquare
    }

    public init(_ block: SubBlock) {
        self.init(weightedMeanSquare: block.weightedMeanSquare, frames: block.frames,
                  samplePeak: Double(block.samplePeak), truePeak: Double(block.truePeak),
                  maxMomentaryMeanSquare: block.maxMomentaryMeanSquare)
    }
}

/// BS.1770-5 / EBU R 128 / EBU Tech 3342 arithmetic on 100 ms sub-blocks.
///
/// Windows are built only from sub-blocks that are consecutive in one contiguous run of audio:
/// momentary = 4 sub-blocks (400 ms), short-term = 30 (3 s), both stepping by one sub-block
/// (10 Hz). The maximum momentary loudness also takes the kernel's 400 ms windows slid in 10 ms
/// steps (`fineMomentaryMaximum`). Gating averages mean squares, never dB values.
public enum Loudness {
    public static let absoluteGateLUFS = -70.0
    public static let relativeGateLU = -10.0
    public static let lraRelativeGateLU = -20.0
    public static let momentarySubBlocks = 4
    public static let shortTermSubBlocks = 30

    /// L_K = -0.691 + 10 log10(sum G_i z_i); nil for silence.
    public static func lufs(meanSquare: Double) -> Double? {
        guard meanSquare > 0, meanSquare.isFinite else { return nil }
        return -0.691 + 10 * log10(meanSquare)
    }

    public static func meanSquare(lufs: Double) -> Double {
        pow(10, (lufs + 0.691) / 10)
    }

    /// 20 log10(|x|); nil for zero.
    public static func decibels(amplitude: Double) -> Double? {
        guard amplitude > 0, amplitude.isFinite else { return nil }
        return 20 * log10(amplitude)
    }

    /// Mean squares of all windows of `length` consecutive sub-blocks of one run (frame-weighted).
    public static func windows(_ run: [MeasuredBlock], length: Int) -> [Double] {
        guard length > 0, run.count >= length else { return [] }
        var result: [Double] = []
        result.reserveCapacity(run.count - length + 1)
        for start in 0...(run.count - length) {
            var energy = 0.0
            var frames = 0
            for block in run[start..<(start + length)] {
                energy += block.weightedMeanSquare * Double(block.frames)
                frames += block.frames
            }
            result.append(frames > 0 ? energy / Double(frames) : 0)
        }
        return result
    }

    /// The largest finer-grid momentary window the kernel reported within one run (weighted mean
    /// square, 0 if none). Sub-blocks 0 ... 3 of the run are skipped: a window ending in
    /// sub-block k reaches back into sub-block k - 4, which must be part of the same run. Each
    /// value is capped at what sub-blocks k - 4 ... k can hold over 400 ms (a reported value can
    /// never raise the maximum beyond the audio it describes).
    ///
    /// Why: windows built from whole sub-blocks step by 100 ms, so a 400 ms burst off that grid
    /// is never inside one window and the maximum under-reads by up to 0.46 LU, outside the
    /// +-0.1 LU of EBU Tech 3341 Table 1 cases 13 and 14. The kernel slides the window in 10 ms
    /// steps (at most 10 log10(395 / 400) = -0.055 LU).
    public static func fineMomentaryMaximum(_ run: [MeasuredBlock]) -> Double {
        let back = momentarySubBlocks
        guard run.count > back else { return 0 }
        var best = 0.0
        for k in back..<run.count {
            let reported = run[k].maxMomentaryMeanSquare
            guard reported > 0, reported.isFinite else { continue }
            var energy = 0.0
            var frames = 0
            for block in run[(k - back)...k] { energy += block.weightedMeanSquare * Double(block.frames) }
            for block in run[(k - back + 1)...k] { frames += block.frames }
            guard frames > 0 else { continue }
            best = max(best, min(reported, energy / Double(frames)))
        }
        return best
    }

    /// Gated integrated loudness (BS.1770-5 Annex 1, equations (5)-(7)) of 400 ms gating-block
    /// mean squares with 75 % overlap (here: 4 sub-blocks stepping by one). Both gates are strict,
    /// as in the Recommendation: J_g = { j : l_j > Gamma_a } with Gamma_a = -70 LKFS, then
    /// { j : l_j > Gamma_r and l_j > Gamma_a } with Gamma_r 10 LU below the absolutely gated
    /// loudness. (libebur128 uses >=; the two differ only for a block exactly on a threshold.)
    /// nil when no block passes both gates (silence, or no complete 400 ms block).
    public static func integrated(gatingBlocks: [Double]) -> Double? {
        let absoluteThreshold = meanSquare(lufs: absoluteGateLUFS)
        let aboveAbsolute = gatingBlocks.filter { $0 > absoluteThreshold }
        guard !aboveAbsolute.isEmpty else { return nil }
        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        guard let ungated = lufs(meanSquare: ungatedMean) else { return nil }
        let relativeThreshold = meanSquare(lufs: ungated + relativeGateLU)
        let aboveRelative = aboveAbsolute.filter { $0 > relativeThreshold }
        guard !aboveRelative.isEmpty else { return nil }
        return lufs(meanSquare: aboveRelative.reduce(0, +) / Double(aboveRelative.count))
    }

    /// Loudness range (EBU Tech 3342 §3.1 and the MATLAB reference in §5) from short-term (3 s)
    /// mean squares sampled at >= 10 Hz: absolute gate `>= -70` LUFS, relative gate `>=` 20 LU
    /// below the power mean of the absolutely gated values (both inclusive, as in the reference
    /// code and libebur128), then P95 - P10 of the remaining loudness values with the reference's
    /// percentile index round((n - 1) * p / 100 + 1), 1-based, i.e. round((n - 1) * p) here.
    /// nil when no short-term value passes the gates.
    public static func loudnessRange(shortTerm: [Double]) -> Double? {
        let absoluteThreshold = meanSquare(lufs: absoluteGateLUFS)
        let aboveAbsolute = shortTerm.filter { $0 >= absoluteThreshold }
        guard !aboveAbsolute.isEmpty else { return nil }
        guard let mean = lufs(meanSquare: aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) else { return nil }
        let relativeThreshold = meanSquare(lufs: mean + lraRelativeGateLU)
        let values = aboveAbsolute.filter { $0 >= relativeThreshold }.compactMap { lufs(meanSquare: $0) }.sorted()
        guard !values.isEmpty else { return nil }
        let last = Double(values.count - 1)
        let low = values[Int((last * 0.10).rounded())]
        let high = values[Int((last * 0.95).rounded())]
        return high - low
    }
}

/// Loudness and peak statistics of a set of contiguous runs.
public struct LoudnessSummary: Sendable, Equatable {
    public var integratedLUFS: Double?
    public var maxMomentaryLUFS: Double?
    public var maxShortTermLUFS: Double?
    public var loudnessRangeLU: Double?
    public var truePeakDBTP: Double?
    public var samplePeakDBFS: Double?
    public var subBlocks: Int
    public var gatingBlocks: Int
    public var shortTermWindows: Int
    /// Momentary and short-term series of the last run (for meters and tests).
    public var lastMomentary: [Double]
    public var lastShortTerm: [Double]

    /// `runs`: each element is a list of sub-blocks that are consecutive in time. Windows never
    /// span two runs.
    public init(runs: [[MeasuredBlock]]) {
        var gating: [Double] = []
        var shortTerm: [Double] = []
        var samplePeak = 0.0
        var truePeak = 0.0
        var blocks = 0
        var lastMomentary: [Double] = []
        var lastShortTerm: [Double] = []
        var fineMomentary = 0.0
        for run in runs where !run.isEmpty {
            blocks += run.count
            let momentary = Loudness.windows(run, length: Loudness.momentarySubBlocks)
            let short = Loudness.windows(run, length: Loudness.shortTermSubBlocks)
            fineMomentary = max(fineMomentary, Loudness.fineMomentaryMaximum(run))
            gating += momentary
            shortTerm += short
            lastMomentary = momentary
            lastShortTerm = short
            for block in run {
                samplePeak = max(samplePeak, block.samplePeak)
                truePeak = max(truePeak, block.truePeak, block.samplePeak)
            }
        }
        subBlocks = blocks
        gatingBlocks = gating.count
        shortTermWindows = shortTerm.count
        integratedLUFS = Loudness.integrated(gatingBlocks: gating)
        // The 100 ms grid windows, raised by the kernel's 10 ms grid where it reported one.
        maxMomentaryLUFS = gating.max().flatMap { Loudness.lufs(meanSquare: max($0, fineMomentary)) }
        maxShortTermLUFS = shortTerm.max().flatMap { Loudness.lufs(meanSquare: $0) }
        loudnessRangeLU = Loudness.loudnessRange(shortTerm: shortTerm)
        truePeakDBTP = Loudness.decibels(amplitude: truePeak)
        samplePeakDBFS = Loudness.decibels(amplitude: samplePeak)
        self.lastMomentary = lastMomentary.map { Loudness.lufs(meanSquare: $0) ?? -.infinity }
        self.lastShortTerm = lastShortTerm.map { Loudness.lufs(meanSquare: $0) ?? -.infinity }
    }
}
