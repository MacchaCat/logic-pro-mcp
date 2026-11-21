import Testing
@testable import LogicBridge
import MIDICore

@Suite("Note names and plans")
struct NotePlanTests {
    @Test func noteNames() {
        #expect(NoteName.parse("C4") == 60)
        #expect(NoteName.parse("c4") == 60)
        #expect(NoteName.parse("C#4") == 61)
        #expect(NoteName.parse("Db4") == 61)
        #expect(NoteName.parse("bb3") == 58)
        #expect(NoteName.parse("B♭3") == 58)
        #expect(NoteName.parse("E#4") == 65)
        #expect(NoteName.parse("Cb4") == 59)
        #expect(NoteName.parse("C-1") == 0)
        #expect(NoteName.parse("G9") == 127)
        #expect(NoteName.parse("G#9") == nil)
        #expect(NoteName.parse("Cb-1") == nil)
        #expect(NoteName.parse("H4") == nil)
        #expect(NoteName.parse("C") == nil)
        #expect(NoteName.parse("C10") == nil)
        #expect(NoteName.name(60) == "C4")
        #expect(NoteName.name(0) == "C-1")
        #expect(NoteName.name(127) == "G9")
    }

    func plan(_ notes: [NoteSpec], bar: Int = 3, track: Int = 1) -> Result<NotePlan, NotePlan.Problem> {
        NotePlan.make(NoteWriteRequest(track: track, startBar: bar, notes: notes))
    }

    @Test func eventsAreGroupedByTickWithNoteOffsFirst() throws {
        let made = try plan([
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1),
            NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1, velocity: 90),
            NoteSpec(pitch: 67, startBeat: 1, durationBeats: 0.5),
        ]).get()
        #expect(made.groups.map(\.tick) == [0, 24, 36, 48])
        let second = made.groups[1].events
        #expect(second.map(\.isOn) == [false, true, true])
        #expect(second.map(\.message) == [
            .noteOff(channel: 0, note: 60, velocity: 0),
            .noteOn(channel: 0, note: 64, velocity: 90),
            .noteOn(channel: 0, note: 67, velocity: 100),
        ])
        #expect(made.endBeats == 2)
        #expect(made.warnings.isEmpty)
    }

    @Test func overlappingSamePitchIsShortened() throws {
        let made = try plan([
            NoteSpec(pitch: 60, startBeat: 0, durationBeats: 2),
            NoteSpec(pitch: 60, startBeat: 1, durationBeats: 1),
        ]).get()
        let offs = made.groups.flatMap(\.events).filter { !$0.isOn }
        #expect(offs.map(\.tick) == [24, 48])
        #expect(made.warnings.count == 1)
        #expect(made.warnings[0].contains("shortened"))
    }

    @Test func invalidRequestsAreRejected() {
        func problem(_ result: Result<NotePlan, NotePlan.Problem>) -> String? {
            if case .failure(let failure) = result { return failure.message }
            return nil
        }
        let note = NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)
        #expect(problem(plan([note], bar: 1))?.contains("start_bar must be 2") == true)
        #expect(problem(plan([note], bar: 1000)) != nil)
        #expect(problem(plan([note], track: 0)) != nil)
        #expect(problem(plan([])) != nil)
        #expect(problem(plan(Array(repeating: note, count: 2001)))?.contains("2000") == true)
        #expect(problem(plan([NoteSpec(pitch: 128, startBeat: 0, durationBeats: 1)])) != nil)
        #expect(problem(plan([NoteSpec(pitch: 60, startBeat: -1, durationBeats: 1)])) != nil)
        #expect(problem(plan([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 0)])) != nil)
        #expect(problem(plan([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1, velocity: 0)])) != nil)
        #expect(problem(plan([NoteSpec(pitch: 60, startBeat: .nan, durationBeats: 1)])) != nil)
        #expect(problem(plan([NoteSpec(pitch: 60, startBeat: 1020, durationBeats: 8)]))?.contains("64 bars") == true)
        #expect(problem(plan([note, note]))?.contains("same pitch") == true)
    }

    @Test func confirmationActionIsBoundToTheRequest() {
        let base = NoteWriteRequest(track: 2, expectedName: "Inst 2", startBar: 9, notes: [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)])
        var otherNotes = base
        otherNotes.notes[0].velocity = 90
        var otherBar = base
        otherBar.startBar = 10
        let action = NoteWriter.confirmationAction(for: base)
        #expect(action == NoteWriter.confirmationAction(for: base))
        #expect(action != NoteWriter.confirmationAction(for: otherNotes))
        #expect(action != NoteWriter.confirmationAction(for: otherBar))
        #expect(action.contains("track 2") && action.contains("bar 9"))
    }
}

@Suite("Controller plans")
struct ControllerPlanTests {
    func plan(_ notes: [NoteSpec] = [], _ controllers: [ControllerSpec]) -> Result<NotePlan, NotePlan.Problem> {
        NotePlan.make(NoteWriteRequest(track: 1, startBar: 3, notes: notes, controllers: controllers))
    }

