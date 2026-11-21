import FakeLogic
import Foundation
import Testing
@testable import LogicBridge
import MackieControl
import MIDICore

/// Writer timings for the in-memory fake.
func fastNoteTimings() -> NoteWriterTimings {
    var timings = NoteWriterTimings()
    timings.clockStartTimeout = .seconds(3)
    timings.monitorInterval = .milliseconds(2)
    timings.minimumTail = .milliseconds(40)
    timings.stopSPPTimeout = .milliseconds(400)
    timings.armRestoreWindow = .milliseconds(200)
    return timings
}

struct NoteHarness {
    let mixerHarness: MixerHarness
    let writer: NoteWriter
    var host: FakeLogicHost { mixerHarness.host }
    var recorder: FakeNoteRecorder { mixerHarness.host.noteRecorder }
    var transport: TransportController { mixerHarness.base.transport }
    var timeline: SyncTimeline { mixerHarness.base.sync.timeline }

    /// The fake runs at `tempo` (fast tempos keep the tests short) and starts its clock 20 ms
    /// after Record.
    static func make(
        tracks: [FakeTrack] = FakeTrack.observedProject, tempo: Double = 480,
        timings: NoteWriterTimings = fastNoteTimings(),
        configure: (inout FakeLogicHost.Behavior) -> Void = { _ in }
    ) async -> NoteHarness {
        let base = await MixerHarness.make(tracks: tracks) { behavior in
            behavior.sync.tempoBPM = tempo
            behavior.sync.startDelay = .milliseconds(20)
            configure(&behavior)
        }
        let writer = NoteWriter(mcu: base.session, sync: base.base.sync, transport: base.base.transport,
                                mixer: base.mixer, notes: base.host.noteRecorder, timings: timings)
        return NoteHarness(mixerHarness: base, writer: writer)
    }

    var stopPresses: Int {
        get async { await host.presses.filter { $0 == MCUButton.stop.rawValue }.count }
    }

    func armStates() async -> [Bool] { await host.tracks.map(\.recArm) }
    /// The Rec LEDs Logic shows for these arm states while some track is armed: armed tracks
    /// blink, the others (the selected one too) are off.
    static func lights(_ arms: [Bool]) -> [RecordArmLight?] { arms.map { $0 ? .alternating : .off } }
    func recArmPresses() async -> [UInt8] { await host.presses.filter { $0 <= 0x07 } }
    var noteOnsReceived: [FakeNoteRecorder.Received] {
        recorder.received.filter { if case let .noteOn(_, _, velocity) = $0.message { return velocity > 0 } else { return false } }
    }
}

/// Polls an async condition (default up to 10 s).
func waitFor(_ timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return false
}

private let inst2 = "Inst 2"
/// Bar 3 in the fake's 4/4: SPP 32, tick 192.
private let startBar = 3
private let startTick = 192.0
/// 0.15 quarter notes = 19 ms at 480 BPM.
private let tolerance = 0.15

private func beats(_ tick: Double?) -> Double { ((tick ?? -1000) - startTick) / 24 }

private func request(_ notes: [NoteSpec], track: Int = 2, name: String? = inst2, bar: Int = startBar) -> NoteWriteRequest {
    // The fake records exactly when a note arrives: no calibration offset.
    NoteWriteRequest(track: track, expectedName: name, startBar: bar, notes: notes, timingOffsetMs: 0)
}

private func expectPlaced(_ recorded: [FakeRecordedNote], _ specs: [NoteSpec], tracks: [Int] = [1]) {
    let got = recorded.sorted { ($0.startTick, $0.pitch) < ($1.startTick, $1.pitch) }
    let want = specs.sorted { ($0.startBeat, $0.pitch) < ($1.startBeat, $1.pitch) }
    #expect(got.count == want.count)
    for (note, spec) in zip(got, want) {
        // Never before the record-in point (the start bar), whatever the tolerance below.
        #expect(note.recordInTick == startTick)
        #expect(note.startTick >= startTick, "pitch \(spec.pitch) starts at tick \(note.startTick), before the record-in tick \(startTick)")
        #expect(note.pitch == spec.pitch)
        #expect(note.velocity == spec.velocity)
        #expect(abs(beats(note.startTick) - spec.startBeat) < tolerance, "pitch \(spec.pitch) starts at beat \(beats(note.startTick)), wanted \(spec.startBeat)")
        #expect(abs(beats(note.endTick) - (spec.startBeat + spec.durationBeats)) < tolerance, "pitch \(spec.pitch) ends at beat \(beats(note.endTick)), wanted \(spec.startBeat + spec.durationBeats)")
        #expect(note.tracks == tracks)
    }
}

