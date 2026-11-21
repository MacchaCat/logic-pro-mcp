import Foundation
import LoudnessKernel
import Testing
@testable import AudioAnalysis

/// True-peak cases of EBU Tech 3341 (2023) Table 1, cases 15-23 (tolerance +0.2 / -0.4 dB),
/// with the parameters as the document gives them (compared with the text on 2026-11-21).
/// Cases 15-19: stereo sines of the given frequency, amplitude ("FFS" = fraction of full scale)
/// and phase; case 15 says the tone "should be tapered with a 10 ms fade-in and fade-out", and the
/// same taper is used for 16-19 (an abrupt onset has a genuine band-limited overshoot that the
/// published targets do not include). Cases 20-23 are synthesized at 4 x fs as the document
/// describes; its anti-aliasing filter is not specified, so ours is stated in `case20To23`.
@Suite("True peak")
struct TruePeakTests {
    private func truePeak(
        frequency: Double, amplitude: Double, phaseDegrees: Double, sampleRate: Double = 48000
    ) throws -> (truePeak: Double, samplePeak: Double) {
        let level = 20 * log10(amplitude)
        let blocks = TestSignals.measure(
            [ToneSegment(seconds: 1, dBFS: level, channels: 2, frequency: frequency)],
            sampleRate: sampleRate, channels: 2, truePeak: true, phaseDegrees: phaseDegrees,
            fadeInSeconds: 0.01, fadeOutSeconds: 0.01)
        let s = LoudnessSummary(runs: [blocks.map(MeasuredBlock.init)])
        return (try #require(s.truePeakDBTP), try #require(s.samplePeakDBFS))
    }

    private func expectWithinTolerance(_ value: Double, _ target: Double, _ label: String) {
        #expect(value <= target + 0.2 && value >= target - 0.4, "\(label): \(value) dBTP, target \(target)")
    }

    @Test func oversamplingFactorBySampleRate() {
        // BS.1770-5 Annex 2 §3: at least 192 kHz after oversampling (2x suffices at 96 kHz); the
        // same rule as libebur128. 44.1 kHz cannot reach 192 kHz with 4x (176.4 kHz).
        #expect(truePeakOversampling(sampleRate: 44100) == 4)
        #expect(truePeakOversampling(sampleRate: 48000) == 4)
        #expect(truePeakOversampling(sampleRate: 88200) == 4)
        #expect(truePeakOversampling(sampleRate: 96000) == 2)
        #expect(truePeakOversampling(sampleRate: 176400) == 2)
        #expect(truePeakOversampling(sampleRate: 192000) == 1)
        for rate in [48000.0, 88200, 96000, 176400, 192000] {
            #expect(rate * Double(truePeakOversampling(sampleRate: rate)) >= 192000, "\(rate)")
        }
    }

    @Test func case15_quarterRatePhase0() throws {
        // Case 15: fs/4, 0.50 FFS, 0.0 degrees: -6.0 dBTP. Samples 0, +0.5, 0, -0.5: the sample
        // peak already is the true peak.
        let result = try truePeak(frequency: 12000, amplitude: 0.5, phaseDegrees: 0)
        expectWithinTolerance(result.truePeak, -6.0, "fs/4 0°")
    }

    @Test func case16_quarterRatePhase45() throws {
        // Case 16: fs/4, 0.50 FFS, 45.0 degrees: -6.0 dBTP. Samples at +-0.354 (-9 dBFS sample
        // peak), true peak half-way between samples.
        let result = try truePeak(frequency: 12000, amplitude: 0.5, phaseDegrees: 45)
        #expect(abs(result.samplePeak - -9.03) < 0.05)
        expectWithinTolerance(result.truePeak, -6.0, "fs/4 45°")
    }

    @Test func case17_sixthRatePhase60() throws {
        // Case 17: fs/6, 0.50 FFS, 60.0 degrees: -6.0 dBTP.
        let result = try truePeak(frequency: 8000, amplitude: 0.5, phaseDegrees: 60)
        expectWithinTolerance(result.truePeak, -6.0, "fs/6 60°")
    }

    @Test func case18_eighthRatePhase67_5() throws {
        // Case 18: fs/8, 0.50 FFS, 67.5 degrees: -6.0 dBTP.
        let result = try truePeak(frequency: 6000, amplitude: 0.5, phaseDegrees: 67.5)
        expectWithinTolerance(result.truePeak, -6.0, "fs/8 67.5°")
    }

    @Test func case19_overFullScale() throws {
        // Case 19: fs/4, 1.41 FFS, 45.0 degrees: +3.0 dBTP. The samples sit at about +-1.0 (0 dBFS)
        // but the waveform reaches +3 dBTP.
        let result = try truePeak(frequency: 12000, amplitude: 1.41, phaseDegrees: 45)
        #expect(abs(result.samplePeak) < 0.05)
        expectWithinTolerance(result.truePeak, 3.0, "fs/4 45° 1.41 FS")
    }

    @Test func at96kHzTwoTimesOversamplingFindsTheMidpointPeak() throws {
        let result = try truePeak(frequency: 24000, amplitude: 0.5, phaseDegrees: 45, sampleRate: 96000)
        #expect(abs(result.samplePeak - -9.03) < 0.05)
        expectWithinTolerance(result.truePeak, -6.0, "96 kHz fs/4 45°")
    }

    @Test func at192kHzTruePeakIsTheSamplePeak() throws {
        let result = try truePeak(frequency: 48000, amplitude: 0.5, phaseDegrees: 45, sampleRate: 192000)
        #expect(result.truePeak == result.samplePeak)
        let kernel = try #require(MeterKernel(.init(sampleRate: 192000, channels: 1)))
        #expect(kernel.oversampling == 1)
    }

    @Test func lowFrequencySineReadsItsAmplitude() throws {
        let result = try truePeak(frequency: 997, amplitude: 1.0, phaseDegrees: 13, sampleRate: 44100)
        #expect(abs(result.truePeak) <= 0.05, "\(result.truePeak)")
    }

    @Test func at88_2kHzFourTimesOversamplingFindsTheMidpointPeak() throws {
        let result = try truePeak(frequency: 22050, amplitude: 0.5, phaseDegrees: 45, sampleRate: 88200)
        #expect(abs(result.samplePeak - -9.03) < 0.05)
        expectWithinTolerance(result.truePeak, -6.0, "88.2 kHz fs/4 45°")
    }

    /// Kaiser-windowed sinc low-pass at `rate`: `taps` (odd) coefficients, cutoff in Hz, unity DC gain.
    private func lowPass(taps: Int, cutoff: Double, rate: Double, beta: Double) -> [Double] {
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0
            var term = 1.0
            for k in 1...40 {
                term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
                sum += term
            }
            return sum
        }
        let half = Double(taps - 1) / 2
        let fc = cutoff / rate
        var h = (0..<taps).map { index -> Double in
            let m = Double(index) - half
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let r = m / half
            return sinc * besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
        }
        let dc = h.reduce(0, +)
        h = h.map { $0 / dc }
        return h
    }

