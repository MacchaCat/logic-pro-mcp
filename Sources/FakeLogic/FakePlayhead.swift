import MackieControl

/// Moves a `FakeLogicHost`'s playhead while it plays, so the fake's time display advances like
/// Logic's does (FakeLogicHost on its own keeps the position still while playing).
///
/// Musical model of the fake: 4/4, quarter-note beats counted from the start of bar 1 (beat 0 =
/// 1.1.1.1), sixteenth-note divisions and 240 ticks per division (Logic's default display).
/// `rate` speeds the musical clock up relative to wall time, for quick tests.
public actor FakePlayhead {
    public struct State: Sendable, Equatable {
        public var playing: Bool
        /// Quarter-note beats from the start of bar 1.
        public var beats: Double
        public var tempoBPM: Double
    }

    public let host: FakeLogicHost
    public let tempoBPM: Double
    public let rate: Double
    private let interval: Duration
    private var beats: Double = 0
    private var playing = false
    private var task: Task<Void, Never>?
    /// Cycle region (bars, inclusive) the playhead loops in, without any Cycle LED: the fake
    /// surface never reports Cycle, like the unverified Logic 13 case.
    private var cycle: ClosedRange<Int>?

    public init(host: FakeLogicHost, tempoBPM: Double = 120, rate: Double = 1, interval: Duration = .milliseconds(5)) {
        self.host = host
        self.tempoBPM = tempoBPM
        self.rate = rate
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Loops playback in `bars` once it reaches their end (nil: no cycle).
    public func setCycle(_ bars: ClosedRange<Int>?) {
        cycle = bars
    }

    /// The playhead as the fake plug-in sees it.
    public func state() async -> State {
        if !playing { beats = Self.beats(of: await host.position) }
        return State(playing: playing, beats: beats, tempoBPM: tempoBPM)
    }

    private func run() async {
        let clock = ContinuousClock()
        var last = clock.now
        while !Task.isCancelled {
            try? await clock.sleep(for: interval)
            let now = clock.now
            let elapsed = last.duration(to: now)
            last = now
            let hostPlaying = await host.playing
            if hostPlaying {
                if !playing {
                    playing = true
                    beats = Self.beats(of: await host.position)
                } else {
                    let (seconds, attoseconds) = elapsed.components
                    let previous = beats
                    beats += (Double(seconds) + Double(attoseconds) / 1e18) * tempoBPM / 60 * rate
                    if let cycle {
                        let end = Double(cycle.upperBound) * 4
                        if previous < end, beats >= end { beats -= Double(cycle.count) * 4 }
                    }
                    let position = Self.position(beats)
                    if position != (await host.position) { await host.setPosition(position) }
                }
            } else {
                playing = false
                beats = Self.beats(of: await host.position)
            }
        }
    }

    public static func beats(of position: BeatsPosition) -> Double {
        Double(position.bar - 1) * 4 + Double(position.beat - 1) + Double(position.division - 1) / 4
            + Double(position.tick - 1) / 960
    }

    public static func position(_ beats: Double) -> BeatsPosition {
        let ticks = Int((max(beats, 0) * 960).rounded(.down))
        let bar = ticks / 3840 + 1
        let beat = ticks % 3840 / 960 + 1
        let division = ticks % 960 / 240 + 1
        let tick = ticks % 240 + 1
        return BeatsPosition(bar: bar, beat: beat, division: division, tick: tick)
    }
}