/// Refusals and failures before Record: no real-time threads, so these run in parallel.
@Suite("write_midi checks against FakeLogic")
struct NoteWriterCheckTests {
    @Test(arguments: ["cycle on", "cycle unknown", "playing", "recording"])
    func refusalsSendNothing(_ situation: String) async {
        let h = await NoteHarness.make { behavior in
            if situation == "cycle on" { behavior.cycleOn = true }
            if situation == "cycle unknown" { behavior.reportsCycleLED = false }
        }
        if situation == "playing" || situation == "recording" {
            await h.host.pressInLogic(situation == "playing" ? .play : .record)
            #expect(await waitFor { await h.transport.snapshot().playing == true })
        }
        let jogs = await h.host.jogTicks
        let result = await h.writer.write(request([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)]), replaceConfirmed: true)
        #expect(result.status == .failed)
        #expect(result.summary.contains("Nothing was sent"))
        #expect(await h.host.presses.isEmpty)
        #expect(await h.host.jogTicks == jogs)
        #expect(h.recorder.received.isEmpty)
        await h.host.pressInLogic(.stop)
    }

    @Test func aWrongExpectedNameChangesNothing() async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        let result = await h.writer.write(request([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)], name: "Bass"), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("name check failed"), "\(result.summary)")
        #expect(await h.recArmPresses().isEmpty)
        #expect(h.recorder.received.isEmpty)
        #expect(await h.armStates() == before)
        #expect(await h.host.recording == false)
    }

    @Test func materialLongerThan64BarsOfTheProjectMeterIsRefused() async {
        // 3/4: 64 bars = 192 quarter notes.
        let h = await NoteHarness.make { $0.sync.sixteenthsPerBar = 12 }
        let result = await h.writer.write(request([NoteSpec(pitch: 60, startBeat: 190, durationBeats: 4)]), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("bars long"), "\(result.summary)")
        #expect(result.after?.timing.barLengthSixteenths == 12)
        #expect(await h.recArmPresses().isEmpty)
        #expect(h.recorder.received.isEmpty)
    }

    @Test func withoutSongPositionFromLogicNothingIsArmedOrSent() async {
        let h = await NoteHarness.make { $0.sendsSync = false }
        let result = await h.writer.write(request([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)]), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("did not send a Song Position Pointer"), "\(result.summary)")
        #expect(await h.recArmPresses().isEmpty)
        #expect(h.recorder.received.isEmpty)
    }

    @Test func aPlayheadMovedAfterArmingRestoresArmsWithoutRecording() async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        async let pending = h.writer.write(request([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)]), replaceConfirmed: false)
        // Once Inst 2 is armed and track 11 disarmed, move the playhead as if the user did it.
        let armed = await waitFor {
            let states = await h.armStates()
            return states[1] && !states[10]
        }
        #expect(armed)
        await h.host.setPosition(BeatsPosition(bar: 5, beat: 1, division: 1, tick: 1))
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains("moved away") || result.summary.contains("another Song Position Pointer"), "\(result.summary)")
        #expect(result.summary.contains("No note was sent"))
        #expect(await !h.host.presses.contains(MCUButton.record.rawValue))
        #expect(await h.host.recording == false)
        #expect(h.recorder.received.isEmpty)
        #expect(await h.armStates() == before)
        #expect(!result.warnings.contains(NoteWriter.contentNote))
    }

    @Test func aMissingTrackIsRefusedBeforeArming() async {
        let h = await NoteHarness.make()
        let result = await h.writer.write(request([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)], track: 12, name: "X"), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("does not exist"))
        #expect(await h.recArmPresses().isEmpty)
        #expect(h.recorder.received.isEmpty)
    }
}

