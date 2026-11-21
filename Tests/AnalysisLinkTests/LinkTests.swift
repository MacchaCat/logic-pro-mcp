import AudioAnalysis
import Foundation
import Synchronization
import Testing
@testable import AnalysisLink

/// Polls `condition` every 5 ms for up to `timeout`.
func eventually(_ timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await clock.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Collects a core's events in the background.
final class EventLog: Sendable {
    private final class Store: Sendable {
        let events = Mutex<[LinkEvent]>([])
    }

    private let store = Store()

    init(_ core: LinkServerCore) {
        let store = self.store
        Task {
            for await event in core.events { store.events.withLock { $0.append(event) } }
        }
    }

    var all: [LinkEvent] { store.events.withLock { $0 } }
    var frames: [AnalysisFrame] {
        all.compactMap { if case let .frame(_, frame) = $0 { return frame } else { return nil } }
    }
    var rejections: Int { all.filter { if case .rejected = $0 { return true } else { return false } }.count }
    var disconnects: Int { all.filter { if case .disconnected = $0 { return true } else { return false } }.count }
}

private func fastClient(_ connector: any LinkConnector, ports: [UInt16] = AnalysisLink.defaultPorts, maxBytes: Int = 256 * 1024) -> AnalysisLinkClient {
    AnalysisLinkClient(
        configuration: .init(ports: ports, helloTimeout: .milliseconds(50), backoff: [.milliseconds(10), .milliseconds(20)], maxBytesInFlight: maxBytes),
        connector: connector)
}

@Suite("Link server core")
struct LinkServerCoreTests {
    @Test func acceptsValidFramesAndRejectsBadOnes() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let id = try #require(core.open(remote: "test"))
        #expect(core.receive(try FrameCodec.encode(sampleFrame()), from: id))
        // Well-delimited but invalid payload: rejected, connection stays.
        let bad = try FrameCodec.encode(type: .analysis, payload: Data("{}".utf8))
        #expect(core.receive(bad, from: id))
        // Unknown frame type: rejected too.
        #expect(core.receive(try FrameCodec.encode(type: .hello, payload: Data("{}".utf8)), from: id))
        #expect(await eventually { log.frames.count == 1 && log.rejections == 2 })
        #expect(core.statistics.framesAccepted == 1 && core.statistics.framesRejected == 2)
        // Header garbage: the connection must close.
        #expect(!core.receive(Data("\u{0}\u{1}junk".utf8), from: id))
        #expect(await eventually { log.disconnects == 1 })
        #expect(core.statistics.connections == 0)
        #expect(!core.receive(try FrameCodec.encode(sampleFrame()), from: id))
    }

    @Test func connectionLimit() throws {
        var limits = LinkServerCore.Limits()
        limits.maxConnections = 2
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let a = try #require(core.open(remote: "a"))
        #expect(core.open(remote: "b") != nil)
        #expect(core.open(remote: "c") == nil)
        #expect(core.statistics.refusedConnections == 1)
        core.close(a)
        #expect(core.open(remote: "d") != nil)
    }

    @Test func idleConnectionsMakeRoomForANewOneAtTheLimit() async throws {
        var limits = LinkServerCore.Limits()
        limits.maxConnections = 2
        limits.idleTimeout = .milliseconds(100)
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let log = EventLog(core)
        let closed = Mutex<[String]>([])
        let idle = try #require(core.open(remote: "idle") { closed.withLock { $0.append("idle") } })
        let busy = try #require(core.open(remote: "busy") { closed.withLock { $0.append("busy") } })
        // Nobody is idle long enough yet: refused.
        #expect(core.open(remote: "early") == nil)
        try await Task.sleep(for: .milliseconds(150))
        // "busy" sends valid frames; "idle" never does.
        #expect(core.receive(try FrameCodec.encode(sampleFrame()), from: busy))
        let newcomer = try #require(core.open(remote: "plug-in"))
        #expect(closed.withLock { $0 } == ["idle"])
        #expect(!core.isOpen(idle))
        #expect(core.isOpen(busy) && core.isOpen(newcomer))
        #expect(core.statistics.evictedConnections == 1 && core.statistics.refusedConnections == 1)
        #expect(await eventually { log.disconnects == 1 })
        // The evicted connection's late bytes are not accepted.
        #expect(!core.receive(try FrameCodec.encode(sampleFrame()), from: idle))
    }

    @Test func framesAndCloseKeepTheirOrder() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let id = try #require(core.open(remote: "x"))
        var bytes = Data()
        for sequence in 1...5 { bytes += try FrameCodec.encode(sampleFrame(sequence: UInt64(sequence))) }
        #expect(core.receive(bytes, from: id))
        core.close(id)
        #expect(!core.isOpen(id))
        #expect(await eventually { log.all.count == 7 })
        let kinds = log.all.map { event -> String in
            switch event {
            case .connected: "c"
            case .frame: "f"
            case .rejected: "r"
            case .disconnected: "d"
            }
        }
        #expect(kinds == ["c", "f", "f", "f", "f", "f", "d"])
        #expect(log.frames.map(\.sequence) == [1, 2, 3, 4, 5])
    }

    @Test func sweepClosesSilentAndIdleConnections() throws {
        var limits = LinkServerCore.Limits()
        limits.firstFrameTimeout = .seconds(10)
        limits.maxIdle = .seconds(60)
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let closed = Mutex<[String]>([])
        let silent = try #require(core.open(remote: "silent") { closed.withLock { $0.append("silent") } })
        let invalid = try #require(core.open(remote: "invalid") { closed.withLock { $0.append("invalid") } })
        let active = try #require(core.open(remote: "active") { closed.withLock { $0.append("active") } })
        // Rejected payloads are not a sign of life.
        #expect(core.receive(try FrameCodec.encode(type: .analysis, payload: Data("{}".utf8)), from: invalid))
        #expect(core.receive(try FrameCodec.encode(sampleFrame()), from: active))
        let now = ContinuousClock().now
        #expect(core.sweep(now: now) == 0)
        #expect(core.sweep(now: now.advanced(by: .seconds(11))) == 2)
        #expect(closed.withLock { $0 } == ["silent", "invalid"])
        #expect(!core.isOpen(silent) && !core.isOpen(invalid) && core.isOpen(active))
        // A connection that did send valid frames stays until it has been quiet for `maxIdle`.
        #expect(core.sweep(now: now.advanced(by: .seconds(59))) == 0)
        #expect(core.sweep(now: now.advanced(by: .seconds(61))) == 1)
        #expect(!core.isOpen(active))
        #expect(core.statistics.timedOutConnections == 3 && core.statistics.connections == 0)
        #expect(!core.receive(try FrameCodec.encode(sampleFrame()), from: active))
    }

    @Test func rateLimitDropsFramesUndecodedAndClosesAFlood() throws {
        var limits = LinkServerCore.Limits()
        limits.subBlocksPerSecond = 0.001  // no token refills during the test, even on a slow machine
        limits.burstSubBlocks = 20
        limits.maxRateLimitedFrames = 50
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let id = try #require(core.open(remote: "flood"))
        var burst = Data()
        for sequence in 1...20 { burst += try FrameCodec.encode(sampleFrame(sequence: UInt64(sequence))) }
        #expect(core.receive(burst, from: id))
        #expect(core.statistics.framesAccepted == 20 && core.statistics.framesRateLimited == 0)
        // The bucket is empty: further frames are dropped before decoding, so even invalid
        // payloads do not count as rejections.
        let invalid = try FrameCodec.encode(type: .analysis, payload: Data("{}".utf8))
        #expect(core.receive(invalid + invalid, from: id))
        #expect(core.statistics.framesRejected == 0 && core.statistics.framesRateLimited == 2)
        // A frame is charged per sub-block: 64 sub-blocks cost 64 tokens.
        let refilled = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let other = try #require(refilled.open(remote: "big"))
        #expect(refilled.receive(try FrameCodec.encode(sampleFrame(count: 64)), from: other))
        #expect(refilled.receive(try FrameCodec.encode(sampleFrame(sequence: 2, firstIndex: 64)), from: other))
        #expect(refilled.statistics.framesAccepted == 1 && refilled.statistics.framesRateLimited == 1)
        // Keeping on flooding closes the connection.
        var open = true
        for _ in 0..<60 where open { open = core.receive(try FrameCodec.encode(sampleFrame()), from: id) }
        #expect(!open && !core.isOpen(id))
        #expect(core.statistics.rateLimitedConnections == 1)
    }

    @Test func aPaddedFrameCostsTokensByItsSize() throws {
        var limits = LinkServerCore.Limits()
        limits.subBlocksPerSecond = 0.001  // no refills during the test
        limits.maxRateLimitedFrames = 1000
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let id = try #require(core.open(remote: "padded"))
        // A valid one-sub-block frame padded with JSON whitespace to 60 KiB: 30 tokens each.
        var payload = try JSONEncoder().encode(sampleFrame())
        payload += Data(repeating: 0x20, count: 60 * 1024 - payload.count)
        #expect(try FrameCodec.decodeAnalysis(payload).subBlocks.count == 1)
        let frame = try FrameCodec.encode(type: .analysis, payload: payload)
        var burst = Data()
        for _ in 0..<30 { burst += frame }
        #expect(core.receive(burst, from: id))
        // The bucket (640 tokens) admits 21 of them, not all 30 at one token each.
        #expect(core.statistics.framesAccepted == 21, "\(core.statistics)")
        #expect(core.statistics.framesRateLimited == 9)
        // Rejected payloads are charged by size as well.
        let other = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let second = try #require(other.open(remote: "garbage"))
        let junk = try FrameCodec.encode(type: .analysis, payload: Data(repeating: 0x20, count: 60 * 1024))
        var flood = Data()
        for _ in 0..<30 { flood += junk }
        #expect(other.receive(flood, from: second) == false)  // more than 20 rejections in a row
        #expect(other.statistics.framesRejected + other.statistics.framesRateLimited == 30)
        #expect(other.statistics.framesRejected == 21)
    }

    @Test func theSweeperClosesASilentConnectionByItself() async throws {
        var limits = LinkServerCore.Limits()
        limits.firstFrameTimeout = .milliseconds(50)
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let closed = Mutex(false)
        let silent = try #require(core.open(remote: "silent") { closed.withLock { $0 = true } })
        core.startSweeping(every: .milliseconds(20))
        core.startSweeping(every: .milliseconds(20))  // a second call does nothing
        #expect(await eventually(.seconds(2)) { !core.isOpen(silent) })
        // The close callback runs just after the connection is marked closed.
        #expect(await eventually(.seconds(2)) { closed.withLock { $0 } })
        #expect(core.statistics.timedOutConnections == 1)
        core.finish()
    }

    @Test func droppedEventsAreCounted() throws {
        var limits = LinkServerCore.Limits()
        limits.eventBuffer = 8
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        // Nobody consumes yet: the buffer keeps the newest 8 events.
        let id = try #require(core.open(remote: "x"))
        var bytes = Data()
        for sequence in 1...30 { bytes += try FrameCodec.encode(sampleFrame(sequence: UInt64(sequence))) }
        #expect(core.receive(bytes, from: id))
        #expect(core.statistics.eventsDropped == 31 - 8)
    }

    @Test func tooManyInvalidFramesCloseTheConnection() throws {
        var limits = LinkServerCore.Limits()
        limits.maxConsecutiveRejections = 3
        let core = LinkServerCore(hello: ServerHello(version: "test"), limits: limits)
        let id = try #require(core.open(remote: "x"))
        let bad = try FrameCodec.encode(type: .analysis, payload: Data("{}".utf8))
        var open = true
        for _ in 0..<4 { open = core.receive(bad, from: id) }
        #expect(!open)
    }
}

