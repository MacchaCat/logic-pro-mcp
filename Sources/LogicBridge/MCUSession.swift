import Foundation
import MackieControl
import MIDICore

/// Connection-level facts about the Mackie Control link, for `logic_status`.
public struct MCULinkStatus: Sendable, Codable {
    /// True once Logic has written to the LCD or LEDs. Logic probes any new port with device
    /// queries even when no surface is installed, so probe traffic alone does not count: only
    /// an installed Mackie Control surface receives display/LED output.
    public var surfaceActive: Bool
    public var handshake: HandshakeResponder.Phase
    public var messagesReceived: Int
    public var messagesSent: Int
    /// Seconds since the last message from Logic; nil if nothing has arrived yet.
    public var secondsSinceLastMessage: Double?
    public var otherModelProbes: [String]
    public var lastSendError: String?
}

/// One message on the Mackie Control link, for logging.
public struct TrafficEvent: Sendable {
    public enum Direction: String, Sendable { case fromLogic = "IN ", toLogic = "OUT" }
    public let direction: Direction
    public let message: MIDIMessage
    /// Interpretation of inbound messages; nil for outbound.
    public let decoded: MCUHostMessage?
}

/// The emulated Mackie Control surface: consumes Logic's messages, keeps `SurfaceState`,
/// answers identification requests, and sends button / fader / jog input to Logic.
public actor MCUSession {
    public let codec = MCUCodec()
    public private(set) var surface = SurfaceState()
    private var handshake = HandshakeResponder()
    private let scheduler: OutputScheduler
    private let limits: RateLimits
    private let clock = ContinuousClock()
    private var lastInbound: ContinuousClock.Instant?
    private var received = 0
    private var otherModels: Set<UInt8> = []
    private var listener: Task<Void, Never>?
    private var observers: [UUID: @Sendable (TrafficEvent) -> Void] = [:]

    public init(output: any MIDIOutput, limits: RateLimits = RateLimits()) {
        self.scheduler = OutputScheduler(output: output)
        self.limits = limits
    }

    /// Starts consuming messages from Logic. Call once.
    public func start(input: AsyncStream<MIDIMessage>) {
        guard listener == nil else { return }
        listener = Task { [weak self] in
            for await message in input {
                guard let self else { return }
                await self.handle(message)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Registers a callback for every message in either direction (used by the console's traffic log).
    @discardableResult
    public func addObserver(_ observer: @escaping @Sendable (TrafficEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func handle(_ message: MIDIMessage) async {
        received += 1
        lastInbound = clock.now
        let decoded = codec.decode(message)
        if case let .otherModel(model, _) = decoded { otherModels.insert(model) }
        surface.apply(decoded)
        notify(TrafficEvent(direction: .fromLogic, message: message, decoded: decoded))
        let replies = handshake.respond(to: decoded)
        if !replies.isEmpty {
            await send(replies)
        }
    }

    // MARK: Input to Logic

    public func send(_ messages: [MCUSurfaceMessage]) async {
        let encoded = messages.map(codec.encode)
        for message in encoded { notify(TrafficEvent(direction: .toLogic, message: message, decoded: nil)) }
        await scheduler.send(encoded, limits: limits)
    }

    private func notify(_ event: TrafficEvent) {
        for observer in observers.values { observer(event) }
    }

    /// Press and release a button.
    public func press(_ note: UInt8) async {
        await send([.button(note: note, pressed: true)])
        if limits.buttonHold > .zero { try? await clock.sleep(for: limits.buttonHold) }
        await send([.button(note: note, pressed: false)])
    }

    public func press(_ button: MCUButton) async {
        await press(button.rawValue)
    }

    // MARK: Observation

    /// Polls the surface until `predicate` holds or the timeout expires. Returns the elapsed
    /// time on success, nil on timeout. Inbound messages keep flowing while this waits.
    public func waitUntil(
        timeout: Duration, pollEvery: Duration = .milliseconds(5),
        _ predicate: @Sendable (SurfaceState) -> Bool
    ) async -> Duration? {
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        while true {
            if predicate(surface) { return start.duration(to: clock.now) }
            if clock.now >= deadline { return nil }
            try? await clock.sleep(for: pollEvery)
        }
    }

    /// Waits until the time display has had no updates for `quiet`. Logic sends only the digits
    /// that changed, one Control Change each, so a display read right after the first change can
    /// mix old and new digits (e.g. bar 9 → 10).
    public func waitForTimecodeQuiet(quiet: Duration = .milliseconds(30), timeout: Duration = .seconds(1)) async {
        let start = clock.now
        var revision = surface.timecodeRevision
        var lastChange = clock.now
        while start.duration(to: clock.now) < timeout {
            try? await clock.sleep(for: .milliseconds(5))
            if surface.timecodeRevision != revision {
                revision = surface.timecodeRevision
                lastChange = clock.now
            } else if lastChange.duration(to: clock.now) >= quiet {
                return
            }
        }
    }

    public func linkStatus() async -> MCULinkStatus {
        MCULinkStatus(
            surfaceActive: surface.lcdRevision > 0 || surface.ledRevision > 0,
            handshake: handshake.phase,
            messagesReceived: received,
            messagesSent: await scheduler.sentCount,
            secondsSinceLastMessage: lastInbound.map { $0.duration(to: clock.now).seconds },
            otherModelProbes: otherModels.sorted().map { [$0].hexString },
            lastSendError: await scheduler.lastError
        )
    }
}

extension Duration {
    public var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }

    public var milliseconds: Int { Int((seconds * 1000).rounded()) }
}
