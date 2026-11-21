import Foundation
import LoudnessKernel
import Testing
@testable import AudioAnalysis

@Suite("K-weighting coefficients")
struct KWeightingTests {
    @Test func reproducesTheBS1770TableAt48kHz() throws {
        // ITU-R BS.1770-5 Annex 1, Tables 1 and 2 (b0, b1, b2, a1, a2).
        let stage1 = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
        let stage2 = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        let derived = try #require(kWeightingCoefficients(sampleRate: 48000))
        for (a, b) in zip(derived.stage1, stage1) { #expect(abs(a - b) < 1e-12, "\(a) vs \(b)") }
        for (a, b) in zip(derived.stage2, stage2) { #expect(abs(a - b) < 1e-12, "\(a) vs \(b)") }
    }

    /// Magnitude response of the cascade in dB at `frequency`.
    private func response(_ sampleRate: Double, _ frequency: Double) throws -> Double {
        let c = try #require(kWeightingCoefficients(sampleRate: sampleRate))
        func magnitude(_ k: [Double]) -> Double {
            let w = 2 * Double.pi * frequency / sampleRate
            let nr = k[0] + k[1] * cos(w) + k[2] * cos(2 * w)
            let ni = -(k[1] * sin(w) + k[2] * sin(2 * w))
            let dr = 1 + k[3] * cos(w) + k[4] * cos(2 * w)
            let di = -(k[3] * sin(w) + k[4] * sin(2 * w))
            return sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        return 20 * log10(magnitude(c.stage1) * magnitude(c.stage2))
    }

    @Test func otherSampleRatesKeepTheSameAudibleResponse() throws {
        // The standard asks for the same frequency response at other rates. Bilinear warping
        // only bends it close to Nyquist, so compare in the audible band below 0.4 fs.
        for rate in [44100.0, 88200, 96000, 192000] {
            for frequency in [20.0, 50, 100, 500, 1000, 2000, 5000, 10000, 15000] where frequency < rate * 0.4 {
                let difference = try response(rate, frequency) - response(48000, frequency)
                #expect(abs(difference) < 0.05, "\(rate) Hz at \(frequency) Hz: \(difference) dB")
            }
        }
        // The -0.691 dB loudness offset compensates exactly this gain at 1 kHz.
        #expect(abs(try response(48000, 1000) - 0.691) < 0.01)
    }

    @Test func rejectsInvalidRates() {
        #expect(kWeightingCoefficients(sampleRate: 0) == nil)
        #expect(kWeightingCoefficients(sampleRate: .nan) == nil)
        #expect(kWeightingCoefficients(sampleRate: 1_000_000) == nil)
        #expect(MeterKernel(.init(sampleRate: 48000, channels: 0)) == nil)
        #expect(MeterKernel(.init(sampleRate: 48000, channels: 9)) == nil)
        #expect(MeterKernel(.init(sampleRate: 48000, channels: 2, weights: [1])) == nil)
        #expect(MeterKernel(.init(sampleRate: 48000, channels: 2, blockCapacity: 3)) == nil)
    }
}

@Suite("Loudness kernel")
struct KernelTests {
    private func silence(_ frames: Int, channels: Int = 2) -> [[Float]] {
        Array(repeating: [Float](repeating: 0, count: frames), count: channels)
    }

    @Test func subBlockLengthIsOneTenthOfASecond() throws {
        for (rate, frames) in [(44100.0, 4410), (48000, 4800), (96000, 9600), (8000, 800)] {
            let kernel = try #require(MeterKernel(.init(sampleRate: rate, channels: 1)))
            #expect(kernel.subBlockFrames == frames)
        }
    }

    @Test func stampsHostContextOnEverySubBlock() throws {
        // 120 bpm, 4/4: 100 ms = 0.2 beats. Buffers of 512 frames do not line up with sub-blocks,
        // so the kernel must extrapolate the beat to each sub-block's first frame.
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 2)))
        var beat = 0.0
        var downbeat = 0.0
        for _ in 0..<(48000 * 3 / 512) {
            if beat >= downbeat + 4 { downbeat += 4 }
            kernel.process(planar: silence(512), context: HostContext(
                beatPosition: beat, tempoBPM: 120, meter: Meter(4, 4), measureDownbeat: downbeat, playing: true))
            beat += 512.0 * 120 / 60 / 48000
        }
        let blocks = kernel.drain()
        #expect(blocks.count == 29)
        for block in blocks {
            #expect(block.flags.isSuperset(of: [.playing, .hasBeat, .hasTempo, .hasMeter, .hasDownbeat, .hasTransport]))
            #expect(!block.flags.contains(.jumpBefore) && !block.flags.contains(.jumpInside))
            let expected = Double(block.index) * 0.2
            #expect(abs(try #require(block.beatPosition) - expected) < 1e-9, "block \(block.index)")
            // The downbeat follows the bar the sub-block starts in.
            let downbeat = try #require(block.measureDownbeat)
            #expect(downbeat <= expected + 1e-6 && expected < downbeat + 4 + 1e-6, "block \(block.index): \(downbeat)")
            #expect(downbeat.truncatingRemainder(dividingBy: 4) == 0)
            #expect(block.startFrame == block.index * 4800)
        }
    }

