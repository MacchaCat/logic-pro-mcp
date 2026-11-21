import CommandMap
import MackieControl
import MIDICore

/// Stand-in for Logic's controller assignments on the `LogicMCP Keys` port (Phase 3): a learned
/// CC (channel 16, value 127) runs a key command, whose effect shows on the fake surface through
/// `FakeLogicHost` (tracks added or removed, playhead moved) or the Cycle / Click LEDs.
///
/// The effects are modelled per command id here, independently of the catalog's verification
/// field, so tests of the verification are not circular. Which CC runs which command is
/// `Behavior.assignments`: tests unlearn commands or learn a CC for a different command.
/// What real Logic 13 does for each command is listed as assumptions in docs/checklists/phase-3.md.
public actor FakeKeyCommandHost {
    public struct Behavior: Sendable {
        /// What Logic has learned: controller number (channel 16) → command id.
        /// Default: every catalog command at its catalog controller.
        public var assignments: [UInt8: String]
        /// Delay before an effect shows (Logic redrawing after adding a track).
        public var effectDelay: Duration = .zero
        /// LED states sent when attached (Logic 13 at connect: cycle off, click on).
        public var cycleOn = false
        public var clickOn = true
        /// Whether Logic reports the Cycle / Click LEDs at all.
        public var reportsLEDs = true

        public init() {
            assignments = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.controller, $0.id) })
        }

        /// Forgets the assignments of these command ids ("not learned").
        public mutating func unlearn(_ ids: some Sequence<String>) {
            let gone = Set(ids)
            assignments = assignments.filter { !gone.contains($0.value) }
        }
    }

    private let host: FakeLogicHost
    private let surface: any MIDIOutput
    public private(set) var behavior: Behavior
    public private(set) var cycleOn: Bool
    public private(set) var clickOn: Bool
    /// Command ids run, in order.
    public private(set) var executed: [String] = []
    /// Every message received on the Keys port.
    public private(set) var received: [MIDIMessage] = []
    /// Messages that matched no assignment: Logic treats them as ordinary MIDI input.
    public private(set) var passedThrough: [MIDIMessage] = []
    private var listener: Task<Void, Never>?

    public init(host: FakeLogicHost, surface: any MIDIOutput, behavior: Behavior = Behavior()) {
        self.host = host
        self.surface = surface
        self.behavior = behavior
        cycleOn = behavior.cycleOn
        clickOn = behavior.clickOn
    }

    /// Creates the fake, reports the LEDs and starts listening to `keys`. The listener keeps the
    /// fake alive until `keys` finishes.
    @discardableResult
    public static func attach(
        host: FakeLogicHost, surface: any MIDIOutput, keys: AsyncStream<MIDIMessage>, behavior: Behavior = Behavior()
    ) async -> FakeKeyCommandHost {
        let fake = FakeKeyCommandHost(host: host, surface: surface, behavior: behavior)
        await fake.start(keys)
        return fake
    }

    private func start(_ keys: AsyncStream<MIDIMessage>) {
        sendLEDs()
        listener = Task {
            for await message in keys { await self.handle(message) }
        }
    }

    /// Changes what is learned from now on.
    public func setAssignments(_ assignments: [UInt8: String]) {
        behavior.assignments = assignments
    }

    func handle(_ message: MIDIMessage) async {
        received.append(message)
        guard case let .controlChange(channel, controller, value) = message,
              channel == LogicCommand.channel, value == LogicCommand.triggerValue,
              let id = behavior.assignments[controller] else {
            passedThrough.append(message)
            return
        }
        if behavior.effectDelay > .zero { try? await Task.sleep(for: behavior.effectDelay) }
        await perform(id)
        executed.append(id)
    }

    private func perform(_ id: String) async {
        switch id {
        case "go-to-beginning":
            await host.setPosition(BeatsPosition(bar: 1, beat: 1, division: 1, tick: 1))
        case "forward-one-bar":
            let position = await host.position
            await host.setPosition(BeatsPosition(bar: position.bar + 1, beat: 1, division: 1, tick: 1))
        case "rewind-one-bar":
            // Modelled like a jog tick back: from a bar line one bar earlier, otherwise to the
            // start of the current bar.
            let position = await host.position
            let onBarLine = position.beat == 1 && position.division == 1 && position.tick == 1
            await host.setPosition(BeatsPosition(bar: onBarLine ? max(1, position.bar - 1) : position.bar, beat: 1, division: 1, tick: 1))
        case "new-audio-track":
            await insertTrack { tracks, _ in FakeTrack("オーディオ \(tracks.count + 1)") }
        case "new-software-instrument-track":
            await insertTrack { tracks, _ in FakeTrack("Inst \(tracks.count + 1)") }
        case "duplicate-track":
            await insertTrack { tracks, selected in
                guard let selected else { return nil }
                var copy = tracks[selected]
                copy.mute = false
                copy.solo = false
                copy.recArm = false
                return copy
            }
        case "delete-track":
            var tracks = await host.tracks
            guard !tracks.isEmpty else { return }
            tracks.remove(at: await selectedIndex(tracks))
            await host.setTracks(tracks)
        case "toggle-cycle":
            cycleOn.toggle()
            sendLEDs()
        case "toggle-metronome":
            clickOn.toggle()
            sendLEDs()
        default:
            // undo, redo, save, quantize, select-all, views, markers, Go to Position: nothing the
            // fake surface shows.
            break
        }
    }

    /// The track Logic acts on: `FakeMixerBehavior.selectedTrack`, by default the last one.
    private func selectedIndex(_ tracks: [FakeTrack]) async -> Int {
        let selected = await host.mixer.behavior.selectedTrack ?? (tracks.count - 1)
        return min(max(selected, 0), max(tracks.count - 1, 0))
    }

    /// Inserts a track below the selected one (`selected` is nil in an empty project).
    private func insertTrack(_ make: @Sendable ([FakeTrack], Int?) -> FakeTrack?) async {
        var tracks = await host.tracks
        let selected = tracks.isEmpty ? nil : await selectedIndex(tracks)
        guard let track = make(tracks, selected) else { return }
        tracks.insert(track, at: selected.map { $0 + 1 } ?? 0)
        await host.setTracks(tracks)
    }

    private func sendLEDs() {
        guard behavior.reportsLEDs else { return }
        try? surface.send([
            .noteOn(channel: 0, note: MCUButton.cycle.rawValue, velocity: cycleOn ? 0x7F : 0x00),
            .noteOn(channel: 0, note: MCUButton.click.rawValue, velocity: clickOn ? 0x7F : 0x00),
        ])
    }
}
