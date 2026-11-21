import Foundation
import MackieControl
import MIDICore

/// Track list and mixer control through the emulated Mackie Control surface (design §3.5, §3.6).
///
/// Everything it reports comes from Logic's own output: LCD text, LEDs and the fader positions
/// Logic sends. Which track a strip shows is derived only from moves made here and what the
/// surface shows afterwards: Option + Bank Left for the first page, then Channel Right one strip
/// at a time, each step checked against the strips it should have shifted in. Before anything is
/// changed, the position is proven from the strips' names and values (`StripKey`), not assumed
/// from the presses sent. It never presses Select.
public actor MixerController {
    public typealias ScanResult = OperationResult<TrackScan>
    public typealias SetResult = OperationResult<[TrackInfo]>

    private let mcu: MCUSession
    private let sync: SyncMonitor
    private let nameSource: (any TrackNameSource)?
    private let timings: MixerTimings
    private let clock = ContinuousClock()

    /// The last scan. Reused for `layoutReuse` while the surface still shows one of its pages.
    private var layout: Layout?
    /// Number of scans so far; each layout carries its own (`Layout.generation`).
    private var scans = 0
    /// Bank offset (index of the track on strip 1) after our own last proven move; nil when
    /// unknown. Only a hint: every use checks it against what the surface shows.
    private var offset: Int?
    /// Our own actions put temporary text over the track names until this time.
    private var upperOverlayUntil: ContinuousClock.Instant?
    /// Strips whose reported fader position is stale: we moved them and Logic showed the level
    /// but sent no echo. Value: `faderUpdates[strip]` at that time; any later position from
    /// Logic for the strip makes it trustworthy again.
    private var staleFaders: [Int: Int] = [:]
    /// Surprises while navigating, reported with the next result.
    private var navigationNotes: [String] = []
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    struct Layout {
        /// Strip readings in surface order, one per bank offset step: the first page's 8 strips
        /// followed by the strip each Channel Right shifted in. Includes trailing blank strips.
        var raw: [StripReading]
        /// The identity of every strip in `raw` (name and values), kept up to date with the
        /// values this controller sets. Used to prove which tracks the surface shows.
        var keys: [StripKey]
        /// Changes with every scan. A change checked against one layout is checked again before
        /// it is applied with a newer one.
        var generation: Int
        var trackCount: Int
        var infos: [TrackInfo]
        /// Why the track count is not confirmed (the scan could not see the end of the list);
        /// nil when it is. Without a confirmed end, pages outside the scan may look like scanned
        /// ones, so positions are then proven only by counted moves from the first page.
        var unconfirmed: String?
        /// How the scan confirmed what it counted (end of the list, runs of identical strips).
        var scanEvidence: [String] = []
        /// How many full names the name source listed at scan time (nil: none available).
        var fullNameCount: Int?
        /// Warnings from scanning itself (view changes, blank strips, restore problems).
        var scanNotes: [String]
        /// Warnings from matching full names to the LCD names.
        var mergeWarnings: [String] = []
        /// All warnings for this layout: scan notes, value caveats, name merge.
        var warnings: [String] = []
        var scannedAt: ContinuousClock.Instant
        var asOf: String

        var complete: Bool { unconfirmed == nil }
        var maxOffset: Int { max(0, keys.count - 8) }

        func names(atOffset offset: Int) -> [String] {
            (offset..<offset + 8).map { $0 < raw.count ? raw[$0].lcdName : "" }
        }

        func window(at offset: Int) -> [StripKey] {
            (offset..<offset + 8).map { $0 < keys.count ? keys[$0] : .blank }
        }

        /// Bank offsets whose scanned strips could be what `shown` is (all names equal, and
        /// every value that both sides know).
        func offsets(showing shown: [StripKey]) -> [Int] {
            (0...maxOffset).filter { StripKey.matches(window(at: $0), shown) }
        }

        func offsets(showingNames shown: [String]) -> [Int] {
            (0...maxOffset).filter { names(atOffset: $0) == shown }
        }

        func offsets(showing page: PageReading, by identify: Identify) -> [Int] {
            switch identify {
            case .strips: return offsets(showing: page.keys)
            case .names: return offsets(showingNames: page.names)
            }
        }

        /// No other bank offset of the layout looks the same.
        func isUnique(_ offset: Int, by identify: Identify) -> Bool {
            switch identify {
            case .strips: return offsets(showing: window(at: offset)) == [offset]
            case .names: return offsets(showingNames: names(atOffset: offset)) == [offset]
            }
        }
    }

    /// How a page of the surface is matched against a layout: by names and values (before
    /// anything is changed), or by names only (returning the surface to where it was after a
    /// scan, which may run during playback while automation changes the values).
    enum Identify { case strips, names }

    struct Failure: Error {
        var summary: String
        var warnings: [String] = []
        /// The surface no longer matches the scanned layout (tracks added, removed, reordered).
        var layoutChanged = false
    }

    public init(mcu: MCUSession, sync: SyncMonitor, names: (any TrackNameSource)?, timings: MixerTimings = MixerTimings()) {
        self.mcu = mcu
        self.sync = sync
        self.nameSource = names
        self.timings = timings
    }

    // MARK: Public operations

    /// Lists all tracks. Uses the last scan when `cachedLayout` accepts it, unless `refresh` is
    /// set; a new scan pages through the whole list and returns the surface to the bank position
    /// it started at. `unverified` when the end of the list could not be confirmed.
    public func tracks(refresh: Bool) async -> ScanResult {
        await acquire()
        defer { release() }
        if !refresh, let cached = await cachedLayout() {
            return Self.scanResult(cached, cached: true, notes: [])
        }
        do {
            let fresh = try await scan(restore: true)
            let notes = navigationNotes
            navigationNotes.removeAll()
            return Self.scanResult(fresh, cached: false, notes: notes)
        } catch let failure as Failure {
            return ScanResult(status: .failed, summary: failure.summary, warnings: failure.warnings)
        } catch {
            return ScanResult(status: .failed, summary: "\(error)")
        }
    }

    /// Forgets the last scan, so the next `tracks(refresh: false)` scans again. Called after a key
    /// command that may have added, removed or reordered tracks.
    public func invalidateLayout() async {
        await acquire()
        defer { release() }
        layout = nil
    }

    static func scanResult(_ layout: Layout, cached: Bool, notes: [String]) -> ScanResult {
        let scan = TrackScan(tracks: layout.infos, trackCount: layout.trackCount, asOf: layout.asOf, cached: cached)
        let source = cached ? "from the scan at \(layout.asOf); pass refresh to rescan" : "read from the control surface"
        var evidence = cached
            ? ["cached scan; the surface still shows one of its pages"]
            : ["paged through \(layout.raw.count) strip positions"]
        if !cached { evidence += layout.scanEvidence }
        if let reason = layout.unconfirmed {
            return ScanResult(status: .unverified,
                              summary: "\(layout.trackCount) tracks (\(source)), but the track count is not confirmed: \(reason)",
                              after: scan, evidence: evidence, warnings: layout.warnings + notes)
        }
        return ScanResult(status: .verified, summary: "\(layout.trackCount) tracks (\(source)).",
                          after: scan, evidence: evidence, warnings: layout.warnings + notes)
    }

    /// Applies mixer changes, each verified against Logic's feedback. Only while Logic is
    /// stopped: during playback a touched fader can write automation (design §3.6). The
    /// transport is checked again right before every press, fader touch and V-Pot tick.
    public func set(_ changes: [MixerChange]) async -> SetResult {
        await acquire()
        defer { release() }
        var warnings: [String] = [Self.automationNote]
        guard !changes.isEmpty else {
            return SetResult(status: .failed, summary: "No changes given. Nothing was sent.")
        }
        for change in changes {
            if let problem = Self.validate(change) {
                return SetResult(status: .failed, summary: problem + " Nothing was sent.", warnings: warnings)
            }
        }
        if let problem = await notStopped() {
            return SetResult(status: .failed, summary: problem + " Nothing was sent.", warnings: warnings)
        }

        let current: Layout
        do {
            try await ensureConnected()
            warnings += try await ensureView()
            if let cached = await cachedLayout() {
                current = cached
                warnings += cached.mergeWarnings
            } else {
                current = try await scan(restore: false)
                warnings += current.scanNotes + current.mergeWarnings
            }
            if let reason = current.unconfirmed {
                warnings.append("The track count is not confirmed: \(reason)")
            }
        } catch let failure as Failure {
            return SetResult(status: .failed, summary: failure.summary, warnings: warnings + failure.warnings)
        } catch {
            return SetResult(status: .failed, summary: "\(error)", warnings: warnings)
        }

        // Every target must exist and match its expected name before anything is changed.
        for change in changes {
            switch Self.validate(change, in: current) {
            case .failure(let failure):
                return SetResult(status: .failed, summary: failure.summary + " No mixer value was changed.", warnings: warnings)
            case .success(let note):
                if let note { warnings.append(note) }
            }
        }

        var before: [TrackInfo] = []
        var after: [TrackInfo] = []
        var evidence: [String] = []
        var verified = 0
        var failed = 0
        for (index, change) in changes.enumerated() {
            if let problem = await notStopped() {
                let remaining = changes[index...].map { "track \($0.track)" }.joined(separator: ", ")
                warnings.append("\(problem) Not applied: \(remaining).")
                failed += changes[index...].count
                break
            }
            do {
                let outcome = try await apply(change, validatedGeneration: current.generation)
                before.append(outcome.before)
                after.append(outcome.after)
                evidence += outcome.evidence
                warnings += outcome.warnings
                verified += outcome.verified
                failed += outcome.failed
            } catch let failure as Failure {
                warnings.append("Track \(change.track): \(failure.summary)")
                warnings += failure.warnings
                failed += 1
            } catch {
                warnings.append("Track \(change.track): \(error)")
                failed += 1
            }
        }

        warnings += navigationNotes
        navigationNotes.removeAll()
        let status: OperationResult<[TrackInfo]>.Status
        let summary: String
        switch (verified, failed) {
        case (_, 0):
            status = .verified
            summary = "All \(verified) change(s) confirmed by Logic."
        case (0, _):
            status = .failed
            summary = "No change was confirmed by Logic (\(failed) failed); see warnings. The after state is what Logic last reported."
        default:
            status = .partial
            summary = "\(verified) change(s) confirmed, \(failed) failed; see evidence and warnings."
        }
        return SetResult(status: status, summary: summary, before: before, after: after, evidence: evidence, warnings: warnings)
    }

    // MARK: Record arm

    public typealias RecordArmResult = OperationResult<[RecordArmState]>

    /// Watches every track's Rec LED for `window` (default `timings.recordArmWindow`), one page
    /// of eight strips at a time, starting with Option + Bank Left: Logic redraws the strips
    /// then, which also re-sends the selected track's steady LED (Logic 13 does not send it when
    /// the last armed track is disarmed). Only while stopped (while recording Logic shows armed
    /// tracks steadily). Returns the surface to the page it showed.
    public func readRecordArms(window: Duration? = nil) async -> RecordArmResult {
        await acquire()
        defer { release() }
        let window = window ?? timings.recordArmWindow
        if let problem = await notStopped() {
            return RecordArmResult(status: .failed, summary: problem.replacingOccurrences(of: "mixer changes only run", with: "Rec LEDs are only read") + " Nothing was sent.")
        }
        do {
            try await ensureConnected()
            var warnings = try await ensureView()
            let current: Layout
            if let cached = await cachedLayout() {
                current = cached
            } else {
                current = try await scan(restore: false)
                warnings += current.scanNotes
            }
            if let reason = current.unconfirmed {
                throw Failure(summary: "The track count is not confirmed (\(reason)), so not every track's Rec LED can be watched.")
            }
            let original = await readPage(namesMatter: true)
            var lights = [RecordArmLight?](repeating: nil, count: current.trackCount)
            var evidence: [String] = []
            var first = 0
            while first < current.trackCount {
                let target = min(first, current.maxOffset)
                if target == 0 {
                    await goToFirstPage()
                    guard await locate(current, .strips, expecting: 0).contains(0) else {
                        offset = nil
                        throw Failure(summary: "After Option + Bank Left the surface shows \(Self.describe(PageReading.read(await mcu.surface).names)) instead of the scanned first page.", layoutChanged: true)
                    }
                } else {
                    try await move(toOffset: target, layout: current)
                }
                await settle()
                let tracks = first..<min(target + 8, current.trackCount)
                let names = PageReading.read(await mcu.surface).names
                var seenOn = Set<Int>(), seenOff = Set<Int>()
                let deadline = clock.now.advanced(by: window)
                repeat {
                    let surface = await mcu.surface
                    guard PageReading.read(surface).names == names else {
                        throw Failure(summary: "The surface changed while the Rec LEDs of tracks \(tracks.lowerBound + 1)–\(tracks.upperBound) were watched (\(Self.describe(PageReading.read(surface).names))).", layoutChanged: true)
                    }
                    for track in tracks {
                        switch surface.led(MCUButton.recArm(track - target)) {
                        case .on?: seenOn.insert(track)
                        case .off?: seenOff.insert(track)
                        case .flashing?: seenOn.insert(track); seenOff.insert(track)
                        case nil: break
                        }
                    }
                    try? await clock.sleep(for: timings.pollInterval)
                } while clock.now < deadline
                for track in tracks {
                    switch (seenOn.contains(track), seenOff.contains(track)) {
                    case (true, true): lights[track] = .alternating
                    case (true, false): lights[track] = .steady
                    case (false, true): lights[track] = .off
                    case (false, false): lights[track] = nil
                    }
                }
                evidence.append("watched the Rec LEDs of tracks \(tracks.lowerBound + 1)–\(tracks.upperBound) for \(window.milliseconds) ms")
                first = target + 8
            }
            warnings += await restorePosition(original: original, layout: current)
            warnings += navigationNotes
            navigationNotes.removeAll()
            let states = current.infos.enumerated().map { index, info in
                RecordArmState(track: info.number, name: info.name, light: lights[index])
            }
            let unknown = states.filter { $0.light == nil }.map(\.track)
            if !unknown.isEmpty {
                warnings.append("Logic sent no Rec LED for track(s) \(unknown.map(String.init).joined(separator: ", ")).")
            }
            let armed = states.filter { $0.light == .alternating }.map(\.track)
            let steady = states.filter { $0.light == .steady }.map(\.track)
            let summary = armed.isEmpty
                ? (steady.isEmpty ? "No track is record-armed or record-enabled." : "No track is armed; track(s) \(steady.map(String.init).joined(separator: ", ")) show a steady Rec LED (the selected track, record-enabled automatically).")
                : "Record-armed (blinking Rec LED): track(s) \(armed.map(String.init).joined(separator: ", "))."
            return RecordArmResult(status: .verified, summary: summary, after: states, evidence: evidence, warnings: warnings)
        } catch let failure as Failure {
            if failure.layoutChanged { layout = nil }
            return RecordArmResult(status: .failed, summary: failure.summary, warnings: failure.warnings)
        } catch {
            return RecordArmResult(status: .failed, summary: "\(error)")
        }
    }

    /// Presses the track's Rec button once, after bringing it into view and checking its
    /// name. Does not verify the new state: one look at the LED cannot tell it (see
    /// `RecordArmLight`), and disarming during the LED's off phase changes no LED at all.
    /// Callers watch the LEDs with `readRecordArms` afterwards. `verified` means Logic answered
    /// with a Rec LED message for the strip; `failed` means nothing was pressed.
    public func pressRecordArm(track: Int, expectedName: String?) async -> OperationResult<RecordArmPress> {
        await acquire()
        defer { release() }
        typealias Result = OperationResult<RecordArmPress>
        if let problem = await notStopped() {
            return Result(status: .failed, summary: problem.replacingOccurrences(of: "mixer changes only run", with: "Rec buttons are only pressed") + " Nothing was sent.")
        }
        do {
            try await ensureConnected()
            var warnings = try await ensureView()
            var current: Layout
            if let cached = await cachedLayout() {
                current = cached
            } else {
                current = try await scan(restore: false)
                warnings += current.scanNotes
            }
            let check = MixerChange(track: track, expectedName: expectedName)
            switch Self.validate(check, in: current) {
            case .failure(let failure): throw Failure(summary: failure.summary + " Nothing was pressed.")
            case .success(let note): if let note { warnings.append(note) }
            }
            let strip: Int
            do {
                strip = try await bringIntoView(track: track, layout: current)
            } catch let failure as Failure where failure.layoutChanged {
                current = try await scan(restore: false)
                try Self.recheck(check, in: current, notes: &warnings, after: "rescanning (the track list changed)")
                strip = try await bringIntoView(track: track, layout: current)
            }
            if let problem = await notStopped() {
                throw Failure(summary: problem.replacingOccurrences(of: "mixer changes only run", with: "Rec buttons are only pressed") + " Nothing was pressed.")
            }
            let note = MCUButton.recArm(strip)
            let ledBefore = await mcu.surface.led(note)
            let revision = await mcu.surface.ledRevision
            await pressButton(note)
            // Any Rec LED message for this strip shows Logic handled the press.
            var answered = false
            let deadline = clock.now.advanced(by: timings.ledTimeout)
            var seen = revision
            while clock.now < deadline {
                let surface = await mcu.surface
                if surface.ledRevision != seen {
                    seen = surface.ledRevision
                    if surface.led(note) != ledBefore { answered = true; break }
                }
                try? await clock.sleep(for: timings.pollInterval)
            }
            let ledAfter = await mcu.surface.led(note)
            let name = current.infos[track - 1].name
            let label = "track \(track) \(ProjectText.quoted(name))"
            let press = RecordArmPress(track: track, name: name, ledBefore: ledBefore.map(Self.ledText), ledAfter: ledAfter.map(Self.ledText))
            if answered {
                return Result(status: .verified, summary: "Pressed Rec on \(label); its LED went \(press.ledBefore ?? "unknown") → \(press.ledAfter ?? "unknown").",
                              after: press, evidence: ["\(label) Rec pressed: mcu.led.recArm[\(strip + 1)] \(press.ledBefore ?? "?") → \(press.ledAfter ?? "?")"], warnings: warnings)
            }
            return Result(status: .unverified, summary: "Pressed Rec on \(label); Logic sent no LED change within \(timings.ledTimeout.milliseconds) ms (normal when disarming during the LED's off phase).",
                          after: press, evidence: ["\(label) Rec pressed: no LED message (LED \(press.ledBefore ?? "?"))"], warnings: warnings)
        } catch let failure as Failure {
            if failure.layoutChanged { layout = nil }
            return Result(status: .failed, summary: failure.summary, warnings: failure.warnings)
        } catch {
            return Result(status: .failed, summary: "\(error)")
        }
    }

    static func ledText(_ state: MCULEDState) -> String {
        switch state {
        case .on: "on"
        case .off: "off"
        case .flashing: "flashing"
        }
    }

    /// The target exists in `layout` and passes `checkName`.
    static func validate(_ change: MixerChange, in layout: Layout) -> Result<String?, Failure> {
        guard change.track <= layout.trackCount else {
            return .failure(Failure(summary: "Track \(change.track) does not exist: the surface shows \(layout.trackCount) tracks."))
        }
        return checkName(change, layout.infos[change.track - 1])
    }

    /// Checks `expected_name`; success carries an optional note about a weak (LCD-only) check.
    static func checkName(_ change: MixerChange, _ info: TrackInfo) -> Result<String?, Failure> {
        guard let expected = change.expectedName else { return .success(nil) }
        let full = info.nameSource == .accessibility ? info.name : nil
        switch TrackNameMerge.check(expected: expected, lcdName: info.lcdName, fullName: full) {
        case .matchesFullName:
            return .success(nil)
        case .matchesLCDOnly:
            return .success("Track \(change.track): \"\(expected)\" was checked only against the LCD abbreviation \"\(info.lcdName)\" (no full name available).")
        case .uncheckable(let detail), .mismatch(let detail):
            return .failure(Failure(summary: "Track \(change.track) name check failed: \(detail)."))
        }
    }

    static let automationNote = "Values changed while stopped are overridden during playback if the track has automation for them in Read mode (or another automation mode); Mackie Control cannot read a track's automation mode."

    static func validate(_ change: MixerChange) -> String? {
        guard change.track >= 1 else { return "Track numbers start at 1 (got \(change.track))." }
        guard !change.isEmpty else { return "Track \(change.track): give at least one of volume_db, pan, mute, solo." }
        if let volume = change.volume, FaderCalibration.position(for: volume) == nil {
            return "Track \(change.track): volume_db must be between \(FaderCalibration.minFiniteDB) and +\(FaderCalibration.maxDB) dB, or \"-inf\" (got \(volume))."
        }
        if let pan = change.pan, !(-64...63).contains(pan) {
            return "Track \(change.track): pan must be between -64 and +63 (got \(pan))."
        }
        return nil
    }

    // MARK: Serialisation

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

    // MARK: Preconditions

    private func ensureConnected() async throws {
        let link = await mcu.linkStatus()
        guard !link.surfaceActive else { return }
        let detail = link.messagesReceived == 0
            ? "Logic has not sent anything to the LogicMCP MCU port."
            : "Logic has only probed the LogicMCP MCU port but has not driven its display or LEDs, so no Mackie Control surface is installed on it."
        throw Failure(summary: detail + " Set up a Mackie Control surface on the LogicMCP MCU ports (docs/setup). Nothing was sent.")
    }

    /// nil when Logic reports that it is stopped; otherwise why mixer changes are refused.
    private func notStopped() async -> String? {
        let transport = TransportSnapshot.make(surface: await mcu.surface, sync: await sync.snapshot())
        if transport.recording == true || transport.playing == true {
            return "Logic is playing or recording; mixer changes only run while stopped (a touched fader can write automation during playback)."
        }
        if transport.playing == nil {
            return "Logic has not reported its transport state (Play LED or MIDI clock), so it cannot be confirmed that Logic is stopped."
        }
        return nil
    }

    /// Puts the surface into the multi-track Pan view with values on the lower line.
    /// Returns warnings describing any change made.
    private func ensureView() async throws -> [String] {
        var notes: [String] = []
        var view = SurfaceViewState.read(await mcu.surface)
        guard view.assignmentKnown else {
            throw Failure(summary: "Logic has not reported the control surface's assignment display, so the surface mode is unknown. Nothing was sent.")
        }
        if let flip = view.flip, flip != .off {
            throw Failure(summary: "Flip mode is on (the faders would control a different parameter). Turn it off on the surface (console: press flip) and try again. Nothing was sent.")
        }
        if let global = view.globalView, global == .on {
            throw Failure(summary: "Global View is on, so the strips do not show the plain track list. Turn it off (console: press globalView) and try again. Nothing was sent.")
        }
        var pressed = 0
        while !view.isMultiTrackPan {
            guard pressed < 2 else {
                throw Failure(summary: "After pressing Pan \(pressed) times the assignment display shows \"\(view.assignment)\" instead of \"PN\".")
            }
            let from = view.assignment
            // Only pressed when the view is not already "PN": pressing Pan in the multi-track
            // Pan view is not observed and may switch to the channel view.
            await pressButton(MCUButton.assignPan.rawValue)
            pressed += 1
            upperOverlayUntil = clock.now.advanced(by: timings.overlayHold)
            // Logic shows an intermediate state at press-down (assignment "P_", surround
            // labels); the multi-track page follows after release.
            _ = await mcu.waitUntil(timeout: timings.moveTimeout, pollEvery: timings.pollInterval) {
                SurfaceViewState.read($0).isMultiTrackPan
            }
            await settle()
            view = SurfaceViewState.read(await mcu.surface)
            notes.append("Switched the control surface from the \"\(from)\" view to the multi-track Pan view (\"\(view.assignment)\").")
        }
        let page = PageReading.read(await mcu.surface)
        if page.showsParameterNames {
            let revision = await mcu.surface.lcdRevision
            await pressButton(MCUButton.nameValue.rawValue)
            _ = await mcu.waitUntil(timeout: timings.moveTimeout, pollEvery: timings.pollInterval) { $0.lcdRevision != revision }
            await settle()
            guard !PageReading.read(await mcu.surface).showsParameterNames else {
                throw Failure(summary: "The lower LCD line still shows parameter names after pressing Name/Value, so pan values cannot be read.", warnings: notes)
            }
            notes.append("Switched the control surface's lower LCD line from parameter names to values (Name/Value).")
        }
        return notes
    }

    // MARK: Scanning

    /// The last scan when it can be reused: younger than `layoutReuse`, the name source lists as
    /// many names as it did at scan time, and the surface shows one of its pages (by LCD names).
    /// Full names are merged again. nil means: scan again. Values and positions are not checked
    /// here; every navigation proves them before anything is changed.
    private func cachedLayout() async -> Layout? {
        guard var cached = layout, clock.now - cached.scannedAt < timings.layoutReuse else { return nil }
        let full = await readFullNames()
        // A different count means tracks were added or removed since the scan, or the name
        // source now sees a different part of the list.
        guard full.names?.count == cached.fullNameCount else { return nil }
        guard await surfaceShowsPage(of: cached) else { return nil }
        let merged = TrackNameMerge.merge(lcd: cached.infos.map(\.lcdName), full: full)
        for index in cached.infos.indices {
            cached.infos[index].name = merged.names[index].name
            cached.infos[index].nameSource = merged.names[index].source
        }
        cached.mergeWarnings = merged.warnings
        cached.warnings = cached.scanNotes + Self.scanWarnings(cached) + merged.warnings
        layout = cached
        return cached
    }

    /// True when the upper LCD line shows the names of some page of `layout` (after our own
    /// temporary text over the names is gone).
    private func surfaceShowsPage(of layout: Layout) async -> Bool {
        if !layout.offsets(showingNames: PageReading.read(await mcu.surface).names).isEmpty { return true }
        guard let until = upperOverlayUntil, clock.now < until else { return false }
        try? await clock.sleep(until: until)
        await settle()
        return !layout.offsets(showingNames: PageReading.read(await mcu.surface).names).isEmpty
    }

    private func readFullNames() async -> TrackNameList {
        guard let nameSource else { return .unavailable("no full-name source is configured") }
        return await nameSource.trackNames()
    }

    enum StepOutcome { case shifted, unchanged, unchangedIdentical, unexpected }

    /// Pages through every track. Throws when the surface does not behave as derived (e.g. the
    /// track list changed during the scan) or when Logic does not show that it is handling the
    /// surface's buttons.
    private func scan(restore: Bool) async throws -> Layout {
        try await ensureConnected()
        var warnings = try await ensureView()
        let original = await readPage(namesMatter: true)

        await goToFirstPage()
        var page = await readPage(namesMatter: true)
        var raw = page.strips
        var keys = page.keys
        var steps = 0
        var reachedEnd = false
        var ambiguousEnd = false
        var scanEvidence: [String] = []
        scanning: while raw.count < timings.maxTracks {
            _ = await pressAndSettle(MCUButton.channelRight.rawValue, expectChange: true)
            let next = await readPage(namesMatter: false)
            switch Self.classify(old: page, new: next) {
            case .shifted:
                steps += 1
                raw.append(next.strips[7])
                keys.append(next.keys[7])
                page = next
            case .unchanged:
                reachedEnd = true
                break scanning
            case .unchangedIdentical where !page.strips.contains(where: { !$0.isBlank }):
                // Nothing but blank strips (no tracks): nothing could come in.
                reachedEnd = true
                break scanning
            case .unchangedIdentical:
                // Eight identical strips: a one-strip shift is invisible until a different strip
                // (or the blank after the last track) comes in. Keep pressing. Once the page
                // changes, every press before it moved one strip as well: Logic handles the
                // buttons in order, and no move follows the end of the list.
                var hidden = 1
                while hidden < timings.identicalRunProbe, raw.count + hidden < timings.maxTracks {
                    _ = await pressAndSettle(MCUButton.channelRight.rawValue, expectChange: true)
                    let probe = await readPage(namesMatter: false)
                    switch Self.classify(old: page, new: probe) {
                    case .unchangedIdentical, .unchanged:
                        hidden += 1
                        continue
                    case .shifted:
                        raw += Array(repeating: page.strips[7], count: hidden) + [probe.strips[7]]
                        keys += Array(repeating: page.keys[7], count: hidden) + [probe.keys[7]]
                        scanEvidence.append("tracks \(raw.count - hidden)–\(raw.count - 1) look the same as the 8 tracks before them on the LCD: \(hidden) Channel Right press(es) showed no change and were confirmed by the visible shift after them (Logic handles the buttons in order)")
                        steps += hidden + 1
                        page = probe
                        continue scanning
                    case .unexpected:
                        offset = nil
                        throw Failure(summary: "The surface did not shift by one strip after Channel Right (before: \(Self.describe(page.names)); after: \(Self.describe(probe.names))). The track list may have changed during the scan, or Logic redrew the display; try again.", warnings: warnings)
                    }
                }
                ambiguousEnd = true
                break scanning
            case .unexpected:
                offset = nil
                throw Failure(summary: "The surface did not shift by one strip after Channel Right (before: \(Self.describe(page.names)); after: \(Self.describe(next.names))). The track list may have changed during the scan, or Logic redrew the display; try again.", warnings: warnings)
            }
        }

        // "No change after Channel Right" also happens when Logic ignores the surface (a modal
        // dialog, Logic busy): the end counts only after Logic visibly handled a later button.
        var unconfirmed: String?
        if ambiguousEnd {
            // The press may or may not have moved the surface.
            offset = nil
            unconfirmed = "the last page showed 8 strips with the same name and values and did not change after \(timings.identicalRunProbe) presses of Channel Right, so the surface cannot tell whether more such tracks follow (a long run of tracks that look the same on the LCD, at the end of the list or longer than the probe). track_count may be too low."
        } else if !reachedEnd {
            offset = steps
            unconfirmed = "stopped at the safety limit of \(timings.maxTracks) strips."
        } else if steps > 0 {
            offset = steps
            try await confirmEnd(endPage: page, raw: raw, steps: steps, warnings: warnings)
            scanEvidence.append("end of the list: Channel Right showed no change, then Channel Left moved back one strip and Channel Right forward again")
        } else if !page.strips.contains(where: { !$0.isBlank }) {
            offset = 0
            unconfirmed = "the surface shows no track at all, so it cannot be confirmed that Logic is handling the surface's buttons."
        } else {
            offset = 0
            if let problem = await nameValueAcknowledged(page: page) {
                offset = nil
                throw Failure(summary: "Logic did not react to the control surface: Channel Right showed no change, and \(problem). Possible causes: a modal dialog in Logic, Logic busy, or the surface is bypassed. The track list is not reported; try again.", warnings: warnings)
            }
            scanEvidence.append("end of the list: Channel Right showed no change on the first page, and Logic then answered Name/Value")
        }

        var count = raw.count
        while count > 0, raw[count - 1].isBlank { count -= 1 }
        let blanks = (0..<count).filter { raw[$0].isBlank }.map { $0 + 1 }
        if !blanks.isEmpty {
            warnings.append("Track(s) \(blanks.map(String.init).joined(separator: ", ")) show neither an LCD name nor a value but are followed by further tracks, so they are counted as tracks (a name made only of non-ASCII characters shows as blank).")
        }

        let full = await readFullNames()
        if ambiguousEnd, let listed = full.names?.count, listed > count {
            unconfirmed = (unconfirmed ?? "") + " Accessibility lists \(listed) tracks."
        }
        let lcdNames = (0..<count).map { raw[$0].lcdName }
        let merged = TrackNameMerge.merge(lcd: lcdNames, full: full)
        var infos: [TrackInfo] = []
        for index in 0..<count {
            infos.append(Self.info(number: index + 1, reading: raw[index], name: merged.names[index]))
        }

        scans += 1
        var result = Layout(raw: raw, keys: keys, generation: scans, trackCount: count, infos: infos,
                            unconfirmed: unconfirmed, scanEvidence: scanEvidence, fullNameCount: full.names?.count,
                            scanNotes: warnings, scannedAt: clock.now, asOf: OperationResult<TrackScan>.timestamp())
        if restore {
            result.scanNotes += await restorePosition(original: original, layout: result)
        }
        result.mergeWarnings = merged.warnings
        result.warnings = result.scanNotes + Self.scanWarnings(result) + merged.warnings
        layout = result
        return result
    }

    /// The end of the list was inferred from Channel Right showing no change. Logic must move
    /// back one strip with Channel Left and forward again with Channel Right. Logic handles the
    /// surface's buttons in order, so this also shows it handled the last Channel Right.
    private func confirmEnd(endPage: PageReading, raw: [StripReading], steps: Int, warnings: [String]) async throws {
        _ = await pressAndSettle(MCUButton.channelLeft.rawValue, expectChange: true)
        let back = await readPage(namesMatter: false)
        guard Self.classify(old: back, new: endPage) == .shifted, back.names[0] == raw[steps - 1].lcdName else {
            offset = nil
            throw Failure(summary: "Could not confirm the end of the track list: Channel Right showed no change, but then Channel Left showed \(Self.describe(back.names)) instead of the page one strip back (\(Self.describe([raw[steps - 1].lcdName] + Array(endPage.names[0..<7])))). Logic may not be handling the control surface (a modal dialog open, or Logic busy), so the track list is not reported. Try again.", warnings: warnings)
        }
        offset = steps - 1
        _ = await pressAndSettle(MCUButton.channelRight.rawValue, expectChange: true)
        let again = await readPage(namesMatter: false)
        guard Self.classify(old: back, new: again) == .shifted, again.names == endPage.names else {
            offset = nil
            throw Failure(summary: "Could not confirm the end of the track list: after Channel Left, Channel Right showed \(Self.describe(again.names)) instead of the last page \(Self.describe(endPage.names)). Logic may not be handling the control surface reliably, so the track list is not reported. Try again.", warnings: warnings)
        }
        offset = steps
    }

    /// Shows that Logic handled every button pressed so far: Name/Value must switch the lower
    /// LCD line of `page` to parameter names and back (observed), with the same names above.
    /// Logic handles the surface's buttons in order, so this also confirms the presses before
    /// it. nil when it did; otherwise what the LCD showed instead.
    private func nameValueAcknowledged(page: PageReading) async -> String? {
        _ = await pressAndSettle(MCUButton.nameValue.rawValue, expectChange: true)
        let shown = PageReading.read(await mcu.surface)
        guard shown.showsParameterNames, shown.names == page.names else {
            if shown.showsParameterNames {
                _ = await pressAndSettle(MCUButton.nameValue.rawValue, expectChange: true)
            }
            return "after Name/Value the LCD shows \(Self.describe(shown.names)) above \"\(shown.strips.map(\.valueText).joined(separator: " "))\" instead of the same tracks with parameter names below"
        }
        _ = await pressAndSettle(MCUButton.nameValue.rawValue, expectChange: true)
        let back = PageReading.read(await mcu.surface)
        guard !back.showsParameterNames, back.names == page.names else {
            return "after Name/Value was pressed again the LCD shows \(Self.describe(back.names)) with \(back.showsParameterNames ? "parameter names" : "values") below instead of the same tracks with values"
        }
        return nil
    }

    static func classify(old: PageReading, new: PageReading) -> StepOutcome {
        let oldNames = old.names, newNames = new.names
        if newNames != oldNames {
            return Array(newNames[0..<7]) == Array(oldNames[1..<8]) ? .shifted : .unexpected
        }
        // Same names. A one-strip shift can only leave them unchanged if all eight are equal.
        guard Set(oldNames).count == 1 else { return .unchanged }
        let oldPrints = old.fingerprints, newPrints = new.fingerprints
        if newPrints == oldPrints {
            return Set(oldPrints).count == 1 ? .unchangedIdentical : .unchanged
        }
        return Array(newPrints[0..<7]) == Array(oldPrints[1..<8]) ? .shifted : .unexpected
    }

    static func scanWarnings(_ layout: Layout) -> [String] {
        var warnings: [String] = []
        if let reason = layout.unconfirmed {
            warnings.append("The track count is not confirmed: \(reason)")
        }
        let unreadablePan = layout.infos.filter { $0.pan == nil }.map(\.number)
        if !unreadablePan.isEmpty {
            warnings.append("Pan could not be read for track(s) \(unreadablePan.map(String.init).joined(separator: ", ")) (the LCD did not show a pan value).")
        }
        let ambiguousLEDs = layout.infos.filter { $0.mute == nil || $0.solo == nil }.map(\.number)
        if layout.infos.contains(where: { $0.solo == true }) {
            warnings.append("A track is soloed: Logic blinks the mute LEDs of the other tracks, so every track's mute value is null until solo is off.")
        } else if !ambiguousLEDs.isEmpty {
            warnings.append("Mute/solo LEDs for track(s) \(ambiguousLEDs.map(String.init).joined(separator: ", ")) were flashing or never reported; those values are null.")
        }
        if !layout.infos.isEmpty {
            warnings.append("volume_db is converted from the fader position Logic reports using the Logic 13 calibration table; between calibration points it is interpolated (approximate).")
        }
        return warnings
    }

    static func info(number: Int, reading: StripReading, name: ResolvedTrackName) -> TrackInfo {
        TrackInfo(
            number: number,
            name: name.name,
            nameSource: name.source,
            lcdName: reading.lcdName,
            // Only from the fader position: dB text on the LCD may belong to a track that was on
            // this strip before a bank move.
            volumeDb: reading.fader.map { FaderCalibration.level(forPosition: Int($0)) },
            faderPosition: reading.fader.map(Int.init),
            pan: reading.pan,
            mute: reading.mute?.asBool,
            solo: reading.solo?.asBool
        )
    }

    static func describe(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Returns the surface to the page it showed before the scan, found by matching that page
    /// against the scanned strips. Best effort, by names (the scan may run during playback):
    /// problems become warnings.
    private func restorePosition(original: PageReading, layout: Layout) async -> [String] {
        var candidates = layout.offsets(showingNames: original.names)
        if candidates.count > 1 {
            candidates = candidates.filter { StripKey.matches(layout.window(at: $0), original.keys) }
        }
        guard candidates.count == 1, let target = candidates.first else {
            let at = offset.map { "at track \($0 + 1)" } ?? "where the scan ended"
            return ["Could not tell which bank position the surface showed before the scan (\(candidates.isEmpty ? "no" : "several") matching positions); it was left \(at)."]
        }
        if offset == target { return [] }
        do {
            try await move(toOffset: target, layout: layout, identify: .names)
            return []
        } catch let failure as Failure {
            return ["Could not return the surface to its original bank position: \(failure.summary)"]
        } catch {
            return ["Could not return the surface to its original bank position: \(error)"]
        }
    }

    // MARK: Navigation

    /// Option + Bank Left: the first page (observed from the first and the last page).
    private func goToFirstPage() async {
        await mcu.send([.button(note: MCUButton.option.rawValue, pressed: true)])
        _ = await pressAndSettle(MCUButton.bankLeft.rawValue, expectChange: false)
        await mcu.send([.button(note: MCUButton.option.rawValue, pressed: false)])
        // Logic flashes Global View while Option is held. Right after New Audio Track it handled
        // the release only after a Channel Right sent 65 ms later, which then acted as Option +
        // Channel Right and jumped to the last page (observed 2026-11-21). So the next press
        // waits until Logic shows that it handled the release.
        if await mcu.surface.led(.globalView) == .flashing {
            _ = await mcu.waitUntil(timeout: timings.moveTimeout, pollEvery: timings.pollInterval) {
                $0.led(.globalView) != .flashing
            }
        }
        await settle()
        offset = 0
    }

    /// Moves so that strip 1 shows track `target + 1`, proving the position from what the
    /// surface shows. A page proves its bank offset when no other offset of a complete layout
    /// looks the same. Otherwise counted moves prove it: from the first page, a Channel Right
    /// that visibly leaves the page it started from for one that fits the next offset shows that
    /// Logic handled it and every press before it (it handles the surface's buttons in order),
    /// and that none of them hit the end of the list, so each moved one strip. A step that shows
    /// no change (identical pages) is proven by a later visible step, or else by a Name/Value
    /// acknowledgement at the end (`nameValueAcknowledged`): every press before it was handled,
    /// and none of them was past the end of the scanned list, so each moved one strip. The same
    /// acknowledgement proves Option + Bank Left when the first page looks like another page.
    /// Bank Right (a jump of 8, observed only from the first page) is used only where its landing
    /// page is unique.
    private func move(toOffset target: Int, layout: Layout, identify: Identify = .strips,
                      startAt known: [Int]? = nil, allowBank: Bool = true) async throws {
        var current: Int
        var proven: Bool
        let found: [Int]
        if let known { found = known } else { found = await locate(layout, identify, expecting: offset) }
        if layout.complete, found.count == 1, let start = found.first, start <= target {
            current = start
            proven = true
        } else {
            await goToFirstPage()
            let first = await locate(layout, identify, expecting: 0)
            guard first.contains(0) else {
                offset = nil
                throw Failure(summary: "After Option + Bank Left the surface shows \(Self.describe(PageReading.read(await mcu.surface).names)) instead of the scanned first page \(Self.describe(layout.names(atOffset: 0))).", layoutChanged: true)
            }
            current = 0
            proven = layout.complete && first == [0]
        }
        while current < target {
            let bank = allowBank && layout.complete && current % 8 == 0 && target - current >= 8
                && current + 16 <= layout.trackCount && layout.isUnique(current + 8, by: identify)
            let next = bank ? current + 8 : current + 1
            _ = await pressAndSettle(bank ? MCUButton.bankRight.rawValue : MCUButton.channelRight.rawValue, expectChange: true)
            let shown = await locate(layout, identify, expecting: next)
            let unique = layout.complete && shown == [next]
            let visible = !bank && shown.contains(next) && !shown.contains(current)
            if unique || visible {
                current = next
                proven = true
                continue
            }
            if !bank, shown.contains(next) {
                // The page fits, but so does the one before (identical pages): whether this press
                // moved shows only through a later step.
                current = next
                proven = false
                continue
            }
            offset = nil
            if bank {
                // Bank Right did not land on the expected page (not observed mid-list): page with
                // Channel Right only, which the scan itself relies on.
                navigationNotes.append("Bank Right from track \(current + 1) did not show the expected page; used Channel Right instead (please report: docs/checklists/phase-2.md).")
                try await move(toOffset: target, layout: layout, identify: identify, startAt: [], allowBank: false)
                return
            }
            throw Failure(summary: "After Channel Right the surface shows \(Self.describe(PageReading.read(await mcu.surface).names)) instead of the scanned \(Self.describe(layout.names(atOffset: next))).", layoutChanged: true)
        }
        if !proven {
            // The page here looks like another one (or like the one before it). Name/Value
            // shows that Logic handled every move so far, so the count of moves is the position.
            let here = await readPage(namesMatter: true)
            guard layout.offsets(showing: here, by: identify).contains(target) else {
                offset = nil
                throw Failure(summary: "The surface shows \(Self.describe(here.names)) instead of the scanned \(Self.describe(layout.names(atOffset: target))).", layoutChanged: true)
            }
            if let problem = await nameValueAcknowledged(page: here) {
                offset = nil
                throw Failure(summary: "Cannot confirm that the surface shows track \(target + 1) on strip 1: the pages on the way look the same as others (same names and values), and Logic did not confirm that it handled the moves (\(problem)).")
            }
        }
        offset = target
    }

    /// Bank offsets of `layout` that could be what the surface shows now. When the answer is
    /// not just `expected`, waits out temporary text first (our own "Pan" over the names; when
    /// values matter, "x.x dB" / "Muted" in the lower line) and looks again.
    private func locate(_ layout: Layout, _ identify: Identify, expecting expected: Int?) async -> [Int] {
        let found = layout.offsets(showing: page(await mcu.surface), by: identify)
        if let expected, found == [expected] { return found }
        var waited = false
        if let until = upperOverlayUntil, clock.now < until {
            try? await clock.sleep(until: until)
            await settle()
            waited = true
        }
        if identify == .strips, PageReading.read(await mcu.surface).hasLowerOverlay {
            await waitForLowerOverlays()
            waited = true
        }
        return waited ? layout.offsets(showing: page(await mcu.surface), by: identify) : found
    }

    /// Reads the page once temporary LCD messages are gone: our own overlays over the names
    /// (when `namesMatter`) and any "x.x dB" / "Muted" text in the lower line.
    private func readPage(namesMatter: Bool) async -> PageReading {
        if namesMatter, let until = upperOverlayUntil, clock.now < until {
            try? await clock.sleep(until: until)
            await settle()
        }
        if PageReading.read(await mcu.surface).hasLowerOverlay {
            await waitForLowerOverlays()
        }
        return page(await mcu.surface)
    }

    /// Waits (up to `overlayHold`) until no strip shows "x.x dB" / "Muted" text: after a bank
    /// move such text may still sit where another track's strip now is.
    private func waitForLowerOverlays() async {
        _ = await mcu.waitUntil(timeout: timings.overlayHold, pollEvery: timings.pollInterval) {
            !PageReading.read($0).hasLowerOverlay
        }
        await settle()
    }

    /// The page with stale fader positions removed (see `staleFaders`).
    private func page(_ surface: SurfaceState) -> PageReading {
        PageReading(strips: (0..<8).map { reading(surface, strip: $0) })
    }

    private func reading(_ surface: SurfaceState, strip: Int) -> StripReading {
        var reading = StripReading.read(surface, strip: strip)
        if !faderTrusted(surface, strip: strip) { reading.fader = nil }
        return reading
    }

    private func faderTrusted(_ surface: SurfaceState, strip: Int) -> Bool {
        guard let mark = staleFaders[strip] else { return true }
        if surface.faderUpdates[strip] != mark {
            staleFaders[strip] = nil
            return true
        }
        return false
    }

    // MARK: Low-level helpers

    /// Presses a button. Refuses the Select buttons (design §1.2: selecting banks the surface
    /// and makes later edits apply to every selected track).
    private func pressButton(_ note: UInt8) async {
        guard !(0x18...0x1F).contains(note) else { return }
        await mcu.press(note)
    }

    /// Presses a button and waits for Logic's redraw (or `moveTimeout` without one).
    /// Returns true when the display changed.
    private func pressAndSettle(_ note: UInt8, expectChange: Bool) async -> Bool {
        let revision = await mcu.surface.displayRevision
        await pressButton(note)
        guard expectChange else {
            await settle()
            return await mcu.surface.displayRevision != revision
        }
        let changed = await mcu.waitUntil(timeout: timings.moveTimeout, pollEvery: timings.pollInterval) {
            $0.displayRevision != revision
        } != nil
        if changed { await settle() }
        return changed
    }

    /// Waits until Logic has sent nothing to the display for `settleQuiet`.
    private func settle() async {
        let start = clock.now
        var revision = await mcu.surface.displayRevision
        var lastChange = clock.now
        while start.duration(to: clock.now) < timings.settleTimeout {
            try? await clock.sleep(for: timings.pollInterval)
            let now = await mcu.surface.displayRevision
            if now != revision {
                revision = now
                lastChange = clock.now
            } else if lastChange.duration(to: clock.now) >= timings.settleQuiet {
                return
            }
        }
    }

    // MARK: Applying changes

    struct ApplyOutcome {
        var before: TrackInfo
        var after: TrackInfo
        var evidence: [String] = []
        var warnings: [String] = []
        var verified = 0
        var failed = 0
    }

    /// Applies one change. `validatedGeneration` is the layout its track number and expected
    /// name were checked against; whenever the layout used to reach the track is a newer one
    /// (an earlier change rescanned), they are checked again before anything is sent.
    private func apply(_ change: MixerChange, validatedGeneration: Int) async throws -> ApplyOutcome {
        guard var current = layout else { throw Failure(summary: "No track layout.") }
        let track = change.track
        var notes: [String] = []
        if current.generation != validatedGeneration {
            try Self.recheck(change, in: current, notes: &notes, after: "an earlier change in this call rescanned the track list")
        }
        var strip: Int
        do {
            strip = try await bringIntoView(track: track, layout: current)
        } catch let failure as Failure where failure.layoutChanged {
            // The track list changed since the scan: rescan, check the target again, retry once.
            current = try await scan(restore: false)
            notes.append("Track \(track): the surface no longer matched the earlier scan (\(failure.summary)); rescanned.")
            try Self.recheck(change, in: current, notes: &notes, after: "rescanning (the track list changed)")
            strip = try await bringIntoView(track: track, layout: current)
        }
        guard track <= current.trackCount, (0..<8).contains(strip) else {
            throw Failure(summary: "Track \(track) is not on the surface (\(current.trackCount) tracks). Nothing was changed on it.", warnings: notes)
        }
        let base = current.infos[track - 1]

        var before = Self.trackInfo(reading(await mcu.surface, strip: strip), base: base)
        // Hidden by temporary text or a stale fader: the last value this server knew.
        if before.pan == nil { before.pan = base.pan }
        if before.volumeDb == nil { before.volumeDb = base.volumeDb }
        var outcome = ApplyOutcome(before: before, after: before, warnings: notes)
        let label = "track \(track) \(ProjectText.quoted(base.name))"
        // Pan first: the dB text after a fader move and "Muted" after a mute toggle hide the
        // pan value for about two seconds.
        var panVerified = false
        if let pan = change.pan {
            let result = await setPan(strip: strip, target: pan, label: label)
            panVerified = result.ok
            record(result, into: &outcome)
        }
        var volume: (level: VolumeLevel?, positionStale: Bool)?
        if let target = change.volume {
            let result = await setVolume(strip: strip, target: target, label: label)
            volume = result.volume
            record(result, into: &outcome)
        }
        if let mute = change.mute {
            record(await setToggle(strip: strip, note: MCUButton.mute(strip), what: "mute", target: mute, label: label), into: &outcome)
        }
        if let solo = change.solo {
            record(await setToggle(strip: strip, note: MCUButton.solo(strip), what: "solo", target: solo, label: label), into: &outcome)
        }

        var after = Self.trackInfo(reading(await mcu.surface, strip: strip), base: base)
        if change.volume == nil, after.volumeDb == nil { after.volumeDb = before.volumeDb }
        if after.pan == nil {
            // Temporary LCD text hides the value: keep what was verified or left untouched.
            if let pan = change.pan { after.pan = panVerified ? pan : nil } else { after.pan = before.pan }
        }
        if let volume {
            after.volumeDb = volume.level
            if volume.positionStale { after.faderPosition = nil }
        }
        outcome.after = after
        if var stored = layout, stored.generation == current.generation, track - 1 < stored.infos.count {
            stored.infos[track - 1] = after
            // Keep the strip's identity in step with what Logic now shows for it; unknown
            // values match anything.
            var key = stored.keys[track - 1]
            if change.pan != nil { key.value = after.pan.map(Self.panText) }
            if change.volume != nil { key.fader = after.faderPosition.map { UInt16($0) } }
            if change.mute != nil { key.mute = after.mute.map { $0 ? .on : .off } }
            if change.solo != nil { key.solo = after.solo.map { $0 ? .on : .off } }
            stored.keys[track - 1] = key
            layout = stored
        }
        return outcome
    }

    /// `validate` against a newer layout; throws (with `notes`) when the change no longer fits.
    static func recheck(_ change: MixerChange, in layout: Layout, notes: inout [String], after reason: String) throws {
        switch validate(change, in: layout) {
        case .failure(var failure):
            failure.summary += " (checked again after \(reason)). Nothing was changed on it."
            failure.warnings = notes
            throw failure
        case .success(let note):
            if let note { notes.append(note) }
        }
    }

    private struct OpResult {
        var ok: Bool
        var evidence: String?
        var warning: String?
        /// Volume operations: the level Logic showed after the last move (nil when unknown),
        /// and whether the reported fader position is stale (Logic showed dB text but sent no
        /// echo, or the level is unknown).
        var volume: (level: VolumeLevel?, positionStale: Bool)?
    }

    private func record(_ result: OpResult, into outcome: inout ApplyOutcome) {
        if result.ok { outcome.verified += 1 } else { outcome.failed += 1 }
        if let evidence = result.evidence { outcome.evidence.append(evidence) }
        if let warning = result.warning { outcome.warnings.append(warning) }
    }

    /// A strip reading as a `TrackInfo`, keeping the identity (number, names) of `base`.
    static func trackInfo(_ reading: StripReading, base: TrackInfo) -> TrackInfo {
        var info = info(number: base.number, reading: reading,
                        name: ResolvedTrackName(name: base.name, source: base.nameSource, fullName: nil))
        info.lcdName = base.lcdName
        return info
    }

    /// Navigates so the track is on a strip; returns the strip index. Only tracks of `layout`
    /// (never a trailing blank strip) and only positions proven from the surface.
    private func bringIntoView(track: Int, layout: Layout) async throws -> Int {
        guard track >= 1, track <= layout.trackCount else {
            throw Failure(summary: "Track \(track) is not in the scanned track list (\(layout.trackCount) tracks).")
        }
        let found = await locate(layout, .strips, expecting: offset)
        if layout.complete, found.count == 1, let here = found.first, here < track, track <= here + 8 {
            offset = here
            return track - here - 1
        }
        // Any page that shows the track will do. Prefer one whose arrival shows on the surface
        // (it differs from the page one strip before), so the move to it can be proven.
        let lowest = max(0, track - 8), highest = max(lowest, min(track - 1, layout.maxOffset))
        let target = (lowest...highest).first {
            $0 == 0 || !StripKey.matches(layout.window(at: $0), layout.window(at: $0 - 1))
        } ?? lowest
        let before = offset
        try await move(toOffset: target, layout: layout, startAt: found)
        if before != target, PageReading.read(await mcu.surface).hasLowerOverlay {
            await waitForLowerOverlays()
        }
        return track - target - 1
    }

    private func setPan(strip: Int, target: Int, label: String) async -> OpResult {
        // Wait out temporary text in this strip's lower cell.
        _ = await mcu.waitUntil(timeout: timings.overlayHold, pollEvery: timings.pollInterval) {
            StripReading.read($0, strip: strip).pan != nil
        }
        guard var current = StripReading.read(await mcu.surface, strip: strip).pan else {
            let shown = StripReading.read(await mcu.surface, strip: strip).valueText
            return OpResult(ok: false, warning: "\(label): the pan value is not readable (LCD shows \"\(shown)\"), so pan was not changed.")
        }
        if current == target {
            return OpResult(ok: true, evidence: "\(label) pan already \(Self.panText(target)) on the LCD; nothing sent")
        }
        let start = clock.now
        let limit = abs(target - current) * 2 + 8
        var ticks = 0
        while current != target {
            guard ticks < limit else {
                return OpResult(ok: false, warning: "\(label): pan stopped at \(Self.panText(current)) after \(ticks) V-Pot ticks without reaching \(Self.panText(target)).")
            }
            if let problem = await notStopped() {
                return OpResult(ok: false, warning: "\(label): \(problem) Pan was left at \(Self.panText(current)) after \(ticks) V-Pot ticks (target \(Self.panText(target))).")
            }
            let previous = current
            await mcu.send([.vPot(strip: strip, delta: target > current ? 1 : -1)])
            ticks += 1
            upperOverlayUntil = clock.now.advanced(by: timings.overlayHold)
            let changed = await mcu.waitUntil(timeout: timings.vPotStepTimeout, pollEvery: timings.pollInterval) {
                let pan = StripReading.read($0, strip: strip).pan
                return pan != nil && pan != previous
            }
            guard changed != nil, let now = StripReading.read(await mcu.surface, strip: strip).pan else {
                return OpResult(ok: false, warning: "\(label): Logic did not show a new pan value after V-Pot tick \(ticks) (pan \(Self.panText(previous)), target \(Self.panText(target))).")
            }
            current = now
        }
        let elapsed = start.duration(to: clock.now).milliseconds
        return OpResult(ok: true, evidence: "\(label) pan \(Self.panText(target)) shown on the LCD after \(ticks) V-Pot ticks in \(elapsed) ms")
    }

    static func panText(_ pan: Int) -> String { pan > 0 ? "+\(pan)" : "\(pan)" }

    private func setToggle(strip: Int, note: UInt8, what: String, target: Bool, label: String) async -> OpResult {
        if note == MCUButton.mute(strip), StripReading.soloActive(await mcu.surface) {
            return OpResult(ok: false, warning: "\(label): a track is soloed, and Logic then blinks the mute LEDs of the other tracks, so the mute state can be neither read nor verified. Turn solo off first; nothing was pressed.")
        }
        guard let state = await mcu.surface.led(note) else {
            return OpResult(ok: false, warning: "\(label): Logic has not reported the \(what) LED, so the current state is unknown; nothing was pressed.")
        }
        guard state != .flashing else {
            return OpResult(ok: false, warning: "\(label): the \(what) LED is flashing, which is ambiguous; nothing was pressed.")
        }
        if (state == .on) == target {
            return OpResult(ok: true, evidence: "\(label) \(what) already \(target ? "on" : "off") (LED); nothing sent")
        }
        if let problem = await notStopped() {
            return OpResult(ok: false, warning: "\(label): \(problem) \(what.capitalized) was not pressed.")
        }
        await pressButton(note)
        let wanted: MCULEDState = target ? .on : .off
        let elapsed = await mcu.waitUntil(timeout: timings.ledTimeout, pollEvery: timings.pollInterval) { $0.led(note) == wanted }
        guard let elapsed else {
            let now = await mcu.surface.led(note).map { "\($0)" } ?? "unknown"
            return OpResult(ok: false, warning: "\(label): pressed \(what) but the LED did not turn \(target ? "on" : "off") within \(timings.ledTimeout.milliseconds) ms (LED \(now)).")
        }
        return OpResult(ok: true, evidence: "\(label) \(what) \(target ? "on" : "off"): mcu.led.\(mcuNoteName(note))=\(wanted) after \(elapsed.milliseconds) ms")
    }

    /// Closed loop on the fader. Reports only what Logic showed after the last move: when a
    /// correction overshoots, the fader is where that move left it, not at the closest level
    /// seen on the way.
    private func setVolume(strip: Int, target: VolumeLevel, label: String) async -> OpResult {
        guard let targetPosition = FaderCalibration.position(for: target) else {
            return OpResult(ok: false, warning: "\(label): volume \(target) is out of range.")
        }
        let tolerance = timings.tolerance(for: target)
        func distance(_ level: VolumeLevel) -> Double {
            switch (level, target) {
            case (.minusInfinity, .minusInfinity): return 0
            case (.db(let a), .db(let b)): return abs(a - b)
            default: return .infinity
            }
        }
        let initial = await mcu.surface
        if faderTrusted(initial, strip: strip), let position = initial.faders[strip], Int(position) == targetPosition {
            return OpResult(ok: true, evidence: "\(label) volume: Logic already reports fader position \(position) (\(target)); nothing sent",
                            volume: (FaderCalibration.level(forPosition: Int(position)), false))
        }
        if let problem = await notStopped() {
            return OpResult(ok: false, warning: "\(label): \(problem) The fader was not touched.")
        }

        let fader = strip
        await mcu.send([.faderTouch(fader: fader, touched: true)])
        let start = clock.now
        var position = targetPosition
        /// Where the fader is after the latest move, as far as Logic showed it: fresh feedback to
        /// that move, or, when the move brought none but Logic echoed earlier moves of this
        /// operation (so it reports changes), its last reported position. nil: unknown.
        var last: (level: VolumeLevel, source: String, stale: Bool)?
        /// A level within tolerance that ended the loop.
        var reached: (level: VolumeLevel, source: String, stale: Bool)?
        var attempt = 0
        var lastSentChanged = true
        var anyChange = false
        var echoSeen = false
        var step = 1.0
        var interrupted: String?
        while true {
            let before = await mcu.surface
            let updatesBefore = before.faderUpdates[fader]
            let textBefore = StripReading.read(before, strip: strip).volumeText
            await mcu.send([.fader(fader: fader, value: UInt16(position))])
            // A reaction to this move: an echo, or dB text that appears or changes. Text that
            // disappears is the previous move's text timing out, not a reaction.
            let changed = await mcu.waitUntil(timeout: timings.faderTimeout, pollEvery: timings.pollInterval) {
                guard $0.faderUpdates[fader] == updatesBefore else { return true }
                let text = StripReading.read($0, strip: strip).volumeText
                return text != nil && text != textBefore
            } != nil
            var captured: VolumeLevel?
            anyChange = anyChange || changed
            if changed {
                // The dB text and the echo arrive ~30 ms apart; give the second one a moment.
                // Capture the text right away: it disappears after about two seconds.
                _ = await mcu.waitUntil(timeout: timings.faderFollowUp, pollEvery: timings.pollInterval) {
                    $0.faderUpdates[fader] != updatesBefore && StripReading.read($0, strip: strip).volumeText != nil
                }
                captured = StripReading.read(await mcu.surface, strip: strip).volumeText
                await settle()
            }
            let after = await mcu.surface
            let echo = after.faders[fader]
            let echoed = after.faderUpdates[fader] != updatesBefore
            if echoed {
                staleFaders[strip] = nil
                echoSeen = true
            } else if changed {
                // Logic showed the level but did not send the position: what the surface state
                // holds for this fader is out of date until Logic sends a new one.
                staleFaders[strip] = after.faderUpdates[fader]
            }
            // The dB text counts only when Logic wrote something after this send; otherwise it
            // may be left over from another track or an earlier move.
            let text = changed ? (StripReading.read(after, strip: strip).volumeText ?? captured) : nil
            var observed: (level: VolumeLevel, source: String, stale: Bool)?
            if let text {
                observed = (text, "LCD \"\(text)\"" + (echoed ? ", echo \(echo.map(String.init) ?? "?")" : ", no echo"), !echoed)
            } else if let echo, echoed || faderTrusted(after, strip: strip) {
                observed = (FaderCalibration.level(forPosition: Int(echo)),
                            echoed ? "echo \(echo) (calibration)" : "reported position \(echo) unchanged (calibration)", false)
            }
            last = changed || echoSeen ? observed : nil
            if let observed, distance(observed.level) <= tolerance {
                reached = observed
                break
            }
            if !changed && !lastSentChanged { break }
            lastSentChanged = changed
            guard attempt < timings.maxVolumeCorrections, case .db(let goal) = target,
                  let seen = observed?.level.finiteDB else { break }
            if let problem = await notStopped() {
                interrupted = problem
                break
            }
            attempt += 1
            // Correct with the local calibration slope; widen the step if Logic did not move.
            // Without an echo the reported position is stale; the value just sent is the base.
            let base = echoed ? Int(echo!) : position
            let slope = FaderCalibration.slope(atPosition: base)
            guard slope > 0 else { break }
            if !changed { step *= 2 }
            var delta = Int(((goal - seen) / slope * step).rounded())
            if delta == 0 { delta = goal > seen ? 1 : -1 }
            position = min(max(base + delta, 1), FaderCalibration.maxPosition)
        }
        await mcu.send([.faderTouch(fader: fader, touched: false)])
        let elapsed = start.duration(to: clock.now).milliseconds
        let stopped = interrupted.map { " \($0) Stopped adjusting the fader (touch released)." } ?? ""
        if let reached {
            return OpResult(ok: true, evidence: "\(label) volume \(reached.level): \(reached.source) after \(elapsed) ms",
                            volume: (reached.level, reached.stale))
        }
        guard let last else {
            // Nothing usable after the last move: where the fader is now is unknown.
            staleFaders[strip] = await mcu.surface.faderUpdates[fader]
            let what = anyChange
                ? "Logic showed nothing usable after the last fader move (no echo, no dB text), so the current level is unknown."
                : "Logic did not react to the fader move (no echo, no dB text within \(timings.faderTimeout.milliseconds) ms), so the current level is unknown. Possible causes: a modal dialog in Logic, or the surface is bypassed."
            return OpResult(ok: false, warning: "\(label): \(what)\(stopped)", volume: (nil, true))
        }
        return OpResult(ok: false, warning: "\(label): asked for \(target) but after the last move Logic reports \(last.level) (\(last.source)); tolerance \(tolerance) dB.\(stopped)",
                        volume: (last.level, last.stale))
    }
}
