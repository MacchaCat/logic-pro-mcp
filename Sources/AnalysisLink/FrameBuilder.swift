import AudioAnalysis
import Foundation

/// Plug-in side: turns drained kernel sub-blocks and tap samples into link frames. Runs on the
/// plug-in's background thread (it allocates and runs the FFT), never on the render thread.
public final class FrameBuilder {
    public let instanceID: String
    /// The host's track / channel name, reduced by `PluginText.contextName` when set (the same
    /// rules the server applies): a long or unusual name never makes a frame invalid.
    public var contextName: String? {
        get { storedContextName }
        set { storedContextName = Self.sanitizedContextName(newValue) }
    }
    /// One of `AnalysisFrame.roles`; anything else is sent as no role.
    public var role: String? {
        get { storedRole }
        set { storedRole = newValue.flatMap { AnalysisFrame.roles.contains($0) ? $0 : nil } }
    }
    public let pluginVersion: String?
    public let sampleRate: Double
    public let channels: Int
    private var storedContextName: String?
    private var storedRole: String?
    private let spectrum: SpectrumAnalyzer?
    private var sequence: UInt64 = 0
    /// When the last frame (audio or heartbeat) was built.
    private var lastFrameAt: ContinuousClock.Instant?

    public init(
        instanceID: String, contextName: String? = nil, role: String? = nil, pluginVersion: String? = nil,
        sampleRate: Double, channels: Int, spectrum: Bool = true
    ) {
        self.instanceID = instanceID
        self.pluginVersion = PluginText.pluginVersion(pluginVersion)
        self.sampleRate = sampleRate
        self.channels = channels
        self.spectrum = spectrum ? SpectrumAnalyzer(sampleRate: sampleRate) : nil
        storedContextName = Self.sanitizedContextName(contextName)
        storedRole = role.flatMap { AnalysisFrame.roles.contains($0) ? $0 : nil }
    }

    /// `name` as `PluginText.contextName` reduces it (letters, digits, a little punctuation; at
    /// most 40 characters and 128 UTF-8 bytes). nil when nothing remains.
    public static func sanitizedContextName(_ name: String?) -> String? {
        PluginText.contextName(name)
    }

    /// Frames for the sub-blocks completed since the last call (normally one frame); the spectrum
    /// of `tap` (the mono tap samples drained alongside) rides on the last frame. Empty when there
    /// is no new sub-block.
    public func frames(
        for subBlocks: [SubBlock], tap: [Float] = [], now: ContinuousClock.Instant = ContinuousClock().now
    ) -> [AnalysisFrame] {
        if !tap.isEmpty { spectrum?.append(tap) }
        guard !subBlocks.isEmpty else { return [] }
        lastFrameAt = now
        var frames: [AnalysisFrame] = []
        var remaining = subBlocks[...]
        while !remaining.isEmpty {
            let chunk = remaining.prefix(AnalysisFrame.maxSubBlocks)
            remaining = remaining.dropFirst(chunk.count)
            sequence += 1
            frames.append(AnalysisFrame(
                instanceID: instanceID, pluginVersion: pluginVersion, contextName: contextName, role: role,
                sampleRate: sampleRate, channels: channels, sequence: sequence,
                host: Self.host(of: chunk.first!), subBlocks: chunk.map(Self.record),
                spectrum: nil))
        }
        if let powers = spectrum?.takeBandPowers() {
            frames[frames.count - 1].spectrum = powers.map { Self.clamp($0) }
        }
        return frames
    }

    /// A frame without sub-blocks and without host state, when no frame was built for
    /// `interval`; nil otherwise. The sending loop calls it after `frames(for:)`: while Logic is
    /// stopped it may not render a strip that has nothing to play, and then no audio frames come.
    /// Heartbeats keep the connection (the server closes one that is silent for a minute) and
    /// the instance's ownership of its id (the server lets another connection with the same id
    /// take over after 2 s of silence) without claiming anything about the host.
    public func heartbeat(now: ContinuousClock.Instant = ContinuousClock().now, interval: Duration = .seconds(1)) -> AnalysisFrame? {
        guard let last = lastFrameAt else {
            // The first call starts the interval: a plug-in that renders right away sends audio
            // frames (with the host state) first.
            lastFrameAt = now
            return nil
        }
        guard last.duration(to: now) >= interval else { return nil }
        lastFrameAt = now
        sequence += 1
        return AnalysisFrame(
            instanceID: instanceID, pluginVersion: pluginVersion, contextName: contextName, role: role,
            sampleRate: sampleRate, channels: channels, sequence: sequence, host: HostState(), subBlocks: [])
    }

    static func host(of block: SubBlock) -> HostState {
        let transportKnown = block.flags.contains(.hasTransport)
        let meter = block.meter.flatMap { $0.isValid ? $0 : nil }
        return HostState(
            tempoBPM: block.tempoBPM.flatMap { AnalysisFrame.validTempo($0) ? $0 : nil },
            meterNumerator: meter?.numerator, meterDenominator: meter?.denominator,
            beatPosition: block.beatPosition.flatMap { AnalysisFrame.validBeat($0) ? $0 : nil },
            measureDownbeat: block.measureDownbeat.flatMap { AnalysisFrame.validBeat($0) ? $0 : nil },
            playing: transportKnown ? block.playing : nil,
            recording: transportKnown ? block.flags.contains(.recording) : nil,
            cycling: transportKnown ? block.flags.contains(.cycling) : nil)
    }

    static func record(_ block: SubBlock) -> SubBlockRecord {
        SubBlockRecord(
            index: block.index, frames: block.frames,
            beat: block.beatPosition.flatMap { AnalysisFrame.validBeat($0) ? $0 : nil },
            tempo: block.tempoBPM.flatMap { AnalysisFrame.validTempo($0) ? $0 : nil },
            playing: block.playing,
            jumpBefore: block.flags.contains(.jumpBefore), jumpInside: block.flags.contains(.jumpInside),
            meanSquare: clamp(block.weightedMeanSquare),
            samplePeak: clamp(Double(block.samplePeak)), truePeak: clamp(Double(block.truePeak)),
            maxMomentary: block.maxMomentaryMeanSquare > 0 ? clamp(block.maxMomentaryMeanSquare) : nil)
    }

    /// Keeps values inside the protocol's limits (a wildly clipping signal must not make frames invalid).
    static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(max(value, 0), 1e4)
    }
}
