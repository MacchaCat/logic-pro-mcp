import Foundation
import MackieControl
import MIDICore

/// One track of the fake Logic project.
public struct FakeTrack: Sendable, Equatable {
    /// Full name as Logic's track header shows it (may contain non-ASCII characters).
    public var name: String
    /// Fader position as Logic would echo it (pitch bend; 12443 = 0.0 dB, 14845 = +6.0 dB).
    public var fader: UInt16
    public var pan: Int
    public var mute: Bool
    public var solo: Bool
    public var recArm: Bool

    public init(_ name: String, fader: UInt16 = 12443, pan: Int = 0, mute: Bool = false, solo: Bool = false, recArm: Bool = false) {
        self.name = name
        self.fader = fader
        self.pan = pan
        self.mute = mute
        self.solo = solo
        self.recArm = recArm
    }

    /// The 11-track project the Logic 13 facts were captured with (track 11 record-armed).
    public static let observedProject: [FakeTrack] =
        [FakeTrack("Inst 1"), FakeTrack("Inst 2")]
        + (1...9).map { FakeTrack("オーディオ \($0)", recArm: $0 == 9) }
}

/// Switches for the fake mixer. Observed Logic 13 behaviour is the default; the alternatives
/// model behaviour that sources describe differently or that has not been observed.
public struct FakeMixerBehavior: Sendable {
    public enum LastPage: Sendable {
        /// Observed on Logic 13 with 11 tracks: the last page starts at track N−6 and shows a
        /// blank 8th strip (offset limit N−7).
        case observed
        /// Apple's older guide: the last page is right-aligned to 8 tracks (offset limit N−8).
        case rightAligned
    }

    public var lastPage: LastPage = .observed
    /// Logic 13 connected in the channel view ("PN." with a dot).
    public var startInChannelView = true
    /// Lower LCD line shows parameter names ("Pan") instead of values.
    public var startShowingNames = false
    /// Logic 13 echoes surface fader moves as pitch bend; Logic 11.2 reportedly did not.
    public var echoesFaderMoves = true
    /// Logic shows "x.x dB" in the strip's lower cell after a fader move.
    public var showsVolumeText = true
    /// Echo quantisation: positions are rounded down to a multiple of this, except the
    /// calibration points, which echo unchanged.
    public var faderQuantum = 8
    /// How long temporary LCD messages stay up (Logic 13: about 2 s).
    public var overlayDuration: Duration = .milliseconds(2000)
    /// Delay of the fader echo after the dB text (Logic 13: ~30 ms).
    public var echoDelay: Duration = .zero
    /// How late Logic handles the Option release. Observed 2026-11-21 right after New Audio
    /// Track: Logic handled the release only after a Channel Right sent 65 ms later, which then
    /// acted as Option + Channel Right (last page). Buttons that arrive before the release is
    /// handled see Option still held; Global View flashes until then.
    public var optionReleaseLag: Duration = .zero
    /// Split every LCD write into SysEx messages of at most this many characters.
    public var lcdChunk: Int?
    /// Not observed: pressing Pan in the multi-track Pan view switches to the channel view.
    public var panInPanViewOpensChannelView = true
    /// How far Bank Left/Right move (8 observed from the first page with 11 tracks).
    public var bankStep = 8
    /// The selected track (index into tracks; default the last): the channel view shows it, and
    /// with no track record-armed Logic records on it.
    public var selectedTrack: Int?
    /// Observed on Logic 13 (2026-11-21): the Rec LED of every record-armed track blinks by
    /// on/off messages, all in phase, about 0.73 s each way, starting on when a track is armed;
    /// steady on while recording. nil: a steady LED.
    public var recArmBlinkHalfPeriod: Duration? = .milliseconds(730)
    /// Observed: with no track armed, Logic record-enables the selected track and lights its Rec
    /// LED steadily; arming a track turns that LED off; disarming the last armed track enables
    /// the selected one again, but Logic sends its LED only when the strips are redrawn (a bank
    /// or channel move).
    public var autoEnablesSelectedTrack = true
    /// Not observed: Logic converts accented letters to their base letter and curly quotes to
    /// straight ones before dropping non-ASCII ("Café" → "Cafe"). Default: the observed rule
    /// (non-ASCII dropped: "Café" → "Caf").
    public var foldsAccents = false
    /// Flip mode on (Flip LED lit).
    public var flipOn = false
    /// Global View on (Global View LED lit).
    public var globalViewOn = false

