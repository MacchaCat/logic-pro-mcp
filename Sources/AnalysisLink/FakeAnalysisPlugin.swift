import AudioAnalysis
import Foundation

/// What a fake host tells the fake plug-in each tick.
public struct FakeHostState: Sendable, Equatable {
    public var playing: Bool
    /// Quarter-note beats from the start of bar 1.
    public var beats: Double
    public var tempoBPM: Double
    public var meter: Meter

    public init(playing: Bool, beats: Double, tempoBPM: Double, meter: Meter = Meter(4, 4)) {
        self.playing = playing
        self.beats = beats
        self.tempoBPM = tempoBPM
        self.meter = meter
    }
}

/// A synthesized "song": sine tones per bar range, rendered from the musical position so the
/// same bar always sounds the same.
public struct FakeSong: Sendable, Equatable {
    public struct Tone: Sendable, Equatable {
        public var frequency: Double
        /// Peak level of the sine in dBFS (on every channel, in phase).
        public var dBFS: Double
        public init(frequency: Double, dBFS: Double) {
            self.frequency = frequency
            self.dBFS = dBFS
        }
    }

    public struct Section: Sendable, Equatable {
        public var fromBar: Int
        /// Inclusive.
        public var toBar: Int
        public var tones: [Tone]
        public init(fromBar: Int, toBar: Int, tones: [Tone]) {
            self.fromBar = fromBar
            self.toBar = toBar
            self.tones = tones
        }
    }

    public var sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    public func tones(atBar bar: Int) -> [Tone] {
        sections.first { (($0.fromBar)...($0.toBar)).contains(bar) }?.tones ?? []
    }

    /// Intro -30, verse (bars 5-8) -26, chorus (bars 9-12) -20 with a 4 kHz tone at -30, outro -30
    /// (1 kHz stereo sines; dBFS of a 1 kHz stereo sine equals its LUFS). Silence after bar 16.
    public static let demo = FakeSong(sections: [
        Section(fromBar: 1, toBar: 4, tones: [Tone(frequency: 1000, dBFS: -30)]),
        Section(fromBar: 5, toBar: 8, tones: [Tone(frequency: 1000, dBFS: -26)]),
        Section(fromBar: 9, toBar: 12, tones: [Tone(frequency: 1000, dBFS: -20), Tone(frequency: 4000, dBFS: -30)]),
        Section(fromBar: 13, toBar: 16, tones: [Tone(frequency: 1000, dBFS: -30)]),
    ])
}

