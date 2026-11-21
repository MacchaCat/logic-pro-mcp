import MIDICore
import Synchronization

/// Logic's position on its MIDI clock, from the Song Position Pointer / Start / Continue / Stop /
/// Timing Clock messages Logic sends to `LogicMCP Sync`, with arrival times.
///
/// Unlike `SyncSnapshot` (a coarse status), this keeps the absolute clock tick of every clock
/// (24 per quarter note; one SPP unit = 6 ticks) so a sender can follow Logic's position.
/// Tick convention (MIDI 1.0): after Continue the **first** clock is at the song position
/// (SPP × 6) and each further clock adds one tick. The Logic 13 capture (note-recording spike)
/// confirms this only to about ±1 tick: the time display Logic sent agrees with it within
/// 0.3–0.5 tick (the clock slightly ahead), and the 247th clock, tick 918 (= SPP 153.0), arrived
/// in the same millisecond as Stop although Logic then reported SPP 152. So Logic's clock may
/// lead its own playhead by up to about a tick (the capture logged arrival times, not CoreMIDI
/// timestamps). If that lead is Logic scheduling its clock ahead with future timestamps, the
/// timestamps now used here remove it, and `write_midi` reports it (timestamp minus arrival);
/// the Event List check (phase-4 checklist B4/B5) decides it.
///
/// Thread-safe and lock-protected so a real-time sender thread can read it while `SyncMonitor`
/// feeds it. Event times are the CoreMIDI packet timestamps when Logic sets them (a clock
/// scheduled ahead is then timed where Logic meant it, not where CoreMIDI delivered it), and
/// otherwise the receipt time taken in the CoreMIDI callback (`TimedMIDIMessage`); only
/// untimed input (`SyncMonitor.start(input:)` with plain messages) is timed when processed.
public final class SyncTimeline: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Song Position Pointer in sixteenths (MIDI beats).
        case songPosition(Int)
        case start
        case `continue`
        case stop
        /// A Timing Clock. `tick` is its absolute tick, nil while the position is unknown or the
        /// transport is not running (clocks while stopped do not move the position).
        case clock(tick: Int?)
    }

    public struct Event: Sendable, Equatable {
        public var kind: Kind
        public var time: ContinuousClock.Instant
        /// Increases by one per sync message, so callers can ask "what arrived since".
        public var sequence: Int
        /// The packet timestamp minus the receipt time (positive: sent ahead of time); nil when
        /// the message carried no timestamp and `time` is the receipt time.
        public var timestampLead: Duration?
    }

    public struct ClockSample: Sendable, Equatable {
        public var tick: Int
        public var time: ContinuousClock.Instant

        public init(tick: Int, time: ContinuousClock.Instant) {
            self.tick = tick
            self.time = time
        }
    }

    /// Where Logic is now, as far as the clock shows.
    public struct Fix: Sendable {
        public var sequence: Int
        /// True after Start/Continue, false after Stop, nil before either.
        public var running: Bool?
        /// How many SPP messages have arrived so far (a new one while running means a jump).
        public var songPositionCount: Int
        public var lastSongPosition: Event?
        /// The last Start, Continue or Stop.
        public var lastTransport: Event?
        /// The latest clock with a known tick, since the last Start/Continue/SPP.
        public var lastClock: ClockSample?
        /// Clocks with a known tick since the last Start/Continue.
        public var clocksSinceStart: Int
        /// Seconds per tick from the last 24 clocks (least squares), nil with fewer than two.
        public var secondsPerTick: Double?
        /// The time of `lastClock.tick` smoothed over recent clocks (median of projections), so
        /// one late arrival does not shift predictions.
        public var anchor: ContinuousClock.Instant?

        public var tempoBPM: Double? { secondsPerTick.map { 60 / ($0 * 24) } }

        /// When Logic's clock reaches `tick`, extrapolated from recent clocks.
        public func time(ofTick tick: Double) -> ContinuousClock.Instant? {
            guard let lastClock, let secondsPerTick, let anchor else { return nil }
            return anchor.advanced(by: .seconds((tick - Double(lastClock.tick)) * secondsPerTick))
        }

        /// Logic's position in ticks at `time`, extrapolated from recent clocks.
        public func tick(at time: ContinuousClock.Instant) -> Double? {
            guard let lastClock, let secondsPerTick, let anchor, secondsPerTick > 0 else { return nil }
            return Double(lastClock.tick) + anchor.duration(to: time).seconds / secondsPerTick
        }
    }

    struct State {
        var sequence = 0
        var running: Bool?
        /// Tick the next clock carries while running; nil until an SPP or Start sets it.
        var nextTick: Int?
        var clocksSinceStart = 0
        var recent: [ClockSample] = []
        var songPositionCount = 0
        var songPositions: [Event] = []
        var lastTransport: Event?
        var capture: [Event]?
    }

    /// Clocks kept for the tempo and anchor estimates.
    static let recentLimit = 24
    static let anchorWindow = 6
    static let songPositionLimit = 64
    /// Safety bound for one capture (about 70 minutes of clock at 120 BPM).
    static let captureLimit = 200_000

    private let state = Mutex(State())

    public init() {}

    /// Feeds one message from Logic's sync output, at the time it stands for (its timestamp, or
    /// when it arrived); `timestampLead` is kept for the evidence. Other message types are ignored.
    public func record(_ message: MIDIMessage, at time: ContinuousClock.Instant, timestampLead: Duration? = nil) {
        state.withLock { state in
            let kind: Kind
            switch message {
            case .songPosition(let value):
                kind = .songPosition(Int(value))
                state.nextTick = Int(value) * 6
                state.recent.removeAll()
                state.songPositionCount += 1
            case .start:
                kind = .start
                state.running = true
                state.nextTick = 0
                state.clocksSinceStart = 0
                state.recent.removeAll()
            case .continue:
                kind = .continue
                state.running = true
                state.clocksSinceStart = 0
                state.recent.removeAll()
            case .stop:
                kind = .stop
                state.running = false
                state.recent.removeAll()
            case .timingClock:
                if state.running == true, let tick = state.nextTick {
                    kind = .clock(tick: tick)
                    state.nextTick = tick + 1
                    state.clocksSinceStart += 1
                    state.recent.append(ClockSample(tick: tick, time: time))
                    if state.recent.count > Self.recentLimit { state.recent.removeFirst(state.recent.count - Self.recentLimit) }
                } else {
                    kind = .clock(tick: nil)
                }
            default:
                return
            }
            state.sequence += 1
            let event = Event(kind: kind, time: time, sequence: state.sequence, timestampLead: timestampLead)
            switch kind {
            case .songPosition:
                state.songPositions.append(event)
                if state.songPositions.count > Self.songPositionLimit { state.songPositions.removeFirst() }
            case .start, .continue, .stop:
                state.lastTransport = event
            case .clock:
                break
            }
            if state.capture != nil, state.capture!.count < Self.captureLimit { state.capture!.append(event) }
        }
    }

    public func fix() -> Fix {
        state.withLock { state in
            let recent = state.recent
            var secondsPerTick: Double?
            var anchor: ContinuousClock.Instant?
            if recent.count >= 2 {
                if let interval = Self.slope(recent), interval > 0 {
                    secondsPerTick = interval
                    let last = recent[recent.count - 1]
                    // Each recent clock projected forward to the last one's tick; the median
                    // ignores a single early or late arrival. Kept as offsets from the last
                    // arrival so the median works on plain numbers.
                    let offsets = recent.suffix(Self.anchorWindow).map { sample in
                        last.time.duration(to: sample.time).seconds + Double(last.tick - sample.tick) * interval
                    }
                    anchor = last.time.advanced(by: .seconds(Self.median(offsets) ?? 0))
                }
            }
            return Fix(
                sequence: state.sequence,
                running: state.running,
                songPositionCount: state.songPositionCount,
                lastSongPosition: state.songPositions.last,
                lastTransport: state.lastTransport,
                lastClock: recent.last,
                clocksSinceStart: state.clocksSinceStart,
                secondsPerTick: secondsPerTick,
                anchor: anchor
            )
        }
    }

    /// SPP messages that arrived after the message with sequence number `sequence`.
    public func songPositions(after sequence: Int) -> [Event] {
        state.withLock { $0.songPositions.filter { $0.sequence > sequence } }
    }

    /// The earliest of the recent clocks (since the last Start/Continue/SPP, at most
    /// `recentLimit`) at or after `tick`; nil when none is there.
    public func clockSample(atOrAfter tick: Int) -> ClockSample? {
        state.withLock { $0.recent.first { $0.tick >= tick } }
    }

    /// Starts keeping every sync message (replacing any capture in progress).
    public func beginCapture() {
        state.withLock { $0.capture = [] }
    }

    /// Stops keeping messages and returns what was kept.
    public func endCapture() -> [Event] {
        state.withLock { state in
            let events = state.capture ?? []
            state.capture = nil
            return events
        }
    }

    /// Seconds per tick: least-squares slope of arrival time over tick. Unlike a median of
    /// intervals it is not biased by timestamps rounded to whole milliseconds (the capture), and
    /// one late clock among 24 moves it by well under 1 %.
    static func slope(_ samples: [ClockSample]) -> Double? {
        guard samples.count >= 2, let origin = samples.first else { return nil }
        let xs = samples.map { Double($0.tick - origin.tick) }
        let ys = samples.map { origin.time.duration(to: $0.time).seconds }
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
        }
        return sxx > 0 ? sxy / sxx : nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// The clocks of one run of Logic's transport (from a capture), for measuring after the fact.
