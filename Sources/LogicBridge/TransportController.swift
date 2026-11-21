import MackieControl
import MIDICore

/// Transport state as reported by Logic (never assumed).
public struct TransportSnapshot: Sendable, Codable, Equatable {
    public enum DisplayMode: String, Sendable, Codable { case beats, smpte, unknown }

    /// From the Play LED; falls back to MIDI Clock running state when the LED is unknown.
    public var playing: Bool?
    /// From the Record LED (flashing counts as recording, e.g. during count-in).
    public var recording: Bool?
    /// From the Replace LED. nil = Logic has not reported it.
    public var replaceMode: Bool?
    public var cycle: Bool?
    /// From the Click LED: the metronome is on (it then sounds through the main output).
    public var click: Bool?
    public var displayMode: DisplayMode
    /// Bars.beats.division.ticks parsed from the time display (nil in SMPTE mode or if unreadable).
    public var position: BeatsPosition?
    /// The time display exactly as shown, for diagnosis.
    public var display: String?
    public var sync: SyncSnapshot

    enum CodingKeys: String, CodingKey {
        case playing, recording, cycle, click, position, display, sync
        case replaceMode = "replace_mode"
        case displayMode = "display_mode"
    }

    static func make(surface: SurfaceState, sync: SyncSnapshot) -> TransportSnapshot {
        func lit(_ button: MCUButton) -> Bool? {
            surface.led(button).map { $0 != .off }
        }
        let mode: DisplayMode
        if lit(.beatsLED) == true {
            mode = .beats
        } else if lit(.smpteLED) == true {
            mode = .smpte
        } else {
            mode = .unknown
        }
        return TransportSnapshot(
            playing: lit(.play) ?? sync.running,
            recording: lit(.record),
            replaceMode: lit(.replace),
            cycle: lit(.cycle),
            click: lit(.click),
            displayMode: mode,
            // Only parsed when the BEATS LED is lit: SMPTE digits would otherwise read as bars.
            // Until the Logic 13 display format is confirmed (checklist C), unknown mode → nil.
            position: mode == .beats ? surface.beatsPosition : nil,
            display: surface.timecodeText,
            sync: sync
        )
    }
}

/// Play / stop / record through Mackie Control, each verified against Logic's feedback.
public struct TransportController: Sendable {
    public struct Timeouts: Sendable {
        public var play: Duration = .seconds(2)
        public var stop: Duration = .seconds(2)
        /// Longer, because count-in may delay the Record LED.
        public var record: Duration = .seconds(4)
        /// Per jog tick while locating. Logic 13 answered within 30–100 ms in tests.
        public var locateStep: Duration = .milliseconds(800)
        public init() {}
    }

    public typealias Result = OperationResult<TransportSnapshot>

    let mcu: MCUSession
    let sync: SyncMonitor
    let timeouts: Timeouts

    public init(mcu: MCUSession, sync: SyncMonitor, timeouts: Timeouts = Timeouts()) {
        self.mcu = mcu
        self.sync = sync
        self.timeouts = timeouts
    }

    public func snapshot() async -> TransportSnapshot {
        TransportSnapshot.make(surface: await mcu.surface, sync: await sync.snapshot())
    }

    public func play() async -> Result {
        let before = await snapshot()
        if let failure = await notConnected(before) { return failure }
        if before.playing == true {
            return Result(status: .verified, summary: "Already playing; nothing sent.", before: before, after: before,
                          evidence: ["mcu.led.play=on before the call"])
        }
        await mcu.press(.play)
        return await confirm(before: before, timeout: timeouts.play, action: "play",
                             evidenceName: "mcu.led.play=on or sync.running") { $0.playing == true }
    }

    public func stop() async -> Result {
        let before = await snapshot()
        if let failure = await notConnected(before) { return failure }
        if before.playing == false, before.recording != true {
            // Pressing Stop while stopped moves the playhead in Logic, so do not press it.
            return Result(status: .verified, summary: "Already stopped; nothing sent.", before: before, after: before,
                          evidence: ["mcu.led.play=off before the call"])
        }
        await mcu.press(.stop)
        return await confirm(before: before, timeout: timeouts.stop, action: "stop",
                             evidenceName: "mcu.led.play=off and mcu.led.record=off") {
            $0.playing == false && $0.recording != true
        }
    }

    /// Starts recording. Replace mode (or an unknown Replace state) overwrites existing
    /// material, so it needs `confirmed == true` (design §7, decision 4).
    public func record(confirmed: Bool) async -> Result {
        let before = await snapshot()
        if let failure = await notConnected(before) { return failure }
        if before.recording == true {
            return Result(status: .verified, summary: "Already recording; nothing sent.", before: before, after: before,
                          evidence: ["mcu.led.record=on before the call"])
        }
        var warnings: [String] = []
        if before.replaceMode != false {
            let reason = before.replaceMode == true
                ? "Replace mode is on: recording will overwrite existing material on record-enabled tracks."
                : "Logic has not reported the Replace LED, so Replace mode may be on and recording could overwrite existing material."
            guard confirmed else {
                return Result(status: .needsConfirmation, summary: reason, before: before)
            }
            warnings.append("Recording started after confirmation: \(reason)")
        }
        await mcu.press(.record)
        var result = await confirm(before: before, timeout: timeouts.record, action: "record",
                                   evidenceName: "mcu.led.record=on") { $0.recording == true }
        result.warnings += warnings
        return result
    }

