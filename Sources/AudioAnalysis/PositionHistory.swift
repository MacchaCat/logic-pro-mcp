import Foundation

/// A measured sub-block placed on the musical timeline.
///
/// Bars are fractional and 1-based: bar 9 spans [9.0, 10.0). They are derived from the host's
/// quarter-note beat position and the reported time signature as `1 + beat / quarterNotesPerBar`,
/// which assumes beat 0 is the start of bar 1 and the meter has not changed before this point.
public struct PositionedBlock: Sendable, Equatable {
    public var startBar: Double
    public var endBar: Double
    public var seconds: Double
    public var measured: MeasuredBlock
    /// One-third-octave band powers (mean square), `ThirdOctaveBands.count` values, if sent.
    public var bandPowers: [Float]?
    public var tempoBPM: Double
    public var meter: Meter
    /// When the server received it (seconds since the reference date).
    public var receivedAt: Double

    public init(
        startBar: Double, endBar: Double, seconds: Double, measured: MeasuredBlock,
        bandPowers: [Float]? = nil, tempoBPM: Double, meter: Meter, receivedAt: Double
    ) {
        self.startBar = startBar
        self.endBar = endBar
        self.seconds = seconds
        self.measured = measured
        self.bandPowers = bandPowers
        self.tempoBPM = tempoBPM
        self.meter = meter
        self.receivedAt = receivedAt
    }

    public var midBar: Double { (startBar + endBar) / 2 }
}

/// What the history holds for one bar range.
public struct RangeMeasurement: Sendable {
    /// Fraction of the range covered by stored sub-blocks (0 ... 1).
    public var coverage: Double
    public var measuredSeconds: Double
    public var summary: LoudnessSummary
    /// Average band powers over the sub-blocks that carried a spectrum (frame-weighted).
    public var bandPowers: [Double]?
    public var minTempo: Double?
    public var maxTempo: Double?
    public var meters: [Meter]
    /// Number of separate contiguous passes the data comes from.
    public var passes: Int
    public var oldestReceivedAt: Double?
    public var newestReceivedAt: Double?
}

/// Per-instance history of measured sub-blocks keyed by musical position, with bounded memory
/// and bounded work per block.
///
/// Data arrives in runs (one contiguous stretch of playback). Loudness windows are only ever
/// built inside one run. When a new pass plays over a position that is already stored, the older
/// data there is removed: the latest pass wins. A run that continues across a small gap claims
/// the gap too, so stored runs always cover disjoint stretches of the timeline.
///
/// Costs, with R runs (at most `maxRuns`) and n blocks (at most `capacity`):
/// - `append`: O(log R) to find the runs a block overlaps, plus O(1) amortized per block removed;
///   a run split around a newer pass copies only its smaller side (each block is copied
///   O(log n) times over its life). Inserting or removing a run id in the position index moves at
///   most R integers.
/// - eviction: O(log R) amortized per run (least recently updated first, via a heap).
/// - `groups(midpointsIn:)` / `measure`: O(log R + runs and blocks in the range).
/// The number of runs is capped: when a new run would exceed `maxRuns`, the least recently
/// updated run is dropped whole, so a stream of tiny out-of-order runs cannot grow the index.
public struct PositionHistory: Sendable {
    struct Run: Sendable {
        var blocks: [PositionedBlock]
        /// Index of the first live block (a cheap prefix removal).
        var head: Int
        var updatedAt: Double
        /// Order of the last append to this run (larger = more recent). A part split off a run
        /// keeps its origin's value.
        var touch: UInt64

        var live: ArraySlice<PositionedBlock> { blocks[head...] }
        var liveCount: Int { blocks.count - head }
        /// Start and end of the stretch the run covers (only for runs with live blocks).
        var start: Double { blocks[head].startBar }
        var end: Double { blocks[blocks.count - 1].endBar }

        /// Drops the dead prefix once it is a quarter of the live part (or the run is small), and
        /// releases spare capacity, so a run holds at most 1.25 x its live blocks plus the growth
        /// slack of its array. Each copy of k live blocks is paid for by >= k / 4 removals, or
        /// costs at most 32 copies.
        mutating func compact() {
            guard head > 0 else { return }
            if head * 4 >= liveCount || liveCount <= 32 {
                blocks = Array(blocks[head...])
                head = 0
            }
        }

        /// After removing blocks at the end: gives back the buffer when it is mostly empty.
        mutating func shrinkIfSparse() {
            if blocks.capacity > 2 * blocks.count + 64 {
                blocks = Array(blocks[head...])
                head = 0
            }
        }
    }

