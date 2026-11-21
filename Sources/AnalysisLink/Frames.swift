import AudioAnalysis
import Foundation

/// Host state at the start of a frame's window (from the first sub-block's context).
public struct HostState: Codable, Sendable, Equatable {
    public var tempoBPM: Double?
    public var meterNumerator: Int?
    public var meterDenominator: Int?
    /// Quarter-note beat position of the window's first frame.
    public var beatPosition: Double?
    /// Beat position of the first beat of the bar containing `beatPosition`.
    public var measureDownbeat: Double?
    public var playing: Bool?
    public var recording: Bool?
    public var cycling: Bool?

    public init(
        tempoBPM: Double? = nil, meterNumerator: Int? = nil, meterDenominator: Int? = nil, beatPosition: Double? = nil,
        measureDownbeat: Double? = nil, playing: Bool? = nil, recording: Bool? = nil, cycling: Bool? = nil
    ) {
        self.tempoBPM = tempoBPM
        self.meterNumerator = meterNumerator
        self.meterDenominator = meterDenominator
        self.beatPosition = beatPosition
        self.measureDownbeat = measureDownbeat
        self.playing = playing
        self.recording = recording
        self.cycling = cycling
    }

    public var meter: Meter? {
        guard let meterNumerator, let meterDenominator else { return nil }
        return Meter(meterNumerator, meterDenominator)
    }

    enum CodingKeys: String, CodingKey {
        case playing, recording, cycling
        case tempoBPM = "tempo_bpm"
        case meterNumerator = "meter_numerator"
        case meterDenominator = "meter_denominator"
        case beatPosition = "beat_position"
        case measureDownbeat = "measure_downbeat"
    }
}

/// One 100 ms sub-block as sent over the link.
public struct SubBlockRecord: Codable, Sendable, Equatable {
    /// The kernel's running sub-block number (gaps = records dropped before sending).
    public var index: UInt64
    public var frames: Int
    /// Beat position and tempo at the sub-block's first frame.
    public var beat: Double?
    public var tempo: Double?
    /// Transport playing for the whole sub-block.
    public var playing: Bool
    /// The host's position jumped right before this sub-block (it does not continue the previous one).
    public var jumpBefore: Bool
    /// The position jumped inside this sub-block (its audio spans two places).
    public var jumpInside: Bool
    /// Sum over channels of G_i * z_i (K-weighted, BS.1770 channel weights).
    public var meanSquare: Double
    public var samplePeak: Double
    public var truePeak: Double
    /// The loudest 400 ms window ending in this sub-block, slid in 10 ms steps (same units as
    /// `meanSquare`; absent when the kernel had no such window). Optional.
    public var maxMomentary: Double?

    public init(
        index: UInt64, frames: Int, beat: Double? = nil, tempo: Double? = nil, playing: Bool,
        jumpBefore: Bool = false, jumpInside: Bool = false, meanSquare: Double, samplePeak: Double, truePeak: Double,
        maxMomentary: Double? = nil
    ) {
        self.index = index
        self.frames = frames
        self.beat = beat
        self.tempo = tempo
        self.playing = playing
        self.jumpBefore = jumpBefore
        self.jumpInside = jumpInside
        self.meanSquare = meanSquare
        self.samplePeak = samplePeak
        self.truePeak = truePeak
        self.maxMomentary = maxMomentary
    }

    enum CodingKeys: String, CodingKey {
        case index, frames, beat, tempo, playing
        case jumpBefore = "jump_before"
        case jumpInside = "jump_inside"
        case meanSquare = "ms"
        case samplePeak = "sample_peak"
        case truePeak = "true_peak"
        case maxMomentary = "max_momentary_ms"
    }
}

/// Frame type 1: the plug-in's measurements for one window (normally ~100 ms, one sub-block).
public struct AnalysisFrame: Codable, Sendable, Equatable {
    public static let kindValue = "analysis"
    public static let roles: Set<String> = ["main_output", "track", "bus", "other"]
    public static let maxSubBlocks = 64
    /// A UUID (36 characters) fits.
    public static let maxInstanceIDLength = 40
    public static let minInstanceIDLength = 8