    public init() {}
}

/// Logic's Mackie Control mixer as observed on Logic 13 (docs/appendix/logic13-mcu-facts.md):
/// track names and pan values on the LCD in partial writes, mute/solo/rec LEDs, fader echoes,
/// banking with the observed end rule, the channel view, and temporary LCD messages.
///
/// A plain state machine: inputs return the messages to send; the host actor does the timing.
public struct FakeMixer: Sendable {
    public private(set) var tracks: [FakeTrack]
    public let behavior: FakeMixerBehavior
    public private(set) var offset = 0
    public private(set) var channelView: Bool
    public private(set) var showValues: Bool
    public private(set) var faderMoves = 0
    public private(set) var vPotTicks = 0
    public private(set) var selectPresses = 0
    private var optionHeld = false
    /// When a lagging Option release takes effect (`behavior.optionReleaseLag`).
    private var optionReleaseDue: ContinuousClock.Instant?
    /// Blink phase of the armed tracks' Rec LEDs and when it next flips.
    private var blinkOn = true
    private var nextBlink: ContinuousClock.Instant?
    /// Whether Logic has sent the selected track's steady Rec LED since an arm turned it off.
    private var autoLEDShown = true
    /// Logic is recording: armed tracks' Rec LEDs are steady (set by the host).
    public private(set) var recording = false
    /// Pan pressed down in the channel view; the multi-track page appears on release.
    private var panPending = false
    private var overlays: [Overlay] = []

    // What has been sent: Logic only sends what differs from it.
    private var shownLCD = [UInt8](repeating: 0x20, count: 112)
    private var shownLEDs: [UInt8: UInt8] = [:]
    private var shownFaders: [UInt16?] = Array(repeating: nil, count: 9)
    private var shownAssignment: [UInt8?] = [nil, nil]
    private let header = MCUCodec().sysExHeader

    struct Overlay: Sendable {
        var offset: Int
        var text: [UInt8]
        var expires: ContinuousClock.Instant
    }

    public init(tracks: [FakeTrack], behavior: FakeMixerBehavior) {
        self.tracks = tracks
        self.behavior = behavior
        channelView = behavior.startInChannelView
        showValues = !behavior.startShowingNames
    }

    public var maxOffset: Int {
        switch behavior.lastPage {
        case .observed: return max(0, tracks.count - 7)
        case .rightAligned: return max(0, tracks.count - 8)
        }
    }

    /// Earliest time a temporary message expires.
    public var nextExpiry: ContinuousClock.Instant? {
        (overlays.map(\.expires) + [optionReleaseDue, blinking ? nextBlink : nil].compactMap { $0 }).min()
    }

    private var anyArmed: Bool { tracks.contains { $0.recArm } }
    private var blinking: Bool { anyArmed && !recording && behavior.recArmBlinkHalfPeriod != nil }

    /// The tracks Logic records on: the armed ones, or with none armed the selected track.
    public var recordingTracks: [Int] {
        let armed = tracks.indices.filter { tracks[$0].recArm }
        if !armed.isEmpty || !behavior.autoEnablesSelectedTrack || tracks.isEmpty { return armed }
        return [selected]
    }

    private func recLEDLit(_ index: Int) -> Bool {
        if tracks[index].recArm { return !blinking || blinkOn }
        return behavior.autoEnablesSelectedTrack && !anyArmed && index == selected && autoLEDShown
    }

    /// The host starts or stops recording.
    mutating func setRecording(_ on: Bool, now: ContinuousClock.Instant) -> [MIDIMessage] {
        recording = on
        if !on { restartBlink(now: now) }
        return flush(now: now)
    }

    private mutating func restartBlink(now: ContinuousClock.Instant) {
        blinkOn = true
        nextBlink = behavior.recArmBlinkHalfPeriod.map { now.advanced(by: $0) }
    }

    private func trackIndex(strip: Int) -> Int? {
        let index = offset + strip
        return index < tracks.count ? index : nil
    }

