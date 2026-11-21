import Foundation
import Network
import Synchronization

/// Events of one client-side connection. Connectors deliver them on the queue passed to `open`.
public enum LinkConnectionEvent: Sendable {
    case ready
    case received(Data)
    case failed(String)
    case closed
}

public protocol LinkConnection: Sendable {
    /// `completion(true)` once the bytes were handed to the transport, false on failure.
    func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void)
    func close()
}

/// Opens client connections: TCP to 127.0.0.1 for the plug-in, in memory for tests and `--fake`.
public protocol LinkConnector: Sendable {
    func open(port: UInt16, queue: DispatchQueue, handler: @escaping @Sendable (LinkConnectionEvent) -> Void) -> any LinkConnection
}

/// The plug-in side of the link, safe to call from any background thread (never the render
/// thread: `send` encodes JSON and allocates).
///
/// It connects to the first port that answers with a logic-mcp hello, reconnects with backoff
/// after failures, and drops frames while not connected or while too many bytes are in flight,
/// so a slow or missing server never blocks the caller.
public final class AnalysisLinkClient: Sendable {
    public struct Configuration: Sendable {
        public var ports: [UInt16]
        public var helloTimeout: Duration
        /// Waits between rounds over all ports; the last value repeats.
        public var backoff: [Duration]
        public var maxBytesInFlight: Int

        public init(
            ports: [UInt16] = AnalysisLink.defaultPorts, helloTimeout: Duration = .seconds(1),
            backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)], maxBytesInFlight: Int = 256 * 1024
        ) {
            self.ports = ports
            self.helloTimeout = helloTimeout
            self.backoff = backoff.isEmpty ? [.seconds(1)] : backoff
            self.maxBytesInFlight = maxBytesInFlight
        }
    }

    public enum State: Sendable, Equatable {
        case stopped
        case connecting(port: UInt16)
        case awaitingHello(port: UInt16)
        case connected(port: UInt16)
        case backingOff
    }

    public enum SendResult: Sendable, Equatable {
        case sent
        case notConnected
        case backpressure
        case encodingFailed
    }

    public struct Statistics: Sendable, Equatable {
        public var framesSent = 0
        public var framesDropped = 0
        public var bytesSent = 0
        public var connects = 0
        public var failedAttempts = 0
    }

    private struct Inner {
        var running = false
        /// Bumped by every `start()`: attempts scheduled for an earlier run do nothing.
        var run: UInt64 = 0
        var generation: UInt64 = 0
        var portIndex = 0
        var backoffIndex = 0
        var phase: State = .stopped
        var connection: (any LinkConnection)?
        var helloDecoder = FrameStreamDecoder()
        var bytesInFlight = 0
        var statistics = Statistics()
    }

    public let configuration: Configuration
    private let connector: any LinkConnector
    private let queue = DispatchQueue(label: "logic-mcp.analysis.client")
    private let inner = Mutex(Inner())

    public init(configuration: Configuration = Configuration(), connector: any LinkConnector = TCPLinkConnector()) {
        self.configuration = configuration
        self.connector = connector
    }

    public var state: State { inner.withLock { $0.phase } }
    public var statistics: Statistics { inner.withLock { $0.statistics } }
    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Starts connecting. `running` is set right here, so a `stop()` right after always wins;
    /// only the first attempt is dispatched to the client's queue.
    public func start() {
        let run = inner.withLock { inner -> UInt64? in
            guard !inner.running, !configuration.ports.isEmpty else { return nil }
            inner.running = true
            inner.run += 1
            inner.portIndex = 0
            inner.backoffIndex = 0
            return inner.run
        }
        guard let run else { return }
        queue.async { [weak self] in self?.attempt(run: run) }
    }

    public func stop() {
        let connection = inner.withLock { inner -> (any LinkConnection)? in
            inner.running = false
            inner.generation += 1
            inner.phase = .stopped
            inner.bytesInFlight = 0
            defer { inner.connection = nil }
            return inner.connection
        }
        connection?.close()
    }

    /// Sends one frame if connected; otherwise drops it. Never blocks.
    @discardableResult
    public func send(_ frame: AnalysisFrame) -> SendResult {
        guard let data = try? FrameCodec.encode(frame) else {
            inner.withLock { $0.statistics.framesDropped += 1 }
            return .encodingFailed
        }
        enum Target {
            case drop(SendResult)
            case send(any LinkConnection, UInt64)
        }
        let target = inner.withLock { inner -> Target in
            guard case .connected = inner.phase, let connection = inner.connection else {
                inner.statistics.framesDropped += 1
                return .drop(.notConnected)
            }
            guard inner.bytesInFlight + data.count <= configuration.maxBytesInFlight else {
                inner.statistics.framesDropped += 1
                return .drop(.backpressure)
            }
            inner.bytesInFlight += data.count
            inner.statistics.framesSent += 1
            inner.statistics.bytesSent += data.count
            return .send(connection, inner.generation)
        }
        switch target {
        case let .drop(result):
            return result
        case let .send(connection, generation):
            let size = data.count
            connection.send(data) { [weak self] (ok: Bool) in
                guard let self else { return }
                self.inner.withLock { inner in
                    if inner.generation == generation { inner.bytesInFlight = max(0, inner.bytesInFlight - size) }
                }
                if !ok { self.queue.async { self.fail(generation, "send failed") } }
            }
            return .sent
        }
    }

    // MARK: State machine (runs on `queue`)

    private func attempt(run: UInt64) {
        let next = inner.withLock { inner -> (UInt16, UInt64, (any LinkConnection)?)? in
            guard inner.running, inner.run == run else { return nil }
            inner.generation += 1
            let port = configuration.ports[inner.portIndex % configuration.ports.count]
            inner.phase = .connecting(port: port)
            inner.helloDecoder = FrameStreamDecoder(maxPayload: 4096)
            inner.bytesInFlight = 0
            // Never leave an earlier connection open behind the new one.
            let previous = inner.connection
            inner.connection = nil
            return (port, inner.generation, previous)
        }
        guard let (port, generation, previous) = next else { return }
        previous?.close()
        let connection = connector.open(port: port, queue: queue) { [weak self] event in
            self?.handle(event, generation: generation)
        }
        let stale = inner.withLock { inner -> Bool in
            guard inner.generation == generation else { return true }
            inner.connection = connection
            return false
        }
        if stale { connection.close() }
    }

    private func handle(_ event: LinkConnectionEvent, generation: UInt64) {
        switch event {
        case .ready:
            let port = inner.withLock { inner -> UInt16? in
                guard inner.generation == generation, case let .connecting(port) = inner.phase else { return nil }
                inner.phase = .awaitingHello(port: port)
                return port
            }
            guard port != nil else { return }
            let timeout = configuration.helloTimeout
            queue.asyncAfter(deadline: .now() + .milliseconds(max(1, timeout.wholeMilliseconds))) { [weak self] in
                guard let self else { return }
                let waiting = self.inner.withLock { inner -> Bool in
                    guard inner.generation == generation, case .awaitingHello = inner.phase else { return false }
                    return true
                }
                if waiting { self.fail(generation, "no hello") }
            }
        case let .received(data):
            var failure: String?
            inner.withLock { inner in
                guard inner.generation == generation, case let .awaitingHello(port) = inner.phase else { return }
                do throws(LinkError) {
                    for frame in try inner.helloDecoder.feed(data) {
                        guard frame.type == FrameType.hello.rawValue else { throw .unknownFrameType(frame.type) }
                        _ = try FrameCodec.decodeHello(frame.payload)
                        inner.phase = .connected(port: port)
                        inner.statistics.connects += 1
                        inner.backoffIndex = 0
                        inner.portIndex = 0
                        break
                    }
                } catch {
                    failure = error.description
                }
            }
            if let failure { fail(generation, failure) }
        case let .failed(reason):
            fail(generation, reason)
        case .closed:
            fail(generation, "closed")
        }
    }

    /// Drops the connection of `generation` and schedules the next attempt.
    private func fail(_ generation: UInt64, _ reason: String) {
        let outcome = inner.withLock { inner -> (connection: (any LinkConnection)?, delay: Duration?, run: UInt64)? in
            guard inner.generation == generation, inner.running else { return nil }
            let run = inner.run
            let wasConnected: Bool
            if case .connected = inner.phase { wasConnected = true } else { wasConnected = false }
            let connection = inner.connection
            inner.connection = nil
            inner.generation += 1
            inner.bytesInFlight = 0
            inner.statistics.failedAttempts += wasConnected ? 0 : 1
            if wasConnected {
                // Lost an established link: start over from the first port after a short pause.
                inner.portIndex = 0
                inner.phase = .backingOff
                return (connection, configuration.backoff[0], run)
            }
            inner.portIndex += 1
            if inner.portIndex < configuration.ports.count {
                return (connection, nil, run)
            }
            inner.portIndex = 0
            let delay = configuration.backoff[min(inner.backoffIndex, configuration.backoff.count - 1)]
            inner.backoffIndex += 1
            inner.phase = .backingOff
            return (connection, delay, run)
        }
        guard let outcome else { return }
        outcome.connection?.close()
        let run = outcome.run
        if let delay = outcome.delay {
            queue.asyncAfter(deadline: .now() + .milliseconds(max(1, delay.wholeMilliseconds))) { [weak self] in
                self?.attempt(run: run)
            }
        } else {
            attempt(run: run)
        }
    }
}

