import Foundation
import Synchronization

public struct ConnectionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "#\(rawValue)" }
}

/// What the server side of the link reports to its consumer.
public enum LinkEvent: Sendable {
    case connected(ConnectionID, remote: String)
    case frame(ConnectionID, AnalysisFrame)
    /// A well-delimited frame whose payload was rejected (the connection stays open).
    case rejected(ConnectionID, reason: String)
    case disconnected(ConnectionID, reason: String?)
}

/// Transport-independent server side: one stream decoder per connection, payload validation and
/// limits. The TCP listener and the in-memory link both feed it; the consumer reads `events`.
///
/// `events` is one ordered stream that keeps the newest `Limits.eventBuffer` events when the
/// consumer stalls, so a `.disconnected` event can be lost (`Statistics.eventsDropped` counts
/// them). The core itself is the authority on which connections are open: consumers should check
/// `isOpen(_:)` rather than rely on seeing every `.disconnected` (and ignore frames of
/// connections that are no longer open).
///
/// Security model: any local process can connect to the loopback port; there is no
/// authentication. A shared secret is not used yet because the plug-in is a sandboxed AUv3
/// extension, which cannot read a token the server writes into its own directory (`var/`); a
/// pairing step that works within the sandbox is left for the plug-in phase. What the core
/// does bound is what one connection can cost: frames are size-checked and validated, a
/// connection that sends no valid frame soon after connecting or goes idle is closed by
/// `sweep(now:)`, each connection has a token-bucket rate limit (charged per sub-block and per
/// 2 KiB of payload) that is checked before any JSON is decoded, and the number of connections
/// is capped.
///
/// The idle close relies on the plug-in sending at least one valid frame a minute, also while
/// Logic is stopped: audio frames while the host renders, else heartbeats
/// (`FrameBuilder.heartbeat`).
public final class LinkServerCore: Sendable {
    public struct Limits: Sendable {
        public var maxConnections = 16
        /// After this many rejected payloads in a row the connection is closed.
        public var maxConsecutiveRejections = 20
        /// Events buffered for a slow consumer before the oldest are dropped.
        public var eventBuffer = 4096
        /// At the connection limit, a connection that has sent no valid frame for this long is
        /// closed to make room (a live plug-in sends one about every 100 ms).
        public var idleTimeout: Duration = .seconds(10)
        /// `sweep(now:)` closes a connection that has sent no valid frame this long after it opened.
        public var firstFrameTimeout: Duration = .seconds(10)
        /// `sweep(now:)` closes a connection whose last valid frame is this old (a running plug-in
        /// sends audio frames about ten times a second while the host renders it and a heartbeat
        /// about once a second when it does not; it reconnects when closed).
        public var maxIdle: Duration = .seconds(60)
        /// Sustained rate a connection may send, in tokens per second. A frame costs its sub-block
        /// count or one token per `bytesPerToken` of payload, whichever is more, at least 1. A
        /// plug-in sends about 10 frames of about 1 KiB per second.
        public var subBlocksPerSecond = 100.0
        /// Payload bytes one token pays for: decoding is charged by size too, so a frame padded
        /// to 64 KiB costs 32 tokens, not 1.
        public var bytesPerToken = 2048
        /// Bucket size: a burst after a stall (the client keeps at most 256 KiB in flight, about
        /// 150 frames) passes.
        public var burstSubBlocks = 640.0
        /// A connection whose frames were dropped by the rate limit this many times is closed.
        public var maxRateLimitedFrames = 1000
        public init() {}
    }

    private struct Connection {
        var decoder = FrameStreamDecoder()
        var rejections = 0
        var openedAt: ContinuousClock.Instant
        var lastActivity: ContinuousClock.Instant
        var sentValidFrame = false
        var tokens: Double
        var refilledAt: ContinuousClock.Instant
        var rateLimited = 0
        /// Closes the transport's side; called when the core closes a connection itself.
        var closer: (@Sendable () -> Void)?

        mutating func refill(_ now: ContinuousClock.Instant, _ limits: Limits) {
            let seconds = max(0, refilledAt.duration(to: now).inSeconds)
            tokens = min(limits.burstSubBlocks, tokens + seconds * limits.subBlocksPerSecond)
            refilledAt = now
        }
    }

    private struct State {
        var nextID: UInt64 = 1
        var connections: [ConnectionID: Connection] = [:]
        var refused = 0
        var evicted = 0
        var timedOut = 0
        var rateLimitClosed = 0
        var framesAccepted = 0
        var framesRejected = 0
        var framesRateLimited = 0
        var sweeper: Task<Void, Never>?
    }

