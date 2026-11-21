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