    @Test func flagsJumpsAndStops() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 1)))
        let tempo = 120.0
        func run(_ frames: Int, beat: Double, playing: Bool) {
            kernel.process(planar: silence(frames, channels: 1),
                           context: HostContext(beatPosition: beat, tempoBPM: tempo, meter: Meter(4, 4), playing: playing))
        }
        let step = 4800.0 * tempo / 60 / 48000  // 0.2 beats per sub-block
        run(4800, beat: 0, playing: true)          // block 0: clean
        run(4800, beat: step, playing: true)       // block 1: clean
        run(4800, beat: 32, playing: true)         // block 2: jump exactly at its start
        run(2400, beat: 32 + step, playing: true)  // block 3, first half
        run(2400, beat: 8, playing: true)          // block 3, second half after a jump
        run(2400, beat: 8 + step / 2, playing: true)  // block 4, first half
        run(2400, beat: 8 + step, playing: false)     // block 4, transport stopped half-way
        let blocks = kernel.drain()
        #expect(blocks.count == 5)
        #expect(blocks[0].flags.contains(.playing) && !blocks[0].flags.contains(.jumpBefore))
        #expect(!blocks[1].flags.contains(.jumpBefore) && !blocks[1].flags.contains(.jumpInside))
        #expect(blocks[2].flags.contains(.jumpBefore) && !blocks[2].flags.contains(.jumpInside))
        #expect(blocks[2].beatPosition == 32)
        #expect(blocks[3].flags.contains(.jumpInside))
        #expect(!blocks[4].flags.contains(.playing))
        #expect(!blocks[4].flags.contains(.jumpInside))
    }

    @Test func reportsTheLoudestTenMillisecondStepWindow() throws {
        #expect(AudioAnalysis.kernelAPIVersion == 2)
        // A steady 1 kHz sine: every 400 ms window holds the same energy, so once 400 ms have
        // passed each sub-block's maximum equals its 100 ms mean square (filters settled).
        let steady = TestSignals.measure([ToneSegment(seconds: 2, dBFS: -20, channels: 2)], channels: 2)
        #expect(steady.prefix(3).allSatisfy { $0.maxMomentaryMeanSquare == 0 })  // less than 400 ms yet
        #expect(steady[3].maxMomentaryMeanSquare > 0)
        for block in steady.dropFirst(5) {
            let ratio = block.maxMomentaryMeanSquare / block.weightedMeanSquare
            #expect(abs(ratio - 1) < 1e-3, "block \(block.index): \(ratio)")
        }
        // A 400 ms burst starting 50 ms into a sub-block, at 8 kHz (80-frame slots): the loudest
        // window holds the whole burst, the 100 ms windows at most 350 ms of it.
        let segments = [ToneSegment(seconds: 0.55, dBFS: nil, channels: 1), ToneSegment(seconds: 0.4, dBFS: -20, channels: 1),
                        ToneSegment(seconds: 1, dBFS: nil, channels: 1)]
        let blocks = TestSignals.measure(segments, sampleRate: 8000, channels: 1)
        let fine = try #require(blocks.map(\.maxMomentaryMeanSquare).max())
        let coarse = try #require(Loudness.windows(blocks.map(MeasuredBlock.init), length: 4).max())
        let burst = Loudness.meanSquare(lufs: -20 - 3.01)  // mono: 3 dB below a stereo sine
        #expect(abs(10 * log10(fine / burst)) < 0.05, "\(10 * log10(fine / burst)) dB")
        #expect(10 * log10(coarse / burst) < -0.5)
    }

    @Test func aJumpRestartsTheMomentaryWindow() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 1)))
        var tone: [Float] = []
        TestSignals.render([ToneSegment(seconds: 1, dBFS: -20, channels: 1)], sampleRate: 48000, channels: 1, chunk: 48000) {
            tone = $0[0]
        }
        func run(_ range: Range<Int>, beat: Double) {
            kernel.process(planar: [Array(tone[range])], context: HostContext(beatPosition: beat, tempoBPM: 120, meter: Meter(4, 4), playing: true))
        }
        // 0.6 s contiguous, then a jump 50 ms into a sub-block, then 0.6 s contiguous again.
        run(0..<28800, beat: 0)
        run(28800..<31200, beat: 1.2)
        run(31200..<48000, beat: 40)
        let blocks = kernel.drain()
        #expect(blocks.count == 10)
        #expect(blocks[3].maxMomentaryMeanSquare > 0 && blocks[5].maxMomentaryMeanSquare > 0)
        // Block 6 holds the jump. Its first half still ends windows that lie wholly before the
        // jump; after it the window restarts with the first slot, so no window ends before
        // 400 ms later, in block 10's range (not drained yet).
        #expect(blocks[6].flags.contains(.jumpInside))
        #expect(abs(blocks[6].maxMomentaryMeanSquare / blocks[5].maxMomentaryMeanSquare - 1) < 1e-3)
        #expect(blocks[7...].allSatisfy { $0.maxMomentaryMeanSquare == 0 }, "\(blocks.map(\.maxMomentaryMeanSquare))")
    }

    @Test func stoppedTransportIsNotAJump() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 1)))
        for _ in 0..<5 {
            kernel.process(planar: silence(4800, channels: 1), context: HostContext(beatPosition: 12, tempoBPM: 100, playing: false))
        }
        let blocks = kernel.drain()
        #expect(blocks.count == 5)
        #expect(blocks.allSatisfy { !$0.flags.contains(.jumpBefore) && !$0.flags.contains(.playing) })
        #expect(blocks.allSatisfy { $0.beatPosition == 12 })
    }

    @Test func interleavedAndPlanarAgree() throws {
        var planar: [[Float]] = [[], []]
        TestSignals.render([ToneSegment(seconds: 1, levelsDBFS: [-12, -20], frequency: 440)], sampleRate: 48000, channels: 2, chunk: 48000) {
            planar = $0
        }
        let interleaved = (0..<48000).flatMap { [planar[0][$0], planar[1][$0]] }
        let a = try #require(MeterKernel(.init(sampleRate: 48000, channels: 2)))
        let b = try #require(MeterKernel(.init(sampleRate: 48000, channels: 2)))
        a.process(planar: planar)
        b.process(interleaved: interleaved)
        let blocksA = a.drain()
        let blocksB = b.drain()
        #expect(blocksA.count == 10)
        #expect(blocksA == blocksB)
        #expect(blocksA[5].channelMeanSquares[0] > blocksA[5].channelMeanSquares[1] * 5)
    }

    @Test func nonFiniteInputDoesNotPoisonTheFilters() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 1)))
        var samples = [Float](repeating: 0, count: 4800)
        samples[100] = .nan
        samples[200] = .infinity
        kernel.process(planar: [samples])
        var tone: [Float] = []
        TestSignals.render([ToneSegment(seconds: 1, dBFS: -20, channels: 1)], sampleRate: 48000, channels: 1, chunk: 48000) { tone = $0[0] }
        kernel.process(planar: [tone])
        let blocks = kernel.drain()
        #expect(blocks.count == 11)
        #expect(blocks.allSatisfy { $0.weightedMeanSquare.isFinite && $0.truePeak.isFinite })
        #expect(blocks[0].samplePeak == 0)
        // Mono 1 kHz at -20 dBFS: -23.0 LUFS once settled.
        let lufs = try #require(Loudness.lufs(meanSquare: blocks[10].weightedMeanSquare))
        #expect(abs(lufs - -23.01) < 0.05)
    }

    @Test func fullRingDropsAndCountsRecords() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 1, blockCapacity: 2)))
        kernel.process(planar: silence(48000, channels: 1))
        #expect(kernel.droppedSubBlocks == 8)
        let blocks = kernel.drain()
        #expect(blocks.map(\.index) == [0, 1])
        kernel.process(planar: silence(4800, channels: 1))
        // Indices keep counting, so the consumer can see the gap.
        #expect(kernel.drain().map(\.index) == [10])
    }

    @Test func tapCarriesTheChannelMean() throws {
        let kernel = try #require(MeterKernel(.init(sampleRate: 48000, channels: 2, tapCapacity: 8192)))
        kernel.process(planar: [[Float](repeating: 0.5, count: 1000), [Float](repeating: -0.25, count: 1000)])
        let tap = kernel.drainTap()
        #expect(tap.count == 1000)
        #expect(tap.allSatisfy { $0 == 0.125 })
        kernel.process(planar: silence(10000))
        #expect(kernel.drainTap().count == 8192)
        #expect(kernel.droppedTapSamples == 10000 - 8192)
    }
}

