import MackieControl
import MIDICore

/// A stand-in for Logic's Mackie Control host side, for tests.
///
/// It only models behaviour that has been observed on real Logic (Logic 12.3 capture,
/// research §1–2). Behaviour that sources disagree on is a switch in `Behavior`, so tests
/// can cover both possibilities. Nothing here is evidence of how Logic 13 behaves.
public actor FakeLogicHost {
    public struct Behavior: Sendable {
        /// Logic 12.3 sends Device Query at connect.
        public var sendsDeviceQuery = true
        /// Logic lights Play / Stop / Record LEDs to reflect transport state.
        public var transportLEDs = true
        /// Whether the Replace LED is ever reported (nil state on our side otherwise).
        public var reportsReplaceLED = true
        public var replaceOn = false
        /// Logic sends MIDI Clock / Start / Stop / SPP to the sync destination.
        public var sendsSync = true
        /// When false, the host ignores all surface input (e.g. a modal dialog or bypass).
        public var respondsToButtons = true
        /// Whether the time display shows Beats (BEATS LED lit).
        public var beatsDisplay = true
        /// No surface installed: Logic only probes the port (device / firmware queries) and
        /// treats everything else arriving on it as ordinary MIDI input.
        public var probeOnly = false
        /// Logic starts playing (and lights Play) only this long after the Play press, e.g. a
        /// slow project or a dialog closing. A Stop press before then cancels the start.
        public var playStartDelay: Duration?
        /// Phase 2: the project's tracks and how the mixer behaves (FakeMixer).
        public var tracks: [FakeTrack] = FakeTrack.observedProject
        public var mixer = FakeMixerBehavior()
        /// Test hooks: after this many button presses Logic ignores all surface input (as with
        /// a modal dialog opening mid-operation).
        public var ignoresSurfaceAfterPresses: Int?
        /// Test hooks: playback starts (as if the user pressed Play in Logic) after this many
        /// V-Pot ticks or fader moves from the surface.
        public var startsPlayingAfterVPotTicks: Int?
        public var startsPlayingAfterFaderMoves: Int?
        /// Test hook: Rec buttons (0x00–0x07) after this many Rec presses have no effect.
        public var ignoresRecArmPressesAfter: Int?
        /// Phase 4: MIDI clock / SPP on the sync port and the Cycle LED (FakeTransportClock).
        public var sync = FakeSyncBehavior()
        public var reportsCycleLED = true
        public var cycleOn = false
        /// The metronome's Click LED at connect (Logic 13 reports it; off here unless a test sets it).
        public var reportsClickLED = false
        public var clickOn = false
        public init() {}
    }

    public let behavior: Behavior
    private let codec = MCUCodec()
    private let toSurface: any MIDIOutput
    private let toSync: any MIDIOutput

    public internal(set) var playing = false
    public internal(set) var recording = false
    public internal(set) var position = BeatsPosition(bar: 1, beat: 1, division: 1, tick: 1)
    public private(set) var presses: [UInt8] = []
    /// Fader touch notes (0x68–0x70) currently held by the surface.
    public private(set) var touchedFaders: Set<UInt8> = []
    /// False while Logic ignores surface input (starts as `behavior.respondsToButtons`).
    public private(set) var respondsToButtons: Bool
    public private(set) var jogTicks = 0
    private var sentTimecode: [UInt8?] = Array(repeating: nil, count: 10)
    public private(set) var handshakeConfirmed = false
    private var listener: Task<Void, Never>?
    private var startPending = false
    public private(set) var mixer: FakeMixer
    private let clock = ContinuousClock()
    /// Phase 4: the transport's position and MIDI clock, and the `LogicMCP Notes` input.
    public nonisolated let transportClock: FakeTransportClock
    public nonisolated let noteRecorder: FakeNoteRecorder

    public init(behavior: Behavior = Behavior(), toSurface: any MIDIOutput, toSync: any MIDIOutput) {
        self.behavior = behavior
        self.toSurface = toSurface
        self.toSync = toSync
        self.mixer = FakeMixer(tracks: behavior.tracks, behavior: behavior.mixer)
        self.respondsToButtons = behavior.respondsToButtons
        self.transportClock = FakeTransportClock(behavior: behavior.sync, output: toSync, sendsSync: behavior.sendsSync)
        self.noteRecorder = FakeNoteRecorder(clock: transportClock)
    }

    /// Makes Logic ignore (false) or handle (true) surface input from now on.
    public func setRespondsToButtons(_ responds: Bool) {
        respondsToButtons = responds
    }

    /// Starts listening to the surface and sends the connect-time dump Logic 12.3 sends.
    public func connect(surfaceInput: AsyncStream<MIDIMessage>) {
        listener = Task { [weak self] in
            for await message in surfaceInput {
                guard let self else { return }
                await self.handle(message)
            }
        }
        var dump: [MIDIMessage] = []
        if behavior.probeOnly {
            send([.sysEx(codec.sysExHeader + [0x00]), .sysEx(codec.sysExHeader + [0x13, 0x00])])
            return
        }
        if behavior.sendsDeviceQuery {
            dump.append(.sysEx(codec.sysExHeader + [0x00]))
            dump.append(.sysEx(mcuManufacturerID + [0x15, 0x00]))  // probe for an Extender too
        }
        dump += mixer.flush(now: clock.now)
        dump += transportLEDMessages()
        dump += displayModeLEDs()
        dump += timecodeMessages()
        send(dump)
        scheduleOverlayExpiry()  // also drives the blinking Rec LEDs of armed tracks
    }

    public func setPosition(_ newPosition: BeatsPosition) {
        position = newPosition
        send(timecodeMessages())
        positionMoved()
    }

    // MARK: Mixer (Phase 2)

    public var tracks: [FakeTrack] { mixer.tracks }
    /// Full names, top to bottom, as Logic's track headers show them.
    public var trackNames: [String] { mixer.tracks.map(\.name) }

    /// Changes a track as if the user did it in Logic; Logic redraws the surface.
    public func updateTrack(_ index: Int, _ change: @Sendable (inout FakeTrack) -> Void) {
        send(mixer.update(track: index, now: clock.now, change))
    }

    /// Replaces the track list (tracks added, removed or renamed in Logic).
    public func setTracks(_ tracks: [FakeTrack]) {
        send(mixer.replaceTracks(tracks, now: clock.now))
    }

    private func sendLater(_ messages: [MIDIMessage], after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.send(messages)
        }
    }

    private var scheduledExpiries: Set<ContinuousClock.Instant> = []

    private func scheduleOverlayExpiry() {
        guard let expiry = mixer.nextExpiry, !scheduledExpiries.contains(expiry) else { return }
        scheduledExpiries.insert(expiry)
        Task { [weak self] in
            try? await Task.sleep(until: expiry, clock: .continuous)
            await self?.expireOverlays()
        }
    }

    private func expireOverlays() {
        let now = clock.now
        scheduledExpiries = scheduledExpiries.filter { $0 > now }
        send(mixer.expire(now: now))
        scheduleOverlayExpiry()
    }

    // MARK: Surface input

    private func handle(_ message: MIDIMessage) {
        switch message {
        case let .noteOn(0, note, velocity) where (0x68...0x70).contains(note):
            if velocity > 0 { touchedFaders.insert(note) } else { touchedFaders.remove(note) }
        case let .noteOff(0, note, _) where (0x68...0x70).contains(note):
            touchedFaders.remove(note)
        default:
            break
        }
        if case let .noteOn(0, note, velocity) = message, velocity > 0 {
            presses.append(note)
            if let limit = behavior.ignoresSurfaceAfterPresses, presses.count > limit { respondsToButtons = false }
        }
        if ignoresRecArmPress(message) { return }
        if respondsToButtons, !behavior.probeOnly, let output = mixer.handle(message, now: clock.now) {
            send(output.now)
            if !output.delayed.isEmpty { sendLater(output.delayed, after: behavior.mixer.echoDelay) }
            scheduleOverlayExpiry()
            if let ticks = behavior.startsPlayingAfterVPotTicks, mixer.vPotTicks >= ticks { press(MCUButton.play.rawValue) }
            if let moves = behavior.startsPlayingAfterFaderMoves, mixer.faderMoves >= moves { press(MCUButton.play.rawValue) }
            return
        }
        switch message {
        case let .noteOn(channel, note, velocity) where channel == 0:
            guard velocity > 0 else { return }  // release
            guard respondsToButtons, !behavior.probeOnly else { return }
            press(note)
        case let .controlChange(channel, controller, value) where channel == 0 && controller == 0x3C:
            jogTicks += 1
            guard respondsToButtons, !behavior.probeOnly, !playing else { return }
            // Logic 13: one tick = one bar, snapping to the bar line.
            let onBarLine = position.beat == 1 && position.division == 1 && position.tick == 1
            if value & 0x40 == 0 {
                position = BeatsPosition(bar: position.bar + 1, beat: 1, division: 1, tick: 1)
            } else {
                position = BeatsPosition(bar: onBarLine ? max(1, position.bar - 1) : position.bar, beat: 1, division: 1, tick: 1)
            }
            send(timecodeMessages())
            positionMoved()
        case let .sysEx(payload) where payload.count >= 5 && Array(payload[0..<4]) == codec.sysExHeader:
            switch payload[4] {
            case 0x01:  // Host Connection Query → reply with any response (the surface verifies)
                let serial = Array(payload[5..<min(12, payload.count)])
                send([.sysEx(codec.sysExHeader + [0x02] + serial + [0x10, 0x20, 0x30, 0x40])])
            case 0x03:
                handshakeConfirmed = true
            default:
                break
            }
        default:
            break
        }
    }

    func press(_ note: UInt8) {
        switch MCUButton(rawValue: note) {
        case .play?:
            guard !playing, !startPending else { return }
            if let delay = behavior.playStartDelay {
                startPending = true
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    await self?.startDelayedPlay()
                }
                return
            }
            startPlaying()
        case .stop?:
            startPending = false
            if playing || recording {
                playing = false
                if recording { send(mixer.setRecording(false, now: clock.now)); scheduleOverlayExpiry() }
                recording = false
                // Logic 13: MIDI Stop and the stop SPP come a few ms before the LEDs.
                stopTransport()
                sendTransportLEDs(after: behavior.sync.stopLEDDelay)
            }
        case .record?:
            guard !recording else { return }
            recording = true
            playing = true
            send(transportLEDMessages())
            send(mixer.setRecording(true, now: clock.now))
            startTransport(recording: true)
        default:
            break
        }
    }

    private func startPlaying() {
        playing = true
        send(transportLEDMessages())
        startTransport(recording: false)  // Phase 4 transport model: SPP, Continue, clock
    }

    private func startDelayedPlay() {
        guard startPending else { return }
        startPending = false
        if !playing { startPlaying() }
    }

    // MARK: Output

    func send(_ messages: [MIDIMessage]) {
        try? toSurface.send(messages)
    }

    func sync(_ messages: [MIDIMessage]) {
        guard behavior.sendsSync else { return }
        try? toSync.send(messages)
    }

    func transportLEDMessages() -> [MIDIMessage] {
        guard behavior.transportLEDs else { return [] }
        func led(_ button: MCUButton, _ on: Bool) -> MIDIMessage {
            .noteOn(channel: 0, note: button.rawValue, velocity: on ? 0x7F : 0x00)
        }
        var messages = [led(.play, playing), led(.stop, !playing), led(.record, recording)]
        if behavior.reportsReplaceLED { messages.append(led(.replace, behavior.replaceOn)) }
        if behavior.reportsCycleLED { messages.append(led(.cycle, behavior.cycleOn)) }
        if behavior.reportsClickLED { messages.append(led(.click, behavior.clickOn)) }
        return messages
    }

    private func displayModeLEDs() -> [MIDIMessage] {
        [.noteOn(channel: 0, note: MCUButton.beatsLED.rawValue, velocity: behavior.beatsDisplay ? 0x7F : 0x00),
         .noteOn(channel: 0, note: MCUButton.smpteLED.rawValue, velocity: behavior.beatsDisplay ? 0x00 : 0x7F)]
    }

    /// Time display in Beats layout 3/2/2/3 with right-aligned groups and no dots, as Logic 13
    /// sends it ("  5 1 1  1"). Like Logic, only digits that changed are sent.
    func timecodeMessages() -> [MIDIMessage] {
        let groups = [(position.bar, 3), (position.beat, 2), (position.division, 2), (position.tick, 3)]
        var leftToRight: [UInt8] = []
        for (value, width) in groups {
            var text = Array(String(value).utf8.suffix(width))
            while text.count < width { text.insert(0x20, at: 0) }
            leftToRight += text
        }
        let rightToLeft = Array(leftToRight.reversed())
        var messages: [MIDIMessage] = []
        for (index, code) in rightToLeft.enumerated() where sentTimecode[index] != code {
            sentTimecode[index] = code
            messages.append(.controlChange(channel: 0, controller: 0x40 + UInt8(index), value: code))
        }
        return messages
    }

    func sixteenths(_ position: BeatsPosition) -> UInt16 {
        // Quarter-note beats assumed by the fake: `sixteenthsPerBar` per bar (16 = 4/4), 4 per beat, 1 per division.
        UInt16(max(0, (position.bar - 1) * behavior.sync.sixteenthsPerBar + (position.beat - 1) * 4 + (position.division - 1)))
    }
}
