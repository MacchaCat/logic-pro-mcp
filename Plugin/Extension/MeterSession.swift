import AnalysisLink
import AudioAnalysis
import Foundation

/// The plug-in's non-real-time half: owns the C kernel (the render block in
/// LMCPMeterAudioUnit.m feeds it through `kernelState`), and on a background queue drains its
/// 100 ms sub-blocks and mono tap, builds link frames and sends them to the logic-mcp server over
/// loopback TCP (the plug-in is the client; research §5.7). Nothing here runs on the audio thread.
@objc(LMCPMeterSession)
public final class MeterSession: NSObject, @unchecked Sendable {
    /// Matches the server's expectations (`AnalysisFrame.subBlockFrames`, link ports).
    private static let tick: DispatchTimeInterval = .milliseconds(50)
    private static let heartbeat: Duration = .seconds(1)

    private let kernel: MeterKernel
    private let builder: FrameBuilder
    private let client: AnalysisLinkClient
    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "LogicMCPMeter.sender", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// `lk_state *` for the render block. Valid until this session is released.
    @objc public var kernelState: UnsafeMutableRawPointer { kernel.unsafeKernelState }
    @objc public let instanceID: String

    /// `instanceID` comes from the audio unit, which makes it once per plug-in instance: a new
    /// session (after the host changes the sample rate or buffer size) keeps the id, so the
    /// server keeps the instance's history and default. It is not saved with the project:
    /// copying the plug-in in Logic copies its saved state, and the server refuses a second
    /// connection that sends an id it already has.
    @objc public init?(sampleRate: Double, channels: Int, contextName: String?, pluginVersion: String?, instanceID: String) {
        guard let kernel = MeterKernel(.init(sampleRate: sampleRate, channels: channels,
                                             blockCapacity: 256, tapCapacity: 1 << 18)) else { return nil }
        self.kernel = kernel
        self.instanceID = instanceID
        // No role: the server recognises the main output by the channel name Logic gives.
        builder = FrameBuilder(instanceID: instanceID, contextName: contextName, role: nil,
                               pluginVersion: pluginVersion, sampleRate: sampleRate, channels: channels,
                               spectrum: true)
        client = AnalysisLinkClient()
        super.init()
    }

    deinit {
        timer?.cancel()
        client.stop()
    }

    @objc public func start() {
        queue.sync {
            guard timer == nil else { return }
            client.start()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.tick, repeating: Self.tick, leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.sendPending() }
            source.resume()
            timer = source
        }
    }

    /// Stops sending. After it returns no drain runs, so the kernel may be released once the
    /// host has stopped rendering.
    @objc public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            client.stop()
        }
    }

    /// Logic sets the AU's context name (the channel strip's name) after loading it.
    @objc public func setContextName(_ name: String?) {
        queue.async { [weak self] in self?.builder.contextName = name }
    }

    private func sendPending() {
        let now = ContinuousClock().now
        var frames = builder.frames(for: kernel.drain(), tap: kernel.drainTap(), now: now)
        if frames.isEmpty, let heartbeat = builder.heartbeat(now: now, interval: Self.heartbeat) {
            frames = [heartbeat]
        }
        for frame in frames {
            _ = client.send(frame)  // dropped while not connected; the client reconnects by itself
        }
    }
}
