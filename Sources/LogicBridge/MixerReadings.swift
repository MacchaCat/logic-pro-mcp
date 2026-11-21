import MackieControl

/// What the surface shows for one channel strip, read from Logic's last output.
public struct StripReading: Sendable, Hashable {
    /// Upper LCD cell, trimmed (Logic shows at most 6 ASCII characters; non-ASCII is dropped).
    public var lcdName: String
    /// Lower LCD cell, trimmed: the pan value in the Pan assignment's value mode.
    public var valueText: String
    /// Lower line from this cell's start, untrimmed, 8 characters (dB text can spill over).
    public var valueRaw: String
    public var fader: UInt16?
    public var mute: MCULEDState?
    public var solo: MCULEDState?
    public var recArm: MCULEDState?

    public var pan: Int? { MixerLCD.pan(valueText) }
    /// The "x.x dB" text Logic shows for a few seconds after a fader move, if present.
    public var volumeText: VolumeLevel? { MixerLCD.volume(valueRaw) }
    /// Neither a name nor a value: an empty strip after the last track.
    public var isBlank: Bool { lcdName.isEmpty && valueText.isEmpty }
    /// The lower cell shows a temporary message (dB, "Muted", "--") instead of the pan value.
    public var showsLowerOverlay: Bool {
        volumeText != nil || MixerLCD.isMuteMessage(valueText)
    }

    /// The strip's identity for locating the surface in a scanned layout (see `StripKey`).
    /// The lower cell does not count while it shows temporary text.
    var key: StripKey {
        StripKey(name: lcdName, value: showsLowerOverlay ? nil : valueText, fader: fader,
                 mute: mute.flatMap(StripKey.steady), solo: solo.flatMap(StripKey.steady))
    }

    /// Everything Logic reports for the strip that stays put while nothing is pressed, for "did
    /// the page change" comparisons. Not the Rec LED: Logic 13 blinks it for armed tracks.
    var fingerprint: Fingerprint {
        Fingerprint(name: lcdName, value: valueText, fader: fader, mute: mute, solo: solo)
    }

    struct Fingerprint: Hashable {
        var name: String
        var value: String
        var fader: UInt16?
        var mute: MCULEDState?
        var solo: MCULEDState?
    }

    /// True while any track is soloed (Rude Solo LED lit or flashing). Logic 13 then blinks the
    /// mute LEDs of the other tracks by sending on/off every ~0.75 s (observed 2026-11-21), so a
    /// mute LED says nothing reliable about the track's own Mute button.
    public static func soloActive(_ surface: SurfaceState) -> Bool {
        surface.led(.rudeSoloLED).map { $0 != .off } ?? false
    }

    public static func read(_ surface: SurfaceState, strip: Int) -> StripReading {
        StripReading(
            lcdName: surface.lcdCell(strip: strip),
            valueText: surface.lcdCell(strip: strip, lower: true),
            valueRaw: surface.lcdText(offset: SurfaceState.lcdLineLength + strip * SurfaceState.cellWidth, length: 8),
            fader: surface.faders[strip],
            mute: soloActive(surface) ? nil : surface.led(MCUButton.mute(strip)),
            solo: surface.led(MCUButton.solo(strip)),
            recArm: surface.led(MCUButton.recArm(strip))
        )
    }
}

/// What identifies a strip when checking which tracks the surface shows: the LCD name and the
/// values Logic reports for it (pan text, fader position, Mute/Solo LEDs). A field that is nil
/// is unknown (hidden by temporary text, a flashing LED, a stale or unreported fader) and
/// matches anything. Names alone are not enough: names made only of non-ASCII characters show
/// as blank, and names with a common 6-character prefix look the same.
///
/// The Rec LED is not part of it (observed on Logic 13, 2026-11-21): Logic blinks it by on/off
/// messages for record-armed tracks, lights it steadily for the selected track while no track is
/// armed, and turns that one off by itself when another track is armed.
struct StripKey: Sendable, Hashable {
    var name: String
    var value: String?
    var fader: UInt16?
    var mute: MCULEDState?
    var solo: MCULEDState?

    /// Past the scanned strips: no name, no value, nothing else known.
    static let blank = StripKey(name: "", value: "")

    init(name: String, value: String?, fader: UInt16? = nil, mute: MCULEDState? = nil,
         solo: MCULEDState? = nil) {
        self.name = name
        self.value = value
        self.fader = fader
        self.mute = mute
        self.solo = solo
    }

    /// Flashing LEDs are not compared: what flashing means for mute/solo/rec is not observed.
    static func steady(_ state: MCULEDState) -> MCULEDState? { state == .flashing ? nil : state }

    /// True when both could be the same strip: equal names, and equal in every field both know.
    func matches(_ other: StripKey) -> Bool {
        guard name == other.name else { return false }
        func agree<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
            guard let a, let b else { return true }
            return a == b
        }
        return agree(value, other.value) && agree(fader, other.fader) && agree(mute, other.mute)
            && agree(solo, other.solo)
    }

    static func matches(_ a: [StripKey], _ b: [StripKey]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.matches($1) }
    }
}

/// The eight strips the surface shows at one bank position.
public struct PageReading: Sendable, Hashable {
    public var strips: [StripReading]

    public static func read(_ surface: SurfaceState) -> PageReading {
        PageReading(strips: (0..<8).map { StripReading.read(surface, strip: $0) })
    }

    public var names: [String] { strips.map(\.lcdName) }
    var fingerprints: [StripReading.Fingerprint] { strips.map(\.fingerprint) }

    /// Strip keys for locating this page in a scanned layout. Logic writes "x.x dB" text 8
    /// characters wide from the start of a cell (observed on strip 1: `-1.2 dB `), so the first
    /// character of the next cell, where its pan value starts, is covered too: that next lower
    /// cell does not count either.
    var keys: [StripKey] {
        strips.indices.map { index in
            var key = strips[index].key
            if index > 0, strips[index - 1].volumeText != nil { key.value = nil }
            return key
        }
    }
    public var hasLowerOverlay: Bool { strips.contains(where: \.showsLowerOverlay) }

    /// The lower line shows parameter names (Name mode of Name/Value) rather than values:
    /// some strip shows text, none of it is a pan value or a temporary message.
    public var showsParameterNames: Bool {
        let texts = strips.map(\.valueText).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return false }
        return !strips.contains(where: { $0.pan != nil || $0.showsLowerOverlay })
    }
}

/// How the surface is set up, from the assignment display and mode LEDs.
public struct SurfaceViewState: Sendable, Equatable {
    /// The two assignment characters plus "." when the right dot is lit, e.g. "PN" or "PN.".
    public var assignment: String
    public var assignmentKnown: Bool
    public var flip: MCULEDState?
    public var globalView: MCULEDState?

    /// Logic 13 marks the channel view (one track's parameters across the strips) with a dot.
    public var isChannelView: Bool { assignment.hasSuffix(".") }
    /// The multi-track Pan view: track names above, pan values below.
    public var isMultiTrackPan: Bool { assignment == "PN" }

    public static func read(_ surface: SurfaceState) -> SurfaceViewState {
        SurfaceViewState(
            assignment: surface.assignmentText,
            assignmentKnown: surface.assignment.allSatisfy { $0 != nil },
            flip: surface.led(.flip),
            globalView: surface.led(.globalView)
        )
    }
}
