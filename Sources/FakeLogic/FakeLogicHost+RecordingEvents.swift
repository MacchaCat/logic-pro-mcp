import MackieControl
import MIDICore

/// Phase 4 test hooks: things the user (or Logic) can do while `write_midi` records. None of
/// these message sequences has been observed on Logic 13; they exist so that the writer's
/// guards (Record LED, jump, restart) and its arm-state restore can be exercised.
extension FakeLogicHost {
    /// As if recording were switched off in Logic while the transport keeps playing (a manual
    /// punch-out): the Record LED goes off, Play stays on, the clock keeps running, and notes
    /// arriving from now on are not recorded.
    public func punchOutInLogic() {
        guard recording else { return }
        recording = false
        transportClock.endRecording(now: .now)
        send(transportLEDMessages())
    }

    /// As if the playhead jumped to `bar` while running (e.g. a click in the ruler): a new Song
    /// Position Pointer on the sync port. Only the message is modelled; the fake's own position
    /// and clock carry on, so anything that keeps sending after this is caught by the recorder.
    public func jumpInLogic(toBar bar: Int) {
        guard playing else { return }
        sync([.songPosition(sixteenths(BeatsPosition(bar: bar, beat: 1, division: 1, tick: 1)))])
    }

    /// As if Logic restarted its transport while running: a new Continue on the sync port (only
    /// the message is modelled, as with `jumpInLogic`).
    public func restartClockInLogic() {
        guard playing else { return }
        sync([.continue])
    }

    /// `ignoresRecArmPressesAfter`: true for a Rec button press beyond the limit (`presses`
    /// already holds it).
    func ignoresRecArmPress(_ message: MIDIMessage) -> Bool {
        guard let limit = behavior.ignoresRecArmPressesAfter,
              case let .noteOn(0, note, velocity) = message, note <= 0x07, velocity > 0 else { return false }
        return presses.filter { $0 <= 0x07 }.count > limit
    }
}