    /// Cases 20-23: "Stereo sine wave with frequency fs/6 Hz, amplitude 0.50 FFS, containing a single
    /// period of a sine wave with frequency fs/4, amplitude 1.00; the signal being continuous in
    /// phase at both sides of the single period", synthesized at 4 x fs, low-pass (anti-aliasing)
    /// filtered and downsampled to fs with a 0, 1, 2 or 3 sample offset (at the 4 x fs rate), with a
    /// short fade-in and fade-out: max true peak 0.0 dBTP +0.2 / -0.4. The document leaves the
    /// anti-aliasing filter open; this one is a 255-tap Kaiser-windowed sinc (beta 7.86, about 80 dB
    /// stop-band) with its cutoff at 22 kHz, i.e. a 20-24 kHz transition band for fs = 48 kHz.
    @Test(arguments: 0..<4) func case20To23_singlePeriodBurst(offset: Int) throws {
        let rate = 48000.0
        let up = 4 * rate
        let total = Int(0.3 * up)
        // fs/6 is 24 samples per period at 4 x fs and fs/4 is 16: the burst starts on a rising zero
        // crossing of the fs/6 sine and the fs/6 sine resumes from phase 0 after it.
        let burstStart = 24 * 1200
        let fade = Int(0.01 * up)
        var x = [Double](repeating: 0, count: total)
        for n in 0..<total {
            var value: Double
            if n < burstStart {
                value = 0.5 * sin(2 * .pi * Double(n) / 24)
            } else if n < burstStart + 16 {
                value = sin(2 * .pi * Double(n - burstStart) / 16)
            } else {
                value = 0.5 * sin(2 * .pi * Double(n - burstStart - 16) / 24)
            }
            let edge = min(n, total - 1 - n)
            if edge < fade { value *= 0.5 - 0.5 * cos(.pi * Double(edge) / Double(fade)) }
            x[n] = value
        }
        let taps = 255
        let h = lowPass(taps: taps, cutoff: 22000, rate: up, beta: 7.86)
        let half = taps / 2
        func filtered(_ n: Int) -> Double {
            var acc = 0.0
            for k in 0..<taps {
                let index = n + half - k
                if index >= 0, index < total { acc += h[k] * x[index] }
            }
            return acc
        }
        // The band-limited 4 x fs waveform's own peak (what an ideal meter would read).
        var ideal = 0.0
        for n in (burstStart - 64)...(burstStart + 80) { ideal = max(ideal, abs(filtered(n))) }
        // Downsampled to fs, keeping every 4th sample starting at `offset`.
        let samples = stride(from: offset, to: total, by: 4).map { Float(filtered($0)) }
        let kernel = try #require(MeterKernel(.init(sampleRate: rate, channels: 2, truePeak: true)))
        var blocks: [SubBlock] = []
        var start = 0
        while start < samples.count {
            let chunk = Array(samples[start..<min(start + 512, samples.count)])
            kernel.process(planar: [chunk, chunk])
            blocks += kernel.drain()
            start += 512
        }
        // Pad with silence so the last partial sub-block completes.
        kernel.process(planar: Array(repeating: [Float](repeating: 0, count: 4800), count: 2))
        blocks += kernel.drain()
        let s = LoudnessSummary(runs: [blocks.map(MeasuredBlock.init)])
        let truePeak = try #require(s.truePeakDBTP)
        expectWithinTolerance(truePeak, 0.0, "case \(20 + offset) (ideal band-limited peak \(20 * log10(ideal)) dB)")
    }
}