@Suite("Link client (in memory)")
struct LinkClientTests {
    @Test func dropsWhileNotConnectedThenConnectsToTheListeningPort() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let connector = InMemoryLinkConnector(core: core, listeningPorts: [AnalysisLink.defaultPorts[2]])
        let client = fastClient(connector)
        #expect(client.send(sampleFrame()) == .notConnected)
        client.start()
        #expect(await eventually { client.isConnected })
        #expect(client.state == .connected(port: AnalysisLink.defaultPorts[2]))
        #expect(client.send(sampleFrame(sequence: 2)) == .sent)
        #expect(await eventually { log.frames.count == 1 })
        #expect(client.statistics.framesDropped == 1)
        #expect(client.statistics.failedAttempts == 2)  // ports 0 and 1 refused
        client.stop()
        #expect(client.state == .stopped)
    }

    @Test func ignoresAPortWithoutAHelloAndBacksOff() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let connector = InMemoryLinkConnector(core: core, listeningPorts: Set(AnalysisLink.defaultPorts), sendsHello: false)
        let client = fastClient(connector)
        client.start()
        // Every port "accepts" but never greets: the client must not treat any as connected.
        #expect(await eventually(.milliseconds(600)) { connector.attempts >= 6 })
        #expect(!client.isConnected)
        #expect(client.send(sampleFrame()) == .notConnected)
        // Now a real server appears on port 1.
        connector.setListening([AnalysisLink.defaultPorts[1]])
        #expect(await eventually { client.isConnected })
        client.stop()
    }

    @Test func reconnectsAfterTheServerGoesAway() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let connector = InMemoryLinkConnector(core: core)
        let client = fastClient(connector)
        client.start()
        #expect(await eventually { client.isConnected })
        connector.disconnectAll()
        #expect(await eventually { !client.isConnected })
        #expect(await eventually { client.isConnected })
        #expect(client.statistics.connects == 2)
        #expect(client.send(sampleFrame()) == .sent)
        #expect(await eventually { log.frames.count == 1 })
        client.stop()
        connector.disconnectAll()
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.state == .stopped)
    }

    @Test func serverClosingOnBadDataMakesTheClientReconnect() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let connector = InMemoryLinkConnector(core: core)
        let client = fastClient(connector)
        client.start()
        #expect(await eventually { client.isConnected })
        var invalid = sampleFrame()
        invalid.channels = 99  // fails validation on the server, not when encoding
        var limits = 0
        while limits < 25 {  // more than the core's consecutive-rejection limit
            _ = client.send(invalid)
            limits += 1
        }
        #expect(await eventually { client.statistics.connects >= 2 })
        client.stop()
    }

    @Test func stopRightAfterStartWins() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let connector = InMemoryLinkConnector(core: core)
        let client = fastClient(connector)
        client.start()
        client.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.state == .stopped)
        #expect(connector.attempts == 0)
        #expect(core.statistics.connections == 0)
    }

    @Test func restartingQuicklyOpensOneConnection() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let connector = InMemoryLinkConnector(core: core)
        let client = fastClient(connector)
        client.start()
        client.stop()
        client.start()
        #expect(await eventually { client.isConnected })
        try await Task.sleep(for: .milliseconds(100))
        #expect(connector.attempts == 1)
        #expect(core.statistics.connections == 1)
        client.stop()
        #expect(await eventually { core.statistics.connections == 0 })
    }

    @Test func backpressureDropsInsteadOfQueueing() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let client = fastClient(InMemoryLinkConnector(core: core), maxBytes: 100)
        client.start()
        #expect(await eventually { client.isConnected })
        #expect(client.send(sampleFrame()) == .backpressure)
        client.stop()
    }
}