extension Duration {
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// TCP to 127.0.0.1 with Network.framework (the plug-in's connector).
public struct TCPLinkConnector: LinkConnector {
    public init() {}

    public func open(port: UInt16, queue: DispatchQueue, handler: @escaping @Sendable (LinkConnectionEvent) -> Void) -> any LinkConnection {
        Self.makeConnection(port: port, queue: queue, handler: handler)
    }

    // Network.framework calls back on `queue`: keep this nonisolated with @Sendable closures.
    private nonisolated static func makeConnection(
        port: UInt16, queue: DispatchQueue, handler: @escaping @Sendable (LinkConnectionEvent) -> Void
    ) -> any LinkConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            queue.async { handler(.failed("invalid port")) }
            return ClosedConnection()
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
        let wrapper = TCPLinkConnection(connection: connection)
        connection.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready:
                handler(.ready)
                receive(connection, handler: handler)
            case let .waiting(error):
                // Refused: nobody listens there. Do not let NWConnection retry on its own.
                handler(.failed("\(error)"))
                connection.cancel()
            case let .failed(error):
                handler(.failed("\(error)"))
                connection.cancel()
            case .cancelled:
                handler(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
        return wrapper
    }

    private static func receive(_ connection: NWConnection, handler: @escaping @Sendable (LinkConnectionEvent) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { @Sendable data, _, isComplete, error in
            if let data, !data.isEmpty { handler(.received(data)) }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(connection, handler: handler)
        }
    }
}

private struct TCPLinkConnection: LinkConnection {
    let connection: NWConnection

    func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { @Sendable error in completion(error == nil) })
    }

    func close() { connection.cancel() }
}

private struct ClosedConnection: LinkConnection {
    func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) { completion(false) }
    func close() {}
}