    public let capacity: Int
    public let maxRuns: Int
    private var runs: [Int: Run] = [:]
    /// Ids of the stored runs in timeline order (their stretches are disjoint, so starts and ends
    /// are both increasing).
    private var order: [Int] = []
    /// Runs other than the current one, least recently updated first (stale entries of removed
    /// runs are skipped lazily).
    private var lru = RunHeap()
    private var currentRunID: Int?
    private var nextRunID = 0
    private var touches: UInt64 = 0
    public private(set) var blockCount = 0
    /// Steps taken by searches, run visits and heap operations (for complexity tests).
    var work = 0

    public init(capacity: Int, maxRuns: Int = 1024) {
        self.capacity = max(capacity, 1)
        self.maxRuns = max(maxRuns, 2)
    }

    /// Ends the current run: the next block starts a new one.
    public mutating func breakRun() {
        retireCurrentRun()
    }

    public var runCount: Int { runs.count }

    /// Forgets everything stored.
    public mutating func removeAll() {
        runs.removeAll()
        order.removeAll()
        lru = RunHeap()
        currentRunID = nil
        blockCount = 0
    }

    /// Block slots held in memory, evicted ones not yet compacted away included (for tests).
    var storedSlots: Int { runs.values.reduce(0) { $0 + $1.blocks.count } }
    /// Block slots allocated, spare array capacity included (for tests).
    var allocatedSlots: Int { runs.values.reduce(0) { $0 + $1.blocks.capacity } }

    /// The first broken internal invariant, nil when all hold (for tests): the position index
    /// lists every run once, in order, with disjoint stretches; no run is empty; the counts and
    /// limits match.
    func invariantViolation() -> String? {
        guard order.count == runs.count, Set(order).count == order.count else {
            return "the index lists \(order.count) ids for \(runs.count) runs"
        }
        var live = 0
        var previousEnd = -Double.infinity
        for id in order {
            guard let run = runs[id] else { return "the index lists a missing run \(id)" }
            guard run.liveCount > 0 else { return "run \(id) is empty" }
            guard run.start >= previousEnd else { return "run \(id) starts at \(run.start) before \(previousEnd)" }
            guard zip(run.live, run.live.dropFirst()).allSatisfy({ $0.startBar <= $1.startBar }) else {
                return "run \(id) is not in bar order"
            }
            previousEnd = run.end
            live += run.liveCount
        }
        if live != blockCount { return "blockCount \(blockCount), live blocks \(live)" }
        if blockCount > capacity { return "\(blockCount) blocks over the capacity \(capacity)" }
        if runs.count > maxRuns { return "\(runs.count) runs over the cap \(maxRuns)" }
        if let id = currentRunID, runs[id] == nil { return "the current run \(id) does not exist" }
        return nil
    }

    /// When the least recently updated run was last updated.
    public var oldestUpdate: Double? {
        if let top = lru.min, let run = runs[top.id] { return run.updatedAt }
        return currentRunID.flatMap { runs[$0]?.updatedAt }
    }

    /// Appends `block`; continues the current run when `continuesRun` and the block does not go
    /// back before the run's last block. Stored data of other runs that overlaps the block (or
    /// the gap between the run's end and the block) is removed.
    public mutating func append(_ block: PositionedBlock, continuesRun: Bool) {
        touches += 1
        if let id = currentRunID, let last = runs[id]?.blocks.last, !continuesRun || block.startBar < last.startBar {
            retireCurrentRun()
        }
        let current = currentRunID.flatMap { runs[$0] != nil ? $0 : nil }
        let lower = current.map { min(block.startBar, runs[$0]!.end) } ?? block.startBar
        let upper = max(block.endBar, lower)
        removeOverlap(lower, upper, except: current)
        if let id = current {
            runs[id]!.blocks.append(block)
            runs[id]!.updatedAt = block.receivedAt
            runs[id]!.touch = touches
        } else {
            if runs.count >= maxRuns { removeLeastRecentRun() }
            let id = nextRunID
            nextRunID += 1
            runs[id] = Run(blocks: [block], head: 0, updatedAt: block.receivedAt, touch: touches)
            let position = search { runs[$0]!.start >= block.startBar }
            work += searchCost
            order.insert(id, at: position)
            currentRunID = id
        }
        blockCount += 1
        if blockCount > capacity { evictOldest(blockCount - capacity) }
        settle()
    }

    /// Removes up to `count` blocks from the start of the least recently updated run (the run
    /// being recorded only when no other run holds blocks). Returns how many were removed.
    @discardableResult
    public mutating func evictOldest(_ count: Int) -> Int {
        var remaining = count
        while remaining > 0 {
            guard let id = leastRecentRun() ?? currentRunID.flatMap({ runs[$0] != nil ? $0 : nil }) else { break }
            let live = runs[id]!.liveCount
            let n = min(remaining, live)
            if n == live {
                removeRun(id)
            } else {
                runs[id]!.head += n
                runs[id]!.compact()
            }
            blockCount -= n
            remaining -= n
        }
        settle()
        return count - remaining
    }

