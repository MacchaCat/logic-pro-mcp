import Foundation
import MackieControl
import MIDICore
import Synchronization

/// How the fake's transport talks on the sync port. Defaults follow the Logic 13 observations
/// (docs/appendix/logic13-mcu-facts.md, "Play and record start positions" and the note-recording
/// spike capture); the rest are knobs for tests.
public struct FakeSyncBehavior: Sendable {
    /// Logic 13 sends a Song Position Pointer whenever the playhead moves while stopped.
    public var sppOnLocate = true
    /// Record starts this many bars before the playhead (observed: one bar, SPP 112 for bar 9).
    public var recordPreRollBars = 1
    /// Play starts this many sixteenths before the playhead (observed: SPP 127 for 9.1.1.1).
    public var playStartsEarlySixteenths = 1
    public var tempoBPM: Double = 120
    /// From the Record/Play press to the repeated SPP, Continue and first clock (observed 46 ms;
    /// SPP once at the press, again with Continue).
    public var startDelay: Duration = .milliseconds(46)
    /// Bar length: 16 = 4/4. Jog moves whole bars whatever the length.
    public var sixteenthsPerBar = 16
    /// How often the running time display is redrawn (Logic 13: about every 33 ms).
    public var displayInterval: Duration = .milliseconds(30)
    /// Test hook: the clock stops after this many clocks of a run while the transport keeps
    /// running (a broken sync connection).
    public var clockStopsAfter: Int?
    /// On Stop, the Play/Stop/Record LEDs follow MIDI Stop and the stop SPP by this much
    /// (Logic 13 spike capture: FC at 23.813 s, SPP 23.815 s, LEDs 23.816–23.817 s).
    public var stopLEDDelay: Duration = .milliseconds(3)
    /// Test hook: each run's SPP, Continue and clocks are sent this much before the fake's
    /// position reaches them, stamped with the exact time (as a sender that schedules its clock
    /// ahead would, which CoreMIDI then delivers early). Needs a `TimestampedMIDIOutput` sync
    /// output; zero sends everything on time without timestamps.
    public var clockLead: Duration = .zero

    public init() {}
}

/// The fake transport's position over time and its MIDI clock output.
///
/// A run starts at an absolute tick (24 per quarter note) and moves along tempo segments from
/// its first clock on. Clocks are sent from a dedicated thread at the times the position
/// reaches each tick, so the clock is regular even when the test machine is busy; the recorder
/// asks for the position at a note's exact arrival time.
public final class FakeTransportClock: Sendable {
    struct Segment: Sendable {
        var time: ContinuousClock.Instant
        var tick: Double
        var secondsPerTick: Double
    }

    struct Run: Sendable {
        var id: Int
        var startTick: Double
        var segments: [Segment]
        var recording: Bool
        /// The playhead when Record was pressed (where Logic's region starts).
        var recordInTick: Double
        var armedTracks: [Int]
        /// Recording was switched off here while the transport kept running (punch-out).
        var recordingEndedAt: ContinuousClock.Instant?
        var stoppedAt: ContinuousClock.Instant?
        var stopTick: Double?
    }

    struct State: Sendable {
        var runs: [Run] = []
        var nextID = 1
        var tempoBPM: Double
        var clocksSent = 0
    }

    private let state: Mutex<State>
    private let output: any MIDIOutput
    let behavior: FakeSyncBehavior
    private let sendsSync: Bool

    init(behavior: FakeSyncBehavior, output: any MIDIOutput, sendsSync: Bool) {
        self.behavior = behavior
        self.output = output
        self.sendsSync = sendsSync
        state = Mutex(State(tempoBPM: behavior.tempoBPM))
    }

    static func secondsPerTick(_ bpm: Double) -> Double { 60 / (bpm * 24) }

    public var tempoBPM: Double { state.withLock { $0.tempoBPM } }
    public var clocksSent: Int { state.withLock { $0.clocksSent } }

