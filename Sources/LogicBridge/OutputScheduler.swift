import MIDICore

/// Minimum gaps between messages sent to Logic (design §4.2). Tuned after real-Logic tests.
public struct RateLimits: Sendable {
    public var shortMessageGap: Duration = .milliseconds(2)
    public var sysExGap: Duration = .milliseconds(10)
    /// Time a button is held between press and release.
    public var buttonHold: Duration = .milliseconds(30)
    /// Gap between controller-assignment (key command) triggers.
    public var keyCommandGap: Duration = .milliseconds(150)

    public init() {}

    /// No delays at all: for in-memory tests.
    public static let none: RateLimits = {
        var limits = RateLimits()
        limits.shortMessageGap = .zero
        limits.sysExGap = .zero
        limits.buttonHold = .zero
        limits.keyCommandGap = .zero
        return limits
    }()
}

/// Serialises everything sent to one output and enforces minimum gaps between messages.
public actor OutputScheduler {
    private let output: any MIDIOutput
    private let clock = ContinuousClock()
    private var lastSend: ContinuousClock.Instant?
    public private(set) var sentCount = 0
    public private(set) var lastError: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(output: any MIDIOutput) {
        self.output = output
    }

    /// Sends messages one by one, waiting `gap(message)` after the previous send. Calls run one
    /// after another in arrival order: the actor is reentrant at the sleep, so without this two
    /// callers could both pass the gap check and send back to back, or interleave their messages.
    public func send(_ messages: [MIDIMessage], limits: RateLimits) async {
        await acquire()
        defer { release() }
        for message in messages {
            let gap: Duration
            if case .sysEx = message { gap = limits.sysExGap } else { gap = limits.shortMessageGap }
            if let lastSend, gap > .zero {
                let due = lastSend.advanced(by: gap)
                if due > clock.now { try? await clock.sleep(until: due) }
            }
            do {
                try output.send([message])
                sentCount += 1
            } catch {
                lastError = "\(error)"
            }
            lastSend = clock.now
        }
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