/// Lets the ring's opaque pointer cross into the test threads (the ring is SPSC-safe by design).
private struct RingHandle: @unchecked Sendable {
    let ring: OpaquePointer
}

@Suite("SPSC ring")
struct RingTests {
    private func makeRing(_ capacity: UInt32) -> (UnsafeMutableRawPointer, OpaquePointer)? {
        let bytes = lk_block_ring_bytes(capacity)
        guard bytes > 0 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        guard let ring = lk_block_ring_init(memory, bytes, capacity) else {
            memory.deallocate()
            return nil
        }
        return (memory, ring)
    }

    @Test func rejectsInvalidCapacitiesAndMemory() {
        #expect(lk_block_ring_bytes(0) == 0)
        #expect(lk_block_ring_bytes(3) == 0)
        #expect(lk_block_ring_bytes(1 << 17) == 0)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
        defer { memory.deallocate() }
        #expect(lk_block_ring_init(memory, 64, 4) == nil)  // too small
        #expect(lk_sample_ring_bytes(5) == 0)
    }

    @Test func fifoOrderAndOverflow() throws {
        let (memory, ring) = try #require(makeRing(4))
        defer { memory.deallocate() }
        var block = lk_subblock()
        for index in 0..<6 {
            block.index = UInt64(index)
            let pushed = lk_block_ring_push(ring, &block)
            #expect(pushed == (index < 4))
        }
        #expect(lk_block_ring_count(ring) == 4)
        #expect(lk_block_ring_dropped(ring) == 2)
        var out = lk_subblock()
        var seen: [UInt64] = []
        while lk_block_ring_pop(ring, &out) { seen.append(out.index) }
        #expect(seen == [0, 1, 2, 3])
        #expect(!lk_block_ring_pop(ring, &out))
    }

    @Test func producerAndConsumerOnSeparateThreads() async throws {
        let (memory, ring) = try #require(makeRing(64))
        defer { memory.deallocate() }
        let handle = RingHandle(ring: ring)
        let total: UInt64 = 200_000
        let producer = Thread {
            var block = lk_subblock()
            var next: UInt64 = 0
            while next < total {
                block.index = next
                block.weighted_mean_square = Double(next) * 0.5
                if lk_block_ring_push(handle.ring, &block) { next += 1 }
            }
        }
        producer.start()
        var expected: UInt64 = 0
        var ordered = true
        var out = lk_subblock()
        let deadline = Date().addingTimeInterval(30)
        while expected < total, Date() < deadline {
            if lk_block_ring_pop(handle.ring, &out) {
                if out.index != expected || out.weighted_mean_square != Double(expected) * 0.5 { ordered = false }
                expected += 1
            }
        }
        #expect(expected == total)
        #expect(ordered)
        // Every refused push is counted as a drop; the producer retried those.
        #expect(lk_block_ring_count(handle.ring) == 0)
    }
}
