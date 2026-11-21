import Foundation
import Testing
@testable import AudioAnalysis

// EBU Tech 3341 (2023) Table 1 and EBU Tech 3342 (2023) Table 1 "Minimum requirements test
// signals", synthesized from the documents' descriptions (the EBU test files are not used: the
// user declined their download, research §6.4). Every case parameter below (frequency, levels,
// durations, repetitions, channel layout, tolerance) was compared with the 2023 texts on
// 2026-11-21; each test names its case.
//
// Covered here:
//   Tech 3341: §2.9 calibration (-18 dBFS 1 kHz stereo -> -18.0 LUFS); cases 1-6 and 9-14
//              (+-0.1 LU); true-peak cases 15-23 in TruePeakTests.
//   Tech 3342: cases 1-4 (LRA, +-1 LU).
//
// NOT covered, and why:
//   Tech 3341 7, 8      authentic programme material, only in the EBU test set.
//   Tech 3342 5, 6      authentic programme material, only in the EBU test set.
//
// Max momentary loudness (cases 13 and 14): windows built from whole 100 ms sub-blocks would miss
// a 400 ms burst off that grid by up to 10 log10(360 / 400) = 0.46 LU, so the kernel also slides
// the 400 ms window in 10 ms steps and reports the loudest window per sub-block
// (`lk_subblock.max_momentary_mean_square`); the summary takes the larger of the two. On the
// 10 ms grid the worst case is 10 log10(395 / 400) = 0.055 LU low. Max short-term (cases 10 /
// 11) stays on the 100 ms grid, within 0.07 LU (2.95 s of 3 s).

private let fs = 48000.0

/// Power mean (in dB of the sine's peak level) of tone segments: what an ideal 1 kHz meter reads,
/// since the -0.691 offset cancels the K-filter gain at 1 kHz for a stereo in-phase sine.
private func closedFormLevel(_ segments: [(dBFS: Double, seconds: Double)]) -> Double {
    let energy = segments.reduce(0.0) { $0 + pow(10, $1.dBFS / 10) * $1.seconds }
    let time = segments.reduce(0.0) { $0 + $1.seconds }
    return 10 * log10(energy / time)
}

private func stereo(_ segments: [(dBFS: Double?, seconds: Double)]) -> [ToneSegment] {
    segments.map { ToneSegment(seconds: $0.seconds, dBFS: $0.dBFS, channels: 2) }
}

private func summary(_ blocks: [SubBlock]) -> LoudnessSummary {
    LoudnessSummary(runs: [blocks.map(MeasuredBlock.init)])
}

@Suite("EBU Tech 3341 (loudness)")
struct Tech3341Tests {
    @Test func calibration() throws {
        // §2.9: 1 kHz stereo sine, peak -18 dBFS, in phase on both channels -> -18.0 LUFS.
        let s = summary(TestSignals.measure(stereo([(-18, 10)]), channels: 2))
        let integrated = try #require(s.integratedLUFS)
        #expect(abs(integrated - -18.0) <= 0.1, "I = \(integrated)")
    }

    @Test func case1And2_steadySineMomentaryShortTermIntegrated() throws {
        // Case 1: stereo 1000 Hz, -23.0 dBFS per channel, 20 s: M, S, I = -23.0 +-0.1.
        // Case 2: as case 1 at -33.0 dBFS: M, S, I = -33.0 +-0.1.
        for level in [-23.0, -33.0] {
            let s = summary(TestSignals.measure(stereo([(level, 20)]), channels: 2))
            let integrated = try #require(s.integratedLUFS)
            let momentary = try #require(s.lastMomentary.last)
            let shortTerm = try #require(s.lastShortTerm.last)
            #expect(abs(integrated - level) <= 0.1, "I = \(integrated) for \(level)")
            #expect(abs(momentary - level) <= 0.1, "M = \(momentary) for \(level)")
            #expect(abs(shortTerm - level) <= 0.1, "S = \(shortTerm) for \(level)")
        }
    }

    @Test func case3_relativeGateRemovesQuietParts() throws {
        // Case 3: 10 s at -36.0, 60 s at -23.0, 10 s at -36.0 dBFS: I = -23.0 +-0.1.
        let s = summary(TestSignals.measure(stereo([(-36, 10), (-23, 60), (-36, 10)]), channels: 2))
        let integrated = try #require(s.integratedLUFS)
        #expect(abs(integrated - -23.0) <= 0.1, "I = \(integrated)")
    }

