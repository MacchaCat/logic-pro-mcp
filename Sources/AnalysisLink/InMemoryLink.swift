import Foundation
import Synchronization

/// A connector that delivers straight into a `LinkServerCore` without sockets: used by unit
/// tests and by `serve --fake`, so neither ever opens a listening port.
public final class InMemoryLinkConnector: LinkConnector {
    private struct State {
        var listeningPorts: Set<UInt16>
        var sendsHello: Bool
        var connections: [InMemoryConnection] = []
        var opened = 0
    }

    private let core: LinkServerCore
    private let state: Mutex<State>

    /// `listeningPorts`: the ports that "accept"; connecting to any other port fails like a
    /// refused TCP connection. `sendsHello: false` imitates some other program on the port.
    public init(core: LinkServerCore, listeningPorts: Set<UInt16> = [AnalysisLink.defaultPorts[0]], sendsHello: Bool = true) {
        self.core = core
        state = Mutex(State(listeningPorts: listeningPorts, sendsHello: sendsHello))
    }

    public func setListening(_ ports: Set<UInt16>, sendsHello: Bool = true) {
        state.withLock {
            $0.listeningPorts = ports
            $0.sendsHello = sendsHello
        }
    }

    /// Number of connection attempts so far.
    public var attempts: Int { state.withLock { $0.opened } }

    /// Closes every open connection from the server side.
    public func disconnectAll() {
        let connections = state.withLock { state -> [InMemoryConnection] in
            defer { state.connections = [] }
            return state.connections
        }
        for connection in connections { connection.serverClose() }
    }

    public func open(port: UInt16, queue: DispatchQueue, handler: @escaping @Sendable (LinkConnectionEvent) -> Void) -> any LinkConnection {
        let connection = InMemoryConnection(core: core, queue: queue, handler: handler)
        let (accepts, hello) = state.withLock { state -> (Bool, Bool) in
            state.opened += 1
            let accepts = state.listeningPorts.contains(port)
            if accepts { state.connections.append(connection) }
            return (accepts, state.sendsHello)
        }
        let core = self.core
        queue.async {
            guard accepts else {
                handler(.failed("connection refused (in-memory port \(port) not listening)"))
                return
            }
            if hello {
                guard let id = core.open(remote: "in-memory:\(port)", closer: { connection.serverClose() }) else {
                    handler(.failed("server refused the connection"))
                    return
                }
                connection.attach(id)
            }
            handler(.ready)
            if hello { handler(.received(core.helloFrame)) }
        }
        return connection
    }
}

final class InMemoryConnection: LinkConnection {
    private let core: LinkServerCore
    private let queue: DispatchQueue
    private let handler: @Sendable (LinkConnectionEvent) -> Void
    private let id = Mutex<ConnectionID?>(nil)
    private let open = Mutex(true)

    init(core: LinkServerCore, queue: DispatchQueue, handler: @escaping @Sendable (LinkConnectionEvent) -> Void) {
        self.core = core
        self.queue = queue
        self.handler = handler
    }

    func attach(_ connection: ConnectionID) { id.withLock { $0 = connection } }

    func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard open.withLock({ $0 }) else {
                completion(false)
                return
            }
            // Without a server-side connection (a "foreign" listener) the bytes go nowhere.
            guard let connection = id.withLock({ $0 }) else {
                completion(true)
                return
            }
            if core.receive(data, from: connection) {
                completion(true)
            } else {
                open.withLock { $0 = false }
                completion(false)
                handler(.closed)
            }
        }
    }

    func close() {
        queue.async { [self] in
            let wasOpen = open.withLock { open -> Bool in
                defer { open = false }
                return open
            }
            guard wasOpen else { return }
            if let connection = id.withLock({ $0 }) { core.close(connection, reason: "client closed") }
        }
    }

    /// The server side goes away.
    func serverClose() {
        queue.async { [self] in
            let wasOpen = open.withLock { open -> Bool in
                defer { open = false }
                return open
            }
            guard wasOpen else { return }
            if let connection = id.withLock({ $0 }) { core.close(connection, reason: "server closed") }
            handler(.closed)
        }
    }
}