    /// Moves the playhead to the start of `bar` with the Mackie jog wheel, one tick at a time,
    /// re-reading the time display after each tick.
    ///
    /// Measured on Logic 13.0 (2026-11-20, checklist F): with "Jog resolution depends on
    /// horizontal zoom" off, one tick moves exactly one bar and snaps to the bar line (from
    /// 6.3.4.137, +1 → 7.1.1.1 and −1 → 6.1.1.1). Bursts of ticks were accelerated or merged,
    /// hence the closed loop. The Go to Position dialog opened but did not accept the F-key digits.
    public func locate(bar: Int, beat: Int) async -> Result {
        let before = await snapshot()
        if let failure = await notConnected(before) { return failure }
        guard beat == 1 else {
            return Result(status: .failed, summary: "Only the start of a bar can be located in this version (beat must be 1). Nothing was sent.", before: before)
        }
        guard (1...999).contains(bar) else {
            return Result(status: .failed, summary: "Bar must be between 1 and 999 (the time display has three bar digits). Nothing was sent.", before: before)
        }
        guard before.playing != true, before.recording != true else {
            return Result(status: .failed, summary: "Logic is playing or recording. Stop first; locate only runs while stopped. Nothing was sent.", before: before)
        }
        guard before.displayMode == .beats, var current = before.position else {
            return Result(status: .failed, summary: "Logic's time display is not readable in Beats mode, so the position cannot be verified. Switch the control surface clock display to Beats. Nothing was sent.", before: before)
        }
        let target = BeatsPosition(bar: bar, beat: 1, division: 1, tick: 1)
        if current == target {
            return Result(status: .verified, summary: "Already at bar \(bar); nothing sent.", before: before, after: before,
                          evidence: ["time display \(current) before the call"])
        }

        let clock = ContinuousClock()
        let start = clock.now
        var ticks = 0
        // One tick per bar, plus one to snap back to a bar line and some slack.
        let limit = abs(bar - current.bar) + 3
        while current != target {
            guard ticks < limit else {
                return Result(
                    status: .failed,
                    summary: "Stopped after \(ticks) jog ticks at \(current) without reaching bar \(bar).",
                    before: before, after: await snapshot(),
                    warnings: ["One jog tick should move exactly one bar. Check that \"Jog resolution depends on horizontal zoom\" is off in Logic Pro > Control Surfaces > Settings."])
            }
            let previous = current
            let direction = current.bar < bar ? 1 : -1
            await mcu.send([.jog(delta: direction)])
            ticks += 1
            let moved = await mcu.waitUntil(timeout: timeouts.locateStep) { $0.beatsPosition != previous }
            guard moved != nil else {
                return Result(
                    status: .failed,
                    summary: "Logic did not move after jog tick \(ticks) (position \(previous)).",
                    before: before, after: await snapshot(),
                    warnings: ["Possible causes: a modal dialog in Logic, or the control surface is bypassed."])
            }
            await mcu.waitForTimecodeQuiet()
            guard let position = await snapshot().position else {
                return Result(status: .failed, summary: "The time display became unreadable while locating.", before: before, after: await snapshot())
            }
            current = position
        }
        let elapsed = start.duration(to: clock.now).milliseconds
        return Result(status: .verified, summary: "Playhead is at bar \(bar).", before: before, after: await snapshot(),
                      evidence: ["time display \(current) after \(ticks) jog ticks in \(elapsed) ms"])
    }

    // MARK: Helpers

    /// Refuses to press anything until Logic drives the surface (LCD or LED output). Without an
    /// installed surface, Logic treats the port as ordinary MIDI input and a button press would be
    /// recorded as a note on the focused track.
    private func notConnected(_ before: TransportSnapshot) async -> Result? {
        let link = await mcu.linkStatus()
        guard !link.surfaceActive else { return nil }
        let detail = link.messagesReceived == 0
            ? "Logic has not sent anything to the LogicMCP MCU port."
            : "Logic has only probed the LogicMCP MCU port (\(link.messagesReceived) messages) but has not driven its display or LEDs, so no Mackie Control surface is installed on it."
        return Result(
            status: .failed,
            summary: detail + " Set up a Mackie Control surface on the LogicMCP MCU ports (docs/setup). Nothing was sent.",
            before: before
        )
    }

    private func confirm(
        before: TransportSnapshot, timeout: Duration, action: String, evidenceName: String,
        _ condition: @escaping @Sendable (TransportSnapshot) -> Bool
    ) async -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        while clock.now < deadline {
            let current = await snapshot()
            if condition(current) {
                let elapsed = start.duration(to: clock.now).milliseconds
                return Result(status: .verified, summary: "\(action.capitalized) confirmed by Logic.",
                              before: before, after: current, evidence: ["\(evidenceName) after \(elapsed) ms"])
            }
            try? await clock.sleep(for: .milliseconds(5))
        }
        let after = await snapshot()
        return Result(
            status: .failed,
            summary: "Pressed \(action.capitalized) but Logic did not confirm within \(timeout.milliseconds) ms. The state below is what Logic last reported.",
            before: before, after: after,
            warnings: ["Possible causes: Logic is showing a modal dialog, the control surface is bypassed while Logic is in the background, or the surface is not set up."]
        )
    }
}
