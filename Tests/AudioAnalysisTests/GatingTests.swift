import Foundation
import Testing
@testable import AudioAnalysis

private func block(lufs: Double?, frames: Int = 4800) -> MeasuredBlock {
    MeasuredBlock(weightedMeanSquare: lufs.map { Loudness.meanSquare(lufs: $0) } ?? 0, frames: frames)
}

@Suite("Gating edge cases")
struct GatingTests {
    @Test func silenceHasNoLoudness() {
        let s = LoudnessSummary(runs: [Array(repeating: block(lufs: nil), count: 100)])
        #expect(s.integratedLUFS == nil)
        #expect(s.loudnessRangeLU == nil)
        #expect(s.maxMomentaryLUFS == nil)
        #expect(s.maxShortTermLUFS == nil)
        #expect(s.truePeakDBTP == nil)
        #expect(s.samplePeakDBFS == nil)
        #expect(s.gatingBlocks == 97)
    }

    @Test func emptyInput() {
        let s = LoudnessSummary(runs: [])
        #expect(s.integratedLUFS == nil && s.subBlocks == 0 && s.gatingBlocks == 0)
    }

    @Test func lessThan400msGivesNoGatingBlock() {
        let s = LoudnessSummary(runs: [Array(repeating: block(lufs: -20), count: 3)])
        #expect(s.gatingBlocks == 0)
        #expect(s.integratedLUFS == nil)
        #expect(s.maxMomentaryLUFS == nil)
    }

    @Test func exactly400msGivesOneGatingBlock() throws {
        let s = LoudnessSummary(runs: [Array(repeating: block(lufs: -20), count: 4)])
        #expect(s.gatingBlocks == 1)
        #expect(abs(try #require(s.integratedLUFS) - -20) < 1e-9)
        #expect(s.maxShortTermLUFS == nil)  // needs 3 s
        #expect(s.loudnessRangeLU == nil)
    }

    @Test func finerMomentaryValuesNeedFourSubBlocksBeforeThemAndAreCapped() throws {
        // A reported maximum in the first four sub-blocks of a run reaches back before the run
        // (another pass, or outside the range): ignored.
        var run = Array(repeating: block(lufs: -30), count: 6)
        run[3].maxMomentaryMeanSquare = Loudness.meanSquare(lufs: -10)
        #expect(abs(try #require(LoudnessSummary(runs: [run]).maxMomentaryLUFS) - -30) < 1e-9)
        // From the fifth on it counts, but never above what five sub-blocks can hold in 400 ms:
        // all of sub-blocks k-4 ... k over four sub-blocks' length (here 5/4 of -30 LUFS).
        run[3].maxMomentaryMeanSquare = 0
        run[4].maxMomentaryMeanSquare = Loudness.meanSquare(lufs: -10)
        let capped = try #require(LoudnessSummary(runs: [run]).maxMomentaryLUFS)
        #expect(abs(capped - (-30 + 10 * log10(5.0 / 4))) < 1e-9)
        // A plausible value is used as reported.
        run[4].maxMomentaryMeanSquare = Loudness.meanSquare(lufs: -29.5)
        #expect(abs(try #require(LoudnessSummary(runs: [run]).maxMomentaryLUFS) - -29.5) < 1e-9)
        // The other statistics ignore it.
        #expect(abs(try #require(LoudnessSummary(runs: [run]).integratedLUFS) - -30) < 1e-9)
    }

    @Test func windowsNeverSpanTwoRuns() {
        // Six sub-blocks in two runs of three: no 400 ms window fits in either.
        let run = Array(repeating: block(lufs: -20), count: 3)
        let s = LoudnessSummary(runs: [run, run])
        #expect(s.subBlocks == 6)
        #expect(s.gatingBlocks == 0)
        #expect(s.integratedLUFS == nil)
    }

    @Test func absoluteGateIsMinus70() throws {
        #expect(Loudness.integrated(gatingBlocks: [Loudness.meanSquare(lufs: -70.5)]) == nil)
        let justAbove = try #require(Loudness.integrated(gatingBlocks: [Loudness.meanSquare(lufs: -69.5)]))
        #expect(abs(justAbove - -69.5) < 1e-9)
    }

    @Test func relativeGateAveragesMeanSquaresNotDecibels() throws {
        // -20 and -40: power mean of both is -22.96, gate -32.96, so -40 drops out.
        let blocks = [Loudness.meanSquare(lufs: -20), Loudness.meanSquare(lufs: -40)]
        #expect(abs(try #require(Loudness.integrated(gatingBlocks: blocks)) - -20) < 1e-9)
        // -20 and -26 both pass; the result is their power mean (-22.03), not the dB mean (-23).
        let both = [Loudness.meanSquare(lufs: -20), Loudness.meanSquare(lufs: -26)]
        let expected = 10 * log10((pow(10, -2.0) + pow(10, -2.6)) / 2)
        #expect(abs(try #require(Loudness.integrated(gatingBlocks: both)) - expected) < 1e-9)
    }

