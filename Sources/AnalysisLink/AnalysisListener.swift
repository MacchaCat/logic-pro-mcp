import Foundation
import Network
import Synchronization

/// The listener's state, for status reports.
public struct ListenerStatus: Sendable, Codable, Equatable {
    public enum State: String, Sendable, Codable {
        case notStarted = "not_started"
        case starting
        case listening
        case failed
        case disabled
    }

    public var state: State
    public var host: String?
    public var port: UInt16?
    public var detail: String?

    public init(state: State, host: String? = nil, port: UInt16? = nil, detail: String? = nil) {
        self.state = state
        self.host = host
        self.port = port
        self.detail = detail
    }

    public static let notStarted = ListenerStatus(state: .notStarted)
}

/// A started listener that can be stopped.
public protocol ListenerHandle: Sendable {
    func cancel()
}

/// Binds one port. The real backend uses Network.framework; tests use a fake one.
public protocol ListenerBackend: Sendable {
    /// Starts listening on 127.0.0.1:`port`, handing accepted connections to `core`. Returns a
    /// handle once listening, or why the port could not be used (busy, refused, timed out).
    /// After a successful start, `lost` is called (at most once) if the listener later fails or
    /// is cancelled, including by `ListenerHandle.cancel()`.
    func listen(port: UInt16, core: LinkServerCore, lost: @escaping @Sendable (String) -> Void) async
        -> Result<any ListenerHandle, ListenFailure>
}

public struct ListenFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Listens on the first free port of a small fixed range, on 127.0.0.1 only.
public final class AnalysisListener: Sendable {
    private struct State {
        var status = ListenerStatus.notStarted
        var handle: (any ListenerHandle)?
        /// Bumped by every start and stop, so a late `lost` call of an earlier listener is ignored.
        var generation: UInt64 = 0
    }

    public let ports: [UInt16]
    private let core: LinkServerCore
    private let backend: any ListenerBackend
    private let state = Mutex(State())

    public init(core: LinkServerCore, ports: [UInt16] = AnalysisLink.defaultPorts, backend: any ListenerBackend = NetworkListenerBackend()) {
        self.core = core
        self.ports = ports
        self.backend = backend
    }

    /// The current state, including a failure after the listener was running.
    public var status: ListenerStatus { state.withLock { $0.status } }

    /// Tries the ports in order; the first that starts listening wins. Never throws: when every
    /// port is busy the status says so and the server carries on without the link.
    @discardableResult
    public func start() async -> ListenerStatus {
        let generation = state.withLock { current -> UInt64? in
            guard current.status.state == .notStarted || current.status.state == .failed else { return nil }
            current.status = ListenerStatus(state: .starting)
            current.generation += 1
            return current.generation
        }
        guard let generation else { return status }
        var failures: [String] = []
        for port in ports {
            let result = await backend.listen(port: port, core: core) { [weak self] reason in
                self?.lost(port: port, generation: generation, reason: reason)
            }
            switch result {
            case let .success(handle):
                let status = ListenerStatus(state: .listening, host: "127.0.0.1", port: port)
                let current = state.withLock { current -> Bool in
                    guard current.generation == generation else { return false }
                    current.status = status
                    current.handle = handle
                    return true
                }
                if !current { handle.cancel() }  // stopped while starting
                return current ? status : self.status
            case let .failure(failure):
                failures.append("\(port): \(failure)")
            }
        }
        let status = ListenerStatus(state: .failed, host: "127.0.0.1",
                                    detail: "No port available (\(failures.joined(separator: "; "))). The analysis plug-in cannot connect.")
        state.withLock { current in
            guard current.generation == generation else { return }
            current.status = status
            current.handle = nil
        }
        return status
    }

    public func stop() {
        let handle = state.withLock { current -> (any ListenerHandle)? in
            let handle = current.handle
            current.status = ListenerStatus(state: .notStarted)
            current.handle = nil
            current.generation += 1
            return handle
        }
        handle?.cancel()
    }

    /// The running listener on `port` failed or was cancelled by the system.
    private func lost(port: UInt16, generation: UInt64, reason: String) {
        state.withLock { current in
            guard current.generation == generation, current.status.state == .listening, current.status.port == port else { return }
            current.status = ListenerStatus(
                state: .failed, host: "127.0.0.1", port: port,
                detail: "The listener on 127.0.0.1:\(port) stopped (\(reason)). The analysis plug-in cannot connect until the server restarts.")
            current.handle = nil
        }
    }
}