    /// Sub-blocks whose midpoint lies in `range` (bars), grouped by contiguous run, in bar order.
    ///
    /// A 100 ms sub-block is the smallest unit, so a range's edges are only accurate to +-50 ms:
    /// a block that straddles the start belongs to the range when its midpoint is inside, and
    /// its loudness and peaks (up to 50 ms of audio before `lowerBound`) count for the range.
    public func groups(midpointsIn range: Range<Double>) -> [[PositionedBlock]] {
        var groups: [[PositionedBlock]] = []
        var index = search { runs[$0]!.end > range.lowerBound }
        while index < order.count {
            let run = runs[order[index]]!
            if run.start >= range.upperBound { break }
            let live = run.live
            let first = partition(live) { $0.midBar >= range.lowerBound }
            let end = partition(live) { $0.midBar >= range.upperBound }
            if first < end { groups.append(Array(live[first..<end])) }
            index += 1
        }
        return groups
    }

    /// Loudness, peaks, spectrum and coverage for bars [fromBar, toBar).
    public func measure(fromBar: Double, toBar: Double) -> RangeMeasurement {
        let groups = groups(midpointsIn: fromBar..<toBar)
        let length = toBar - fromBar
        var covered = 0.0
        var seconds = 0.0
        var bandSums: [Double]?
        var bandFrames = 0.0
        var tempos: [Double] = []
        var meters: [Meter] = []
        var oldest: Double?
        var newest: Double?
        for group in groups {
            for block in group {
                covered += max(0, min(block.endBar, toBar) - max(block.startBar, fromBar))
                seconds += block.seconds
                tempos.append(block.tempoBPM)
                if !meters.contains(block.meter) { meters.append(block.meter) }
                oldest = min(oldest ?? block.receivedAt, block.receivedAt)
                newest = max(newest ?? block.receivedAt, block.receivedAt)
                if let powers = block.bandPowers, powers.count == ThirdOctaveBands.count {
                    let weight = Double(block.measured.frames)
                    var sums = bandSums ?? Array(repeating: 0, count: ThirdOctaveBands.count)
                    for (index, power) in powers.enumerated() { sums[index] += Double(power) * weight }
                    bandSums = sums
                    bandFrames += weight
                }
            }
        }
        return RangeMeasurement(
            coverage: length > 0 ? min(1, covered / length) : 0,
            measuredSeconds: seconds,
            summary: LoudnessSummary(runs: groups.map { $0.map(\.measured) }),
            bandPowers: bandFrames > 0 ? bandSums?.map { $0 / bandFrames } : nil,
            minTempo: tempos.min(),
            maxTempo: tempos.max(),
            meters: meters,
            passes: groups.count,
            oldestReceivedAt: oldest,
            newestReceivedAt: newest
        )
    }

