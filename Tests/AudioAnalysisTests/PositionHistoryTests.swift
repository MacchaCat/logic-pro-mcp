import Foundation
import Testing
@testable import AudioAnalysis

/// Blocks of 1/8 bar each (exactly representable, so bar arithmetic in the tests is exact).
private func blocks(from startBar: Double, count: Int, lufs: Double, receivedAt: Double = 0, step: Double = 0.125) -> [PositionedBlock] {
    (0..<count).map { index in
        let start = startBar + Double(index) * step
        return PositionedBlock(
            startBar: start, endBar: start + step, seconds: 0.1,
            measured: MeasuredBlock(weightedMeanSquare: Loudness.meanSquare(lufs: lufs), frames: 4800, samplePeak: 0.1, truePeak: 0.1),
            bandPowers: Array(repeating: 0.001, count: ThirdOctaveBands.count),
            tempoBPM: 240, meter: Meter(4, 4), receivedAt: receivedAt)
    }
}

private func append(_ list: [PositionedBlock], to history: inout PositionHistory) {
    history.breakRun()
    for block in list { history.append(block, continuesRun: true) }
}

@Suite("Position history")
struct PositionHistoryTests {
    @Test func fullyPlayedRangeIsCovered() throws {
        var history = PositionHistory(capacity: 10_000)
        append(blocks(from: 1, count: 64, lufs: -20), to: &history)  // bars 1 ... 9
        let m = history.measure(fromBar: 2, toBar: 6)
        #expect(abs(m.coverage - 1) < 1e-9)
        #expect(m.passes == 1)
        #expect(abs(try #require(m.summary.integratedLUFS) - -20) < 1e-9)
        #expect(abs(m.measuredSeconds - 3.2) < 1e-9)
        #expect(m.bandPowers?.count == ThirdOctaveBands.count)
        #expect(m.meters == [Meter(4, 4)])
    }

    @Test func partialCoverage() {
        var history = PositionHistory(capacity: 10_000)
        append(blocks(from: 1, count: 16, lufs: -20), to: &history)  // bars 1 ... 3
        let m = history.measure(fromBar: 2, toBar: 6)
        #expect(abs(m.coverage - 0.25) < 1e-9)
        #expect(history.measure(fromBar: 10, toBar: 11).coverage == 0)
        #expect(history.measure(fromBar: 10, toBar: 11).summary.integratedLUFS == nil)
    }

    @Test func latestPassWinsAndSplitsTheOlderRun() throws {
        var history = PositionHistory(capacity: 10_000)
        append(blocks(from: 1, count: 64, lufs: -20, receivedAt: 1), to: &history)  // bars 1 ... 9 at -20
        append(blocks(from: 4, count: 16, lufs: -30, receivedAt: 2), to: &history)  // bars 4 ... 6 again at -30
        #expect(history.blockCount == 64)
        #expect(history.runCount == 3)  // left part, right part, new pass
        #expect(abs(try #require(history.measure(fromBar: 4, toBar: 6).summary.integratedLUFS) - -30) < 1e-9)
        #expect(abs(try #require(history.measure(fromBar: 1, toBar: 4).summary.integratedLUFS) - -20) < 1e-9)
        #expect(abs(try #require(history.measure(fromBar: 6, toBar: 9).summary.integratedLUFS) - -20) < 1e-9)
        let mixed = history.measure(fromBar: 3, toBar: 7)
        #expect(mixed.passes == 3)
        #expect(abs(mixed.coverage - 1) < 1e-9)
        #expect(history.coveredSpans.count == 1)
    }

    @Test func loopedPassReplacesTheTailOfTheOldOne() {
        var history = PositionHistory(capacity: 10_000)
        append(blocks(from: 1, count: 32, lufs: -20, receivedAt: 1), to: &history)  // bars 1 ... 5
        append(blocks(from: 3, count: 16, lufs: -25, receivedAt: 2), to: &history)  // bars 3 ... 5
        #expect(history.runCount == 2)
        #expect(history.blockCount == 32)
    }

    @Test func memoryCapEvictsTheOldestData() {
        var history = PositionHistory(capacity: 100)
        append(blocks(from: 1, count: 60, lufs: -20, receivedAt: 1), to: &history)   // bars 1 ... 8.5
        append(blocks(from: 20, count: 60, lufs: -20, receivedAt: 2), to: &history)  // bars 20 ... 27.5
        #expect(history.blockCount == 100)
        // The oldest pass lost its first 20 blocks (bars 1 ... 3.5).
        #expect(history.measure(fromBar: 1, toBar: 3).coverage == 0)
        #expect(history.measure(fromBar: 20, toBar: 27).coverage == 1)
        append(blocks(from: 40, count: 150, lufs: -20, receivedAt: 3), to: &history)
        #expect(history.blockCount == 100)
        #expect(history.measure(fromBar: 1, toBar: 30).coverage == 0)
    }

