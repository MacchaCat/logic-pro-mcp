import Foundation
import MIDICore
import Synchronization

/// Shared between the note-sending thread and the async supervisor of a recording: the first
/// reason to stop wins, and the thread checks it before every send.
final class SchedulerControl: Sendable {
    private struct State {
        var abortReason: String?
        var finished = false
    }

    private let state = Mutex(State())

    func abort(_ reason: String) {
        state.withLock { if $0.abortReason == nil { $0.abortReason = reason } }
    }

    var abortReason: String? { state.withLock { $0.abortReason } }

    func markFinished() { state.withLock { $0.finished = true } }

    var isFinished: Bool { state.withLock { $0.finished } }
}

/// Sends timed note groups on `LogicMCP Notes` from a dedicated high-priority thread, each when
/// Logic's MIDI clock (from `SyncTimeline`) reaches its tick: at the predicted time, or at the
/// time of the clock seen at or past the tick, interpolating between clocks by time. Clock
/// times are Logic's CoreMIDI timestamps when it sets them, so a clock delivered ahead of time
/// does not make notes early.
///
/// Nothing is sent before the record-in point: no group is due until the clock at the start
/// bar's first tick has been seen, and none is sent before that clock's time, whatever the
/// calibration offset.
///
/// Before every send it checks that the transport still runs as it did when recording started:
/// no Stop, no new Song Position Pointer (a jump), no restart, a clock within `stallTimeout`,
/// and no abort from the supervisor (which polls the Record LED). Nothing is sent otherwise.
final class NoteScheduler: Sendable {
    struct Configuration: Sendable {
        /// Absolute tick of beat 0 (the start bar's SPP × 6).
        var startTick: Int
        /// `songPositionCount` after recording started; a different count means Logic jumped.
        var songPositionCount: Int
        /// Sequence number of the Continue/Start that started this run.
        var transportSequence: Int
        var stallTimeout: Duration
        /// Busy-wait this close to a send time instead of sleeping.
        var spin: Duration
        /// Calibration added to every send time.
        var offset: Duration
    }

    struct Group: Sendable {
        /// Absolute tick.
        var tick: Double
        var messages: [MIDIMessage]
        var on: [UInt8]
        var off: [UInt8]
    }

    struct Sent: Sendable {
        var group: Int
        var tick: Double
        var time: ContinuousClock.Instant
    }

    struct Outcome: Sendable {
        var sent: [Sent] = []
        var noteOns = 0
        var noteOffs = 0
        /// Pitches with a note-on but no note-off yet (stopped early).
        var sounding: [UInt8] = []
        var abortReason: String?
    }

    /// A group is sent only once Logic's clock has been seen within this many ticks of it.
    static let lookaheadTicks = 2.0

    let groups: [Group]
    let timeline: SyncTimeline
    let output: any MIDIOutput
    let control: SchedulerControl
    let configuration: Configuration

    init(groups: [Group], timeline: SyncTimeline, output: any MIDIOutput, control: SchedulerControl, configuration: Configuration) {
        self.groups = groups
        self.timeline = timeline
        self.output = output
        self.control = control
        self.configuration = configuration
    }