    public struct Statistics: Sendable, Codable, Equatable {
        public var connections: Int
        public var refusedConnections: Int
        public var evictedConnections: Int
        /// Closed by `sweep(now:)`: no valid frame after connecting, or idle too long.
        public var timedOutConnections: Int
        /// Closed for exceeding the rate limit too often.
        public var rateLimitedConnections: Int
        public var framesAccepted: Int
        public var framesRejected: Int
        /// Frames dropped undecoded by the per-connection rate limit.
        public var framesRateLimited: Int
        /// Events the consumer never saw because the event buffer was full.
        public var eventsDropped: Int

        enum CodingKeys: String, CodingKey {
            case connections
            case refusedConnections = "refused_connections"
            case evictedConnections = "evicted_connections"
            case timedOutConnections = "timed_out_connections"
            case rateLimitedConnections = "rate_limited_connections"
            case framesAccepted = "frames_accepted"
            case framesRejected = "frames_rejected"
            case framesRateLimited = "frames_rate_limited"
            case eventsDropped = "events_dropped"
        }
    }

    public let limits: Limits
    public let events: AsyncStream<LinkEvent>
    /// Sent to every client right after it connects.
    public let helloFrame: Data
    private let continuation: AsyncStream<LinkEvent>.Continuation
    private let state = Mutex(State())
    private let dropped = Atomic<Int>(0)
    private let clock = ContinuousClock()

    public init(hello: ServerHello, limits: Limits = Limits()) {
        self.limits = limits
        helloFrame = FrameCodec.encode(hello)
        (events, continuation) = AsyncStream.makeStream(of: LinkEvent.self, bufferingPolicy: .bufferingNewest(limits.eventBuffer))
    }