    func problem(_ notes: [NoteSpec] = [], _ controllers: [ControllerSpec]) -> String? {
        if case .failure(let failure) = plan(notes, controllers) { return failure.message }
        return nil
    }

    @Test func atASharedTickNoteOffsThenControllersThenNoteOns() throws {
        let made = try plan(
            [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1), NoteSpec(pitch: 64, startBeat: 1, durationBeats: 1)],
            [.controlChange(64, at: 1, 127), .pitchBend(at: 1, 0)]).get()
        #expect(made.groups.map(\.tick) == [0, 24, 48])
        #expect(made.groups[1].messages == [
            .noteOff(channel: 0, note: 60, velocity: 0),
            .controlChange(channel: 0, controller: 64, value: 127),
            .pitchBend(channel: 0, value: 8192),
            .noteOn(channel: 0, note: 64, velocity: 100),
        ])
        #expect(made.noteCount == 2)
        #expect(made.controlCount == 2)
        #expect(made.usesPitchBend && made.usesSustain)
    }

    @Test func pitchBendRangeMapsToFourteenBits() throws {
        let made = try plan([], [.pitchBend(at: 0, -8192), .pitchBend(at: 1, 0), .pitchBend(at: 2, 8191)]).get()
        let bytes = made.groups.flatMap(\.messages).map(\.bytes)
        #expect(bytes == [[0xE0, 0x00, 0x00], [0xE0, 0x00, 0x40], [0xE0, 0x7F, 0x7F]])
    }

    @Test func rampsStepAtMostEveryHalfClockAndOnlyWhenTheValueChanges() throws {
        let made = try plan([], [ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 127, durationBeats: 1)]).get()
        let controls = made.groups.flatMap(\.controls)
        let values = controls.map { message -> Int in
            if case let .controlChange(_, _, value) = message.message { return Int(value) }
            return -1
        }
        #expect(values.first == 0)
        #expect(values.last == 127)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(controls.first?.tick == 0)
        #expect(controls.last?.tick == 24)
        #expect(zip(controls, controls.dropFirst()).allSatisfy { $1.tick - $0.tick >= ControllerSpec.rampStepTicks - 1e-9 })
        #expect(controls.count == 49)  // 48 half-clock steps over one beat, plus the start
        // A ramp over few values sends only the changes.
        let slow = try plan([], [ControllerSpec(kind: .controlChange(11), startBeat: 0, value: 100, toValue: 102, durationBeats: 4)]).get()
        #expect(slow.controlCount == 3)
        #expect(slow.groups.map(\.tick) == [0, 24, 72])  // 100, then 101 and 102 where the rounded value changes
        #expect(slow.endBeats == 4)
    }

    @Test func aBendRampEndsExactlyOnItsValue() throws {
        let made = try plan([], [ControllerSpec(kind: .pitchBend, startBeat: 2, value: 0, toValue: -8192, durationBeats: 0.5)]).get()
        let controls = made.groups.flatMap(\.controls)
        #expect(controls.count == 25)
        #expect(controls.first?.message == .pitchBend(channel: 0, value: 8192))
        #expect(controls.last?.message == .pitchBend(channel: 0, value: 0))
        #expect(controls.last?.tick == 60)
    }

    @Test func theMaterialEndsAtTheLastNoteOrControllerChange() throws {
        let made = try plan([NoteSpec(pitch: 60, startBeat: 0, durationBeats: 2)],
                            [ControllerSpec(kind: .controlChange(1), startBeat: 4, value: 0, toValue: 10, durationBeats: 2)]).get()
        #expect(made.endBeats == 6)
        let only = try plan([], [.controlChange(64, at: 3, 0)]).get()
        #expect(only.noteCount == 0)
        #expect(only.endBeats == 3)
        #expect(only.usesSustain && !only.usesPitchBend)
    }

    @Test func touchingRampsAreAllowedAndTheLaterWinsTheSharedTick() throws {
        let made = try plan([], [
            ControllerSpec(kind: .controlChange(1), startBeat: 2, value: 64, toValue: 0, durationBeats: 2),
            ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 64, durationBeats: 2),
        ]).get()
        let shared = try #require(made.groups.first { $0.tick == 48 })
        #expect(shared.controls.map(\.controller) == [1, 0])
    }

    @Test func decimalBeatsThatAddUpCountAsTheSamePosition() throws {
        // 0.1 + 0.2 is 0.30000000000000004 in floating point.
        let made = try plan(
            [NoteSpec(pitch: 60, startBeat: 0.3, durationBeats: 1)],
            [ControllerSpec(kind: .pitchBend, startBeat: 0.1, value: 0, toValue: 4000, durationBeats: 0.2),
             .pitchBend(at: 0.3, 0)]).get()
        let shared = try #require(made.groups.first { $0.events.contains(where: \.isOn) })
        #expect(shared.messages == [
            .pitchBend(channel: 0, value: 8192 + 4000),
            .pitchBend(channel: 0, value: 8192),
            .noteOn(channel: 0, note: 60, velocity: 100),
        ])
        #expect(made.groups.filter { abs($0.tick - 7.2) < 0.01 }.count == 1)
    }

    @Test func invalidControllerChangesAreRejected() {
        #expect(problem([], [])?.contains("at least one note or controller change") == true)
        #expect(problem([], [.controlChange(123, at: 0, 0)])?.contains("channel mode") == true)
        #expect(problem([], [.controlChange(120, at: 0, 0)])?.contains("channel mode") == true)
        for number: UInt8 in [20, 29, 39] {
            #expect(problem([], [.controlChange(number, at: 0, 127)])?.contains("CC 20–39") == true, "CC \(number)")
        }
        #expect(problem([], [.controlChange(19, at: 0, 127)]) == nil)
        #expect(problem([], [.controlChange(40, at: 0, 127)]) == nil)
        #expect(problem([], [.controlChange(1, at: 0, 128)])?.contains("0–127") == true)
        #expect(problem([], [.pitchBend(at: 0, 8192)])?.contains("−8192…8191") == true)
        #expect(problem([], [.pitchBend(at: 0, -8193)]) != nil)
        #expect(problem([], [.controlChange(1, at: -1, 0)])?.contains("start_beat") == true)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 10)])?.contains("duration_beats") == true)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, durationBeats: 1)])?.contains("to_value") == true)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 10, durationBeats: 0)]) != nil)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 9000, durationBeats: 1)])?.contains("to_value") == true)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 1020, value: 0, toValue: 1, durationBeats: 8)])?.contains("64 bars") == true)
        // One controller cannot change twice at once.
        let ramp = ControllerSpec(kind: .controlChange(1), startBeat: 0, value: 0, toValue: 127, durationBeats: 4)
        #expect(problem([], [ramp, .controlChange(1, at: 2, 64)])?.contains("must not overlap") == true)
        #expect(problem([], [ramp, .controlChange(1, at: 0, 64)])?.contains("must not overlap") == true)
        #expect(problem([], [.pitchBend(at: 1, 0), .pitchBend(at: 1, 100)])?.contains("must not overlap") == true)
        #expect(problem([], [ramp, .controlChange(1, at: 4, 0)]) == nil)
        #expect(problem([], [ControllerSpec(kind: .controlChange(1), startBeat: 0.1, value: 0, toValue: 9, durationBeats: 0.2),
                              .controlChange(1, at: 0.3, 9)]) == nil)
        #expect(problem([], [ramp, .controlChange(2, at: 2, 64), .pitchBend(at: 2, 0)]) == nil)
    }

    @Test func expandedMessagesAreCapped() {
        let ramps = (40..<80).map { ControllerSpec(kind: .controlChange(UInt8($0)), startBeat: 0, value: 0, toValue: 127, durationBeats: 8) }
        #expect(problem([], ramps)?.contains("\(NoteWriteRequest.maxControllerMessages)") == true)
    }

    @Test func warningsForChannelStripControllersAndValuesLeftOn() throws {
        let strip = try plan([], [.controlChange(7, at: 0, 100), .controlChange(10, at: 0, 64)]).get()
        #expect(strip.warnings.contains { $0.contains("CC 7 (volume) and CC 10 (pan)") })
        let left = try plan([], [.pitchBend(at: 0, 4000), .controlChange(64, at: 0, 127)]).get()
        #expect(left.warnings.contains { $0.contains("pitch bend ends at 4000") })
        #expect(left.warnings.contains { $0.contains("sustain pedal (CC 64) ends down") })
        let clean = try plan([], [.pitchBend(at: 0, 4000), .pitchBend(at: 1, 0), .controlChange(64, at: 0, 127), .controlChange(64, at: 2, 0)]).get()
        #expect(clean.warnings.isEmpty)
    }

    @Test func resetsAfterStopReleaseTheSustainBeforeCentringTheBend() throws {
        let both = try plan([], [.pitchBend(at: 0, 100), .controlChange(64, at: 0, 127)]).get()
        #expect(NoteWriter.resetMessages(both) == [
            .controlChange(channel: 0, controller: 64, value: 0),
            .pitchBend(channel: 0, value: 8192),
        ])
        let neither = try plan([], [.controlChange(1, at: 0, 64)]).get()
        #expect(NoteWriter.resetMessages(neither).isEmpty)
    }

    @Test func confirmationActionCoversControllers() {
        let base = NoteWriteRequest(track: 2, expectedName: "Inst 2", startBar: 9, notes: [NoteSpec(pitch: 60, startBeat: 0, durationBeats: 1)])
        var withBend = base
        withBend.controllers = [.pitchBend(at: 0, 100)]
        var otherBend = base
        otherBend.controllers = [.pitchBend(at: 0, 200)]
        let action = NoteWriter.confirmationAction(for: withBend)
        #expect(action != NoteWriter.confirmationAction(for: base))
        #expect(action != NoteWriter.confirmationAction(for: otherBend))
        #expect(action.contains("1 controller change"))
    }
}