    /// Covered stretches of the timeline (bars), merged, in order.
    public var coveredSpans: [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for id in order {
            let run = runs[id]!
            let span = run.start...max(run.start, run.end)
            if let last = merged.last, span.lowerBound <= last.upperBound + 0.01 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    // MARK: Private

    /// The current run stops being recorded; it becomes a candidate for eviction.
    private mutating func retireCurrentRun() {
        if let id = currentRunID, let run = runs[id] {
            lru.push((run.touch, id))
            work += 1
        }
        currentRunID = nil
    }

    /// Indices into a run's `blocks` (head, end, and the overlap [first, last) with [lower, upper)).
    /// The run is only read here, so no reference to its buffer outlives the call (a mutation
    /// right after must not copy the whole array).
    private func overlap(of id: Int, _ lower: Double, _ upper: Double) -> (head: Int, total: Int, first: Int, last: Int) {
        let run = runs[id]!
        let live = run.live
        return (run.head, run.blocks.count, partition(live) { $0.endBar > lower }, partition(live) { $0.startBar >= upper })
    }

    /// Removes the blocks of runs other than `except` that overlap [lower, upper).
    private mutating func removeOverlap(_ lower: Double, _ upper: Double, except: Int?) {
        var index = search { runs[$0]!.end > lower }
        work += searchCost
        while index < order.count {
            work += 1
            let id = order[index]
            guard runs[id]!.start < upper else { break }
            if id == except {
                index += 1
                continue
            }
            let (head, total, first, last) = overlap(of: id, lower, upper)
            work += 2 * (Int.bitWidth - (total - head).leadingZeroBitCount)
            // No block overlaps and [lower, upper) is not inside the run: nothing to do. (Inside the
            // run without overlapping a block means it lands in a gap the run had claimed; the run
            // is split there below, without removing anything, so runs stay disjoint.)
            if first == last, first == head || first == total {
                index += 1
                continue
            }
            // Defensive: a zero-width range (only possible with a degenerate block) must not make
            // the count grow or copy a block into two runs.
            guard first <= last else {
                index += 1
                continue
            }
            blockCount -= last - first
            if first == head && last == total {
                runs[id] = nil
                order.remove(at: index)
                if currentRunID == id { currentRunID = nil }
            } else if first == head {
                runs[id]!.head = last
                runs[id]!.compact()
                index += 1
            } else if last == total {
                runs[id]!.blocks.removeLast(total - first)
                runs[id]!.shrinkIfSparse()
                index += 1
            } else {
                // A newer pass inside an older run: the run splits in two. The smaller side is
                // copied into a new run, so a block is copied O(log n) times over its life.
                let newID = nextRunID
                nextRunID += 1
                let updatedAt = runs[id]!.updatedAt
                let touch = runs[id]!.touch
                if first - head <= total - last {
                    let left = Array(runs[id]!.blocks[head..<first])
                    runs[newID] = Run(blocks: left, head: 0, updatedAt: updatedAt, touch: touch)
                    runs[id]!.head = last
                    runs[id]!.compact()
                    order.insert(newID, at: index)
                } else {
                    let right = Array(runs[id]!.blocks[last...])
                    runs[newID] = Run(blocks: right, head: 0, updatedAt: updatedAt, touch: touch)
                    runs[id]!.blocks.removeLast(total - first)
                    runs[id]!.shrinkIfSparse()
                    order.insert(newID, at: index + 1)
                }
                lru.push((touch, newID))
                work += 1
                index += 2
            }
        }
        // A split can take the count one over the cap (removing a run inside the loop would shift
        // `index`, so it happens here).
        while runs.count > maxRuns, removeLeastRecentRun() {}
    }

    /// The least recently updated run other than the current one, if any (cleans stale heap entries).
    private mutating func leastRecentRun() -> Int? {
        while let top = lru.min {
            if top.id != currentRunID, let touch = runs[top.id]?.touch, touch == top.touch { return top.id }
            lru.popMin()
            work += 1
        }
        return nil
    }

    /// Drops the least recently updated run other than the current one whole. False when there is
    /// no such run.
    @discardableResult
    private mutating func removeLeastRecentRun() -> Bool {
        guard let id = leastRecentRun() else { return false }
        blockCount -= runs[id]!.liveCount
        removeRun(id)
        return true
    }

    private mutating func removeRun(_ id: Int) {
        guard let start = runs[id]?.start else { return }
        let index = search { runs[$0]!.start >= start }
        work += searchCost
        if index < order.count, order[index] == id {
            order.remove(at: index)
        } else if let found = order.firstIndex(of: id) {
            order.remove(at: found)  // not reached while starts are distinct; kept as a safety net
        }
        runs[id] = nil
        if currentRunID == id { currentRunID = nil }
    }

    /// Keeps the heap's top valid (so `oldestUpdate` can read it) and its size bounded.
    private mutating func settle() {
        _ = leastRecentRun()
        if lru.count > 2 * runs.count + 64 {
            let current = currentRunID
            lru = RunHeap(runs.compactMap { id, run in id == current ? nil : (run.touch, id) })
            work += runs.count
        }
    }

    /// First index in `order` where `predicate` (monotonic: false ... true) holds.
    private func search(_ predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = order.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(order[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }

    /// Steps of one `search` (for the work counter).
    private var searchCost: Int { Int.bitWidth - order.count.leadingZeroBitCount }
}

/// A binary min-heap of (touch, run id).
struct RunHeap: Sendable {
    private var items: [(touch: UInt64, id: Int)] = []

    init() {}

    init(_ entries: [(UInt64, Int)]) {
        for entry in entries { push(entry) }
    }

    var count: Int { items.count }
    var min: (touch: UInt64, id: Int)? { items.first }

    mutating func push(_ entry: (UInt64, Int)) {
        items.append((entry.0, entry.1))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].touch < items[parent].touch else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popMin() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left].touch < items[smallest].touch { smallest = left }
            if right < items.count, items[right].touch < items[smallest].touch { smallest = right }
            guard smallest != parent else { return }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

/// First index in `slice` where `predicate` becomes true (the predicate must be monotonic).
private func partition(_ slice: ArraySlice<PositionedBlock>, _ predicate: (PositionedBlock) -> Bool) -> Int {
    var low = slice.startIndex
    var high = slice.endIndex
    while low < high {
        let mid = (low + high) / 2
        if predicate(slice[mid]) { high = mid } else { low = mid + 1 }
    }
    return low
}
