/// A message from Logic with the times it came with: when the server received it, and the
/// CoreMIDI packet timestamp the sender put on it (if any).
public struct TimedMIDIMessage: Sendable, Equatable {
    public var message: MIDIMessage
    /// When the message reached the server (for real ports: taken in the CoreMIDI receive
    /// callback, before any decoding or task hop).
    public var receivedAt: ContinuousClock.Instant
    /// The packet's timestamp converted to `ContinuousClock`; nil when the sender left it 0
    /// ("now") or it was implausible. A sender that schedules ahead stamps future times, and
    /// CoreMIDI hands such packets to a virtual destination early.
    public var timestamp: ContinuousClock.Instant?

    public init(message: MIDIMessage, receivedAt: ContinuousClock.Instant, timestamp: ContinuousClock.Instant? = nil) {
        self.message = message
        self.receivedAt = receivedAt
        self.timestamp = timestamp
    }

    /// The time the message stands for: its timestamp, or the receipt time without one.
    public var time: ContinuousClock.Instant { timestamp ?? receivedAt }

    /// Timestamp minus receipt (positive: sent ahead of time); nil without a timestamp.
    public var lead: Duration? { timestamp.map { receivedAt.duration(to: $0) } }
}

/// An output that can stamp what it sends with a time (as CoreMIDI packet timestamps do).
public protocol TimestampedMIDIOutput: MIDIOutput {
    func send(_ messages: [MIDIMessage], timestamp: ContinuousClock.Instant?) throws
}

/// In-memory connection that delivers `TimedMIDIMessage`s: the receipt time is taken when a
/// message is sent (as the CoreMIDI callback takes it on arrival), plus an optional timestamp.
public final class TimedMIDIPipe: TimestampedMIDIOutput {
    public let stream: AsyncStream<TimedMIDIMessage>
    private let continuation: AsyncStream<TimedMIDIMessage>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: TimedMIDIMessage.self, bufferingPolicy: .unbounded)
    }

    public func send(_ messages: [MIDIMessage]) {
        send(messages, timestamp: nil)
    }

    public func send(_ messages: [MIDIMessage], timestamp: ContinuousClock.Instant?) {
        let now = ContinuousClock.now
        for message in messages {
            continuation.yield(TimedMIDIMessage(message: message, receivedAt: now, timestamp: timestamp))
        }
    }

    public func finish() {
        continuation.finish()
    }
}

/// CoreMIDI timestamps are host time (`mach_absolute_time` ticks), which neither shares an epoch
/// with `ContinuousClock` nor (on Apple silicon) its units. They are converted by difference:
/// the receive callback reads host time and `ContinuousClock.now` together, and a timestamp
/// becomes that instant plus the tick difference scaled by the timebase.
public enum HostTime {
    /// Timestamps further than this from the receipt time are treated as missing.
    public static let plausibleOffset: Duration = .seconds(1)

    /// The instant of packet timestamp `timestamp`, received at host time `receivedHost` =
    /// instant `receivedAt`, with the timebase `numer / denom` (nanoseconds per tick); nil for
    /// 0 ("now") or a timestamp more than `plausibleOffset` away.
    public static func instant(timestamp: UInt64, receivedHost: UInt64, receivedAt: ContinuousClock.Instant,
                               numer: UInt32, denom: UInt32) -> ContinuousClock.Instant? {
        guard timestamp != 0, denom > 0 else { return nil }
        let difference = timestamp >= receivedHost
            ? Double(timestamp - receivedHost) : -Double(receivedHost - timestamp)
        let nanoseconds = difference * Double(numer) / Double(denom)
        guard nanoseconds.isFinite, abs(nanoseconds) <= Double(plausibleOffset.components.seconds) * 1e9 else { return nil }
        return receivedAt.advanced(by: .nanoseconds(Int64(nanoseconds.rounded())))
    }
}