    @Test func runBreakKeepsWindowsApart() {
        var history = PositionHistory(capacity: 1000)
        history.append(blocks(from: 1, count: 1, lufs: -20)[0], continuesRun: true)
        for block in blocks(from: 1.125, count: 2, lufs: -20) { history.append(block, continuesRun: true) }
        history.breakRun()
        for block in blocks(from: 1.375, count: 3, lufs: -20) { history.append(block, continuesRun: true) }
        let m = history.measure(fromBar: 1, toBar: 2)
        #expect(m.summary.subBlocks == 6)
        #expect(m.summary.gatingBlocks == 0)
        #expect(m.passes == 2)
    }

    @Test func evictionCompactsSoMemoryStaysNearTheCap() {
        // One long run at the cap: evicted blocks must not pile up in the backing array.
        var history = PositionHistory(capacity: 2000)
        history.breakRun()
        var worst = 0
        for (index, block) in blocks(from: 1, count: 20_000, lufs: -20, step: 0.01).enumerated() {
            history.append(block, continuesRun: true)
            if index % 97 == 0 { worst = max(worst, history.storedSlots) }
        }
        worst = max(worst, history.storedSlots)
        #expect(history.blockCount == 2000)
        #expect(worst <= 2000 + max(256, 2000 / 4) + 1, "\(worst) slots for 2000 live blocks")
        history.removeAll()
        #expect(history.blockCount == 0 && history.storedSlots == 0 && history.runCount == 0)
    }

    @Test func aBlockStraddlingTheStartCountsWhenItsMidpointIsInside() throws {
        // 100 ms blocks at 120 bpm 4/4 (2 s per bar) are 1/20 bar. A loud transient (peak 0.9) is
        // in the block [8.97, 9.02): 60 ms before bar 9 and 40 ms after, midpoint 8.995, before
        // bar 9. The next block [9.02, 9.07) holds a 0.5 peak.
        var history = PositionHistory(capacity: 1000)
        let step = 0.05
        let starts = [8.87, 8.92, 8.97, 9.02, 9.07, 9.12]
        let peaks = [0.1, 0.1, 0.9, 0.5, 0.1, 0.1]
        history.breakRun()
        for (start, peak) in zip(starts, peaks) {
            history.append(PositionedBlock(
                startBar: start, endBar: start + step, seconds: 0.1,
                measured: MeasuredBlock(weightedMeanSquare: 0.01, frames: 4800, samplePeak: peak, truePeak: peak),
                tempoBPM: 120, meter: Meter(4, 4), receivedAt: 0), continuesRun: true)
        }
        // Midpoint before bar 9: the block belongs to bar 8, even though 40 ms of it is in bar 9.
        let bar9 = history.measure(fromBar: 9, toBar: 10)
        #expect(abs(try #require(bar9.summary.samplePeakDBFS) - 20 * log10(0.5)) < 1e-9)
        #expect(abs(try #require(history.measure(fromBar: 8, toBar: 9).summary.samplePeakDBFS) - 20 * log10(0.9)) < 1e-9)
        // Shifted to [8.985, 9.035) its midpoint is inside bar 9: then its peak counts for bar 9,
        // although 30 ms of the block lie before the bar line (the +-50 ms edge rule).
        var later = PositionHistory(capacity: 1000)
        later.breakRun()
        for (start, peak) in zip(starts, peaks) {
            later.append(PositionedBlock(
                startBar: start + 0.015, endBar: start + 0.015 + step, seconds: 0.1,
                measured: MeasuredBlock(weightedMeanSquare: 0.01, frames: 4800, samplePeak: peak, truePeak: peak),
                tempoBPM: 120, meter: Meter(4, 4), receivedAt: 0), continuesRun: true)
        }
        #expect(abs(try #require(later.measure(fromBar: 9, toBar: 10).summary.truePeakDBTP) - 20 * log10(0.9)) < 1e-9)
    }

    /// A deliberately simple model of the history's rules (latest pass wins, runs split around a
    /// newer pass, windows only inside a run), without capacity limits.
    private struct NaiveHistory {
        var runs: [[PositionedBlock]] = []
        var current: Int?

        mutating func breakRun() { current = nil }

