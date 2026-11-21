/// Something MIDI messages can be sent to: a CoreMIDI virtual source, or an in-memory pipe in tests.
public protocol MIDIOutput: Sendable {
    func send(_ messages: [MIDIMessage]) throws
}

/// In-memory MIDI connection. Whatever is sent comes out of `stream`, in order.
public final class MIDIPipe: MIDIOutput {
    public let stream: AsyncStream<MIDIMessage>
    private let continuation: AsyncStream<MIDIMessage>.Continuation

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: MIDIMessage.self, bufferingPolicy: .unbounded)
    }

    public func send(_ messages: [MIDIMessage]) {
        for message in messages { continuation.yield(message) }
    }

    public func finish() {
        continuation.finish()
    }
}