    @Test func case4_absoluteAndRelativeGates() throws {
        // Case 4: 10 s -72, 10 s -36, 60 s -23, 10 s -36, 10 s -72 dBFS: I = -23.0 +-0.1.
        let s = summary(TestSignals.measure(stereo([(-72, 10), (-36, 10), (-23, 60), (-36, 10), (-72, 10)]), channels: 2))
        let integrated = try #require(s.integratedLUFS)
        #expect(abs(integrated - -23.0) <= 0.1, "I = \(integrated)")
    }

    @Test func case5_levelChangesAveragedInPower() throws {
        // Case 5: 20 s at -26.0, 20.1 s at -20.0, 20 s at -26.0 dBFS: I = -23.0 +-0.1.
        // Closed form: 10 log10((20 * 10^-2.6 + 20.1 * 10^-2 + 20 * 10^-2.6) / 60.1) = -23.00.
        let segments: [(dBFS: Double, seconds: Double)] = [(-26, 20), (-20, 20.1), (-26, 20)]
        #expect(abs(closedFormLevel(segments) - -23.0) <= 0.01)
        let s = summary(TestSignals.measure(stereo(segments.map { ($0.dBFS, $0.seconds) }), channels: 2))
        let integrated = try #require(s.integratedLUFS)
        #expect(abs(integrated - -23.0) <= 0.1, "I = \(integrated)")
    }

    @Test func case6_fiveChannelWeights() throws {
        // Case 6: 5.0 channels, 1000 Hz, 20 s: -28.0 dBFS in L and R, -24.0 in C, -30.0 in Ls and
        // Rs: I = -23.0 +-0.1 (BS.1770-5 Table 3 weights 1, 1, 1, 1.41, 1.41).
        // Closed form relative to stereo -23 dBFS (sum G z = 2 * 0.5 * 10^-2.3):
        // 0.5 * (2 * 10^-2.8 + 10^-2.4) + 1.41 * 0.5 * 2 * 10^-3.0 = 0.0049855 -> -23.02.
        let weighted = 0.5 * (2 * pow(10, -2.8) + pow(10, -2.4)) + 1.41 * 0.5 * 2 * pow(10, -3.0)
        let reference = 2 * 0.5 * pow(10, -2.3)
        #expect(abs(-23 + 10 * log10(weighted / reference) - -23.0) <= 0.05)
        let segment = ToneSegment(seconds: 20, levelsDBFS: [-28, -28, -24, -30, -30])
        let s = summary(TestSignals.measure([segment], channels: 5))
        let integrated = try #require(s.integratedLUFS)
        #expect(abs(integrated - -23.0) <= 0.1, "I = \(integrated)")
    }

    @Test func case9_shortTermOfPeriodicSequence() throws {
        // Case 9: (1.34 s at -20.0 dBFS; 1.66 s at -30.0 dBFS) repeated 5 times:
        // S = -23.0 +-0.1, constant after 3 s. Every 3 s window holds exactly one period.
        // Closed form: 10 log10((1.34 * 10^-2 + 1.66 * 10^-3) / 3) = -22.99.
        let period: [(dBFS: Double?, seconds: Double)] = [(-20, 1.34), (-30, 1.66)]
        #expect(abs(closedFormLevel([(-20, 1.34), (-30, 1.66)]) - -23.0) <= 0.02)
        let segments = Array(repeating: period, count: 5).flatMap { $0 }
        let s = summary(TestSignals.measure(stereo(segments), channels: 2))
        // 15 s = 150 sub-blocks: 121 windows, the first ending at 3 s.
        #expect(s.lastShortTerm.count == 121)
        for (index, value) in s.lastShortTerm.enumerated() {
            #expect(abs(value - -23.0) <= 0.1, "S[\(index)] (ending at \(Double(index) / 10 + 3) s) = \(value)")
        }
    }

    @Test func case10_maxShortTermOfShiftedBursts() throws {
        // Case 10 (file-based meters): 20 separate signals (i * 0.15 s of silence; 3 s at -23.0 dBFS;
        // 1 s of silence), i = 0 ... 19, each measured from a reset meter: max S = -23.0 +-0.1.
        for i in 0..<20 {
            let segments = stereo([(nil, Double(i) * 0.15), (-23, 3), (nil, 1)])
            let s = summary(TestSignals.measure(segments, channels: 2))
            let maxS = try #require(s.maxShortTermLUFS)
            #expect(abs(maxS - -23.0) <= 0.1, "i = \(i): max S = \(maxS)")
        }
    }

