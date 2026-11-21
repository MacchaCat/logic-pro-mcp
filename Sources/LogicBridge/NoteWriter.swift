import Foundation
import MackieControl
import MIDICore

/// Waits and limits for `write_midi`.
public struct NoteWriterTimings: Sendable {
    /// After a locate that moved the playhead, how long to wait for Logic's SPP if it has not
    /// arrived yet (Logic 13 sent it about 65 ms before the time display settled).
    public var locateSPPGrace: Duration = .milliseconds(300)
    /// From the Record LED to Logic's Continue/Start and first clock (a count-in that does not
    /// move the clock would delay it).
    public var clockStartTimeout: Duration = .seconds(10)
    /// Abort when no clock arrives for this long (or 8 clock intervals, whichever is longer).
    public var stallTimeout: Duration = .milliseconds(400)
    /// How often the supervisor reads the Record LED and the time display while sending.
    public var monitorInterval: Duration = .milliseconds(5)
    /// Recording continues this many clocks (half a beat) after the last note-off...
    public var tailTicks = 12
    /// ...and at least this long after the last send.
    public var minimumTail: Duration = .milliseconds(150)
    /// Wait for the SPP Logic sends after Stop.
    public var stopSPPTimeout: Duration = .milliseconds(600)
    /// When Logic stopped (or stopped recording) by itself, how long to wait for its Play and
    /// Record LEDs to go off before pressing Stop. Logic 13 sent MIDI Stop and the stop SPP
    /// 2–4 ms before the LEDs; pressing Stop on a stopped Logic moves its playhead.
    public var stopSettle: Duration = .milliseconds(300)
    /// Upper bound on the recording, from the Record press to the last note-off. Checked on
    /// every supervisor round: against the time so far, and against the time so far plus the
    /// rest of the material at the tempo Logic's clock shows now (so a tempo drop is caught).
    public var maxRecordingSeconds = 600.0
    /// The sending thread busy-waits this close to a send time.
    public var spin: Duration = .microseconds(1500)
    /// How long each page's Rec LEDs are watched before and after arming (nil: the mixer's
    /// `recordArmWindow`, 1 s), and after restoring. The restore check watches longer: a track
    /// armed again may keep its LED on for up to about 2 s before blinking (observed).
    public var armWindow: Duration?
    public var armRestoreWindow: Duration = .milliseconds(2200)

    public init() {}
}