public struct ClockTrack: Sendable {
    /// Clocks with known ticks, in arrival order, ticks increasing by one.
    public let samples: [SyncTimeline.ClockSample]

    public init(samples: [SyncTimeline.ClockSample]) {
        self.samples = samples
    }

    /// The contiguous run of clocks after the event with sequence `sequence`, up to the next
    /// Stop, SPP or Start/Continue.
    public init(events: [SyncTimeline.Event], after sequence: Int) {
        self.init(samples: Self.run(in: events, after: sequence))
    }

    static func run(in events: [SyncTimeline.Event], after sequence: Int) -> [SyncTimeline.ClockSample] {
        var samples: [SyncTimeline.ClockSample] = []
        for event in events where event.sequence > sequence {
            switch event.kind {
            case .clock(let tick?):
                if let last = samples.last, tick != last.tick + 1 { return samples }
                samples.append(.init(tick: tick, time: event.time))
            case .clock(nil):
                continue
            case .stop, .songPosition, .start, .continue:
                if !samples.isEmpty { return samples }
            }
        }
        return samples
    }

    /// Least-squares seconds per tick over the whole run (the first clock, which Logic sends
    /// together with Continue, arrived 8 ms off the regular grid in the capture).
    public var secondsPerTick: Double? { SyncTimeline.slope(samples) }