        mutating func append(_ block: PositionedBlock, continuesRun: Bool) {
            if let index = current, !continuesRun || block.startBar < runs[index].last!.startBar { current = nil }
            let lower = current.map { min(block.startBar, runs[$0].last!.endBar) } ?? block.startBar
            let upper = max(block.endBar, lower)
            var kept: [[PositionedBlock]] = []
            var newCurrent: Int?
            for (index, run) in runs.enumerated() {
                if index == current {
                    newCurrent = kept.count
                    kept.append(run)
                    continue
                }
                // Overlapping blocks go; what remains on either side stays as separate runs (also
                // when the new block only falls into a gap of the run).
                let before = run.filter { $0.endBar <= lower }
                let after = run.filter { $0.startBar >= upper }
                if !before.isEmpty { kept.append(before) }
                if !after.isEmpty { kept.append(after) }
            }
            runs = kept
            if let index = newCurrent {
                runs[index].append(block)
                current = index
            } else {
                runs.append([block])
                current = runs.count - 1
            }
        }

        var blockCount: Int { runs.reduce(0) { $0 + $1.count } }

        func groups(_ range: Range<Double>) -> [[PositionedBlock]] {
            runs.map { $0.filter { range.contains($0.midBar) } }.filter { !$0.isEmpty }
                .sorted { $0[0].startBar < $1[0].startBar }
        }
    }

    @Test(arguments: [12345, 777, 2026] as [UInt64])
    func matchesASimpleModelOnRandomPasses(seed: UInt64) {
        // Bars in 1/16 steps (exact in binary) so both sides compare positions exactly. Passes
        // overlap, jump, continue across gaps and land in other runs' gaps.
        var generator = SeededGenerator(seed: seed)
        for trial in 0..<12 {
            var history = PositionHistory(capacity: 1_000_000)
            var model = NaiveHistory()
            var serial = 0.0
            for _ in 0..<60 {
                let start = 1 + Double(Int.random(in: 0..<(16 * 24), using: &generator)) / 16
                let count = Int.random(in: 1...40, using: &generator)
                if Bool.random(using: &generator) {
                    history.breakRun()
                    model.breakRun()
                }
                for index in 0..<count {
                    serial += 1
                    let block = blocks(from: start + Double(index) / 16, count: 1, lufs: -20 - Double(index % 7),
                                       receivedAt: serial, step: 1.0 / 16)[0]
                    // Mostly contiguous playback; now and then a jump inside a pass.
                    let continues = index == 0 ? Bool.random(using: &generator) : Int.random(in: 0..<20, using: &generator) != 0
                    history.append(block, continuesRun: continues)
                    model.append(block, continuesRun: continues)
                }
                #expect(history.invariantViolation() == nil, "seed \(seed) trial \(trial): \(history.invariantViolation() ?? "")")
                #expect(history.blockCount == model.blockCount, "seed \(seed) trial \(trial)")
                #expect(history.runCount == model.runs.count, "seed \(seed) trial \(trial)")
                for _ in 0..<5 {
                    let a = 1 + Double(Int.random(in: 0..<(16 * 26), using: &generator)) / 16
                    let b = a + Double(Int.random(in: 1..<(16 * 8), using: &generator)) / 16
                    let actual = history.groups(midpointsIn: a..<b).map { $0.map(\.receivedAt) }
                    let expected = model.groups(a..<b).map { $0.map(\.receivedAt) }
                    #expect(actual == expected, "seed \(seed) trial \(trial), bars \(a)..<\(b)")
                }
            }
        }
    }

    @Test(arguments: [5, 41, 2027] as [UInt64])
    func invariantsHoldUnderSmallCaps(seed: UInt64) {
        // Capacity and run cap both bite all the time: eviction, whole-run removal and splits mix.
        var generator = SeededGenerator(seed: seed)
        var history = PositionHistory(capacity: 200, maxRuns: 8)
        var serial = 0.0
        for pass in 0..<400 {
            if Bool.random(using: &generator) { history.breakRun() }
            let start = 1 + Double(Int.random(in: 0..<(16 * 30), using: &generator)) / 16
            for index in 0..<Int.random(in: 1...60, using: &generator) {
                serial += 1
                let block = blocks(from: start + Double(index) / 16, count: 1, lufs: -20, receivedAt: serial, step: 1.0 / 16)[0]
                history.append(block, continuesRun: index == 0 ? Bool.random(using: &generator) : Int.random(in: 0..<15, using: &generator) != 0)
            }
            if pass % 50 == 49 { history.evictOldest(Int.random(in: 1...150, using: &generator)) }
            #expect(history.invariantViolation() == nil, "seed \(seed) pass \(pass): \(history.invariantViolation() ?? "")")
            #expect(history.blockCount <= 200 && history.runCount <= 8)
            let a = 1 + Double(Int.random(in: 0..<(16 * 30), using: &generator)) / 16
            let m = history.measure(fromBar: a, toBar: a + 4)
            #expect(m.coverage >= 0 && m.coverage <= 1)
        }
    }

