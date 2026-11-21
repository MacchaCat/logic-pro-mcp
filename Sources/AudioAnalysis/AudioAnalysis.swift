import LoudnessKernel

/// Phase 5: gated loudness (BS.1770-5 / EBU R 128), LRA (EBU Tech 3342), true peak and spectrum
/// on top of the real-time kernel. Everything here runs on background threads only.
public enum AudioAnalysis {
    public static var kernelAPIVersion: Int { Int(lk_api_version()) }
}

/// One process call's host context (for an AU: the musical context and transport state blocks).
public struct HostContext: Sendable, Equatable {
    /// Quarter-note beats at the call's first frame.
    public var beatPosition: Double?
    public var tempoBPM: Double?
    public var meter: Meter?
    /// Beat position of the first beat of the current bar.
    public var measureDownbeat: Double?
    /// nil = the host gave no transport state.
    public var playing: Bool?
    public var recording: Bool
    public var cycling: Bool

    public init(
        beatPosition: Double? = nil, tempoBPM: Double? = nil, meter: Meter? = nil,
        measureDownbeat: Double? = nil, playing: Bool? = nil, recording: Bool = false, cycling: Bool = false
    ) {
        self.beatPosition = beatPosition
        self.tempoBPM = tempoBPM
        self.meter = meter
        self.measureDownbeat = measureDownbeat
        self.playing = playing
        self.recording = recording
        self.cycling = cycling
    }

    var kernelContext: lk_host_context {
        var context = lk_host_context()
        var flags: UInt32 = 0
        if let beatPosition, beatPosition.isFinite {
            context.beat_position = beatPosition
            flags |= UInt32(LK_CONTEXT_HAS_BEAT)
        }
        if let tempoBPM, tempoBPM.isFinite, tempoBPM > 0 {
            context.tempo_bpm = tempoBPM
            flags |= UInt32(LK_CONTEXT_HAS_TEMPO)
        }
        if let meter {
            context.meter_numerator = Int32(clamping: meter.numerator)
            context.meter_denominator = Int32(clamping: meter.denominator)
            flags |= UInt32(LK_CONTEXT_HAS_METER)
        }
        if let measureDownbeat, measureDownbeat.isFinite {
            context.measure_downbeat = measureDownbeat
            flags |= UInt32(LK_CONTEXT_HAS_DOWNBEAT)
        }
        if let playing {
            flags |= UInt32(LK_CONTEXT_HAS_TRANSPORT)
            if playing { flags |= UInt32(LK_CONTEXT_PLAYING) }
            if recording { flags |= UInt32(LK_CONTEXT_RECORDING) }
            if cycling { flags |= UInt32(LK_CONTEXT_CYCLING) }
        }
        context.flags = flags
        return context
    }
}

/// A time signature.
public struct Meter: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Bar length in quarter-note beats (the unit of host beat positions).
    public var quarterNotesPerBar: Double { 4.0 * Double(numerator) / Double(denominator) }

    public var isValid: Bool {
        (1...64).contains(numerator) && [1, 2, 4, 8, 16, 32, 64].contains(denominator)
    }

    public var description: String { "\(numerator)/\(denominator)" }
}