    /// Runs the sending loop on its own thread; returns when every group is sent or on abort.
    func run() async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let thread = Thread { [self] in
                let outcome = self.loop()
                self.control.markFinished()
                continuation.resume(returning: outcome)
            }
            thread.name = "logic-mcp.notes"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    private func loop() -> Outcome {
        let clock = ContinuousClock()
        var outcome = Outcome()
        var sounding: [UInt8: Int] = [:]
        func finish(_ reason: String?) -> Outcome {
            if let reason { control.abort(reason) }
            outcome.abortReason = control.abortReason
            outcome.sounding = sounding.filter { $0.value > 0 }.keys.sorted()
            return outcome
        }

        // The time of Logic's clock at the start bar's first tick, once seen.
        var recordIn: ContinuousClock.Instant?
        for (index, group) in groups.enumerated() {
            let whole = Int(group.tick.rounded(.down))
            // Wait until the group is due.
            while true {
                if control.abortReason != nil { return finish(nil) }
                let fix = timeline.fix()
                if let problem = transportProblem(fix, now: clock.now) { return finish(problem) }
                guard let last = fix.lastClock else {
                    Thread.sleep(forTimeInterval: 0.00025)
                    continue
                }
                if recordIn == nil, last.tick >= configuration.startTick {
                    recordIn = timeline.clockSample(atOrAfter: configuration.startTick)?.time ?? last.time
                }
                let ahead = offsetTicks(fix)
                if group.tick - ahead > Double(last.tick) + Self.lookaheadTicks {
                    // Not near yet: Logic's clock must come within `lookaheadTicks` (plus what a
                    // negative offset asks for) before a send, so a clock that stops cannot be
                    // extrapolated far.
                    let wake = fix.time(ofTick: group.tick - ahead - Self.lookaheadTicks).map { clock.now.duration(to: $0).seconds } ?? 0
                    Thread.sleep(forTimeInterval: min(max(wake, 0.00025), 0.002))
                    continue
                }
                let reached = last.tick >= whole ? timeline.clockSample(atOrAfter: whole) : nil
                guard let due = dueTime(group.tick, fix: fix, reached: reached, recordIn: recordIn) else {
                    Thread.sleep(forTimeInterval: 0.00025)
                    continue
                }
                let remaining = clock.now.duration(to: due)
                if remaining <= .zero { break }
                if remaining > configuration.spin {
                    Thread.sleep(forTimeInterval: min((remaining - configuration.spin).seconds, 0.002))
                    continue
                }
                while clock.now < due {}
                break
            }
            // The gate, right before sending.
            if control.abortReason != nil { return finish(nil) }
            let fix = timeline.fix()
            if let problem = transportProblem(fix, now: clock.now) { return finish(problem) }
            let time = clock.now
            do {
                try output.send(group.messages)
            } catch {
                return finish("Sending on LogicMCP Notes failed: \(error)")
            }
            outcome.sent.append(Sent(group: index, tick: group.tick, time: time))
            outcome.noteOns += group.on.count
            outcome.noteOffs += group.off.count
            for pitch in group.off { sounding[pitch, default: 0] = max(0, sounding[pitch, default: 0] - 1) }
            for pitch in group.on { sounding[pitch, default: 0] += 1 }
        }
        return finish(nil)
    }

    /// nil while Logic's transport runs as it did when recording started.
    func transportProblem(_ fix: SyncTimeline.Fix, now: ContinuousClock.Instant) -> String? {
        if fix.running != true {
            return "Logic stopped its transport (MIDI Stop on LogicMCP Sync)."
        }
        if fix.lastTransport?.sequence != configuration.transportSequence {
            return "Logic restarted its transport (a new Start/Continue on LogicMCP Sync)."
        }
        if fix.songPositionCount != configuration.songPositionCount {
            return "Logic's playhead jumped (a new Song Position Pointer arrived while recording)."
        }
        guard let last = fix.lastClock else {
            return "Logic's MIDI clock position is unknown."
        }
        var limit = configuration.stallTimeout
        if let interval = fix.secondsPerTick { limit = max(limit, .seconds(interval * 8)) }
        if last.time.duration(to: now) > limit {
            return "Logic's MIDI clock stopped arriving (no clock for \(last.time.duration(to: now).milliseconds) ms)."
        }
        return nil
    }

    /// How many ticks a negative calibration offset brings sends forward (0 without a tempo).
    func offsetTicks(_ fix: SyncTimeline.Fix) -> Double {
        guard configuration.offset < .zero, let secondsPerTick = fix.secondsPerTick, secondsPerTick > 0 else { return 0 }
        return (.zero - configuration.offset).seconds / secondsPerTick
    }

    /// When to send a group at `tick`, or nil when it cannot be told yet.
    ///
    /// - `reached`: the first recent clock at or after the tick's whole part, once Logic's clock
    ///   got there. Its time (its timestamp, which can lie ahead of its arrival) is when Logic
    ///   reached it; the latest clock's time would be later, and keeps moving with a clock sent
    ///   ahead.
    /// - `recordIn`: the time of Logic's clock at the start bar's first tick. Nothing is due
    ///   before it has been seen, and nothing before that time, whatever the offset.
    func dueTime(_ tick: Double, fix: SyncTimeline.Fix, reached: SyncTimeline.ClockSample?,
                 recordIn: ContinuousClock.Instant?) -> ContinuousClock.Instant? {
        guard let recordIn else { return nil }
        let whole = Int(tick.rounded(.down))
        var observed: ContinuousClock.Instant?
        if let reached, reached.tick >= whole {
            observed = reached.tick == whole
                ? reached.time.advanced(by: .seconds((tick - Double(whole)) * (fix.secondsPerTick ?? 0)))
                : reached.time
        }
        let due: ContinuousClock.Instant
        switch (fix.time(ofTick: tick), observed) {
        case let (p?, o?): due = min(p, o)
        case let (p?, nil): due = p
        case let (nil, o?): due = o
        case (nil, nil): return nil
        }
        return max(due.advanced(by: configuration.offset), recordIn)
    }
}