    @Test func lraPercentileIndexRule() throws {
        // 100 short-term values -30.0, -29.9, ... -20.1: P10 index round(99 * 0.10) = 10 -> -29.0,
        // P95 index round(99 * 0.95) = 94 -> -20.6.
        let values = (0..<100).map { Loudness.meanSquare(lufs: -30 + Double($0) / 10) }
        let lra = try #require(Loudness.loudnessRange(shortTerm: values.shuffled()))
        #expect(abs(lra - 8.4) < 1e-9)
    }

    @Test func gatesOnTheThreshold() throws {
        // BS.1770-5 eq. (6)/(7): integrated loudness gates are strict (l_j > Gamma).
        #expect(Loudness.integrated(gatingBlocks: [Loudness.meanSquare(lufs: -70)]) == nil)
        // Tech 3342 §5 (MATLAB reference): LRA gates are inclusive (>=), so a short-term value
        // exactly at -70 LUFS still counts (the relative gate uses the same comparison).
        #expect(Loudness.loudnessRange(shortTerm: [Loudness.meanSquare(lufs: -70)]) == 0)
        #expect(Loudness.loudnessRange(shortTerm: [Loudness.meanSquare(lufs: -70.01)]) == nil)
    }

    @Test func sevenOneWeightsFollowAnnex3() {
        // BS.1770-5 Annex 3 Table 5, configuration 0+7+0: M+-090 weighted 1.41, M+-135 1.00.
        #expect(MeterKernel.defaultWeights(channels: 8) == [1, 1, 1, 0, 1.41, 1.41, 1, 1])
        #expect(MeterKernel.defaultWeights(channels: 6) == [1, 1, 1, 0, 1.41, 1.41])
        #expect(MeterKernel.defaultWeights(channels: 5) == [1, 1, 1, 1.41, 1.41])
        #expect(MeterKernel.defaultWeights(channels: 2) == [1, 1])
    }

    @Test func lraRelativeGateIsMinus20() throws {
        // -45 is more than 20 LU below the power mean of (-20, -45): excluded, so LRA is 0.
        let values = Array(repeating: Loudness.meanSquare(lufs: -20), count: 50) + Array(repeating: Loudness.meanSquare(lufs: -45), count: 50)
        #expect(try #require(Loudness.loudnessRange(shortTerm: values)) == 0)
    }

    @Test func peaksAreTheMaximumAcrossRuns() throws {
        let a = MeasuredBlock(weightedMeanSquare: 0.01, frames: 4800, samplePeak: 0.5, truePeak: 0.6)
        let b = MeasuredBlock(weightedMeanSquare: 0.01, frames: 4800, samplePeak: 0.25, truePeak: 0.2)
        let s = LoudnessSummary(runs: [[a], [b]])
        #expect(abs(try #require(s.truePeakDBTP) - 20 * log10(0.6)) < 1e-9)
        #expect(abs(try #require(s.samplePeakDBFS) - 20 * log10(0.5)) < 1e-9)
    }
}

@Suite("One-third-octave spectrum")
struct SpectrumTests {
    private func bands(_ segments: [ToneSegment], sampleRate: Double = 48000) throws -> [Double] {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: sampleRate))
        TestSignals.render(segments, sampleRate: sampleRate, channels: 1, chunk: 3000) { analyzer.append($0[0]) }
        return try #require(analyzer.takeBandPowers())
    }

    @Test func bandLayout() {
        #expect(ThirdOctaveBands.count == 30)
        #expect(abs(ThirdOctaveBands.exactCenters[16] - 1000) < 1e-9)
        let edges = ThirdOctaveBands.edges(16)
        #expect(abs(edges.upper / edges.lower - pow(2, 1.0 / 3)) < 1e-12)
    }

    @Test func sineLandsInItsBandAtItsLevel() throws {
        let powers = try bands([ToneSegment(seconds: 2, dBFS: -6, channels: 1, frequency: 1000)])
        let level = try #require(ThirdOctaveBands.decibels(power: powers[16]))
        #expect(abs(level - -6) < 0.3, "1 kHz band \(level) dB")
        for neighbour in [14, 18] {
            let other = ThirdOctaveBands.decibels(power: powers[neighbour]) ?? -200
            #expect(other < -46, "band \(neighbour): \(other) dB")
        }
    }

    @Test func lowAndHighBands() throws {
        let low = try bands([ToneSegment(seconds: 2, dBFS: -20, channels: 1, frequency: 100)])
        #expect(abs((ThirdOctaveBands.decibels(power: low[6]) ?? -200) - -20) < 0.5)
        let high = try bands([ToneSegment(seconds: 2, dBFS: -10, channels: 1, frequency: 10000)], sampleRate: 96000)
        #expect(abs((ThirdOctaveBands.decibels(power: high[26]) ?? -200) - -10) < 0.5)
    }

    @Test func nothingBeforeTheFirstFrame() throws {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: 48000))
        analyzer.append([Float](repeating: 0.1, count: 1000))
        #expect(analyzer.takeBandPowers() == nil)
        #expect(SpectrumAnalyzer(sampleRate: 48000, fftSize: 3000) == nil)
    }
}