    private var selected: Int { min(behavior.selectedTrack ?? (tracks.count - 1), max(tracks.count - 1, 0)) }

    // MARK: Names and values as Logic shows them

    /// Non-ASCII dropped (observed: "オーディオ 1" → "1"), trimmed, first 6 characters.
    /// `foldingAccents` models the unobserved alternative (see `FakeMixerBehavior.foldsAccents`).
    public static func lcdName(_ name: String, foldingAccents: Bool = false) -> String {
        var source = name
        if foldingAccents {
            source = source
                .replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{2019}", with: "'")
                .folding(options: [.diacriticInsensitive], locale: nil)
        }
        let ascii = String(String.UnicodeScalarView(source.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }))
        return String(ascii.trimmingCharacters(in: .whitespaces).prefix(6)).trimmingCharacters(in: .whitespaces)
    }

    private func shownName(_ name: String) -> String {
        Self.lcdName(name, foldingAccents: behavior.foldsAccents)
    }

    public static func panText(_ pan: Int) -> String { pan > 0 ? "+\(pan)" : "\(pan)" }

    static let calibration: [(position: Double, db: Double)] = [
        (99, -106.0), (495, -59.6), (994, -55.0), (1994, -45.3), (2995, -35.6),
        (3990, -30.0), (4995, -22.6), (5990, -17.1), (6987, -12.8), (8178, -9.0),
        (8962, -7.6), (9990, -5.8), (10969, -3.7), (11965, -1.2), (12443, 0.0),
        (12967, 1.3), (13976, 3.8), (14845, 6.0),
    ]

    /// The fake's fader law: the measured points, interpolated in log(position) between them,
    /// which deliberately differs from the server's linear interpolation.
    public static func decibels(_ position: UInt16) -> Double? {
        guard position > 0 else { return nil }
        let p = Double(min(position, 14845))
        if p < 99 { return -106 + 20 * log10(p / 99) }
        for index in 1..<calibration.count where p <= calibration[index].position {
            let lower = calibration[index - 1], upper = calibration[index]
            let fraction = (log(p) - log(lower.position)) / (log(upper.position) - log(lower.position))
            return lower.db + fraction * (upper.db - lower.db)
        }
        return 6.0
    }

    /// "-1.2 dB", "+0.0 dB", "-12.8 dB", "-106 dB", "-oo dB".
    public static func volumeText(_ position: UInt16) -> String {
        guard let db = decibels(position) else { return "-oo dB" }
        let rounded = (db * 10).rounded() / 10
        if rounded <= -100 { return String(format: "%.0f dB", rounded) }
        if rounded == 0 { return "+0.0 dB" }
        return String(format: "%+.1f dB", rounded)
    }

    func quantize(_ value: UInt16) -> UInt16 {
        let clamped = min(value, 14845)
        if Self.calibration.contains(where: { UInt16($0.position) == clamped }) || clamped == 0 { return clamped }
        let quantum = UInt16(max(behavior.faderQuantum, 1))
        return clamped - clamped % quantum
    }

    // MARK: Rendering

    private func render(now: ContinuousClock.Instant) -> [UInt8] {
        var lcd = [UInt8](repeating: 0x20, count: 112)
        func put(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() where offset + index < 112 { lcd[offset + index] = byte }
        }
        if panPending {
            // Intermediate state at Pan press-down (observed): surround labels.
            put("Angle  Divers LFE    Spread", at: 56)
            put("CStrip Ang/Dv X/Y", at: 91)
        } else if channelView {
            let track = tracks.indices.contains(selected) ? tracks[selected] : nil
            if showValues {
                put("Pan", at: 0)
                for strip in 1..<8 { put("-", at: strip * 7) }
                if let track { put(Self.panText(track.pan), at: 56) }
            } else {
                if let track { put("Track \(selected + 1) \"\(shownName(track.name))\"", at: 0) }
                put("Pan/Surround", at: 43)
                put("Pan", at: 56)
                for strip in 1..<8 { put("-", at: 56 + strip * 7) }
            }
        } else {
            for strip in 0..<8 {
                guard let index = trackIndex(strip: strip) else { continue }
                put(shownName(tracks[index].name), at: strip * 7)
                put(showValues ? Self.panText(tracks[index].pan) : "Pan", at: 56 + strip * 7)
            }
        }
        for overlay in overlays where overlay.expires > now {
            for (index, byte) in overlay.text.enumerated() {
                let position = overlay.offset + index
                let lineEnd = overlay.offset < 56 ? 56 : 112
                guard position < lineEnd else { break }
                lcd[position] = byte
            }
        }
        return lcd
    }

    private var assignmentCodes: [UInt8] {
        // Right digit first: "N" (0x0E), +0x40 lights its dot; left digit "P" (0x10).
        if panPending { return [0x1F, 0x10] }
        return [channelView ? 0x4E : 0x0E, 0x10]
    }

    /// Everything that differs from what was last sent, as Logic would send it.
    mutating func flush(now: ContinuousClock.Instant) -> [MIDIMessage] {
        if blinking, nextBlink == nil { nextBlink = behavior.recArmBlinkHalfPeriod.map { now.advanced(by: $0) } }
        var out: [MIDIMessage] = []
        let desired = render(now: now)
        for line in [0..<56, 56..<112] {
            guard let first = line.first(where: { desired[$0] != shownLCD[$0] }),
                  let last = line.last(where: { desired[$0] != shownLCD[$0] }) else { continue }
            let bytes = Array(desired[first...last])
            let chunk = max(behavior.lcdChunk ?? bytes.count, 1)
            var start = 0
            while start < bytes.count {
                let end = min(start + chunk, bytes.count)
                out.append(.sysEx(header + [0x12, UInt8(first + start)] + Array(bytes[start..<end])))
                start = end
            }
            for index in first...last { shownLCD[index] = desired[index] }
        }
        let codes = assignmentCodes
        for (position, code) in codes.enumerated() where shownAssignment[position] != code {
            shownAssignment[position] = code
            out.append(.controlChange(channel: 0, controller: 0x4A + UInt8(position), value: code))
        }
        // Logic 13 with any track soloed: Rude Solo flashes (velocity 01) and the mute LEDs of the
        // other tracks blink by on/off messages; the fake shows the "on" phase.
        let anySolo = tracks.contains { $0.solo }
        let rudeSolo: UInt8 = anySolo ? 0x01 : 0x00
        if shownLEDs[MCUButton.rudeSoloLED.rawValue] != rudeSolo {
            shownLEDs[MCUButton.rudeSoloLED.rawValue] = rudeSolo
            out.append(.noteOn(channel: 0, note: MCUButton.rudeSoloLED.rawValue, velocity: rudeSolo))
        }
        for strip in 0..<8 {
            let track = trackIndex(strip: strip).map { tracks[$0] }
            let muteShown = (track?.mute ?? false) || (anySolo && track != nil && !(track?.solo ?? false))
            for (note, on) in [(MCUButton.recArm(strip), trackIndex(strip: strip).map(recLEDLit) ?? false),
                               (MCUButton.solo(strip), track?.solo ?? false),
                               (MCUButton.mute(strip), muteShown)] {
                let velocity: UInt8 = on ? 0x7F : 0x00
                if shownLEDs[note] != velocity {
                    shownLEDs[note] = velocity
                    out.append(.noteOn(channel: 0, note: note, velocity: velocity))
                }
            }
            let fader = track?.fader ?? 0
            if shownFaders[strip] != fader {
                shownFaders[strip] = fader
                out.append(.pitchBend(channel: UInt8(strip), value: fader))
            }
        }
        if shownFaders[8] == nil {
            shownFaders[8] = 12443
            out.append(.pitchBend(channel: 8, value: 12443))
        }
        // Observed while Option is held: Global View flashes (velocity 01).
        let modes: [(UInt8, UInt8)] = [
            (MCUButton.flip.rawValue, behavior.flipOn ? 0x7F : 0x00),
            (MCUButton.globalView.rawValue, optionHeld ? 0x01 : (behavior.globalViewOn ? 0x7F : 0x00)),
        ]
        for (note, velocity) in modes where shownLEDs[note] != velocity {
            shownLEDs[note] = velocity
            out.append(.noteOn(channel: 0, note: note, velocity: velocity))
        }
        return out
    }

    /// Drops expired temporary messages and redraws what they covered.
    mutating func expire(now: ContinuousClock.Instant) -> [MIDIMessage] {
        overlays.removeAll { $0.expires <= now }
        if blinking, let half = behavior.recArmBlinkHalfPeriod {
            var next = nextBlink ?? now.advanced(by: half)
            while next <= now {
                blinkOn.toggle()
                next = next.advanced(by: half)
            }
            nextBlink = next
        }
        return applyDueOptionRelease(now: now) + flush(now: now)
    }

    /// Applies a lagging Option release once it is due: Select LEDs off, Global View stops.
    private mutating func applyDueOptionRelease(now: ContinuousClock.Instant) -> [MIDIMessage] {
        guard let due = optionReleaseDue, due <= now else { return [] }
        optionReleaseDue = nil
        optionHeld = false
        return (0..<8).map { .noteOn(channel: 0, note: MCUButton.select($0), velocity: 0x00) }
    }

    private mutating func overlay(_ text: String, at offset: Int, now: ContinuousClock.Instant) {
        overlays.removeAll { $0.offset == offset }
        overlays.append(Overlay(offset: offset, text: Array(text.utf8), expires: now.advanced(by: behavior.overlayDuration)))
    }

    // MARK: Input from the surface

    public struct Output: Sendable {
        public var now: [MIDIMessage] = []
        public var delayed: [MIDIMessage] = []
    }

    /// Handles a message from the surface; returns nil for messages the mixer does not own.
    mutating func handle(_ message: MIDIMessage, now: ContinuousClock.Instant) -> Output? {
        switch message {
        case let .noteOn(0, note, velocity):
            return button(note, pressed: velocity > 0, now: now)
        case let .noteOff(0, note, _):
            return button(note, pressed: false, now: now)
        case let .pitchBend(channel, value) where channel < 8:
            return fader(strip: Int(channel), value: value, now: now)
        case let .controlChange(0, controller, value) where (0x10...0x17).contains(controller):
            return vPot(strip: Int(controller - 0x10), value: value, now: now)
        default:
            return nil
        }
    }

    private mutating func button(_ note: UInt8, pressed: Bool, now: ContinuousClock.Instant) -> Output? {
        // Buttons the mixer does not own (transport etc.) go to the host untouched.
        guard Self.ownedButtons.contains(where: { $0.contains(note) }) else { return nil }
        let released = applyDueOptionRelease(now: now)
        var output = buttonAfterRelease(note, pressed: pressed, now: now) ?? Output()
        output.now = released + output.now
        return output
    }

    private static let ownedButtons: [ClosedRange<UInt8>] = [
        MCUButton.option.rawValue...MCUButton.option.rawValue,
        MCUButton.assignPan.rawValue...MCUButton.assignPan.rawValue,
        MCUButton.nameValue.rawValue...MCUButton.nameValue.rawValue,
        MCUButton.bankLeft.rawValue...MCUButton.bankLeft.rawValue,
        MCUButton.bankRight.rawValue...MCUButton.bankRight.rawValue,
        MCUButton.channelLeft.rawValue...MCUButton.channelLeft.rawValue,
        MCUButton.channelRight.rawValue...MCUButton.channelRight.rawValue,
        0x00...0x1F, 0x68...0x70,
    ]

    private mutating func buttonAfterRelease(_ note: UInt8, pressed: Bool, now: ContinuousClock.Instant) -> Output? {
        switch note {
        case MCUButton.option.rawValue:
            if !pressed, behavior.optionReleaseLag > .zero {
                optionReleaseDue = now.advanced(by: behavior.optionReleaseLag)
                return Output()
            }
            optionReleaseDue = nil
            optionHeld = pressed
            // Observed (capture, Option + Bank chords): while Option is held, Logic lights the
            // Select LEDs and flashes Global View.
            var out = Output()
            for strip in 0..<8 { out.now.append(.noteOn(channel: 0, note: MCUButton.select(strip), velocity: pressed ? 0x7F : 0x00)) }
            out.now += flush(now: now)
            return out
        case MCUButton.assignPan.rawValue:
            if pressed {
                if channelView {
                    panPending = true
                } else if behavior.panInPanViewOpensChannelView {
                    channelView = true
                }
            } else if panPending {
                panPending = false
                channelView = false
                overlay("Pan/Surround parameter: Pan", at: 28, now: now)
            }
            return Output(now: flush(now: now))
        case MCUButton.nameValue.rawValue:
            guard pressed else { return Output() }
            showValues.toggle()
            return Output(now: flush(now: now))
        case MCUButton.bankLeft.rawValue, MCUButton.bankRight.rawValue,
             MCUButton.channelLeft.rawValue, MCUButton.channelRight.rawValue:
            guard pressed, !channelView else { return Output() }  // observed: no effect in the channel view
            let right = note == MCUButton.bankRight.rawValue || note == MCUButton.channelRight.rawValue
            let step = (note == MCUButton.bankLeft.rawValue || note == MCUButton.bankRight.rawValue) ? behavior.bankStep : 1
            if optionHeld {
                offset = right ? maxOffset : 0
            } else {
                offset = right ? min(offset + step, maxOffset) : max(offset - step, 0)
            }
            autoLEDShown = true  // the strips are redrawn
            return Output(now: flush(now: now))
        case 0x00...0x17:
            guard pressed else { return Output() }
            let strip = Int(note & 7)
            guard let index = trackIndex(strip: strip) else { return Output() }
            switch note {
            case 0x00...0x07:
                let wasArmed = anyArmed
                tracks[index].recArm.toggle()
                if tracks[index].recArm { restartBlink(now: now) }  // a new arm lights at once
                if !wasArmed, anyArmed { autoLEDShown = false }
            case 0x08...0x0F:
                tracks[index].solo.toggle()
            default:
                tracks[index].mute.toggle()
                overlay(tracks[index].mute ? "Muted  " : "--     ", at: 56 + strip * 7, now: now)
            }
            return Output(now: flush(now: now))
        case 0x18...0x1F:
            if pressed { selectPresses += 1 }
            return Output()
        case 0x68...0x70:
            return Output()  // fader touch: accepted, no output
        default:
            return nil
        }
    }

    private mutating func fader(strip: Int, value: UInt16, now: ContinuousClock.Instant) -> Output {
        faderMoves += 1
        guard !channelView, let index = trackIndex(strip: strip) else { return Output() }
        let quantized = quantize(value)
        // Not observed (assumption, checklist #16): no echo and no LCD text when the value
        // does not change.
        guard quantized != tracks[index].fader else { return Output() }
        tracks[index].fader = quantized
        if behavior.showsVolumeText {
            let text = Self.volumeText(quantized)
            overlay(text + String(repeating: " ", count: max(0, 8 - text.count)), at: 56 + strip * 7, now: now)
        }
        // Logic's model of the fader is the new value whether or not it echoes it.
        shownFaders[strip] = quantized
        var out = Output(now: flush(now: now))
        if behavior.echoesFaderMoves {
            let echo = MIDIMessage.pitchBend(channel: UInt8(strip), value: quantized)
            if behavior.echoDelay > .zero { out.delayed.append(echo) } else { out.now.append(echo) }
        }
        return out
    }

    private mutating func vPot(strip: Int, value: UInt8, now: ContinuousClock.Instant) -> Output {
        vPotTicks += 1
        guard !channelView, let index = trackIndex(strip: strip) else { return Output() }
        let magnitude = Int(value & 0x3F)
        let delta = value & 0x40 != 0 ? -magnitude : magnitude
        tracks[index].pan = min(max(tracks[index].pan + delta, -64), 63)
        // Observed on strip 1: "Pan" plus spaces over 13 characters of the upper line.
        overlay("Pan" + String(repeating: " ", count: 10), at: strip * 7, now: now)
        return Output(now: flush(now: now))
    }

    // MARK: Changes made "in Logic"

    mutating func update(track index: Int, now: ContinuousClock.Instant, _ change: (inout FakeTrack) -> Void) -> [MIDIMessage] {
        guard tracks.indices.contains(index) else { return [] }
        change(&tracks[index])
        return flush(now: now)
    }

    mutating func replaceTracks(_ newTracks: [FakeTrack], now: ContinuousClock.Instant) -> [MIDIMessage] {
        tracks = newTracks
        offset = min(offset, maxOffset)
        return flush(now: now)
    }
}