/// `write_midi`: records notes into a Logic track by playing them on `LogicMCP Notes` in real
/// time while Logic records, timed by Logic's own MIDI clock (design §3.8).
///
/// Flow: refuse unless Logic is stopped with Cycle off (Replace needs confirmation); place the
/// playhead at the start bar and take its absolute position and the bar length from the Song
/// Position Pointers Logic sends; make the target the only record-armed track with the Mackie
/// Rec buttons and prove it by reading every Rec LED again; press Record; follow Logic's clock
/// (one bar of pre-roll observed) and send every note when the clock reaches it; stop (unless
/// Logic already stopped by itself); put the record-arm states back. On any problem it stops
/// sending, releases held notes, stops Logic and restores the arm states. What Logic recorded is
/// not read back, so success is `partial`.
///
/// Track names come from Logic's project: they appear verbatim only in the structured fields
/// (`track_name`, `arm_before`, `arm_after`); prose quotes them through `ProjectText.quoted`.
public actor NoteWriter {
    public typealias Result = OperationResult<NoteWriteReport>

    private let mcu: MCUSession
    private let sync: SyncMonitor
    private let transport: TransportController
    private let mixer: MixerController
    private let notes: any MIDIOutput
    private let timings: NoteWriterTimings
    private let clock = ContinuousClock()
    private var busy = false

    private var timeline: SyncTimeline { sync.timeline }

    public init(mcu: MCUSession, sync: SyncMonitor, transport: TransportController, mixer: MixerController,
                notes: any MIDIOutput, timings: NoteWriterTimings = NoteWriterTimings()) {
        self.mcu = mcu
        self.sync = sync
        self.transport = transport
        self.mixer = mixer
        self.notes = notes
        self.timings = timings
    }

    struct Failure: Error {
        var summary: String
        var warnings: [String] = []
    }

    /// Everything collected while one write runs.
    struct Run {
        var report: NoteWriteReport
        var evidence: [String] = []
        var warnings: [String] = []
        /// The Rec LEDs before arming; set before any Rec button is pressed.
        var originalArm: [RecordArmState]?
        var target: TrackInfo?
        /// Tracks whose Rec button this run pressed, in order; the restore presses them again in
        /// reverse order and nothing else.
        var pressed: [TrackInfo] = []
        /// Logic confirmed Record (from then on it may have recorded something).
        var recordPressed = false
    }

    struct StartPosition {
        /// The start bar's SPP (sixteenths).
        var songPosition: Int
        var barSixteenths: Int
        /// Timeline sequence of that SPP.
        var sequence: Int
    }

    struct DisplaySample {
        var position: BeatsPosition
        var time: ContinuousClock.Instant
    }

    public static let contentNote = "The notes were played into Logic in real time; Mackie Control cannot see regions or notes, so what Logic recorded is not read back. Check the new region on the target track (for example in the Event List)."
    public static let trackTypeNote = "The track type cannot be checked over Mackie Control: a software instrument (or external MIDI) track records the notes; on an audio track Logic would record audio from its input instead."

    /// The action a confirmation token is bound to: the same track, bar and notes.
    public static func confirmationAction(for request: NoteWriteRequest) -> String {
        var hash: UInt32 = 0x811C_9DC5
        func mix(_ text: String) { for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 } }
        mix("\(request.track)|\(request.expectedName ?? "")|\(request.startBar)|\(request.timingOffsetMs)")
        for note in request.notes { mix("|\(note.pitch),\(note.startBeat),\(note.durationBeats),\(note.velocity)") }
        return "write_midi in Replace mode: \(request.notes.count) note(s) on track \(request.track) from bar \(request.startBar) [\(String(hash, radix: 16))]"
    }

    public func write(_ request: NoteWriteRequest, replaceConfirmed: Bool) async -> Result {
        guard !busy else {
            return Result(status: .failed, summary: "Another write_midi is still running. Nothing was sent.")
        }
        busy = true
        defer { busy = false }

        let plan: NotePlan
        switch NotePlan.make(request) {
        case .failure(let problem): return Result(status: .failed, summary: problem.message + " Nothing was sent.")
        case .success(let made): plan = made
        }
        var run = Run(report: NoteWriteReport(
            track: request.track, trackName: nil, startBar: request.startBar, notesRequested: plan.noteCount,
            noteOnsSent: 0, noteOffsSent: 0, timing: .init(timingOffsetMs: request.timingOffsetMs),
            armBefore: [], armAfter: [], transport: nil))
        run.warnings += plan.warnings

        let before = await transport.snapshot()
        if let problem = await refusal(before) {
            return Result(status: .failed, summary: problem + " Nothing was sent.", warnings: run.warnings)
        }
        if before.replaceMode != false {
            let reason = Self.replaceReason(before.replaceMode)
            guard replaceConfirmed else {
                return Result(status: .needsConfirmation, summary: reason, warnings: run.warnings)
            }
            run.warnings.append("Recorded after confirmation: \(reason)")
        }

        // 1. Playhead and bar length. Only the playhead moves here.
        let start: StartPosition
        do {
            start = try await locateStart(request.startBar, run: &run)
        } catch {
            let failure = error as? Failure ?? Failure(summary: "\(error)")
            return finish(.failed, failure.summary + " Only the playhead may have moved; nothing else was changed.", run, failure.warnings)
        }
        let barTicks = Double(start.barSixteenths * 6)
        let bars = plan.endBeats * 24 / barTicks
        guard bars <= Double(NoteWriteRequest.maxBars) + 1e-9 else {
            return finish(.failed, "The material is \(String(format: "%.1f", bars)) bars long at Logic's bar length at bar \(request.startBar) (\(start.barSixteenths) sixteenths); at most \(NoteWriteRequest.maxBars) bars per call. Only the playhead was moved.", run)
        }

        // 2. Arm, record, send, stop. Arm states are restored whatever happens.
        var status: Result.Status = .partial
        var summary: String
        do {
            try await armTarget(request, run: &run)
            try await checkStillAtStart(start, bar: request.startBar, replaceConfirmed: replaceConfirmed)
            let recording = try await recordAndSend(plan, start: start, request: request, replaceConfirmed: replaceConfirmed, run: &run)
            (status, summary) = Self.describe(recording, plan: plan, request: request, run: run)
        } catch {
            let failure = error as? Failure ?? Failure(summary: "\(error)")
            status = .failed
            summary = failure.summary + " No note was sent."
            run.warnings += failure.warnings
        }
        let problems = await restoreArming(run: &run)
        if !problems.isEmpty {
            summary += " Record-arm states were not fully restored: " + problems.joined(separator: "; ") + "."
        }
        run.report.transport = await transport.snapshot()
        return finish(status, summary, run)
    }

    private func finish(_ status: Result.Status, _ summary: String, _ run: Run, _ extra: [String] = []) -> Result {
        var warnings = run.warnings + extra
        if run.report.noteOnsSent > 0 { warnings.append(Self.contentNote) }
        if run.recordPressed { warnings.append(Self.trackTypeNote) }
        return Result(status: status, summary: summary, after: run.report, evidence: run.evidence, warnings: warnings)
    }

    // MARK: Preconditions

    /// Why the write cannot start in this state; nil when it can.
    private func refusal(_ s: TransportSnapshot) async -> String? {
        let link = await mcu.linkStatus()
        guard link.surfaceActive else {
            return link.messagesReceived == 0
                ? "Logic has not sent anything to the LogicMCP MCU port. Set up the Mackie Control surface (docs/setup)."
                : "Logic has only probed the LogicMCP MCU port; no Mackie Control surface is installed on it (docs/setup)."
        }
        if s.recording == true || s.playing == true {
            return "Logic is playing or recording. Stop first: write_midi only starts while Logic is stopped."
        }
        if s.playing == nil {
            return "Logic has not reported its transport state (Play LED or MIDI clock), so it cannot be confirmed that Logic is stopped."
        }
        if s.cycle == true {
            return "Cycle is on: recording would loop over the cycle range. Turn Cycle off in Logic first."
        }
        if s.cycle == nil {
            return "Logic has not reported the Cycle LED, so it cannot be confirmed that Cycle is off."
        }
        if s.displayMode != .beats || s.position == nil {
            return "Logic's time display is not readable in Beats mode, so the playhead cannot be placed and checked. Switch the control surface's clock display to Beats."
        }
        return nil
    }

    static func replaceReason(_ replace: Bool?) -> String {
        replace == true
            ? "Replace mode is on: recording erases existing material on the record-armed target track from the start bar to where recording stops."
            : "Logic has not reported the Replace LED, so Replace mode may be on: recording could erase existing material on the target track from the start bar to where recording stops."
    }

    // MARK: Playhead

    /// Locates `bar`; returns the last SPP Logic sent for the move (nil when nothing moved).
    private func locate(_ bar: Int) async throws -> (spp: SyncTimeline.Event?, result: TransportController.Result) {
        let mark = timeline.fix().sequence
        let result = await transport.locate(bar: bar, beat: 1)
        guard result.status == .verified else {
            throw Failure(summary: "Could not move the playhead to bar \(bar): \(result.summary)", warnings: result.warnings)
        }
        if result.before?.position == BeatsPosition(bar: bar, beat: 1, division: 1, tick: 1) {
            return (nil, result)  // already there: nothing was sent, so Logic sent no SPP
        }
        // Logic 13 sent the SPP about 65 ms before its time display settled, so it is normally
        // here already. The last one since the mark belongs to the last jog tick.
        let deadline = clock.now.advanced(by: timings.locateSPPGrace)
        while timeline.songPositions(after: mark).isEmpty, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(5))
        }
        return (timeline.songPositions(after: mark).last, result)
    }

    /// Moves to a neighbouring bar and then to `bar`, so that Logic sends an SPP for both: the
    /// start position and the bar length come from Logic, not from an assumed meter.
    private func locateStart(_ bar: Int, run: inout Run) async throws -> StartPosition {
        let neighbour = bar < 999 ? bar + 1 : bar - 1
        var away = try await locate(neighbour)
        var here = try await locate(bar)
        if away.spp == nil {
            // The playhead was already at the neighbouring bar, so it sent nothing for it.
            away = try await locate(neighbour)
            here = try await locate(bar)
        }
        guard let awayEvent = away.spp, let hereEvent = here.spp,
              case .songPosition(let awaySPP) = awayEvent.kind, case .songPosition(let startSPP) = hereEvent.kind else {
            throw Failure(summary: "Logic did not send a Song Position Pointer to LogicMCP Sync after the playhead moved, so the start position cannot be taken from Logic's clock. Set Logic to send MIDI clock to LogicMCP Sync (docs/setup/01-phase1-logic-setup.md, step 5).")
        }
        let length = neighbour > bar ? awaySPP - startSPP : startSPP - awaySPP
        guard length > 0, length <= 256 else {
            throw Failure(summary: "Logic's Song Position Pointers for bar \(bar) (\(startSPP)) and bar \(neighbour) (\(awaySPP)) do not give a plausible bar length (\(length) sixteenths).")
        }
        run.report.timing.startBarSongPosition = startSPP
        run.report.timing.barLengthSixteenths = length
        run.report.timing.displayAtStart = here.result.after?.display
        run.evidence.append("playhead at bar \(bar) (time display \(here.result.after?.position?.description ?? "?")); Logic's Song Position Pointer: bar \(bar) = \(startSPP), bar \(neighbour) = \(awaySPP) sixteenths, so one bar = \(length) sixteenths")
        return StartPosition(songPosition: startSPP, barSixteenths: length, sequence: hereEvent.sequence)
    }

    /// Right before Record: still stopped, Cycle off, at the start bar, and no SPP since then
    /// other than repeats of the start bar's.
    private func checkStillAtStart(_ start: StartPosition, bar: Int, replaceConfirmed: Bool) async throws {
        let now = await transport.snapshot()
        if let problem = await refusal(now) { throw Failure(summary: problem) }
        if now.replaceMode != false, !replaceConfirmed {
            throw Failure(summary: "Replace mode turned on (or became unknown) while the tracks were armed: " + Self.replaceReason(now.replaceMode))
        }
        guard now.position == BeatsPosition(bar: bar, beat: 1, division: 1, tick: 1) else {
            throw Failure(summary: "The playhead moved away from bar \(bar) while the tracks were armed (time display \(now.display ?? "?")).")
        }
        let later = timeline.songPositions(after: start.sequence)
        guard later.allSatisfy({ $0.kind == .songPosition(start.songPosition) }) else {
            throw Failure(summary: "Logic sent another Song Position Pointer after the playhead reached bar \(bar), so the start position is not certain.")
        }
    }

    // MARK: Record arm

    /// Makes the target the only track Logic records on. Logic 13 (observed 2026-11-21) blinks
    /// the Rec LED of every armed track and records on those; with none armed it records on the
    /// selected track, whose LED is then steady, and arming any track turns that one off by
    /// itself. So: watch the LEDs, press Rec on the target unless it is already armed, press Rec
    /// on every other armed track, and watch again: only the target may be lit.
    private func armTarget(_ request: NoteWriteRequest, run: inout Run) async throws {
        let scan = await mixer.tracks(refresh: true)
        guard scan.status == .verified, let tracks = scan.after?.tracks else {
            throw Failure(summary: "Could not read the track list to see which tracks are record-armed: \(scan.summary)", warnings: scan.warnings)
        }
        guard request.track <= tracks.count else {
            throw Failure(summary: "Track \(request.track) does not exist: the surface shows \(tracks.count) tracks.")
        }
        let target = tracks[request.track - 1]
        if let expected = request.expectedName {
            switch MixerController.checkName(MixerChange(track: request.track, expectedName: expected), target) {
            case .failure(let failure): throw Failure(summary: failure.summary)
            case .success(let note): if let note { run.warnings.append(note) }
            }
        } else {
            run.warnings.append("No expected name was given, so track \(request.track) (\(ProjectText.quoted(target.name))) was not checked by name.")
        }
        run.target = target
        run.report.trackName = target.name

        let before = try await watchRecordArms(window: timings.armWindow, expecting: tracks, what: "before arming")
        let unknown = before.filter { $0.light == nil }.map(\.track)
        guard unknown.isEmpty else {
            throw Failure(summary: "Logic sent no Rec LED for track(s) \(Self.list(unknown)), so it cannot be told which tracks are record-armed.")
        }
        run.report.armBefore = before.map(Self.armState)
        run.originalArm = before

        var toPress: [TrackInfo] = []
        if before[target.number - 1].light != .alternating { toPress.append(target) }
        toPress += before.filter { $0.track != target.number && $0.light == .alternating }.map { tracks[$0.track - 1] }
        if toPress.isEmpty {
            run.evidence.append("Rec LEDs: track \(target.number) was already the only armed track")
        }
        for info in toPress {
            let press = await mixer.pressRecordArm(track: info.number, expectedName: Self.expectedName(info))
            guard press.status != .failed else {
                throw Failure(summary: "Could not press Rec on track \(info.number) \(ProjectText.quoted(info.name)): \(press.summary)", warnings: Self.mixerWarnings(press.warnings))
            }
            run.pressed.append(info)
            run.evidence += press.evidence.map { "arm: " + $0 }
        }

        let now = try await watchRecordArms(window: timings.armWindow, expecting: tracks, what: "after arming")
        let targetLight = now[target.number - 1].light
        let others = now.filter { $0.track != target.number && $0.light != .off }.map(\.track)
        guard targetLight == .alternating || targetLight == .steady, others.isEmpty else {
            let shown = now.filter { $0.light != .off }.map { "\($0.track) (\($0.light?.rawValue ?? "unknown"))" }
            throw Failure(summary: "After arming, the Rec LEDs show \(shown.isEmpty ? "no track" : "track(s) " + shown.joined(separator: ", ")) lit instead of only track \(target.number).")
        }
        run.evidence.append("Rec LEDs watched again: only track \(target.number) \(ProjectText.quoted(target.name)) is lit (\(targetLight?.rawValue ?? "?"))")
    }

    /// Presses Rec again on every track this run pressed, in reverse order (never anything
    /// else: re-creating the before state could turn the selected track's automatic record
    /// enable into a real arm), then watches the LEDs and compares them with before.
    /// Returns the problems; empty when every LED looks as before.
    private func restoreArming(run: inout Run) async -> [String] {
        guard let original = run.originalArm else { return [] }
        guard !run.pressed.isEmpty else {
            run.report.armAfter = original.map(Self.armState)
            run.evidence.append("restore: no Rec button was pressed, so none was pressed again")
            return []
        }
        var problems: [String] = []
        for info in run.pressed.reversed() {
            let press = await mixer.pressRecordArm(track: info.number, expectedName: Self.expectedName(info))
            run.evidence += press.evidence.map { "restore: " + $0 }
            run.warnings += Self.mixerWarnings(press.warnings)
            if press.status == .failed { problems.append("Rec on track \(info.number) was not pressed again (\(press.summary))") }
        }
        run.pressed.removeAll()
        let check = await mixer.readRecordArms(window: timings.armRestoreWindow)
        guard check.status == .verified, let now = check.after else {
            problems.append("could not read the Rec LEDs afterwards (\(check.summary))")
            return problems
        }
        run.report.armAfter = now.map(Self.armState)
        if now.count != original.count {
            problems.append("the track list changed (\(original.count) → \(now.count) tracks)")
        } else {
            let differing = zip(original, now).filter { $0.light != $1.light }.map(\.0.track)
            if differing.isEmpty {
                run.evidence.append("Rec LEDs watched again: as before")
            } else {
                problems.append("track(s) \(Self.list(differing)) differ from before")
            }
        }
        return problems
    }

    /// `readRecordArms`, as a failure unless every track of `tracks` is listed in order.
    private func watchRecordArms(window: Duration?, expecting tracks: [TrackInfo], what: String) async throws -> [RecordArmState] {
        let result = await mixer.readRecordArms(window: window)
        guard result.status == .verified, let states = result.after else {
            throw Failure(summary: "Could not read the Rec LEDs \(what): \(result.summary)", warnings: Self.mixerWarnings(result.warnings))
        }
        guard states.count == tracks.count, zip(states, tracks).allSatisfy({ $0.name == $1.name }) else {
            throw Failure(summary: "The track list changed \(what) (now \(states.count) tracks).")
        }
        return states
    }

    static func armState(_ state: RecordArmState) -> NoteWriteReport.ArmState {
        .init(track: state.track, name: state.name, light: state.light)
    }

    /// The name to check a track by when pressing its Rec button: the full name, or the LCD
    /// name when that is all there is (nil when the LCD shows nothing to compare).
    static func expectedName(_ info: TrackInfo) -> String? {
        if info.nameSource == .accessibility { return info.name }
        return info.lcdName.isEmpty ? nil : info.lcdName
    }

    static func mixerWarnings(_ warnings: [String]) -> [String] {
        warnings.filter { $0 != MixerController.automationNote }
    }

    static func list(_ numbers: [Int]) -> String {
        numbers.isEmpty ? "none" : numbers.map(String.init).joined(separator: ", ")
    }

    // MARK: Recording

    struct Recording {
        var abortReason: String?
        var stopped: Bool
        var stopSummary: String
        var noteOns: Int
        var noteOffs: Int
    }

    /// Presses Record, sends the notes along Logic's clock and stops. Throws only before
    /// Record was confirmed; from then on it always ends by stopping Logic.
    private func recordAndSend(_ plan: NotePlan, start: StartPosition, request: NoteWriteRequest,
                               replaceConfirmed: Bool, run: inout Run) async throws -> Recording {
        let startTick = start.songPosition * 6
        timeline.beginCapture()
        let mark = timeline.fix().sequence
        let recordResult = await transport.record(confirmed: replaceConfirmed)
        guard recordResult.status == .verified, recordResult.before?.recording != true else {
            _ = timeline.endCapture()
            if recordResult.after?.recording == true || recordResult.after?.playing == true { _ = await transport.stop() }
            throw Failure(summary: "Recording did not start: \(recordResult.summary)", warnings: recordResult.warnings)
        }
        run.evidence += recordResult.evidence.map { "record: " + $0 }
        run.recordPressed = true
        let pressed = clock.now

        var abortReason: String?
        var outcome = NoteScheduler.Outcome()
        var samples: [DisplaySample] = []
        var runSequence: Int?

        switch await waitForClockStart(after: mark) {
        case .failure(let failure):
            abortReason = failure.summary
        case .success(let begin):
            runSequence = begin.transport.sequence
            let firstTick = begin.firstTick
            run.report.timing.recordStartSongPosition = Double(firstTick) / 6
            run.report.timing.preRollSixteenths = Double(startTick - firstTick) / 6
            run.evidence.append("Logic started its clock \(pressed.duration(to: begin.transport.time).milliseconds) ms after the Record LED at song position \(Self.sixteenths(Double(firstTick))) (\(begin.transport.kind == .start ? "Start" : "Continue")), \(Self.sixteenths(Double(startTick - firstTick))) sixteenths before bar \(request.startBar)")
            if firstTick > startTick {
                abortReason = "Logic's clock started at song position \(Self.sixteenths(Double(firstTick))), after bar \(request.startBar) (\(start.songPosition)), so the first notes would be missed. Nothing was sent."
            } else {
                if firstTick == startTick {
                    run.warnings.append("Logic started recording exactly at bar \(request.startBar) without pre-roll: notes at beat 0 were sent only once Logic's first clock arrived.")
                }
                let groups = plan.groups.map { group in
                    NoteScheduler.Group(
                        tick: Double(startTick) + group.tick,
                        messages: group.events.map(\.message),
                        on: group.events.filter(\.isOn).map(\.pitch),
                        off: group.events.filter { !$0.isOn }.map(\.pitch))
                }
                let control = SchedulerControl()
                let scheduler = NoteScheduler(
                    groups: groups, timeline: timeline, output: notes, control: control,
                    configuration: .init(
                        startTick: startTick, songPositionCount: begin.songPositionCount,
                        transportSequence: begin.transport.sequence, stallTimeout: timings.stallTimeout,
                        spin: timings.spin, offset: .milliseconds(request.timingOffsetMs)))
                async let result = scheduler.run()
                samples = await supervise(control, endTick: Double(startTick) + plan.endBeats * 24, pressed: pressed)
                outcome = await result
                abortReason = outcome.abortReason
            }
        }

        if abortReason != nil, !outcome.sounding.isEmpty {
            // Explicit note-offs first: while Logic still records they end the notes cleanly.
            let offs = outcome.sounding.map { MIDIMessage.noteOff(channel: 0, note: $0, velocity: 0) }
            try? notes.send(offs)
            outcome.noteOffs += offs.count
            run.evidence.append("released \(offs.count) held note(s) with note-offs after stopping early")
        }
        if abortReason == nil {
            await waitForTail(endTick: Double(startTick) + plan.endBeats * 24 + Double(timings.tailTicks),
                              after: outcome.sent.last?.time ?? clock.now)
        }

        // Stop, unless Logic already did: pressing Stop on a stopped Logic moves its playhead.
        let stopped: Bool
        let stopSummary: String
        if let own = await waitForOwnStop(after: mark) {
            stopped = true
            stopSummary = "Logic stopped by itself."
            run.evidence.append("Logic stopped by itself (\(own.cause)); its Play and Record LEDs were off \(own.after.milliseconds) ms later, so Stop was not pressed")
        } else {
            var stopResult = await transport.stop()
            if stopResult.status != .verified { stopResult = await transport.stop() }
            stopped = stopResult.status == .verified
            stopSummary = stopResult.summary
            if stopped {
                run.evidence += stopResult.evidence.map { "stop: " + $0 }
            } else {
                run.warnings.append("Logic did not confirm Stop: \(stopResult.summary) Logic may still be recording: press Stop in Logic. All Notes Off was not sent (it would be recorded).")
                run.warnings += stopResult.warnings
            }
        }
        if stopped {
            run.report.timing.stopSongPosition = await stopSongPosition(after: mark)
            await mcu.waitForTimecodeQuiet()
            run.report.timing.displayAtStop = await transport.snapshot().display
            run.evidence.append("after Stop: Song Position Pointer right after Logic's MIDI Stop \(run.report.timing.stopSongPosition.map { "= \($0)" } ?? "not received"), time display \(run.report.timing.displayAtStop ?? "?")")
            if abortReason != nil {
                // Only after Stop is confirmed: while recording, CC 123 would be recorded.
                try? notes.send([.controlChange(channel: 0, controller: 123, value: 0)])
                run.evidence.append("sent All Notes Off (CC 123) on LogicMCP Notes after Stop")
            }
        }
        let capture = timeline.endCapture()

        run.report.noteOnsSent = outcome.noteOns
        run.report.noteOffsSent = outcome.noteOffs
        if let runSequence {
            analyse(capture, after: runSequence, outcome: outcome, samples: samples, startTick: startTick, run: &run)
        }
        return Recording(abortReason: abortReason, stopped: stopped, stopSummary: stopSummary,
                         noteOns: outcome.noteOns, noteOffs: outcome.noteOffs)
    }

    struct OwnStop {
        var cause: String
        var after: Duration
    }

    /// When Logic shows that it stopped, or stopped recording, by itself (a MIDI Stop on the sync
    /// port after `mark`, or its Record LED off), waits up to `stopSettle` for its Play and Record
    /// LEDs to go off: Logic 13 sent MIDI Stop and the stop SPP 2–4 ms before the LEDs (spike
    /// capture: FC 23.813 s, SPP 23.815 s, LEDs 23.817 s). Returns nil when Logic shows no sign
    /// of stopping, or still plays or records after the wait (a punch-out): then Stop is pressed.
    private func waitForOwnStop(after mark: Int) async -> OwnStop? {
        let midiStop = timeline.fix().lastTransport.map { $0.kind == .stop && $0.sequence > mark } ?? false
        let recordOff = await mcu.surface.led(.record).map { $0 == .off } ?? false
        guard midiStop || recordOff else { return nil }
        let start = clock.now
        let deadline = start.advanced(by: timings.stopSettle)
        while true {
            let now = await transport.snapshot()
            if now.playing == false, now.recording != true {
                return OwnStop(cause: midiStop ? "MIDI Stop on LogicMCP Sync" : "its Record LED went off",
                               after: start.duration(to: clock.now))
            }
            if clock.now >= deadline { return nil }
            try? await clock.sleep(for: .milliseconds(5))
        }
    }

    /// The Song Position Pointer Logic sent right after its MIDI Stop for this run (the last
    /// Stop after `mark`): where recording stopped, before anything else moved the playhead.
    private func stopSongPosition(after mark: Int) async -> Int? {
        let deadline = clock.now.advanced(by: timings.stopSPPTimeout)
        while true {
            if let stop = timeline.fix().lastTransport, stop.kind == .stop, stop.sequence > mark,
               let event = timeline.songPositions(after: stop.sequence).first, case .songPosition(let value) = event.kind {
                return value
            }
            if clock.now >= deadline { return nil }
            try? await clock.sleep(for: .milliseconds(5))
        }
    }

    struct ClockStart {
        var transport: SyncTimeline.Event
        var firstTick: Int
        /// SPPs received so far, taken after the Continue (Logic repeats the pre-roll SPP just
        /// before it); any further SPP while recording is a jump.
        var songPositionCount: Int
    }

    /// Waits for Logic's Continue/Start after `mark` and the first clock after it.
    private func waitForClockStart(after mark: Int) async -> Swift.Result<ClockStart, Failure> {
        let deadline = clock.now.advanced(by: timings.clockStartTimeout)
        while true {
            let fix = timeline.fix()
            if let event = fix.lastTransport, event.sequence > mark {
                if event.kind == .stop {
                    return .failure(Failure(summary: "Logic stopped before its clock started (MIDI Stop). Nothing was sent."))
                }
                if let last = fix.lastClock, fix.clocksSinceStart >= 1, last.time >= event.time {
                    guard timeline.songPositions(after: event.sequence).isEmpty else {
                        return .failure(Failure(summary: "Logic sent a Song Position Pointer right after starting (a jump). Nothing was sent."))
                    }
                    return .success(ClockStart(transport: event, firstTick: last.tick - fix.clocksSinceStart + 1,
                                               songPositionCount: fix.songPositionCount))
                }
            }
            if await mcu.surface.led(.record).map({ $0 != .off }) != true {
                return .failure(Failure(summary: "Logic's Record LED went off before its MIDI clock started. Nothing was sent."))
            }
            if clock.now >= deadline {
                return .failure(Failure(summary: "Logic did not start its MIDI clock on LogicMCP Sync within \(timings.clockStartTimeout.milliseconds) ms of the Record LED. Nothing was sent."))
            }
            try? await clock.sleep(for: .milliseconds(2))
        }
    }

    /// Polls the Record LED and the time display every `monitorInterval` while the thread
    /// sends; aborts the thread when the Record LED is off (recording stopped in Logic) or when
    /// the recording would run past `maxRecordingSeconds` from the Record press: already, or at
    /// the tempo Logic's clock shows now (checked every round, so a tempo drop is caught).
    /// (MCP calls are not cancelled: tool calls run one at a time to the end; Stop in Logic
    /// is the way to abort.)
    private func supervise(_ control: SchedulerControl, endTick: Double, pressed: ContinuousClock.Instant) async -> [DisplaySample] {
        var samples: [DisplaySample] = []
        var lastPosition: BeatsPosition?
        let limit = timings.maxRecordingSeconds
        while !control.isFinished {
            let surface = await mcu.surface
            if surface.led(.record).map({ $0 != .off }) != true {
                control.abort("Logic's Record LED went off (recording was stopped in Logic).")
            }
            if surface.led(.beatsLED).map({ $0 != .off }) == true, let position = surface.beatsPosition, position != lastPosition {
                lastPosition = position
                samples.append(DisplaySample(position: position, time: clock.now))
            }
            let elapsed = pressed.duration(to: clock.now).seconds
            if elapsed > limit {
                control.abort("The recording has run \(Int(elapsed)) s since Record; the limit is \(Self.seconds(limit)) s.")
            } else {
                let fix = timeline.fix()
                if fix.clocksSinceStart >= 24, let perTick = fix.secondsPerTick, let last = fix.lastClock {
                    let remaining = max(0, endTick - Double(last.tick)) * perTick
                    if elapsed + remaining > limit {
                        control.abort("At the tempo Logic's clock shows now (\(String(format: "%.1f", fix.tempoBPM ?? 0)) BPM) the material would end \(Int((elapsed + remaining).rounded())) s after Record; the limit is \(Self.seconds(limit)) s.")
                    }
                }
            }
            try? await clock.sleep(for: timings.monitorInterval)
        }
        return samples
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Lets Logic record a little past the last note-off before stopping.
    private func waitForTail(endTick: Double, after lastSend: ContinuousClock.Instant) async {
        let earliest = lastSend.advanced(by: timings.minimumTail)
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let fix = timeline.fix()
            if fix.running != true { return }
            if await mcu.surface.led(.record).map({ $0 != .off }) != true { return }
            if clock.now >= earliest, let tick = fix.tick(at: clock.now), tick >= endTick { return }
            try? await clock.sleep(for: .milliseconds(5))
        }
    }

    /// Timing evidence from the captured clock: scheduling error per send, tempo, jitter, and
    /// where the time display showed the start bar.
    private func analyse(_ capture: [SyncTimeline.Event], after sequence: Int, outcome: NoteScheduler.Outcome,
                         samples: [DisplaySample], startTick: Int, run: inout Run) {
        let track = ClockTrack(events: capture, after: sequence)
        run.report.timing.tempoBPM = track.tempoBPM.map { ($0 * 10).rounded() / 10 }
        run.report.timing.clockJitterMs = track.jitterRMS.map { ($0 * 10000).rounded() / 10 }
        if let first = track.samples.first, let last = track.samples.last {
            run.report.timing.recordedSeconds = (first.time.duration(to: last.time).seconds * 100).rounded() / 100
        }
        let errors = outcome.sent.compactMap { sent in
            track.time(ofTick: sent.tick).map { $0.duration(to: sent.time).seconds * 1000 }
        }
        if let worst = errors.map(abs).max() {
            run.report.timing.maxSchedulingErrorMs = (worst * 100).rounded() / 100
            let mean = errors.reduce(0, +) / Double(errors.count)
            run.report.timing.meanSchedulingErrorMs = (mean * 100).rounded() / 100
        }
        let bar = run.report.startBar
        if let sample = samples.first(where: { $0.position.bar == bar }), let at = track.tick(at: sample.time) {
            // Assumes the display's beat is a quarter note and its division a sixteenth (240 ticks).
            let p = sample.position
            let shown = Double(startTick) + Double((p.beat - 1) * 960 + (p.division - 1) * 240 + (p.tick - 1)) / 40
            run.report.timing.displayStartBarOffsetSixteenths = ((at - shown) / 6 * 100).rounded() / 100
        }
        // CoreMIDI timestamps on the run's clocks, against their arrival.
        let clocks = capture.filter { event in
            guard event.sequence > sequence, case .clock(tick: _?) = event.kind else { return false }
            return true
        }
        let leads = clocks.compactMap { $0.timestampLead?.seconds }.map { $0 * 1000 }
        run.report.timing.clocksWithTimestamp = leads.count
        if let max = leads.max(), let min = leads.min() {
            run.report.timing.clockTimestampLeadMaxMs = (max * 100).rounded() / 100
            run.report.timing.clockTimestampLeadMinMs = (min * 100).rounded() / 100
            run.report.timing.clockTimestampLeadMeanMs = (leads.reduce(0, +) / Double(leads.count) * 100).rounded() / 100
        }
        if !outcome.sent.isEmpty {
            run.evidence.append("sent \(outcome.noteOns) note-on(s) and \(outcome.noteOffs) note-off(s) in \(outcome.sent.count) group(s) on LogicMCP Notes between song positions \(Self.sixteenths(outcome.sent.first!.tick)) and \(Self.sixteenths(outcome.sent.last!.tick)); right before each send Logic's clock was running with no Stop, jump or restart, and the Record LED, polled every \(timings.monitorInterval.milliseconds) ms, was not seen off before the last send")
            if leads.isEmpty {
                run.evidence.append("Logic's clock messages carried no CoreMIDI timestamps (\(clocks.count) clocks): notes were timed by when the clock reached the server")
            } else {
                run.evidence.append("\(leads.count) of \(clocks.count) clock messages carried CoreMIDI timestamps, and notes were timed by them; timestamp minus arrival at the server: max \(String(format: "%+.2f", run.report.timing.clockTimestampLeadMaxMs ?? 0)) ms, min \(String(format: "%+.2f", run.report.timing.clockTimestampLeadMinMs ?? 0)) ms, mean \(String(format: "%+.2f", run.report.timing.clockTimestampLeadMeanMs ?? 0)) ms (positive: Logic sent its clock ahead of time)")
            }
            var timing = "scheduling error against Logic's clock (its timestamps, or arrival times where it had none): max \(run.report.timing.maxSchedulingErrorMs.map { String(format: "%.2f", $0) } ?? "?") ms, mean \(run.report.timing.meanSchedulingErrorMs.map { String(format: "%+.2f", $0) } ?? "?") ms"
            if let jitter = run.report.timing.clockJitterMs { timing += "; clock jitter \(String(format: "%.1f", jitter)) ms RMS" }
            if let tempo = run.report.timing.tempoBPM { timing += "; tempo from the clock \(tempo) BPM" }
            run.evidence.append(timing)
        }
        if let offset = run.report.timing.displayStartBarOffsetSixteenths {
            run.evidence.append("the time display first showed bar \(bar) when Logic's clock was \(String(format: "%+.2f", offset)) sixteenths from it (display updates lag)")
        }
    }

    static func sixteenths(_ ticks: Double) -> String {
        let value = ticks / 6
        return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    static func describe(_ recording: Recording, plan: NotePlan, request: NoteWriteRequest, run: Run) -> (Result.Status, String) {
        let target = "track \(request.track)" + (run.report.trackName.map { " " + ProjectText.quoted($0) } ?? "")
        if let reason = recording.abortReason {
            let stopped = recording.stopped ? "Logic was stopped" : "Logic did NOT confirm Stop and may still be recording: press Stop in Logic"
            if recording.noteOns == 0 {
                return (.failed, "Stopped before any note was sent: \(reason) \(stopped).")
            }
            return (.failed, "Stopped after \(recording.noteOns) of \(plan.noteCount) notes: \(reason) \(stopped). Logic has recorded the notes sent so far on \(target); undo the recording in Logic if it is not wanted.")
        }
        guard recording.stopped else {
            return (.failed, "All \(plan.noteCount) notes were sent to \(target) while Logic recorded, but Logic did not confirm Stop (\(recording.stopSummary)). Logic may still be recording: press Stop in Logic.")
        }
        return (.partial, "Sent all \(plan.noteCount) notes to \(target) from bar \(request.startBar) while Logic recorded, timed by Logic's MIDI clock, then stopped. What Logic recorded is not read back; check the region in Logic.")
    }
}
