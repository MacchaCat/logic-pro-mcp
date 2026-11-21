import MackieControl
import MIDICore

/// Phase 4: the fake transport's sync output and running time display (FakeTransportClock),
/// as observed on Logic 13: SPP whenever the playhead moves while stopped; on Record an SPP
/// one bar before the playhead at the press, the same SPP again with Continue and the first
/// clock about 46 ms later, then a clock per tick; on Play the same from one sixteenth before
/// the playhead; on Stop, MIDI Stop and then the stop position as SPP.
extension FakeLogicHost {
    /// Hook for Play / Record.
    func startTransport(recording: Bool) {
        let sync = behavior.sync
        let here = Int(sixteenths(position))
        let from = recording
            ? max(0, here - sync.recordPreRollBars * sync.sixteenthsPerBar)
            : max(0, here - sync.playStartsEarlySixteenths)
        self.sync([.songPosition(UInt16(from))])
        let armed = mixer.recordingTracks
        transportClock.start(fromTick: from * 6, recordInTick: here * 6, recording: recording, armedTracks: armed,
                             now: .now) { [weak self] tick in
            Task { await self?.showRunning(tick: tick) }
        }
    }

    /// Hook for Stop: MIDI Stop, then the stop position as SPP; the playhead stays there. The
    /// transport LEDs follow `stopLEDDelay` later (see `sendTransportLEDs(after:)`).
    func stopTransport() {
        let tick = transportClock.stop(now: .now)
        sync([.stop] + (tick.map { [.songPosition(UInt16(max(0, Int($0.rounded(.down)) / 6)))] } ?? []))
        if let tick {
            position = displayPosition(tick)
            send(timecodeMessages())
        }
    }

    /// Sends the transport LEDs after `delay`, as they are then (not as they were when this was
    /// called), so that a quick Stop → Play cannot reorder them.
    func sendTransportLEDs(after delay: Duration) {
        guard delay > .zero else {
            send(transportLEDMessages())
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.sendCurrentTransportLEDs()
        }
    }

    private func sendCurrentTransportLEDs() {
        send(transportLEDMessages())
    }

    /// Hook for playhead moves while stopped (jog, `setPosition`).
    func positionMoved() {
        guard behavior.sync.sppOnLocate, !playing else { return }
        sync([.songPosition(sixteenths(position))])
    }

    func showRunning(tick: Double) {
        guard playing else { return }
        position = displayPosition(tick)
        send(timecodeMessages())
    }

    /// Bars.beats.division.ticks for an absolute clock tick (quarter-note beats, sixteenth
    /// divisions, 240 display ticks per division).
    func displayPosition(_ tick: Double) -> BeatsPosition {
        let units = max(0, Int((tick * 40).rounded(.down)))  // 960 per quarter note
        let bar = units / (behavior.sync.sixteenthsPerBar * 240)
        let inBar = units % (behavior.sync.sixteenthsPerBar * 240)
        return BeatsPosition(bar: bar + 1, beat: inBar / 960 + 1, division: inBar % 960 / 240 + 1, tick: inBar % 240 + 1)
    }

    /// Changes the tempo as if the user did it in Logic (also while running).
    public func setTempo(_ bpm: Double) {
        transportClock.setTempo(bpm, now: .now)
    }

    /// Presses a transport button as if the user clicked it in Logic.
    public func pressInLogic(_ button: MCUButton) {
        press(button.rawValue)
    }
}