/// A backend whose ports are busy on request, for the port-selection logic. `fail(port:)`
/// makes a running listener fail later; cancelling a handle reports "cancelled" like
/// Network.framework's `.cancelled` state.
private final class FakeBackend: ListenerBackend {
    let busy: Set<UInt16>
    private let lostHandlers = Mutex<[UInt16: @Sendable (String) -> Void]>([:])

    init(busy: Set<UInt16>) { self.busy = busy }

    struct Handle: ListenerHandle {
        let onCancel: @Sendable () -> Void
        func cancel() { onCancel() }
    }

    func listen(port: UInt16, core: LinkServerCore, lost: @escaping @Sendable (String) -> Void) async
        -> Result<any ListenerHandle, ListenFailure> {
        guard !busy.contains(port) else { return .failure(ListenFailure("address in use")) }
        lostHandlers.withLock { $0[port] = lost }
        return .success(Handle { lost("cancelled") })
    }

    func fail(port: UInt16, _ reason: String) {
        lostHandlers.withLock { $0[port] }?(reason)
    }
}

@Suite("Listener port selection")
struct ListenerTests {
    @Test func firstFreePortWins() async {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let listener = AnalysisListener(core: core, ports: [1, 2, 3, 4], backend: FakeBackend(busy: [1, 2]))
        let status = await listener.start()
        #expect(status.state == .listening)
        #expect(status.port == 3)
        #expect(status.host == "127.0.0.1")
        #expect(listener.status == status)
        listener.stop()
        #expect(listener.status.state == .notStarted)
    }