/// Resumes a continuation at most once.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = Mutex(continuation) }
    /// True when this call resumed the continuation (false when it was already resumed).
    @discardableResult
    func resume(_ value: T) -> Bool {
        continuation.withLock { continuation in
            guard let pending = continuation.take() else { return false }
            pending.resume(returning: value)
            return true
        }
    }
}

/// Network.framework backend: an NWListener whose required local endpoint is 127.0.0.1:port, so it
/// never accepts connections from other machines.
public struct NetworkListenerBackend: ListenerBackend {
    public var startTimeout: Duration

    public init(startTimeout: Duration = .seconds(2)) {
        self.startTimeout = startTimeout
    }

    public func listen(port: UInt16, core: LinkServerCore, lost: @escaping @Sendable (String) -> Void) async
        -> Result<any ListenerHandle, ListenFailure> {
        await Self.start(port: port, core: core, timeout: startTimeout, lost: lost)
    }

    // Callbacks run on Network.framework's queues: everything here stays nonisolated and every
    // closure is @Sendable.
    private nonisolated static func start(
        port: UInt16, core: LinkServerCore, timeout: Duration, lost: @escaping @Sendable (String) -> Void
    ) async -> Result<any ListenerHandle, ListenFailure> {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .failure(ListenFailure("invalid port")) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return .failure(ListenFailure("\(error)"))
        }
        let queue = DispatchQueue(label: "logic-mcp.analysis.listener.\(port)")
        listener.newConnectionHandler = { @Sendable connection in
            NetworkConnectionDriver.accept(connection, core: core, queue: queue)
        }
        let handle = NetworkListenerHandle(listener: listener)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<any ListenerHandle, ListenFailure>, Never>) in
            let once = Once(continuation)
            // After `.ready` the start has been reported; later failures go to `lost` (once).
            let lostOnce = Mutex(Optional(lost))
            let reportLost: @Sendable (String) -> Void = { reason in
                lostOnce.withLock { $0.take() }?(reason)
            }
            listener.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    once.resume(.success(handle))
                case let .failed(error):
                    if !once.resume(.failure(ListenFailure("\(error)"))) { reportLost("\(error)") }
                    listener.cancel()
                case let .waiting(error):
                    // A busy port shows up as failed or waiting depending on the OS; neither is usable.
                    if !once.resume(.failure(ListenFailure("\(error)"))) { reportLost("\(error)") }
                    listener.cancel()
                case .cancelled:
                    if !once.resume(.failure(ListenFailure("cancelled"))) { reportLost("cancelled") }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            let milliseconds = max(1, timeout.wholeMilliseconds)
            queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                // If the timeout is what ends the start, the listener must not come up later and
                // keep a port bound behind the caller's back.
                if once.resume(.failure(ListenFailure("did not start within \(milliseconds) ms"))) {
                    listener.cancel()
                }
            }
        }
    }
}

private struct NetworkListenerHandle: ListenerHandle {
    let listener: NWListener
    func cancel() { listener.cancel() }
}

/// Drives one accepted connection: hello out, bytes in, into the core.
private enum NetworkConnectionDriver {
    static func accept(_ connection: NWConnection, core: LinkServerCore, queue: DispatchQueue) {
        guard let id = core.open(remote: "\(connection.endpoint)", closer: { @Sendable in connection.cancel() }) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready:
                connection.send(content: core.helloFrame, completion: .contentProcessed { @Sendable _ in })
                receive(connection, id: id, core: core)
            case let .failed(error):
                core.close(id, reason: "\(error)")
                connection.cancel()
            case .cancelled:
                core.close(id, reason: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    static func receive(_ connection: NWConnection, id: ConnectionID, core: LinkServerCore) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: AnalysisLink.maxPayload) { @Sendable data, _, isComplete, error in
            if let data, !data.isEmpty, !core.receive(data, from: id) {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                core.close(id, reason: error.map { "\($0)" })
                connection.cancel()
                return
            }
            receive(connection, id: id, core: core)
        }
    }
}