/// A stand-in for the analysis plug-in: renders `song` at the fake host's playhead, runs it through
/// the real kernel, frame builder and link client, exactly like the plug-in will. While the fake
/// transport is stopped it renders silence in real time (assumed for Logic's main output;
/// unverified), or, with `rendersWhileStopped` off, nothing (a track strip with nothing to play),
/// and then sends heartbeats.
public actor FakeAnalysisPlugin {
    public struct Configuration: Sendable {
        public static let defaultInstanceID = "0000fa4e-0000-4000-8000-000000000001"

        public var instanceID: String
        public var contextName: String?
        public var role: String?
        public var sampleRate: Double
        public var channels: Int
        public var tick: Duration
        public var spectrum: Bool
        /// Whether the fake host keeps rendering (silence) while stopped.
        public var rendersWhileStopped: Bool
        /// Heartbeat interval when no audio frame was sent (`FrameBuilder.heartbeat`); nil: none.
        public var heartbeat: Duration?

        public init(
            instanceID: String = Configuration.defaultInstanceID, contextName: String? = "Stereo Out",
            role: String? = "main_output", sampleRate: Double = 48000, channels: Int = 2, tick: Duration = .milliseconds(20),
            spectrum: Bool = true, rendersWhileStopped: Bool = true, heartbeat: Duration? = .seconds(1)
        ) {
            self.instanceID = instanceID
            self.contextName = contextName
            self.role = role
            self.sampleRate = sampleRate
            self.channels = channels
            self.tick = tick
            self.spectrum = spectrum
            self.rendersWhileStopped = rendersWhileStopped
            self.heartbeat = heartbeat
        }
    }

    public let configuration: Configuration
    public let song: FakeSong
    private let clock: @Sendable () async -> FakeHostState
    private let client: AnalysisLinkClient
    private var task: Task<Void, Never>?
    public private(set) var framesSent = 0
    public private(set) var framesDropped = 0

    public init(configuration: Configuration = Configuration(), song: FakeSong = .demo, client: AnalysisLinkClient,
                clock: @escaping @Sendable () async -> FakeHostState) {
        self.configuration = configuration
        self.song = song
        self.client = client
        self.clock = clock
    }

    public func start() {
        guard task == nil else { return }
        client.start()
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        client.stop()
    }

    private func run() async {
        let config = configuration
        guard let kernel = MeterKernel(.init(sampleRate: config.sampleRate, channels: config.channels,
                                             blockCapacity: 256, tapCapacity: 1 << 18)) else { return }
        let builder = FrameBuilder(instanceID: config.instanceID, contextName: config.contextName, role: config.role,
                                   pluginVersion: "fake", sampleRate: config.sampleRate, channels: config.channels,
                                   spectrum: config.spectrum)
        let wall = ContinuousClock()
        var lastTick = wall.now
        var renderedBeat: Double?
        while !Task.isCancelled {
            try? await wall.sleep(for: config.tick)
            let state = await clock()
            let now = wall.now
            let elapsed = lastTick.duration(to: now)
            lastTick = now
            let tempo = max(state.tempoBPM, 1)
            let beatsPerFrame = tempo / 60 / config.sampleRate
            if state.playing {
                // A locate or a lag of more than two bars restarts rendering at the playhead.
                if let rendered = renderedBeat, state.beats >= rendered - 1e-9, state.beats - rendered <= 2 * state.meter.quarterNotesPerBar {
                    let frames = Int(((state.beats - rendered) / beatsPerFrame).rounded(.down))
                    if frames > 0 {
                        render(kernel: kernel, fromBeat: rendered, frames: frames, state: state, beatsPerFrame: beatsPerFrame, playing: true)
                        renderedBeat = rendered + Double(frames) * beatsPerFrame
                    }
                } else {
                    renderedBeat = state.beats
                }
            } else {
                renderedBeat = nil
                let frames = min(Int(elapsed.inSeconds * config.sampleRate), Int(config.sampleRate / 4))
                if frames > 0, config.rendersWhileStopped {
                    render(kernel: kernel, fromBeat: state.beats, frames: frames, state: state, beatsPerFrame: beatsPerFrame, playing: false)
                }
            }
            var frames = builder.frames(for: kernel.drain(), tap: kernel.drainTap(), now: now)
            if frames.isEmpty, let interval = config.heartbeat, let heartbeat = builder.heartbeat(now: now, interval: interval) {
                frames = [heartbeat]
            }
            for frame in frames {
                if client.send(frame) == .sent { framesSent += 1 } else { framesDropped += 1 }
            }
        }
    }

    /// Renders `frames` frames starting at `fromBeat` (silence when not playing) in render-sized
    /// chunks, each with its own host context, like an AU render callback.
    private func render(kernel: MeterKernel, fromBeat: Double, frames: Int, state: FakeHostState, beatsPerFrame: Double, playing: Bool) {
        let chunk = 512
        let channels = configuration.channels
        let barLength = state.meter.quarterNotesPerBar
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            let startBeat = fromBeat + (playing ? Double(done) * beatsPerFrame : 0)
            var buffer = [Float](repeating: 0, count: n)
            if playing {
                for i in 0..<n {
                    let beat = startBeat + Double(i) * beatsPerFrame
                    let bar = Int((beat / barLength).rounded(.down)) + 1
                    let seconds = beat * 60 / state.tempoBPM
                    var value = 0.0
                    for tone in song.tones(atBar: bar) {
                        value += pow(10, tone.dBFS / 20) * sin(2 * .pi * tone.frequency * seconds)
                    }
                    buffer[i] = Float(value)
                }
            }
            let downbeat = (startBeat / barLength).rounded(.down) * barLength
            kernel.process(
                planar: Array(repeating: buffer, count: channels),
                context: HostContext(beatPosition: startBeat, tempoBPM: state.tempoBPM, meter: state.meter,
                                     measureDownbeat: downbeat, playing: playing))
            done += n
        }
    }
}