    @Test func allPortsBusyIsAStatusNotAnError() async {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let listener = AnalysisListener(core: core, ports: [1, 2, 3, 4], backend: FakeBackend(busy: [1, 2, 3, 4]))
        let status = await listener.start()
        #expect(status.state == .failed)
        #expect(status.detail?.contains("address in use") == true)
    }

    @Test func aFailureAfterStartingShowsInTheStatus() async {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let backend = FakeBackend(busy: [1])
        let listener = AnalysisListener(core: core, ports: [1, 2], backend: backend)
        #expect(await listener.start().port == 2)
        backend.fail(port: 1, "stale")  // a port that never started: ignored
        #expect(listener.status.state == .listening)
        backend.fail(port: 2, "network down")
        #expect(listener.status.state == .failed)
        #expect(listener.status.detail?.contains("network down") == true)
        // It can be started again after a failure.
        #expect(await listener.start().state == .listening)
    }

    @Test func stoppingIsNotAFailure() async {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let backend = FakeBackend(busy: [])
        let listener = AnalysisListener(core: core, ports: [1], backend: backend)
        #expect(await listener.start().state == .listening)
        listener.stop()  // the handle reports "cancelled" while stopping
        #expect(listener.status.state == .notStarted)
        backend.fail(port: 1, "late callback of the stopped listener")
        #expect(listener.status.state == .notStarted)
    }
}

/// The only test that opens a real socket. Off by default: a listening socket may make macOS
/// show a firewall prompt. Run with LOGIC_MCP_LOOPBACK_TESTS=1.
@Suite("Loopback TCP")
struct LoopbackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOGIC_MCP_LOOPBACK_TESTS"] == "1"))
    func realListenerAndClient() async throws {
        let core = LinkServerCore(hello: ServerHello(version: "test"))
        let log = EventLog(core)
        let listener = AnalysisListener(core: core)
        let status = await listener.start()
        try #require(status.state == .listening)
        let port = try #require(status.port)
        defer { listener.stop() }
        let client = AnalysisLinkClient()
        client.start()
        defer { client.stop() }
        #expect(await eventually(.seconds(5)) { client.isConnected })
        #expect(client.state == .connected(port: port))
        #expect(client.send(sampleFrame()) == .sent)
        #expect(await eventually(.seconds(5)) { log.frames.count == 1 })
    }
}
