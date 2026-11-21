import CommandMap
import Foundation
import MackieControl
import MIDICore

/// Waits for the effects of key commands. Defaults are sized from Logic 13 observations: the time
/// display answered jog ticks within 30–100 ms, a full scan of 11 tracks took about 3.6 s.
public struct CommandTimings: Sendable {
    /// Wait for the Cycle / Click LED to change after a toggle.
    public var ledTimeout: Duration = .milliseconds(1000)
    /// Wait for the time display to change after a playhead command.
    public var playheadTimeout: Duration = .milliseconds(1000)
    /// Track commands: delay before the first track scan after sending…
    public var trackFirstScanDelay: Duration = .milliseconds(300)
    /// …then scan again until the count changes, at most this many scans in all…
    public var maxTrackScans = 3
    /// …with this pause between scans…
    public var trackRescanGap: Duration = .milliseconds(300)
    /// …and no new scan starting later than this after sending (a scan of 11 tracks took 3.6 s,
    /// so a long project gets only one scan after sending).
    public var trackDeadline: Duration = .seconds(8)
    public var pollInterval: Duration = .milliseconds(5)

    public init() {}
}

/// What Logic's control surface showed around a key command.
public struct CommandState: Sendable, Codable, Equatable {
    public var playing: Bool?
    public var recording: Bool?
    /// From the time display in Beats mode; nil when not readable.
    public var position: BeatsPosition?
    public var display: String?
    /// Cycle LED (note 0x56); nil = Logic has not reported it.
    public var cycle: Bool?
    /// Click LED (note 0x59); nil = Logic has not reported it.
    public var click: Bool?
    /// From a full track scan; only for commands checked by the track count.
    public var trackCount: Int?
    /// False when the scan could not confirm the end of the track list.
    public var trackCountConfirmed: Bool?
    public var trackNames: [String]?

    enum CodingKeys: String, CodingKey {
        case playing, recording, position, display, cycle, click
        case trackCount = "track_count"
        case trackCountConfirmed = "track_count_confirmed"
        case trackNames = "track_names"
    }
}

/// Payload of a learn trigger.
public struct LearnReport: Sendable, Codable, Equatable {
    public var command: String
    public var englishName: String
    /// nil when the Japanese name has not been seen on Logic 13 yet.
    public var japaneseName: String?
    public var port: String
    public var channel: Int
    public var controller: Int
    public var message: String
    /// The whole procedure for the user (with Logic's English menu names).
    public var steps: [String]
    /// What to check in Logic after the trigger was sent.
    public var check: [String]

    enum CodingKeys: String, CodingKey {
        case command, port, channel, controller, message, steps, check
        case englishName = "english_name"
        case japaneseName = "japanese_name"
    }
}

/// The outcome of the last `run` of a command in this process that sent the command's trigger.
/// Runs that sent nothing (refusals, confirmation requests, "already at 1 1 1 1") are not
/// recorded: they say nothing about whether Logic has learned the command.
public struct CommandRunRecord: Sendable, Codable, Equatable {
    public var status: String
    public var summary: String
    public var asOf: String

    enum CodingKeys: String, CodingKey {
        case status, summary
        case asOf = "as_of"
    }
}