    @Test func runCountIsCappedAndTheLeastRecentRunGoesFirst() {
        var history = PositionHistory(capacity: 10_000, maxRuns: 8)
        for index in 0..<100 {
            history.breakRun()
            // Every pass at its own place, in an order that jumps back and forth.
            let bar = 1 + Double((index * 37) % 100)
            for block in blocks(from: bar, count: 3, lufs: -20, receivedAt: Double(index)) {
                history.append(block, continuesRun: true)
            }
            #expect(history.runCount <= 8)
        }
        #expect(history.blockCount == 8 * 3)
        // The eight newest passes survive.
        let kept = Set(history.coveredSpans.map { Int($0.lowerBound) })
        let newest = Set((92..<100).map { 1 + ($0 * 37) % 100 })
        #expect(kept == newest)
    }

    @Test func manyTinyOutOfOrderRunsStayWithinTimeAndMemoryBounds() {
        // The production limits: 72 000 blocks, 1024 runs per instance.
        var history = PositionHistory(capacity: 72_000, maxRuns: 1024)
        var generator = SeededGenerator(seed: 99)
        let clock = ContinuousClock()
        let started = clock.now
        // One long pass first (50 000 blocks), so a whole-array copy per block would show.
        history.breakRun()
        for block in blocks(from: 1, count: 50_000, lufs: -20, receivedAt: 0, step: 0.01) {
            history.append(block, continuesRun: true)
        }
        let workBefore = history.work
        // Then 100 000 tiny passes of 1-3 blocks at random places, out of order: each starts a
        // run, many land inside older runs and split them.
        var appended = 0
        var worstRuns = 0
        var worstSlots = 0
        var worstAllocated = 0
        for pass in 0..<100_000 {
            history.breakRun()
            let start = 1 + Double(Int.random(in: 0..<50_000, using: &generator)) * 0.01
            for block in blocks(from: start, count: Int.random(in: 1...3, using: &generator), lufs: -30,
                                receivedAt: Double(pass + 1), step: 0.01) {
                history.append(block, continuesRun: true)
                appended += 1
            }
            if pass % 997 == 0 {
                #expect(history.invariantViolation() == nil, "pass \(pass): \(history.invariantViolation() ?? "")")
                worstRuns = max(worstRuns, history.runCount)
                worstSlots = max(worstSlots, history.storedSlots - history.blockCount)
                worstAllocated = max(worstAllocated, history.allocatedSlots)
            }
        }
        let elapsed = started.duration(to: clock.now)
        #expect(history.runCount <= 1024 && worstRuns <= 1024)
        #expect(history.blockCount <= 72_000)
        // Dead slots stay a fraction of the live blocks; allocations at most about twice that
        // plus a little per run.
        #expect(worstSlots <= 72_000 / 4 + 32 * 1024, "\(worstSlots) dead slots")
        #expect(worstAllocated <= 2 * (72_000 + 72_000 / 4) + 64 * 1024, "\(worstAllocated) slots allocated")
        // Bounded work per block: searches and visits, not a scan over every run or block.
        let perBlock = Double(history.work - workBefore) / Double(appended)
        #expect(perBlock < 200, "\(perBlock) steps per appended block")
        // A loose wall-clock bound (debug build, shared machine; about 1 s here). A scan over every
        // run per block (no run cap: up to 100 000 runs here) would take hours.
        #expect(elapsed < .seconds(30), "\(elapsed)")
        // Still answers queries consistently.
        let m = history.measure(fromBar: 1, toBar: 501)
        #expect(m.coverage > 0 && m.coverage <= 1)
    }

    @Test func blockThatGoesBackwardsStartsANewRun() {
        var history = PositionHistory(capacity: 1000)
        for block in blocks(from: 5, count: 5, lufs: -20, receivedAt: 1) { history.append(block, continuesRun: true) }
        for block in blocks(from: 2, count: 5, lufs: -20, receivedAt: 2) { history.append(block, continuesRun: true) }
        #expect(history.runCount == 2)
    }
}

/// A small deterministic generator (SplitMix64) so randomized tests can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