    /// Starts a run at `startTick`: after `startDelay` the SPP is repeated, then Continue and
    /// the first clock, then a clock per tick. `onDisplay` gets the position about every
    /// `displayInterval` while the run lasts.
    func start(fromTick startTick: Int, recordInTick: Int, recording: Bool, armedTracks: [Int], now: ContinuousClock.Instant,
               onDisplay: @escaping @Sendable (Double) -> Void) {
        let first = now.advanced(by: behavior.startDelay)
        let id = state.withLock { state -> Int in
            let id = state.nextID
            state.nextID += 1
            let segment = Segment(time: first, tick: Double(startTick), secondsPerTick: Self.secondsPerTick(state.tempoBPM))
            state.runs.append(Run(id: id, startTick: Double(startTick), segments: [segment], recording: recording,
                                  recordInTick: Double(recordInTick), armedTracks: armedTracks))
            return id
        }
        // Holds the clock only during each step, so the thread ends when the host goes away.
        let thread = Thread { [weak self] in
            var cursor = Cursor(run: id, startTick: startTick, index: 0, nextDisplay: .now)
            while let step = self?.step(&cursor, onDisplay: onDisplay) {
                switch step {
                case .sleep(let seconds): Thread.sleep(forTimeInterval: seconds)
                case .next: continue
                case .done: return
                }
            }
        }
        thread.name = "FakeLogic.clock"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the current run; returns its position at `now` (nil when nothing was running).
    func stop(now: ContinuousClock.Instant) -> Double? {
        state.withLock { state in
            guard let index = state.runs.indices.last, state.runs[index].stoppedAt == nil else { return nil }
            let tick = Self.position(of: state.runs[index], at: now)
            state.runs[index].stoppedAt = now
            state.runs[index].stopTick = tick
            return tick
        }
    }

    /// Stops recording from `now` on while the run continues (a punch-out).
    func endRecording(now: ContinuousClock.Instant) {
        state.withLock { state in
            guard let index = state.runs.indices.last, state.runs[index].stoppedAt == nil,
                  state.runs[index].recordingEndedAt == nil else { return }
            state.runs[index].recordingEndedAt = now
        }
    }

    /// Changes the tempo from `now` on (also while running).
    func setTempo(_ bpm: Double, now: ContinuousClock.Instant) {
        state.withLock { state in
            state.tempoBPM = bpm
            guard let index = state.runs.indices.last, state.runs[index].stoppedAt == nil else { return }
            let run = state.runs[index]
            let time = max(now, run.segments[0].time)
            let tick = Self.position(of: run, at: time)
            state.runs[index].segments.append(Segment(time: time, tick: tick, secondsPerTick: Self.secondsPerTick(bpm)))
        }
    }

    /// The running position in ticks at `time`; nil while stopped.
    public func position(at time: ContinuousClock.Instant) -> Double? {
        state.withLock { state in
            guard let run = state.runs.last, run.stoppedAt.map({ time < $0 }) ?? true else { return nil }
            return Self.position(of: run, at: time)
        }
    }

    /// Position, run, record-in tick and armed tracks at `time` when the fake is recording then.
    func recordingContext(at time: ContinuousClock.Instant) -> (tick: Double, run: Int, recordIn: Double, tracks: [Int])? {
        state.withLock { state in
            guard let run = state.runs.last, run.recording, run.stoppedAt.map({ time < $0 }) ?? true,
                  run.recordingEndedAt.map({ time < $0 }) ?? true else { return nil }
            return (Self.position(of: run, at: time), run.id, run.recordInTick, run.armedTracks)
        }
    }

    /// Where a run stopped (nil while it runs).
    func stopTick(run id: Int) -> Double? {
        state.withLock { state in state.runs.first { $0.id == id }?.stopTick }
    }

    func isRunning(_ id: Int) -> Bool {
        state.withLock { state in state.runs.last.map { $0.id == id && $0.stoppedAt == nil } ?? false }
    }

    static func position(of run: Run, at time: ContinuousClock.Instant) -> Double {
        guard let segment = run.segments.last(where: { $0.time <= time }) else { return run.startTick }
        return segment.tick + segment.time.duration(to: time).asSeconds / segment.secondsPerTick
    }

    /// When the run reaches `tick` (nil when the run has ended).
    private func time(ofTick tick: Double, run id: Int) -> ContinuousClock.Instant? {
        state.withLock { state in
            guard let run = state.runs.last, run.id == id, run.stoppedAt == nil else { return nil }
            let segment = run.segments.last(where: { $0.tick <= tick }) ?? run.segments[0]
            return segment.time.advanced(by: .seconds((tick - segment.tick) * segment.secondsPerTick))
        }
    }

    struct Cursor {
        var run: Int
        var startTick: Int
        /// Index of the next clock of the run (0 = the first, at the start tick).
        var index: Int
        var nextDisplay: ContinuousClock.Instant
    }

    enum Step { case sleep(Double), next, done }

    /// One step of a run's clock thread: sleep until the next clock is due (less the lead), or
    /// send it (stamped with its exact time when there is a lead).
    private func step(_ cursor: inout Cursor, onDisplay: @Sendable (Double) -> Void) -> Step {
        guard let due = time(ofTick: Double(cursor.startTick + cursor.index), run: cursor.run) else { return .done }
        let timed = behavior.clockLead > .zero ? output as? any TimestampedMIDIOutput : nil
        let sendAt = timed == nil ? due : due.advanced(by: .zero - behavior.clockLead)
        let now = ContinuousClock.now
        if sendAt > now {
            if cursor.nextDisplay <= now, let position = position(at: now) {
                onDisplay(position)
                cursor.nextDisplay = now.advanced(by: behavior.displayInterval)
            }
            return .sleep(min(now.duration(to: sendAt).asSeconds, 0.005))
        }
        guard isRunning(cursor.run) else { return .done }
        if sendsSync {
            var messages: [MIDIMessage] = []
            if cursor.index == 0 { messages += [.songPosition(UInt16(cursor.startTick / 6)), .continue] }
            if behavior.clockStopsAfter.map({ cursor.index < $0 }) ?? true {
                messages.append(.timingClock)
                state.withLock { $0.clocksSent += 1 }
            }
            if !messages.isEmpty {
                if let timed { try? timed.send(messages, timestamp: due) } else { try? output.send(messages) }
            }
        }
        cursor.index += 1
        return .next
    }
}

/// A Control Change or pitch bend the fake recorded from `LogicMCP Notes` (All Notes Off is
/// not recorded: it only ends notes).
public struct FakeRecordedControl: Sendable, Equatable {
    public var message: MIDIMessage
    public var tick: Double
    public var tracks: [Int]
    var run: Int
}

/// What the fake recorded from `LogicMCP Notes`.
public struct FakeRecordedNote: Sendable, Equatable {
    public var pitch: UInt8
    public var velocity: UInt8
    public var channel: UInt8
    /// Absolute ticks (24 per quarter note; SPP × 6) of the fake's position at the note-on.
    public var startTick: Double
    /// Position at the note-off, or where recording stopped if none came; nil while sounding.
    public var endTick: Double?
    /// Indices of the tracks that were record-armed when recording started.
    public var tracks: [Int]
    /// The playhead when Record was pressed: Logic's region starts here, so a note that starts
    /// earlier (in the pre-roll) was sent too early.
    public var recordInTick: Double
    var run: Int
}

/// The fake's `LogicMCP Notes` input. Stamps every message as it arrives (synchronously, in
/// the sender's thread) with the fake transport's position, and while the fake records turns
/// note-on / note-off pairs into notes on the armed tracks, as Logic records a region.
public final class FakeNoteRecorder: MIDIOutput, Sendable {
    public struct Received: Sendable, Equatable {
        public var message: MIDIMessage
        public var time: ContinuousClock.Instant
        /// Transport position when it arrived; nil while stopped.
        public var tick: Double?
        public var whileRecording: Bool
    }