/// Runs catalog key commands on `LogicMCP Keys` and checks their effect on Logic's Mackie Control
/// output (design §3.7). Logic never acknowledges a key command (research §3.3), so a result is
/// "verified" only when the surface shows the change the command explains: the track count from a
/// full scan before and after, the Cycle / Click LED, or the time display. Everything else is
/// "unverified".
///
/// Nothing is sent while Logic's Record LED shows that it is recording. `run` also refuses while
/// the record state is unknown (no Mackie Control feedback). `learn` and `trigger` (setup and
/// diagnostics: learning, the console's `key`) are the exception: with an unknown record state
/// they still send, with a warning.
///
/// Every trigger drops the mixer's cached track list: in Logic a CC may be learned for any
/// command, including one that adds or removes tracks.
///
/// Runs and triggers are serialised (one at a time, including the wait for the effect), and
/// triggers are at least `RateLimits.keyCommandGap` apart.
public actor CommandController {
    public typealias RunResult = OperationResult<CommandState>
    public typealias LearnResult = OperationResult<LearnReport>

    private let mcu: MCUSession
    private let sync: SyncMonitor
    private let mixer: MixerController?
    private let keys: OutputScheduler
    private let limits: RateLimits
    private let timings: CommandTimings
    private let clock = ContinuousClock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `send`; reset at the start of each run (runs are serialised).
    private var triggerSent = false
    /// LEDs that changed after one of our key commands in this process: Logic has shown that it
    /// reports the command's effect there, so an unchanged LED later means the command did not run.
    private var ledsSeenFollowing: Set<SurfaceLED> = []
    /// Last result per command id, only for runs that sent the trigger.
    public private(set) var lastRuns: [String: CommandRunRecord] = [:]

    public init(
        mcu: MCUSession, sync: SyncMonitor, mixer: MixerController?, keys: OutputScheduler,
        limits: RateLimits = RateLimits(), timings: CommandTimings = CommandTimings()
    ) {
        self.mcu = mcu
        self.sync = sync
        self.mixer = mixer
        self.keys = keys
        self.limits = limits
        self.timings = timings
    }

    static let portName = "LogicMCP Keys"

    static let focusNote = "Key commands act on the Logic window with key focus; whether they work while Logic is in the background has not been confirmed yet."

    static func notSeenCauses(_ command: LogicCommand) -> String {
        "Possible causes: \(command.englishName) has not been learned for CC \(command.controller) yet (learn_command), the CC is learned for a different command, Logic is showing a dialog, or the key command does not reach the focused window."
    }

    static let unknownRecordStateWarning = "Logic has not reported its transport state through Mackie Control, so it could not be checked that Logic was not recording."

    // MARK: Run

    /// Sends `command` once and checks its effect. Destructive commands need `confirmed`;
    /// without it the result is `needs_confirmation` and nothing is sent.
    public func run(_ command: LogicCommand, confirmed: Bool) async -> RunResult {
        await acquire()
        defer { release() }
        triggerSent = false
        var result = await perform(command, confirmed: confirmed)
        if result.status != .needsConfirmation {
            for note in command.notes where !result.warnings.contains(note) { result.warnings.append(note) }
        }
        // Only a run that sent the trigger says anything about whether Logic has learned it.
        if triggerSent {
            lastRuns[command.id] = CommandRunRecord(status: result.status.rawValue, summary: result.summary, asOf: result.asOf)
        }
        return result
    }

    private func perform(_ command: LogicCommand, confirmed: Bool) async -> RunResult {
        let before = await state()
        if case .notRunnable(let reason) = command.verification {
            return RunResult(status: .failed, summary: "\(command.id) cannot be run: \(reason) Nothing was sent.", before: before)
        }
        if let refusal = Self.recordingRefusal(before) {
            return RunResult(status: .failed, summary: refusal + " Nothing was sent.", before: before)
        }
        if command.destructive, !confirmed {
            return RunResult(
                status: .needsConfirmation,
                summary: "\(command.confirmationReason ?? "\(command.englishName) is destructive.") Run \(command.englishName) in Logic?",
                before: before)
        }
        switch command.verification {
        case .trackCount(let change):
            return await runTrackCount(command, change: change, before: before)
        case .surfaceLED(let led):
            return await runLED(command, led: led, before: before)
        case .playhead(let move):
            return await runPlayhead(command, move: move, before: before)
        case .none, .notRunnable:
            await send(command)
            return RunResult(
                status: .unverified,
                summary: "Sent \(command.englishName). Logic gives no feedback for this command, so whether it ran, and what it changed, is unknown; check in Logic.",
                before: before, after: await state(), evidence: [Self.sentEvidence(command)], warnings: [Self.focusNote])
        }
    }

    /// nil when Logic reports that it is not recording; otherwise why nothing is sent.
    static func recordingRefusal(_ state: CommandState) -> String? {
        switch state.recording {
        case true?:
            return "Logic is recording. Key commands are not sent while recording: an edit during recording is unsafe, and a trigger Logic has not learned would be recorded as MIDI data."
        case nil:
            return "Logic has not reported its Record LED through Mackie Control, so it cannot be confirmed that Logic is not recording. Set up the Mackie Control surface (docs/setup/01-phase1-logic-setup.md) and check logic_status."
        case false?:
            return nil
        }
    }

    // MARK: Track count

    private func runTrackCount(_ command: LogicCommand, change: Int, before initial: CommandState) async -> RunResult {
        guard let mixer else {
            await send(command)
            return RunResult(status: .unverified, summary: "Sent \(command.englishName); no track reader is configured, so the track count was not checked.",
                             before: initial, after: await state(), evidence: [Self.sentEvidence(command)])
        }
        let beforeScan = await mixer.tracks(refresh: true)
        guard beforeScan.status != .failed, let beforeTracks = beforeScan.after else {
            return RunResult(
                status: .failed,
                summary: "Could not read the track list before \(command.englishName), so its effect could not be checked: \(beforeScan.summary) Nothing was sent.",
                before: initial, warnings: beforeScan.warnings)
        }
        var before = await state()
        before.trackCount = beforeTracks.trackCount
        before.trackCountConfirmed = beforeScan.status == .verified
        before.trackNames = beforeTracks.tracks.map(\.name)
        // The scan takes seconds: check again right before sending.
        if let refusal = Self.recordingRefusal(before) {
            return RunResult(status: .failed, summary: refusal + " Nothing was sent.", before: before)
        }

        await send(command)
        let sentAt = clock.now
        try? await clock.sleep(for: timings.trackFirstScanDelay)
        var scans = 0
        var afterScan: MixerController.ScanResult
        while true {
            afterScan = await mixer.tracks(refresh: true)
            scans += 1
            if afterScan.status != .failed, let count = afterScan.after?.trackCount, count != beforeTracks.trackCount { break }
            guard Self.startsAnotherScan(after: scans, elapsed: sentAt.duration(to: clock.now), timings: timings) else { break }
            try? await clock.sleep(for: timings.trackRescanGap)
        }
        let elapsed = sentAt.duration(to: clock.now).milliseconds
        var after = await state()
        var warnings = Self.unique(beforeScan.warnings + afterScan.warnings)
        var evidence = [Self.sentEvidence(command),
                        "track scan before: \(beforeTracks.trackCount) tracks (\(beforeScan.status.rawValue))"]
        guard afterScan.status != .failed, let afterTracks = afterScan.after else {
            warnings.insert("Check the track list in Logic before running \(command.id) again.", at: 0)
            return RunResult(status: .unverified,
                             summary: "Sent \(command.englishName), but the track list could not be read afterwards: \(afterScan.summary)",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        }
        after.trackCount = afterTracks.trackCount
        after.trackCountConfirmed = afterScan.status == .verified
        after.trackNames = afterTracks.tracks.map(\.name)
        evidence.append("track scan \(scans) (\(elapsed) ms after sending): \(afterTracks.trackCount) tracks (\(afterScan.status.rawValue))")

        let from = beforeTracks.trackCount, to = afterTracks.trackCount
        let expected = change > 0 ? "+\(change)" : "\(change)"
        let confirmedCounts = beforeScan.status == .verified && afterScan.status == .verified
        switch Self.trackCountOutcome(change: change, from: from, to: to, confirmed: confirmedCounts) {
        case .notConfirmed:
            warnings.insert("The track count is not confirmed (the scan could not see the end of the track list), so the change cannot be verified. Check the track list in Logic before running \(command.id) again.", at: 0)
            return RunResult(status: .unverified,
                             summary: "Sent \(command.englishName); the scans read \(from) tracks before and \(to) after (expected \(expected)), but the counts are not confirmed.",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        case .expected:
            return RunResult(status: .verified, summary: "\(command.englishName): the track count went from \(from) to \(to).",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        case .unchanged:
            warnings.insert(Self.notSeenCauses(command), at: 0)
            warnings.insert("If the selected track is inside a collapsed folder or track stack, or tracks are hidden, the change may not show on the control surface (not yet checked on Logic 13). Check the track list in Logic before running \(command.id) again: if it did run, running it again \(change > 0 ? "creates another track" : "deletes another track").", at: 1)
            return RunResult(status: .failed,
                             summary: "Sent \(command.englishName), but the track count stayed at \(from) (\(scans) scans over \(elapsed) ms).",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        case .otherAmount:
            warnings.insert("Several tracks may have been selected in Logic, or tracks were changed in Logic at the same time. Check the track list in Logic before running \(command.id) again.", at: 0)
            return RunResult(status: .unverified,
                             summary: "\(command.englishName): the track count went from \(from) to \(to), not by \(expected) as expected.",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        case .opposite:
            warnings.insert("The CC may be learned for a different command, or tracks were changed in Logic at the same time. Check the track list in Logic.", at: 0)
            return RunResult(status: .failed,
                             summary: "Sent \(command.englishName), but the track count went from \(from) to \(to), the opposite of what it does.",
                             before: before, after: after, evidence: evidence, warnings: warnings)
        }
    }

    /// How a track count change compares with what a command does.
    enum TrackCountOutcome: Equatable {
        /// A scan could not confirm the end of the track list.
        case notConfirmed
        /// Changed by exactly `change`: verified.
        case expected
        /// No change: failed.
        case unchanged
        /// Changed in the right direction by a different amount: unverified.
        case otherAmount
        /// Changed the other way: failed.
        case opposite
    }

    /// Whether to scan again after `scans` scans that showed no change, `elapsed` after sending:
    /// at most `maxTrackScans` in all, and none starting later than `trackDeadline` after sending
    /// (the next one would start `trackRescanGap` from now).
    static func startsAnotherScan(after scans: Int, elapsed: Duration, timings: CommandTimings) -> Bool {
        scans < timings.maxTrackScans && elapsed + timings.trackRescanGap <= timings.trackDeadline
    }

    static func trackCountOutcome(change: Int, from: Int, to: Int, confirmed: Bool) -> TrackCountOutcome {
        guard confirmed else { return .notConfirmed }
        let diff = to - from
        if diff == change { return .expected }
        if diff == 0 { return .unchanged }
        return diff.signum() == change.signum() ? .otherAmount : .opposite
    }

    // MARK: LEDs

    static func note(_ led: SurfaceLED) -> MCUButton {
        switch led {
        case .cycle: return .cycle
        case .click: return .click
        }
    }

    static func ledName(_ led: SurfaceLED) -> String {
        switch led {
        case .cycle: return "Cycle"
        case .click: return "Click (metronome)"
        }
    }

    private func runLED(_ command: LogicCommand, led: SurfaceLED, before: CommandState) async -> RunResult {
        let button = Self.note(led)
        let name = Self.ledName(led)
        func lit(_ surface: SurfaceState) -> Bool? { surface.led(button).map { $0 != .off } }
        let was = lit(await mcu.surface)
        await send(command)
        var evidence = [Self.sentEvidence(command)]
        guard let was else {
            _ = await mcu.waitUntil(timeout: timings.ledTimeout, pollEvery: timings.pollInterval) { $0.led(button) != nil }
            let after = await state()
            let now = lit(await mcu.surface)
            return RunResult(
                status: .unverified,
                summary: "Sent \(command.englishName). Logic had not reported the \(name) LED before, so a change cannot be shown"
                    + (now.map { "; it now shows \($0 ? "on" : "off")." } ?? "; it still has not reported it."),
                before: before, after: after, evidence: evidence, warnings: [Self.focusNote])
        }
        let changed = await mcu.waitUntil(timeout: timings.ledTimeout, pollEvery: timings.pollInterval) { surface in
            surface.led(button).map { $0 != .off } != was
        }
        let after = await state()
        let now = lit(await mcu.surface)
        guard let changed, let now else {
            let summary = "Sent \(command.englishName), but Logic's \(name) LED stayed \(was ? "on" : "off") for \(timings.ledTimeout.milliseconds) ms."
            if ledsSeenFollowing.contains(led) {
                // Logic has shown this effect on the LED before in this process: it did not run now.
                return RunResult(status: .failed, summary: summary, before: before, after: after, evidence: evidence,
                                 warnings: [Self.notSeenCauses(command)])
            }
            // That Logic reports a key command's change on this LED is not confirmed yet, so the
            // command may have run, and running it again would switch the setting back.
            return RunResult(
                status: .unverified, summary: summary, before: before, after: after, evidence: evidence,
                warnings: ["Either \(command.englishName) did not run, or Logic does not report its change on the \(name) LED of the Mackie Control surface (not yet confirmed on Logic 13, and not seen in this session). Check it in Logic's control bar before running \(command.id) again: if it did run, running it again switches it back.",
                           Self.notSeenCauses(command)])
        }
        ledsSeenFollowing.insert(led)
        evidence.append("mcu.led.\(led.rawValue)=\(now ? "on" : "off") after \(changed.milliseconds) ms")
        return RunResult(status: .verified, summary: "\(command.englishName): the \(name) LED went from \(was ? "on" : "off") to \(now ? "on" : "off").",
                         before: before, after: after, evidence: evidence)
    }

    // MARK: Playhead

    static let projectStart = BeatsPosition(bar: 1, beat: 1, division: 1, tick: 1)

    /// Lexicographic order of bars, beats, divisions and ticks.
    static func isEarlier(_ a: BeatsPosition, _ b: BeatsPosition) -> Bool {
        (a.bar, a.beat, a.division, a.tick) < (b.bar, b.beat, b.division, b.tick)
    }

    /// Whether moving from `from` to `to` is what `move` does.
    static func matches(_ move: PlayheadMove, from: BeatsPosition, to: BeatsPosition) -> Bool {
        switch move {
        case .toBeginning:
            return to == projectStart
        case .forwardOneBar:
            return to.bar == from.bar + 1 && isEarlier(from, to)
        case .rewindOneBar:
            let onBarLine = to.beat == 1 && to.division == 1 && to.tick == 1
            return isEarlier(to, from) && (to.bar == from.bar - 1 || (to.bar == from.bar && onBarLine))
        }
    }

    private func runPlayhead(_ command: LogicCommand, move: PlayheadMove, before: CommandState) async -> RunResult {
        guard before.playing == false else {
            await send(command)
            return RunResult(
                status: .unverified,
                summary: "Sent \(command.englishName) while Logic is playing (or its play state is unknown); the time display moves during playback, so the jump cannot be verified.",
                before: before, after: await state(), evidence: [Self.sentEvidence(command)], warnings: [Self.focusNote])
        }
        guard let from = before.position else {
            await send(command)
            return RunResult(
                status: .unverified,
                summary: "Sent \(command.englishName), but Logic's time display is not readable in Beats mode, so the new position cannot be verified. Switch the control surface clock display to Beats.",
                before: before, after: await state(), evidence: [Self.sentEvidence(command)], warnings: [Self.focusNote])
        }
        if from == Self.projectStart, move != .forwardOneBar {
            return RunResult(
                status: .verified,
                summary: "The playhead is already at 1 1 1 1" + (move == .rewindOneBar ? ", so it cannot move earlier" : "") + "; nothing sent.",
                before: before, after: before, evidence: ["time display \(from) before the call"],
                warnings: ["Nothing was sent, so this result does not show whether \(command.englishName) is learned for CC \(command.controller)."])
        }
        await send(command)
        let moved = await mcu.waitUntil(timeout: timings.playheadTimeout, pollEvery: timings.pollInterval) { $0.beatsPosition != from }
        guard let moved else {
            return RunResult(
                status: .failed,
                summary: "Sent \(command.englishName), but the time display stayed at \(from) for \(timings.playheadTimeout.milliseconds) ms.",
                before: before, after: await state(), evidence: [Self.sentEvidence(command)], warnings: [Self.notSeenCauses(command)])
        }
        await mcu.waitForTimecodeQuiet()
        let after = await state()
        var evidence = [Self.sentEvidence(command)]
        guard let to = after.position else {
            return RunResult(status: .unverified,
                             summary: "Sent \(command.englishName); the time display changed but became unreadable.",
                             before: before, after: after, evidence: evidence)
        }
        evidence.append("time display \(from) → \(to), first change after \(moved.milliseconds) ms")
        if Self.matches(move, from: from, to: to) {
            return RunResult(status: .verified, summary: "\(command.englishName): the playhead moved from \(from) to \(to).",
                             before: before, after: after, evidence: evidence)
        }
        return RunResult(
            status: .failed,
            summary: "Sent \(command.englishName), but the playhead moved from \(from) to \(to), which is not what it does.",
            before: before, after: after, evidence: evidence,
            warnings: ["The CC may be learned for a different command, or the playhead was moved in Logic at the same time."])
    }

    // MARK: Learn

    /// Sends `command`'s trigger once so that Logic can learn it while "Learn New Assignment" is
    /// armed. Sends nothing on the Mackie Control port: in learn mode Logic captures surface
    /// traffic too. If the trigger is already learned and learn mode is not armed, Logic runs the
    /// command, so destructive commands need `confirmed`. Refused while Logic is recording; sent
    /// with a warning when Logic has not reported its record state (learning is setup, possibly
    /// before the control surface works).
    public func learn(_ command: LogicCommand, confirmed: Bool) async -> LearnResult {
        await acquire()
        defer { release() }
        let before = await state()
        let report = LearnReport(
            command: command.id, englishName: command.englishName, japaneseName: command.verifiedJapaneseName,
            port: Self.portName, channel: Int(LogicCommand.channel) + 1, controller: Int(command.controller),
            message: command.message.bytes.hexString,
            steps: LearnGuide.steps(command, sendStep: "Once the button is armed, send the trigger: Claude calls learn_command (command: \(command.id)), or type learn \(command.id) in the console. The trigger is CC \(command.controller) (value 127, channel 16, port \(Self.portName)), sent once."),
            check: LearnGuide.afterSending(command))
        if before.recording == true {
            return LearnResult(status: .failed, summary: "Logic is recording; the learn trigger would be recorded as MIDI data. Stop first. Nothing was sent.",
                               after: report)
        }
        if command.destructive, !confirmed {
            return LearnResult(
                status: .needsConfirmation,
                summary: "If \(command.englishName) is already learned for CC \(command.controller) and \(LearnGuide.learnButton) is not armed, this trigger runs it: \(command.confirmationReason ?? "") Keep \(LearnGuide.learnButton) armed while confirming. Send the learn trigger?",
                after: report)
        }
        await send(command)
        var warnings = [Self.ranIfNotArmed(command)]
        if before.recording == nil { warnings.append(Self.unknownRecordStateWarning) }
        return LearnResult(
            status: .unverified,
            summary: "Sent the learn trigger for \(command.englishName) (CC \(command.controller), value 127, MIDI channel 16) once on \(Self.portName). Logic gives no feedback for learning: check the command's row in the Key Commands window.",
            after: report, evidence: [Self.sentEvidence(command)], warnings: warnings)
    }

    /// What Logic did with a learn trigger if learn mode was not armed.
    static func ranIfNotArmed(_ command: LogicCommand) -> String {
        let condition = "If \(LearnGuide.learnButton) was not armed and CC \(command.controller) is already learned, Logic ran \(command.englishName)"
        if case .notRunnable = command.verification {
            // Go to Position: the reason run_command refuses it.
            return condition + " and opened its dialog. Ask the user to close that dialog in Logic (Cancel) before using any other Logic tool: the server cannot close it, and while it is open Mackie Control input goes to the dialog."
        }
        return condition + "."
    }

    // MARK: Trigger

    /// Sends `command`'s trigger once without checking its effect (the console's `key`, for setup
    /// and diagnostics). Destructive commands need `confirmed`. Refused while Logic is recording;
    /// sent with a warning when Logic has not reported its record state, as for learning. Not
    /// recorded in `lastRuns`.
    public func trigger(_ command: LogicCommand, confirmed: Bool) async -> RunResult {
        await acquire()
        defer { release() }
        let before = await state()
        if before.recording == true, let refusal = Self.recordingRefusal(before) {
            return RunResult(status: .failed, summary: refusal + " Nothing was sent.", before: before)
        }
        if command.destructive, !confirmed {
            return RunResult(
                status: .needsConfirmation,
                summary: "\(command.confirmationReason ?? "\(command.englishName) is destructive.") Send the trigger for \(command.englishName)?",
                before: before)
        }
        await send(command)
        let warnings = before.recording == nil ? [Self.unknownRecordStateWarning] : []
        return RunResult(
            status: .unverified,
            summary: "Sent the trigger for \(command.englishName) once; its effect was not checked.",
            before: before, after: await state(), evidence: [Self.sentEvidence(command)], warnings: warnings)
    }

    // MARK: Helpers

    /// Sends one trigger and drops the mixer's cached track list: whatever the CC is learned for
    /// in Logic may have added, removed or reordered tracks.
    private func send(_ command: LogicCommand) async {
        await keys.sendKeyCommand(command, limits: limits)
        triggerSent = true
        await mixer?.invalidateLayout()
    }

    static func sentEvidence(_ command: LogicCommand) -> String {
        "sent \(command.message.bytes.hexString) (CC \(command.controller), channel 16) on \(portName)"
    }

    private func state() async -> CommandState {
        let surface = await mcu.surface
        let transport = TransportSnapshot.make(surface: surface, sync: await sync.snapshot())
        return CommandState(
            playing: transport.playing, recording: transport.recording, position: transport.position,
            display: transport.display,
            cycle: surface.led(.cycle).map { $0 != .off }, click: surface.led(.click).map { $0 != .off })
    }

    static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
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