    /// An instance id is 8-40 characters of hex digits and "-" with at least 8 hex digits: a
    /// UUID, as the plug-in creates it. Ids are shown to the model (in `instance` fields), and
    /// this alphabet cannot spell instructions.
    public static func isValidInstanceID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard (minInstanceIDLength...maxInstanceIDLength).contains(scalars.count) else { return false }
        var hexDigits = 0
        for scalar in scalars {
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F": hexDigits += 1
            case "-": break
            default: return false
            }
        }
        return hexDigits >= minInstanceIDLength
    }

    public var kind: String
    /// Stable per plug-in instance (a UUID kept in the plug-in's saved state; see
    /// `isValidInstanceID`).
    public var instanceID: String
    /// Untrusted text: the server keeps only `PluginText.pluginVersion` of it.
    public var pluginVersion: String?
    /// Channel strip / track name if the host provides one. Untrusted text: the server keeps only
    /// `PluginText.contextName` of it and shows it as `plugin_reported_context_name`.
    public var contextName: String?
    /// What the user marked this instance as in the plug-in (e.g. "main_output"). Self-declared:
    /// it helps pick a default instance but never displaces one already chosen.
    public var role: String?
    public var sampleRate: Double
    public var channels: Int
    /// Frame counter of this connection's sender.
    public var sequence: UInt64
    public var host: HostState
    public var subBlocks: [SubBlockRecord]
    /// One-third-octave band powers (mean square), `ThirdOctaveBands.count` values, averaged over
    /// the audio since the previous frame. Optional.
    public var spectrum: [Double]?

    public init(
        instanceID: String, pluginVersion: String? = nil, contextName: String? = nil, role: String? = nil,
        sampleRate: Double, channels: Int, sequence: UInt64, host: HostState, subBlocks: [SubBlockRecord],
        spectrum: [Double]? = nil
    ) {
        self.kind = Self.kindValue
        self.instanceID = instanceID
        self.pluginVersion = pluginVersion
        self.contextName = contextName
        self.role = role
        self.sampleRate = sampleRate
        self.channels = channels
        self.sequence = sequence
        self.host = host
        self.subBlocks = subBlocks
        self.spectrum = spectrum
    }

    enum CodingKeys: String, CodingKey {
        case kind, role, channels, host, spectrum
        case instanceID = "instance_id"
        case pluginVersion = "plugin_version"
        case contextName = "context_name"
        case sampleRate = "sample_rate"
        case sequence = "seq"
        case subBlocks = "sub_blocks"
    }

    /// Checks every field against the protocol's limits. Throws `LinkError.invalidFrame`.
    public func validate() throws(LinkError) {
        func fail(_ reason: String) -> LinkError { .invalidFrame(reason) }
        guard kind == Self.kindValue else { throw fail("kind must be \"analysis\"") }
        // The id is shown to the model as `instance` (a label, never in prose): a UUID-like
        // string that cannot carry words.
        guard Self.isValidInstanceID(instanceID) else {
            throw fail("instance_id must be \(Self.minInstanceIDLength)-\(Self.maxInstanceIDLength) characters of hex digits and - (a UUID)")
        }
        // Version and channel name only get structural limits here (so an unusual name does not
        // make every frame invalid); the server reduces them further with `PluginText`.
        if let pluginVersion {
            guard pluginVersion.utf8.count <= 32, pluginVersion.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F })
            else { throw fail("plugin_version must be at most 32 printable ASCII characters") }
        }
        if let contextName {
            guard contextName.utf8.count <= 256, contextName.count <= 128,
                  !contextName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format && $0.value != 0x200D })
            else { throw fail("context_name must be at most 128 characters without control characters") }
        }
        if let role, !Self.roles.contains(role) { throw fail("unknown role") }
        guard sampleRate.isFinite, (8000...768_000).contains(sampleRate) else { throw fail("sample_rate out of range") }
        guard (1...8).contains(channels) else { throw fail("channels must be 1-8") }
        try host.validate()
        guard subBlocks.count <= Self.maxSubBlocks else { throw fail("more than \(Self.maxSubBlocks) sub-blocks") }
        // Loudness windows count sub-blocks (4 = 400 ms, 30 = 3 s), so each must be 100 ms: the
        // kernel's round(sample_rate / 10) frames, +-1 for another rounding.
        let blockFrames = Self.subBlockFrames(sampleRate: sampleRate)
        var previous: UInt64?
        // A range test: `block.frames` is untrusted, and arithmetic on it (block.frames -
        // blockFrames) would trap for values near Int.min / Int.max.
        let acceptedFrames = (blockFrames - 1)...(blockFrames + 1)
        for block in subBlocks {
            guard acceptedFrames.contains(block.frames) else {
                throw fail("sub-block frames must be \(blockFrames) (100 ms at the sample rate)")
            }
            if let previous, block.index <= previous { throw fail("sub-block indices must increase") }
            previous = block.index
            if let beat = block.beat, !Self.validBeat(beat) { throw fail("sub-block beat out of range") }
            if let tempo = block.tempo, !Self.validTempo(tempo) { throw fail("sub-block tempo out of range") }
            for value in [block.meanSquare, block.samplePeak, block.truePeak, block.maxMomentary ?? 0] {
                guard value.isFinite, value >= 0, value <= 1e4 else { throw fail("sub-block level out of range") }
            }
        }
        if let spectrum {
            guard spectrum.count == ThirdOctaveBands.count else { throw fail("spectrum must have \(ThirdOctaveBands.count) bands") }
            guard spectrum.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1e4 }) else { throw fail("spectrum value out of range") }
        }
    }

    /// Frames in one 100 ms sub-block at `sampleRate`, as the kernel counts them (lround).
    public static func subBlockFrames(sampleRate: Double) -> Int {
        Int((sampleRate / 10).rounded(.toNearestOrAwayFromZero))
    }

    static func validBeat(_ beat: Double) -> Bool { beat.isFinite && abs(beat) <= 1e7 }
    /// Logic's tempo range is 5-990 BPM. A tempo near 0 would give a 100 ms sub-block a beat
    /// span of ~0, a zero-width block the position history cannot place.
    static func validTempo(_ tempo: Double) -> Bool { tempo.isFinite && tempo >= 5 && tempo <= 999 }
}