    @Test func case11_maxShortTermOfASequence() throws {
        // Case 11 (live meters): 20 tones (i * 0.15 s of silence; 3 s at (-38.0 + i) dBFS;
        // 3 - i * 0.15 s of silence), i = 0 ... 19, in one signal: successive max S = -38.0,
        // -37.0, ..., -19.0 +-0.1. Each tone and its silences take 6 s; a window belongs to the
        // 6 s slot in which it ends.
        let segments = (0..<20).flatMap { i -> [(dBFS: Double?, seconds: Double)] in
            [(nil, Double(i) * 0.15), (-38 + Double(i), 3), (nil, 3 - Double(i) * 0.15)]
        }
        let s = summary(TestSignals.measure(stereo(segments), channels: 2))
        var maxima = Array(repeating: -Double.infinity, count: 20)
        for (index, value) in s.lastShortTerm.enumerated() {
            let end = Double(index) / 10 + 3
            let slot = min(19, Int(((end - 1e-9) / 6).rounded(.down)))
            maxima[slot] = max(maxima[slot], value)
        }
        for (i, value) in maxima.enumerated() {
            #expect(abs(value - (-38 + Double(i))) <= 0.1, "tone \(i): max S = \(value)")
        }
    }

    @Test func case12_momentaryOfPeriodicSequence() throws {
        // Case 12: (0.18 s at -20.0 dBFS; 0.22 s at -30.0 dBFS) repeated 25 times:
        // M = -23.0 +-0.1, constant after 1 s. Every 400 ms window holds exactly one period.
        // Closed form: 10 log10((0.18 * 10^-2 + 0.22 * 10^-3) / 0.4) = -22.97.
        let period: [(dBFS: Double?, seconds: Double)] = [(-20, 0.18), (-30, 0.22)]
        #expect(abs(closedFormLevel([(-20, 0.18), (-30, 0.22)]) - -23.0) <= 0.05)
        let segments = Array(repeating: period, count: 25).flatMap { $0 }
        let s = summary(TestSignals.measure(stereo(segments), channels: 2))
        // 10 s = 100 sub-blocks: 97 windows; window k ends at 0.1 k + 0.4 s, so k >= 6 is after 1 s.
        #expect(s.lastMomentary.count == 97)
        for (index, value) in s.lastMomentary.enumerated() where index >= 6 {
            #expect(abs(value - -23.0) <= 0.1, "M[\(index)] (ending at \(Double(index) / 10 + 0.4) s) = \(value)")
        }
    }