    private func emit(_ event: LinkEvent) {
        if case .dropped = continuation.yield(event) {
            dropped.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Registers a new connection; nil when the connection limit is reached (close it). At the
    /// limit, the connection idle longest (no valid frame for `Limits.idleTimeout`) is closed
    /// through its `closer` to make room, so idle sockets cannot lock the plug-in out.
    public func open(remote: String, closer: (@Sendable () -> Void)? = nil) -> ConnectionID? {
        let now = clock.now
        let (id, evicted) = state.withLock { state -> (ConnectionID?, (ConnectionID, Connection)?) in
            var evicted: (ConnectionID, Connection)?
            if state.connections.count >= limits.maxConnections {
                let idle = state.connections
                    .filter { $0.value.lastActivity.duration(to: now) >= limits.idleTimeout }
                    .min { $0.value.lastActivity < $1.value.lastActivity }
                guard let idle else {
                    state.refused += 1
                    return (nil, nil)
                }
                state.connections[idle.key] = nil
                state.evicted += 1
                evicted = (idle.key, idle.value)
            }
            let id = ConnectionID(state.nextID)
            state.nextID += 1
            state.connections[id] = Connection(openedAt: now, lastActivity: now, tokens: limits.burstSubBlocks,
                                               refilledAt: now, closer: closer)
            return (id, evicted)
        }
        if let (old, connection) = evicted {
            emit(.disconnected(old, reason: "idle: no valid frame for \(limits.idleTimeout)"))
            connection.closer?()
        }
        if let id { emit(.connected(id, remote: String(remote.prefix(128)))) }
        return id
    }

    /// Whether `id` is still registered (not closed by either side).
    public func isOpen(_ id: ConnectionID) -> Bool {
        state.withLock { $0.connections[id] != nil }
    }

    /// Feeds received bytes. Returns false when the connection must be closed (it is then already
    /// unregistered and a `.disconnected` event has been sent).
    ///
    /// Only the framing and the rate limit run under the shared lock; payloads are decoded and
    /// validated outside it, so one connection's JSON does not hold up the others. The transports
    /// deliver one connection's bytes in order, one call at a time.
    public func receive(_ data: Data, from id: ConnectionID) -> Bool {
        let now = clock.now
        // 1. Framing (cheap) and the rate limit under the lock: a frame only gets decoded when
        //    the connection has the tokens its size costs (reserved here; the full cost, at
        //    least one per sub-block, is charged in step 3).
        let framed: (raw: [RawFrame], limited: Int, fatal: LinkError?)? = state.withLock { state in
            guard var connection = state.connections[id] else { return nil }
            var raw: [RawFrame] = []
            var fatal: LinkError?
            do throws(LinkError) {
                raw = try connection.decoder.feed(data)
            } catch {
                fatal = error
            }
            if fatal == nil, let failure = connection.decoder.failure { fatal = failure }
            connection.refill(now, limits)
            var admitted: [RawFrame] = []
            var limited = 0
            var reserved = 0.0
            for frame in raw {
                let cost = sizeCost(frame.payload.count)
                if connection.tokens - reserved >= cost {
                    admitted.append(frame)
                    reserved += cost
                } else {
                    limited += 1
                }
            }
            connection.rateLimited += limited
            state.framesRateLimited += limited
            if fatal != nil {
                state.connections[id] = nil
            } else {
                state.connections[id] = connection
            }
            return (admitted, limited, fatal)
        }
        guard let framed else { return false }

        // 2. Decoding and validation without the lock.
        var out: [LinkEvent] = []
        var accepted = 0
        var outcomes: [(ok: Bool, cost: Double)] = []
        for frame in framed.raw {
            let size = sizeCost(frame.payload.count)
            do throws(LinkError) {
                guard frame.type == FrameType.analysis.rawValue else { throw .unknownFrameType(frame.type) }
                let decoded = try FrameCodec.decodeAnalysis(frame.payload)
                out.append(.frame(id, decoded))
                accepted += 1
                outcomes.append((true, max(size, Double(decoded.subBlocks.count))))
            } catch {
                out.append(.rejected(id, reason: error.description))
                outcomes.append((false, size))
            }
        }

        // 3. Counters, token charges and the limits under the lock again.
        let keep: Bool = state.withLock { state in
            state.framesAccepted += accepted
            state.framesRejected += outcomes.count - accepted
            if let fatal = framed.fatal {
                out.append(.disconnected(id, reason: fatal.description))
                return false
            }
            guard var connection = state.connections[id] else { return false }
            for outcome in outcomes {
                connection.tokens -= outcome.cost
                if outcome.ok {
                    connection.rejections = 0
                    connection.lastActivity = now
                    connection.sentValidFrame = true
                } else {
                    connection.rejections += 1
                }
            }
            if connection.rejections > limits.maxConsecutiveRejections {
                state.connections[id] = nil
                out.append(.disconnected(id, reason: "too many invalid frames"))
                return false
            }
            if connection.rateLimited >= limits.maxRateLimitedFrames {
                state.connections[id] = nil
                state.rateLimitClosed += 1
                out.append(.disconnected(id, reason: "sending faster than the rate limit"))
                return false
            }
            state.connections[id] = connection
            return true
        }
        for event in out { emit(event) }
        return keep
    }

    /// Tokens a payload of `bytes` costs by its size alone (at least 1).
    private func sizeCost(_ bytes: Int) -> Double {
        let perToken = max(1, limits.bytesPerToken)
        return Double(max(1, (bytes + perToken - 1) / perToken))
    }

    /// Closes connections that sent no valid frame within `Limits.firstFrameTimeout` of opening,
    /// or none for `Limits.maxIdle`. Returns how many were closed. Takes the time as a parameter
    /// so tests can drive it; `startSweeping(every:)` calls it periodically.
    @discardableResult
    public func sweep(now: ContinuousClock.Instant) -> Int {
        let expired = state.withLock { state -> [(ConnectionID, Connection, String)] in
            var expired: [(ConnectionID, Connection, String)] = []
            for (id, connection) in state.connections {
                if !connection.sentValidFrame, connection.openedAt.duration(to: now) >= limits.firstFrameTimeout {
                    expired.append((id, connection, "no valid frame within \(limits.firstFrameTimeout) of connecting"))
                } else if connection.sentValidFrame, connection.lastActivity.duration(to: now) >= limits.maxIdle {
                    expired.append((id, connection, "idle: no valid frame for \(limits.maxIdle)"))
                }
            }
            for (id, _, _) in expired { state.connections[id] = nil }
            state.timedOut += expired.count
            return expired.sorted { $0.0.rawValue < $1.0.rawValue }
        }
        for (id, connection, reason) in expired {
            emit(.disconnected(id, reason: reason))
            connection.closer?()
        }
        return expired.count
    }

    /// Runs `sweep(now:)` every `interval` until `finish()` (once; later calls do nothing).
    public func startSweeping(every interval: Duration = .seconds(1)) {
        state.withLock { state in
            guard state.sweeper == nil else { return }
            state.sweeper = Task { [weak self] in
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    try? await clock.sleep(for: interval)
                    guard let self else { return }
                    self.sweep(now: clock.now)
                }
            }
        }
    }

    /// The transport closed the connection (no-op if it is already gone).
    public func close(_ id: ConnectionID, reason: String? = nil) {
        let removed = state.withLock { $0.connections.removeValue(forKey: id) != nil }
        if removed { emit(.disconnected(id, reason: reason)) }
    }

    public var statistics: Statistics {
        let eventsDropped = dropped.load(ordering: .relaxed)
        return state.withLock {
            Statistics(connections: $0.connections.count, refusedConnections: $0.refused, evictedConnections: $0.evicted,
                       timedOutConnections: $0.timedOut, rateLimitedConnections: $0.rateLimitClosed,
                       framesAccepted: $0.framesAccepted, framesRejected: $0.framesRejected,
                       framesRateLimited: $0.framesRateLimited, eventsDropped: eventsDropped)
        }
    }

    /// Ends the event stream and the sweeper.
    public func finish() {
        let sweeper = state.withLock { state -> Task<Void, Never>? in
            defer { state.sweeper = nil }
            return state.sweeper
        }
        sweeper?.cancel()
        continuation.finish()
    }
}