// The recording tests run a real-time note thread and the fake's clock thread at 480 BPM (a
// tick every 5 ms). Two serialized suites run side by side: twenty such tests at once would
// measure CPU contention, not the writer.

@Suite("write_midi placement against FakeLogic", .serialized)
struct NoteWriterTests {
    @Test func notesLandWhereTheyBelongAndArmingIsRestored() async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        #expect(before[10] == true)  // the observed project has track 11 armed
        let notes = [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1, velocity: 100),
            NoteSpec(pitch: 64, startBeat: 1, durationBeats: 0.5, velocity: 80),
            NoteSpec(pitch: 67, startBeat: 1.5, durationBeats: 1.5, velocity: 90),
            NoteSpec(pitch: 48, startBeat: 2, durationBeats: 1, velocity: 70),
            NoteSpec(pitch: 55, startBeat: 2, durationBeats: 1, velocity: 71),
        ]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary) \(result.warnings)")
        // Only Inst 2 (index 1) was armed while recording.
        expectPlaced(h.recorder.notes, notes)
        let allWhileRecording = h.recorder.received.allSatisfy { $0.whileRecording }
        #expect(allWhileRecording)
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(await h.armStates() == before)
        #expect(await h.host.playing == false)

        let report = result.after
        #expect(report?.trackName == inst2)
        #expect(report?.timing.startBarSongPosition == 32)
        #expect(report?.timing.barLengthSixteenths == 16)
        #expect(report?.timing.recordStartSongPosition == 16)
        #expect(report?.timing.preRollSixteenths == 16)
        #expect(report?.timing.stopSongPosition.map { $0 >= 44 } == true)
        #expect(report?.noteOnsSent == 5)
        #expect(report?.noteOffsSent == 5)
        #expect(report?.timing.maxSchedulingErrorMs != nil)
        let tempo = report?.timing.tempoBPM ?? 0
        #expect(abs(tempo - 480) < 10)
        #expect(report?.armBefore.map(\.light) == NoteHarness.lights(before))
        #expect(report?.armAfter.map(\.light) == NoteHarness.lights(before))
        #expect(result.warnings.contains(NoteWriter.contentNote))
        #expect(result.warnings.contains(NoteWriter.trackTypeNote))
        #expect(result.evidence.contains { $0.contains("only track 2 \"Inst 2\" is lit") })
        // Arm the target (strip 2 of the first page) first, then disarm track 11; the restore
        // presses the same two again in reverse order: four Rec presses in all.
        let presses = await h.recArmPresses()
        #expect(presses.count == 4)
        #expect(presses.first == MCUButton.recArm(1))
        #expect(presses.count == 4 && presses[0] == presses[3] && presses[1] == presses[2])
    }

    @Test func replaceModeNeedsConfirmationAndSendsNothingUntilConfirmed() async {
        let h = await NoteHarness.make { $0.replaceOn = true }
        let notes = [NoteSpec(pitch: 62, startBeat: 0.5, durationBeats: 0.5)]
        let first = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(first.status == .needsConfirmation)
        #expect(first.summary.contains("Replace mode is on"))
        #expect(await h.host.presses.isEmpty)
        #expect(await h.host.jogTicks == 0)
        #expect(h.recorder.received.isEmpty)

        let second = await h.writer.write(request(notes), replaceConfirmed: true)
        #expect(second.status == .partial, "\(second.summary)")
        expectPlaced(h.recorder.notes, notes)
        #expect(second.warnings.contains { $0.contains("after confirmation") })
    }

    @Test func aTempoChangeWhileRecordingIsFollowed() async {
        let h = await NoteHarness.make(tempo: 480)
        let notes = (0..<8).map { NoteSpec(pitch: UInt8(60 + $0), startBeat: Double($0), durationBeats: 0.5) }
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { !h.noteOnsReceived.isEmpty })
        await h.host.setTempo(360)
        let result = await pending
        #expect(result.status == .partial, "\(result.summary)")
        expectPlaced(h.recorder.notes, notes)
    }

    @Test func withoutPreRollTheFirstNotesWaitForLogicsClock() async {
        let h = await NoteHarness.make { $0.sync.recordPreRollBars = 0 }
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1), NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary)")
        #expect(result.warnings.contains { $0.contains("without pre-roll") })
        #expect(result.after?.timing.preRollSixteenths == 0)
        expectPlaced(h.recorder.notes, notes)
        // Never before the record-in point.
        #expect(h.recorder.notes.allSatisfy { $0.startTick >= startTick })
    }

    @Test func anAlreadyArmedTargetNeedsNoRecArmPresses() async {
        let tracks = [FakeTrack("Inst 1"), FakeTrack("Inst 2", recArm: true)] + (1...3).map { FakeTrack("Audio \($0)") }
        let h = await NoteHarness.make(tracks: tracks)
        let notes = [NoteSpec(pitch: 72, startBeat: 0.25, durationBeats: 0.75)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary)")
        #expect(await h.recArmPresses().isEmpty)
        expectPlaced(h.recorder.notes, notes)
        #expect(await h.armStates() == tracks.map(\.recArm))
    }

    /// Observed on Logic 13 (2026-11-21): with no track armed, the selected track is
    /// record-enabled (steady Rec LED); arming another track turns its LED off by itself. The
    /// first real-Logic run failed here (the LED change broke strip identity) and its restore
    /// pressed the selected track's Rec, turning its automatic enable into a real arm.
    @Test func anotherSelectedTrackIsLeftToLogic() async {
        let tracks = [FakeTrack("Inst 1"), FakeTrack("Inst 2")] + (1...3).map { FakeTrack("Audio \($0)") }
        let h = await NoteHarness.make(tracks: tracks) { $0.mixer.selectedTrack = 0 }
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1), NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary) \(result.warnings)")
        expectPlaced(h.recorder.notes, notes)  // on Inst 2 only
        // Rec on Inst 2 to arm it and once more to restore; never on the selected Inst 1.
        #expect(await h.recArmPresses() == [MCUButton.recArm(1), MCUButton.recArm(1)])
        #expect(await h.armStates() == tracks.map(\.recArm))
        let lights: [RecordArmLight?] = [.steady, .off, .off, .off, .off]
        #expect(result.after?.armBefore.map(\.light) == lights)
        #expect(result.after?.armAfter.map(\.light) == lights)
        #expect(!result.summary.contains("not fully restored"), "\(result.summary)")
    }

    @Test func theSelectedTargetIsArmedAndGivenBack() async {
        let tracks = [FakeTrack("Inst 1"), FakeTrack("Inst 2")] + (1...3).map { FakeTrack("Audio \($0)") }
        let h = await NoteHarness.make(tracks: tracks) { $0.mixer.selectedTrack = 1 }
        let notes = [NoteSpec(pitch: 67, startBeat: 0.5, durationBeats: 0.5)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary) \(result.warnings)")
        expectPlaced(h.recorder.notes, notes)
        #expect(await h.recArmPresses() == [MCUButton.recArm(1), MCUButton.recArm(1)])
        #expect(await h.armStates() == tracks.map(\.recArm))
        let lights: [RecordArmLight?] = [.off, .steady, .off, .off, .off]
        #expect(result.after?.armBefore.map(\.light) == lights)
        #expect(result.after?.armAfter.map(\.light) == lights)
    }

    @Test func aFailedArmRestoreIsReported() async {
        // Arming takes two Rec presses (Inst 2 on, track 11 off); Logic ignores the restore.
        let h = await NoteHarness.make { $0.ignoresRecArmPressesAfter = 2 }
        let before = await h.armStates()
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary)")
        #expect(result.summary.contains("Record-arm states were not fully restored"), "\(result.summary)")
        #expect(result.summary.contains("track(s) 2, 11 differ from before"), "\(result.summary)")
        expectPlaced(h.recorder.notes, notes)
        // The report shows the LEDs as Logic left them.
        let now = await h.armStates()
        #expect(now != before)
        #expect(result.after?.armAfter.map(\.light) == NoteHarness.lights(now))
        #expect(result.after?.armBefore.map(\.light) == NoteHarness.lights(before))
    }

    @Test func notesFollowLogicsTimestampsWhenItSendsItsClockAhead() async {
        // The fake sends its clock 40 ms (about 8 ticks at 480 BPM) early, stamped with the
        // times it stands for, as CoreMIDI delivers a clock scheduled ahead to a virtual port.
        let h = await NoteHarness.make { $0.sync.clockLead = .milliseconds(40) }
        let notes = [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1),
            NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1),
            NoteSpec(pitch: 67, startBeat: 2.5, durationBeats: 0.5),
        ]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary)")
        expectPlaced(h.recorder.notes, notes)
        // The fake's clock thread can only wake late, which shrinks the lead below 40 ms;
        // `expectPlaced` above is what shows that the timestamps were followed.
        let timing = result.after?.timing
        #expect((timing?.clocksWithTimestamp ?? 0) > 24)
        #expect((timing?.clockTimestampLeadMeanMs ?? 0) > 15, "\(String(describing: timing))")
        #expect((timing?.clockTimestampLeadMaxMs ?? 100) <= 40.5, "\(String(describing: timing))")
        #expect(result.evidence.contains { $0.contains("timestamp") })
    }

    @Test func aNegativeOffsetNeverSendsBeforeTheStartBar() async {
        let h = await NoteHarness.make()
        // -150 ms is 1.2 beats at 480 BPM: the first note would fall into the pre-roll.
        var write = request([NoteSpec(pitch: 60, startBeat: 0.25, durationBeats: 0.5), NoteSpec(pitch: 64, startBeat: 2, durationBeats: 0.5)])
        write.timingOffsetMs = -150
        let result = await h.writer.write(write, replaceConfirmed: false)
        #expect(result.status == .partial, "\(result.summary)")
        let recorded = h.recorder.notes.sorted { $0.startTick < $1.startTick }
        #expect(recorded.count == 2)
        #expect(recorded.allSatisfy { $0.startTick >= startTick }, "\(recorded.map(\.startTick))")
        // The later note moves 1.2 beats earlier, as asked.
        #expect(abs(beats(recorded.last?.startTick) - 0.8) < tolerance, "\(recorded.map(\.startTick))")
    }
}