    private struct State {
        var received: [Received] = []
        var notes: [FakeRecordedNote] = []
        var controls: [FakeRecordedControl] = []
        /// (channel << 8 | pitch) → index into `notes` of the sounding note.
        var open: [Int: Int] = [:]
    }

    private let clock: FakeTransportClock
    private let state = Mutex(State())

    init(clock: FakeTransportClock) {
        self.clock = clock
    }

    public func send(_ messages: [MIDIMessage]) {
        let now = ContinuousClock.now
        let context = clock.recordingContext(at: now)
        let position = context?.tick ?? clock.position(at: now)
        state.withLock { state in
            for message in messages {
                state.received.append(Received(message: message, time: now, tick: position, whileRecording: context != nil))
                guard let context else { continue }
                switch message {
                case let .noteOn(channel, pitch, velocity) where velocity > 0:
                    let key = Int(channel) << 8 | Int(pitch)
                    if let open = state.open.removeValue(forKey: key) { state.notes[open].endTick = context.tick }
                    state.notes.append(FakeRecordedNote(pitch: pitch, velocity: velocity, channel: channel, startTick: context.tick,
                                                        endTick: nil, tracks: context.tracks, recordInTick: context.recordIn,
                                                        run: context.run))
                    state.open[key] = state.notes.count - 1
                case let .noteOn(channel, pitch, _), let .noteOff(channel, pitch, _):
                    if let open = state.open.removeValue(forKey: Int(channel) << 8 | Int(pitch)) { state.notes[open].endTick = context.tick }
                case let .controlChange(channel, 123, _):
                    for (key, open) in state.open where key >> 8 == Int(channel) { state.notes[open].endTick = context.tick }
                    state.open = state.open.filter { $0.key >> 8 != Int(channel) }
                case .controlChange, .pitchBend:
                    state.controls.append(FakeRecordedControl(message: message, tick: context.tick, tracks: context.tracks, run: context.run))
                default:
                    break
                }
            }
        }
    }

    /// Everything that arrived, in order.
    public var received: [Received] { state.withLock { $0.received } }

    /// Control Changes and pitch bends recorded, in order.
    public var controls: [FakeRecordedControl] { state.withLock { $0.controls } }

    /// Recorded notes; notes still open when their run stopped end at the stop position.
    public var notes: [FakeRecordedNote] {
        let notes = state.withLock { $0.notes }
        return notes.map { note in
            var note = note
            if note.endTick == nil { note.endTick = clock.stopTick(run: note.run) }
            return note
        }
    }

    /// Pitches with a note-on and no note-off/All Notes Off afterwards, over everything received
    /// (recording or not): what would hang in Logic's instrument.
    public var hangingNotes: [UInt8] {
        var on: [Int: Int] = [:]
        for item in received {
            switch item.message {
            case let .noteOn(channel, pitch, velocity) where velocity > 0: on[Int(channel) << 8 | Int(pitch), default: 0] += 1
            case let .noteOn(channel, pitch, _), let .noteOff(channel, pitch, _): on[Int(channel) << 8 | Int(pitch)] = 0
            case let .controlChange(channel, 123, _): on = on.filter { $0.key >> 8 != Int(channel) }
            default: break
            }
        }
        return on.filter { $0.value > 0 }.keys.map { UInt8($0 & 0xFF) }.sorted()
    }
}

private extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