    @Test func case13_maxMomentaryOfShiftedBursts() throws {
        // Case 13 (file-based meters): 20 signals (i * 20 ms of silence; 400 ms at -23.0 dBFS; 1 s
        // of silence), each from a reset meter: max M = -23.0 +-0.1.
        for i in 0..<20 {
            let segments = stereo([(nil, Double(i) * 0.02), (-23, 0.4), (nil, 1)])
            let blocks = TestSignals.measure(segments, channels: 2)
            let s = summary(blocks)
            let maxM = try #require(s.maxMomentaryLUFS)
            #expect(abs(maxM - -23.0) <= 0.1, "i = \(i): max M = \(maxM)")
            // Without the 10 ms grid the 100 ms windows alone miss bursts off their grid.
            let coarse = summary(blocks.map { var block = $0; block.maxMomentaryMeanSquare = 0; return block })
            if i % 5 != 0 { #expect(try #require(coarse.maxMomentaryLUFS) < -23.15, "i = \(i)") }
        }
    }

    @Test func maxMomentaryOffTheTenMillisecondGrid() throws {
        // Bursts starting between the 10 ms steps: at most 10 log10(395 / 400) = 0.055 LU low.
        for offsetMs in [3, 5, 7, 13, 45, 95, 99] {
            let segments = stereo([(nil, Double(offsetMs) / 1000), (-23, 0.4), (nil, 1)])
            let maxM = try #require(summary(TestSignals.measure(segments, channels: 2)).maxMomentaryLUFS)
            #expect(maxM <= -23.0 + 0.05 && maxM >= -23.0 - 0.06 - 0.03, "offset \(offsetMs) ms: max M = \(maxM)")
        }
    }

    @Test func case14_maxMomentaryOfASequence() throws {
        // Case 14 (live meters): 20 tones (i * 20 ms of silence; 400 ms at (-38.0 + i) dBFS;
        // 400 - i * 20 ms of silence), one signal: successive max M = -38.0, ..., -19.0 +-0.1.
        // Each tone and its silences take 800 ms; a sub-block's maximum belongs to the 800 ms
        // slot in which its windows end (every window ending in slot i holds only tone i, or tone
        // i - 1's tail at a lower level).
        let segments = (0..<20).flatMap { i -> [(dBFS: Double?, seconds: Double)] in
            [(nil, Double(i) * 0.02), (-38 + Double(i), 0.4), (nil, 0.4 - Double(i) * 0.02)]
        }
        let blocks = TestSignals.measure(stereo(segments), channels: 2)
        var maxima = Array(repeating: -Double.infinity, count: 20)
        func slot(endingAt end: Double) -> Int { min(19, Int(((end - 1e-9) / 0.8).rounded(.down))) }
        // A live meter's successive maxima: the loudest window ending in each 800 ms slot, from
        // the 100 ms grid windows (the first ends at 0.4 s) and the kernel's 10 ms grid.
        for (index, value) in summary(blocks).lastMomentary.enumerated() {
            let end = Double(index) / 10 + 0.4
            maxima[slot(endingAt: end)] = max(maxima[slot(endingAt: end)], value)
        }
        for index in blocks.indices where index >= Loudness.momentarySubBlocks {
            let measured = blocks[...index].suffix(Loudness.momentarySubBlocks + 1).map(MeasuredBlock.init)
            let best = Loudness.fineMomentaryMaximum(Array(measured))
            guard let lufs = Loudness.lufs(meanSquare: best) else { continue }
            let end = Double(index + 1) / 10
            maxima[slot(endingAt: end)] = max(maxima[slot(endingAt: end)], lufs)
        }
        for (i, value) in maxima.enumerated() {
            #expect(abs(value - (-38 + Double(i))) <= 0.1, "tone \(i): max M = \(value)")
        }
        // The summary over the whole signal is the loudest tone's.
        #expect(abs(try #require(summary(blocks).maxMomentaryLUFS) - -19.0) <= 0.1)
    }
}

@Suite("EBU Tech 3342 (loudness range)")
struct Tech3342Tests {
    private func lra(_ segments: [(dBFS: Double?, seconds: Double)]) throws -> Double {
        let s = summary(TestSignals.measure(stereo(segments), channels: 2))
        return try #require(s.loudnessRangeLU)
    }

    @Test func case1() throws {
        // Stereo 1000 Hz, -20.0 dBFS for 20 s, followed immediately by -30.0 dBFS: LRA = 10 +-1.
        let value = try lra([(-20, 20), (-30, 20)])
        #expect(abs(value - 10) <= 1, "LRA = \(value)")
    }

    @Test func case2() throws {
        // As case 1 with -20.0 and -15.0 dBFS: LRA = 5 +-1.
        let value = try lra([(-20, 20), (-15, 20)])
        #expect(abs(value - 5) <= 1, "LRA = \(value)")
    }

    @Test func case3() throws {
        // As case 1 with -40.0 and -20.0 dBFS: LRA = 20 +-1.
        let value = try lra([(-40, 20), (-20, 20)])
        #expect(abs(value - 20) <= 1, "LRA = \(value)")
    }

    @Test func case4_relativeGateDropsTheQuietestParts() throws {
        // Five 20 s tones at -50, -35, -20, -35, -50 dBFS: LRA = 15 +-1. The -50 parts are more
        // than 20 LU below the absolute-gated mean (about -27).
        let value = try lra([(-50, 20), (-35, 20), (-20, 20), (-35, 20), (-50, 20)])
        #expect(abs(value - 15) <= 1, "LRA = \(value)")
    }

    @Test func repeatingTheSignalDoesNotChangeTheResult() throws {
        // Table 1 note: "the expected response is unchanged if the test signal is repeated".
        let once = try lra([(-20, 20), (-30, 20)])
        let twice = try lra([(-20, 20), (-30, 20), (-20, 20), (-30, 20)])
        #expect(abs(once - twice) <= 1, "\(once) vs \(twice)")
    }
}