@Suite("write_midi aborts against FakeLogic", .serialized)
struct NoteWriterAbortTests {
    @Test func stopInLogicAbortsAndReleasesHeldNotes() async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        let notes = [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 8),
            NoteSpec(pitch: 64, startBeat: 0.5, durationBeats: 0.5),
            NoteSpec(pitch: 67, startBeat: 6, durationBeats: 1),
        ]
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { h.noteOnsReceived.count >= 2 })
        await h.host.pressInLogic(.stop)
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains("Stopped after 2 of 3 notes"), "\(result.summary)")
        // Nothing was played after Logic stopped; the held C4 was released and All Notes Off followed Stop.
        #expect(!h.noteOnsReceived.contains { !$0.whileRecording })
        #expect(!h.noteOnsReceived.contains { $0.message == .noteOn(channel: 0, note: 67, velocity: 100) })
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(h.recorder.received.contains { $0.message == .noteOff(channel: 0, note: 60, velocity: 0) })
        #expect(h.recorder.received.last?.message == .controlChange(channel: 0, controller: 123, value: 0))
        #expect(h.recorder.received.last?.whileRecording == false)
        #expect(await h.armStates() == before)
        // Logic had stopped: pressing Stop again would move its playhead.
        #expect(await h.stopPresses == 0)
    }

    @Test func stoppingInLogicIsNotFollowedByAnotherStopPress() async {
        // Logic 13 sends MIDI Stop and the stop SPP a few ms before its LEDs; widen that gap.
        let h = await NoteHarness.make { $0.sync.stopLEDDelay = .milliseconds(40) }
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 8), NoteSpec(pitch: 67, startBeat: 6, durationBeats: 1)]
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { !h.noteOnsReceived.isEmpty })
        await h.host.pressInLogic(.stop)
        let result = await pending
        #expect(result.status == .failed, "\(result.summary)")
        #expect(await h.stopPresses == 0)  // `presses` lists only presses from the surface
        #expect(result.evidence.contains { $0.contains("Stop was not pressed") }, "\(result.evidence)")
        // The stop position is the SPP Logic sent right after its MIDI Stop (the last one).
        guard case .songPosition(let stopSPP)? = h.timeline.songPositions(after: 0).last?.kind else {
            Issue.record("no SPP after Stop")
            return
        }
        #expect(stopSPP >= 32)
        #expect(result.after?.timing.stopSongPosition == stopSPP)
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(h.recorder.received.last?.message == .controlChange(channel: 0, controller: 123, value: 0))
        #expect(await h.host.playing == false)
    }

    @Test func stoppingInLogicDuringThePreRollSendsNothingAndPressesNoStop() async {
        let h = await NoteHarness.make { $0.sync.stopLEDDelay = .milliseconds(40) }
        let before = await h.armStates()
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)]
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        // A few clocks into the one-bar pre-roll (96 clocks).
        #expect(await waitFor { h.timeline.fix().clocksSinceStart >= 6 })
        await h.host.pressInLogic(.stop)
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains("before any note"), "\(result.summary)")
        #expect(h.noteOnsReceived.isEmpty)
        #expect(await h.stopPresses == 0)
        #expect(result.evidence.contains { $0.contains("Stop was not pressed") }, "\(result.evidence)")
        #expect(await h.armStates() == before)
    }

    @Test func aPunchOutInLogicStopsSendingAndThenStopsLogic() async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        // The second note-on is due a whole beat (125 ms) after the first.
        let notes = [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 8),
            NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1),
            NoteSpec(pitch: 67, startBeat: 6, durationBeats: 1),
        ]
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { !h.noteOnsReceived.isEmpty })
        await h.host.punchOutInLogic()
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains("Record LED went off"), "\(result.summary)")
        #expect(result.summary.contains("Stopped after 1 of 3 notes"), "\(result.summary)")
        #expect(h.noteOnsReceived.count == 1)
        #expect(!h.noteOnsReceived.contains { !$0.whileRecording })
        // The held C4 was released, then All Notes Off after Stop.
        #expect(h.recorder.received.contains { $0.message == .noteOff(channel: 0, note: 60, velocity: 0) })
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(h.recorder.received.last?.message == .controlChange(channel: 0, controller: 123, value: 0))
        // Logic kept playing after the punch-out, so the writer had to press Stop.
        #expect(await h.stopPresses == 1)
        #expect(await h.host.playing == false)
        #expect(await h.armStates() == before)
    }

    @Test(arguments: ["jump", "restart"])
    func aJumpOrRestartWhileRecordingStopsSending(_ event: String) async {
        let h = await NoteHarness.make()
        let before = await h.armStates()
        let notes = [
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 8),
            NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1),
            NoteSpec(pitch: 67, startBeat: 6, durationBeats: 1),
        ]
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { !h.noteOnsReceived.isEmpty })
        if event == "jump" { await h.host.jumpInLogic(toBar: 20) } else { await h.host.restartClockInLogic() }
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains(event == "jump" ? "jumped" : "restarted"), "\(result.summary)")
        #expect(result.summary.contains("Stopped after 1 of 3 notes"), "\(result.summary)")
        #expect(h.noteOnsReceived.count == 1)
        #expect(h.recorder.received.contains { $0.message == .noteOff(channel: 0, note: 60, velocity: 0) })
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(h.recorder.received.last?.message == .controlChange(channel: 0, controller: 123, value: 0))
        #expect(await h.stopPresses == 1)
        #expect(await h.host.playing == false)
        #expect(await h.armStates() == before)
    }

    @Test func aStalledClockAbortsStopsAndReleases() async {
        // The clock dies half a beat after the start bar (96 pre-roll clocks + 12).
        let h = await NoteHarness.make { $0.sync.clockStopsAfter = 108 }
        let before = await h.armStates()
        let notes = [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 2), NoteSpec(pitch: 62, startBeat: 3, durationBeats: 1)]
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("clock stopped arriving"), "\(result.summary)")
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(!h.noteOnsReceived.contains { $0.message == .noteOn(channel: 0, note: 62, velocity: 100) })
        #expect(await h.host.playing == false)
        #expect(await h.host.presses.contains(MCUButton.stop.rawValue))
        #expect(await h.armStates() == before)
    }

    @Test func materialThatWouldRunPastTheTimeLimitIsStoppedBeforeAnyNote() async {
        var timings = fastNoteTimings()
        timings.maxRecordingSeconds = 1
        let h = await NoteHarness.make(timings: timings)
        // 16 beats = 2 s at 480 BPM, after half a second of pre-roll.
        let notes = (0..<16).map { NoteSpec(pitch: UInt8(60 + $0), startBeat: Double($0), durationBeats: 0.5) }
        let result = await h.writer.write(request(notes), replaceConfirmed: false)
        #expect(result.status == .failed)
        #expect(result.summary.contains("the limit is 1 s"), "\(result.summary)")
        #expect(result.summary.contains("before any note"), "\(result.summary)")
        #expect(h.noteOnsReceived.isEmpty)
        #expect(await h.host.playing == false)
    }

    @Test func aTempoDropWhileRecordingIsCheckedAgainstTheTimeLimit() async {
        var timings = fastNoteTimings()
        timings.maxRecordingSeconds = 2.5
        let h = await NoteHarness.make(timings: timings)
        // 8 beats: 1 s at 480 BPM (fine), 8 s at 60 BPM (too long).
        let notes = (0..<8).map { NoteSpec(pitch: UInt8(60 + $0), startBeat: Double($0), durationBeats: 0.5) }
        let clock = ContinuousClock()
        let start = clock.now
        async let pending = h.writer.write(request(notes), replaceConfirmed: false)
        #expect(await waitFor { !h.noteOnsReceived.isEmpty })
        await h.host.setTempo(60)
        let result = await pending
        #expect(result.status == .failed)
        #expect(result.summary.contains("the limit is 2.5 s"), "\(result.summary)")
        #expect(h.noteOnsReceived.count < 8)
        #expect(h.recorder.hangingNotes.isEmpty)
        #expect(start.duration(to: clock.now) < .seconds(6))
    }
}