    public var tempoBPM: Double? { secondsPerTick.map { 60 / ($0 * 24) } }

    /// Arrival time of Logic's clock at `tick`: linear interpolation between the clocks around
    /// it (extrapolated with the overall interval past either end).
    public func time(ofTick tick: Double) -> ContinuousClock.Instant? {
        guard let first = samples.first, let last = samples.last, let interval = secondsPerTick else {
            if samples.count == 1, let only = samples.first, tick == Double(only.tick) { return only.time }
            return nil
        }
        if tick <= Double(first.tick) {
            return first.time.advanced(by: .seconds((tick - Double(first.tick)) * interval))
        }
        if tick >= Double(last.tick) {
            return last.time.advanced(by: .seconds((tick - Double(last.tick)) * interval))
        }
        let index = Int(tick.rounded(.down)) - first.tick
        let lower = samples[index], upper = samples[index + 1]
        let fraction = tick - Double(lower.tick)
        return lower.time.advanced(by: .seconds(lower.time.duration(to: upper.time).seconds * fraction))
    }

    /// Logic's clock position at `time` (interpolated between clock arrivals).
    public func tick(at time: ContinuousClock.Instant) -> Double? {
        guard let first = samples.first, let last = samples.last, let interval = secondsPerTick, interval > 0 else { return nil }
        if time <= first.time { return Double(first.tick) - time.duration(to: first.time).seconds / interval }
        if time >= last.time { return Double(last.tick) + last.time.duration(to: time).seconds / interval }
        var low = 0, high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle } else { high = middle }
        }
        let lower = samples[low], upper = samples[high]
        let span = lower.time.duration(to: upper.time).seconds
        let fraction = span > 0 ? lower.time.duration(to: time).seconds / span : 0
        return Double(lower.tick) + fraction * Double(upper.tick - lower.tick)
    }

    /// RMS of clock arrival times around a straight line fitted per window of 24 clocks: how
    /// irregularly the clock arrived (Logic's output plus the server's own processing delay).
    public var jitterRMS: Double? {
        guard samples.count >= 8 else { return nil }
        var squares = 0.0, count = 0
        var start = 0
        while start < samples.count {
            let window = Array(samples[start..<min(start + 24, samples.count)])
            start += 24
            guard window.count >= 4 else { continue }
            let origin = window[0].time
            let xs = window.map { Double($0.tick - window[0].tick) }
            let ys = window.map { origin.duration(to: $0.time).seconds }
            let n = Double(window.count)
            let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
            var sxx = 0.0, sxy = 0.0
            for (x, y) in zip(xs, ys) {
                sxx += (x - meanX) * (x - meanX)
                sxy += (x - meanX) * (y - meanY)
            }
            guard sxx > 0 else { continue }
            let slope = sxy / sxx
            for (x, y) in zip(xs, ys) {
                let residual = y - (meanY + slope * (x - meanX))
                squares += residual * residual
                count += 1
            }
        }
        return count > 0 ? (squares / Double(count)).squareRoot() : nil
    }
}