/// The interpolation filters themselves, from the kernel's tables: what the comments in
/// LoudnessKernel.c claim about them.
@Suite("True-peak filters")
struct TruePeakFilterTests {
    /// ITU-R BS.1770-5 Annex 2 §3, the order-48, 4-phase interpolating FIR: column "Phase p" of the
    /// published table, top to bottom (copied from the Recommendation's text on 2026-11-21).
    static let publishedTable: [[Double]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
    ]

    @Test func fourTimesTableIsThePublishedOne() throws {
        #expect(try filter(4) == Self.publishedTable)
    }

    /// The table rows for `oversampling`, coefficient 0 = oldest sample.
    private func filter(_ oversampling: UInt32) throws -> [[Double]] {
        var phases: UInt32 = 0
        var taps: UInt32 = 0
        let table = try #require(lk_true_peak_filter(oversampling, &phases, &taps))
        return (0..<Int(phases)).map { p in (0..<Int(taps)).map { table[p * Int(taps) + $0] } }
    }

    /// Response at `omega` (radians per input sample), delay measured from the newest sample.
    private func response(_ c: [Double], _ omega: Double) -> (re: Double, im: Double) {
        var re = 0.0
        var im = 0.0
        for (k, value) in c.enumerated() {
            let delay = Double(c.count - 1 - k)
            re += value * cos(omega * delay)
            im -= value * sin(omega * delay)
        }
        return (re, im)
    }

    private func magnitudeDB(_ c: [Double], _ omega: Double) -> Double {
        let h = response(c, omega)
        return 10 * log10(h.re * h.re + h.im * h.im)
    }

    /// Group delay in samples (numerical derivative of the phase).
    private func groupDelay(_ c: [Double], _ omega: Double) -> Double {
        let step = 1e-5
        let a = response(c, omega + step)
        let b = response(c, omega - step)
        var difference = atan2(a.im, a.re) - atan2(b.im, b.re)
        if difference > .pi { difference -= 2 * .pi }
        if difference < -.pi { difference += 2 * .pi }
        return -difference / (2 * step)
    }

    @Test func fourTimesPhasesAreFlatAndSitBetweenTheSamples() throws {
        let phases = try filter(4)
        #expect(phases.count == 4 && phases.allSatisfy { $0.count == 12 })
        // Phase 3 is phase 0 reversed, phase 2 is phase 1 reversed.
        #expect(phases[3] == Array(phases[0].reversed()))
        #expect(phases[2] == Array(phases[1].reversed()))
        let rate = 48000.0
        for (p, c) in phases.enumerated() {
            var worst = 0.0
            for hz in stride(from: 0.0, through: 20000, by: 50) {
                worst = max(worst, abs(magnitudeDB(c, 2 * .pi * hz / rate)))
            }
            #expect(worst <= 0.25, "phase \(p): \(worst) dB")
            // Low-frequency delay: within 0.07 sample of 5 + (2p + 1) / 8 (1/8, 3/8, 5/8, 7/8 of
            // the way between the 6th and 7th newest samples), increasing with p.
            let delay = groupDelay(c, 2 * .pi * 1000 / rate)
            let nominal = 5 + Double(2 * p + 1) / 8
            #expect(abs(delay - nominal) < 0.07, "phase \(p): delay \(delay), nominal \(nominal)")
        }
        let delays = phases.map { groupDelay($0, 2 * .pi * 1000 / rate) }
        #expect(delays == delays.sorted())
        // Mirrored pairs add up to 11 samples (the 12-tap window's centre is at 5.5).
        #expect(abs(delays[0] + delays[3] - 11) < 1e-6 && abs(delays[1] + delays[2] - 11) < 1e-6)
    }

    @Test func twoTimesFilterIsFlatToFortyPercentOfTheRate() throws {
        let phases = try filter(2)
        #expect(phases.count == 1 && phases[0].count == 24)
        let c = phases[0]
        #expect(abs(c.reduce(0, +) - 1) < 1e-12)  // unity at DC
        var worst = 0.0
        for step in 0...400 {
            worst = max(worst, abs(magnitudeDB(c, 2 * .pi * 0.40 * Double(step) / 400)))
        }
        #expect(worst <= 0.01, "\(worst) dB")
        // Symmetric: exactly half-way between the 12th and 13th newest samples.
        #expect(c == Array(c.reversed()))
        #expect(abs(groupDelay(c, 2 * .pi * 0.1) - 11.5) < 1e-6)
    }

    @Test func otherFactorsHaveNoFilter() {
        var phases: UInt32 = 9
        var taps: UInt32 = 9
        #expect(lk_true_peak_filter(1, &phases, &taps) == nil)
        #expect(phases == 0 && taps == 0)
    }
}