@Suite("Fake transport sync")
struct FakeTransportSyncTests {
    @Test func locateSendsSongPositionAndRecordPreRollsOneBar() async {
        var behavior = FakeLogicHost.Behavior()
        behavior.sync.tempoBPM = 480
        behavior.sync.startDelay = .milliseconds(20)
        let h = await Harness.make(behavior)
        let timeline = h.sync.timeline
        #expect(await h.transport.locate(bar: 9, beat: 1).status == .verified)
        #expect(await waitFor(.seconds(1)) { timeline.fix().lastSongPosition?.kind == .songPosition(128) })
        let mark = timeline.fix().sequence
        #expect(await h.transport.record(confirmed: false).status == .verified)
        #expect(await waitFor(.seconds(2)) { timeline.fix().clocksSinceStart >= 30 })
        let fix = timeline.fix()
        // SPP 112 at the press and again with Continue, then clocks from tick 672.
        #expect(timeline.songPositions(after: mark).map(\.kind) == [.songPosition(112), .songPosition(112)])
        #expect(fix.lastTransport?.kind == .continue)
        #expect(fix.lastClock.map { $0.tick - fix.clocksSinceStart + 1 } == 672)
        // Polled: a busy test machine can delay the fake's clock thread for a moment.
        #expect(await waitFor(.seconds(2)) { abs((timeline.fix().tempoBPM ?? 0) - 480) < 20 })
        // The time display runs while recording.
        #expect(await waitFor(.seconds(2)) { await h.transport.snapshot().position?.bar == 9 })
        let stopMark = timeline.fix().sequence
        #expect(await h.transport.stop().status == .verified)
        #expect(await waitFor(.seconds(1)) { !timeline.songPositions(after: stopMark).isEmpty })
        #expect(timeline.fix().running == false)
        if case .songPosition(let stopSPP)? = timeline.songPositions(after: stopMark).last?.kind {
            #expect(stopSPP >= 128)
        }
    }
}
