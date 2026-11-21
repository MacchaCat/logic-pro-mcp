import MIDICore

/// What Logic's MIDI Clock / Song Position Pointer output tells us (sent to `LogicMCP Sync`).
public struct SyncSnapshot: Sendable, Codable, Equatable {
    /// True after Start/Continue, false after Stop, nil if neither has been seen.
    public var running: Bool?
    /// Tempo estimated from clock intervals while running (24 clocks per quarter note).
    public var tempoBPM: Double?
    /// Position in sixteenth notes (MIDI beats) from the last SPP plus clocks counted since.
    public var positionSixteenths: Int?
    public var secondsSinceLastMessage: Double?
    public var messagesReceived: Int
}

/// Consumes Logic's sync output. Arrival times are injectable for tests.
public actor SyncMonitor {
    private let clock = ContinuousClock()
    private var running: Bool?
    private var clockTimes: [ContinuousClock.Instant] = []
    private var sppSixteenths: Int?
    private var clocksSinceSPP = 0
    private var lastMessage: ContinuousClock.Instant?
    private var received = 0
    private var listener: Task<Void, Never>?
    private var observer: (@Sendable (MIDIMessage) -> Void)?
    /// Absolute clock positions with arrival times, readable from any thread (Phase 4).
    public nonisolated let timeline = SyncTimeline()

    public init() {}

    /// Called for every message from Logic on the sync port (used by the console's traffic log).
    public func setObserver(_ observer: @escaping @Sendable (MIDIMessage) -> Void) {
        self.observer = observer
    }

    /// Messages without times: each is timed when this monitor takes it from the stream.
    public func start(input: AsyncStream<MIDIMessage>) {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await message in input {
                guard let self else { return }
                await self.handle(message, at: ContinuousClock.now)
            }
        }
    }

    /// Messages timed on arrival (real ports: in the CoreMIDI callback) with their packet
    /// timestamps, so the hop to this actor does not shift them.
    public func start(input: AsyncStream<TimedMIDIMessage>) {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await item in input {
                guard let self else { return }
                await self.handle(item)
            }
        }
    }

    public func handle(_ message: MIDIMessage, at time: ContinuousClock.Instant) {
        handle(message, time: time, receivedAt: time, lead: nil)
    }

    /// Uses the packet timestamp when there is one, the receipt time otherwise.
    public func handle(_ item: TimedMIDIMessage) {
        handle(item.message, time: item.time, receivedAt: item.receivedAt, lead: item.lead)
    }

    private func handle(_ message: MIDIMessage, time: ContinuousClock.Instant, receivedAt: ContinuousClock.Instant, lead: Duration?) {
        received += 1
        lastMessage = receivedAt
        // The timeline first: the note sender reads it; the observer may write a log file.
        timeline.record(message, at: time, timestampLead: lead)
        observer?(message)
        switch message {
        case .start:
            running = true
            sppSixteenths = 0
            clocksSinceSPP = 0
            clockTimes.removeAll()
        case .continue:
            running = true
            clockTimes.removeAll()
        case .stop:
            running = false
            clockTimes.removeAll()
        case .songPosition(let position):
            sppSixteenths = Int(position)
            clocksSinceSPP = 0
        case .timingClock:
            clocksSinceSPP += 1
            clockTimes.append(time)
            if clockTimes.count > 49 { clockTimes.removeFirst(clockTimes.count - 49) }
        default:
            break
        }
    }

    public func snapshot() -> SyncSnapshot {
        var tempo: Double?
        if running == true, clockTimes.count >= 25,
           let first = clockTimes.first, let last = clockTimes.last {
            let interval = first.duration(to: last).seconds / Double(clockTimes.count - 1)
            if interval > 0 { tempo = (60.0 / (interval * 24.0) * 10).rounded() / 10 }
        }
        return SyncSnapshot(
            running: running,
            tempoBPM: tempo,
            positionSixteenths: sppSixteenths.map { $0 + clocksSinceSPP / 6 },
            secondsSinceLastMessage: lastMessage.map { $0.duration(to: clock.now).seconds },
            messagesReceived: received
        )
    }
}
