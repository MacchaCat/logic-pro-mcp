import Accelerate
import Foundation

/// The 30 one-third-octave bands from 25 Hz to 20 kHz (base-2 centres 1000 * 2^(k/3),
/// k = -16 ... 13, labelled with their nominal IEC 61260 frequencies).
public enum ThirdOctaveBands {
    public static let nominalCenters: [Double] = [
        25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000,
        1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]
    public static let exactCenters: [Double] = (-16...13).map { 1000 * pow(2, Double($0) / 3) }
    public static var count: Int { nominalCenters.count }

    /// Band edges: centre * 2^(-1/6) ... centre * 2^(1/6).
    public static func edges(_ index: Int) -> (lower: Double, upper: Double) {
        let center = exactCenters[index]
        return (center * pow(2, -1.0 / 6), center * pow(2, 1.0 / 6))
    }

    /// Band power (mean square) as dB relative to a full-scale sine (AES17 dBFS): a 0 dBFS sine
    /// whose energy falls in one band reads 0 dB there. nil for zero power.
    public static func decibels(power: Double) -> Double? {
        guard power > 0, power.isFinite else { return nil }
        return 10 * log10(2 * power)
    }
}

/// Averaged one-third-octave spectrum of a mono signal: Hann window, 50 % overlap, power
/// averaged over every FFT frame completed since the last `takeBandPowers()` (Welch). Uses
/// vDSP; runs on background threads only (it allocates).
public final class SpectrumAnalyzer {
    public let sampleRate: Double
    public let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let powerScale: Float
    /// Per band: (bin, fraction of the bin's width inside the band).
    private let bandBins: [[(bin: Int, weight: Double)]]
    private var pending: [Float] = []
    private var bandSums: [Double]
    private var framesAveraged = 0

    /// `fftSize` must be a power of two in 1024 ... 16384; default 4096 up to 50 kHz, else 8192.
    public init?(sampleRate: Double, fftSize: Int? = nil) {
        let size = fftSize ?? (sampleRate <= 50_000 ? 4096 : 8192)
        guard sampleRate >= 8000, sampleRate <= 768_000, size >= 1024, size <= 16384, size.nonzeroBitCount == 1 else {
            return nil
        }
        let log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        self.fftSize = size
        self.log2n = log2n
        self.setup = setup
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
        self.window = window
        let windowEnergy = window.reduce(0) { $0 + Double($1) * Double($1) }
        // vDSP's real FFT returns 2 * X[k]; one-sided power of bin k is 2 |X[k]|^2 / (N * sum w^2).
        powerScale = Float(1 / (2 * Double(size) * windowEnergy))
        let binWidth = sampleRate / Double(size)
        bandBins = (0..<ThirdOctaveBands.count).map { band in
            let (lower, upper) = ThirdOctaveBands.edges(band)
            var bins: [(Int, Double)] = []
            let first = max(1, Int((lower / binWidth).rounded(.down)))
            let last = min(size / 2 - 1, Int((upper / binWidth).rounded(.up)))
            if first <= last {
                for bin in first...last {
                    let low = (Double(bin) - 0.5) * binWidth
                    let high = (Double(bin) + 0.5) * binWidth
                    let overlap = min(high, upper) - max(low, lower)
                    if overlap > 0 { bins.append((bin, overlap / binWidth)) }
                }
            }
            return bins
        }
        bandSums = Array(repeating: 0, count: ThirdOctaveBands.count)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func append(_ samples: [Float]) {
        pending += samples
        let hop = fftSize / 2
        var consumed = 0
        while pending.count - consumed >= fftSize {
            analyze(pending[consumed..<(consumed + fftSize)])
            consumed += hop
        }
        if consumed > 0 { pending.removeFirst(consumed) }
    }

    /// Mean band powers over the FFT frames completed since the last call; nil if none completed.
    public func takeBandPowers() -> [Double]? {
        guard framesAveraged > 0 else { return nil }
        let result = bandSums.map { $0 / Double(framesAveraged) }
        bandSums = Array(repeating: 0, count: ThirdOctaveBands.count)
        framesAveraged = 0
        return result
    }

    private func analyze(_ frame: ArraySlice<Float>) {
        let n = fftSize
        var windowed = [Float](repeating: 0, count: n)
        frame.withUnsafeBufferPointer { input in
            vDSP_vmul(input.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imag.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        var scale = powerScale
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(n / 2))
        for (band, bins) in bandBins.enumerated() {
            var power = 0.0
            for (bin, weight) in bins { power += Double(magnitudes[bin]) * weight }
            bandSums[band] += power
        }
        framesAveraged += 1
    }
}