extension HostState {
    func validate() throws(LinkError) {
        if let tempoBPM, !AnalysisFrame.validTempo(tempoBPM) { throw .invalidFrame("tempo_bpm out of range") }
        if meterNumerator != nil || meterDenominator != nil {
            guard let meter, meter.isValid else { throw .invalidFrame("time signature out of range") }
        }
        if let beatPosition, !AnalysisFrame.validBeat(beatPosition) { throw .invalidFrame("beat_position out of range") }
        if let measureDownbeat, !AnalysisFrame.validBeat(measureDownbeat) { throw .invalidFrame("measure_downbeat out of range") }
    }
}

/// Frame type 2: the server's greeting on every accepted connection.
public struct ServerHello: Codable, Sendable, Equatable {
    public var kind: String
    public var server: String
    public var version: String
    public var protocolVersion: Int

    public init(version: String) {
        kind = "hello"
        server = AnalysisLink.serverName
        self.version = version
        protocolVersion = Int(AnalysisLink.protocolVersion)
    }

    enum CodingKeys: String, CodingKey {
        case kind, server, version
        case protocolVersion = "protocol"
    }

    var isValid: Bool {
        kind == "hello" && server == AnalysisLink.serverName && protocolVersion == Int(AnalysisLink.protocolVersion)
    }
}
