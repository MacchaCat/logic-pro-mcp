import Foundation
import MackieControl

/// Waits and limits for mixer work over Mackie Control. Defaults are sized from the Logic 13
/// capture (docs/appendix/captures/logic13-mixer-banking-fader-vpot.log) with headroom.
public struct MixerTimings: Sendable {
    /// Longest wait for Logic to redraw after a bank/channel/mode button. Logic 13 answered in
    /// 15–35 ms; a step that shows no change within this time counts as "did not move".
    public var moveTimeout: Duration = .milliseconds(500)
    /// The surface counts as settled after this long without LCD/LED/fader/assignment output.
    /// Logic sends a redraw as one burst of partial writes within a few ms.
    public var settleQuiet: Duration = .milliseconds(60)
    /// Upper bound for one settle wait (the surface may never go quiet, e.g. during automation).
    public var settleTimeout: Duration = .milliseconds(1500)
    /// How long temporary LCD messages stay up: "Pan/Surround parameter: Pan" after a mode
    /// change, "Pan" over the names after a V-Pot turn, "x.x dB" after a fader move, "Muted".
    /// Observed about 2.0 s after the last related event.
    public var overlayHold: Duration = .milliseconds(2600)
    /// Wait for the fader echo (Logic 13: ~30 ms) or the dB text after a fader move.
    public var faderTimeout: Duration = .milliseconds(800)
    /// After the first of the two fader signals (dB text, echo), how long to wait for the
    /// other one. Logic 13 sent the echo ~30 ms after the text.
    public var faderFollowUp: Duration = .milliseconds(150)
    /// Wait for the pan value to change after one V-Pot tick (Logic 13: 30–70 ms).
    public var vPotStepTimeout: Duration = .milliseconds(500)
    /// Wait for a Mute/Solo LED after pressing the button.
    public var ledTimeout: Duration = .milliseconds(800)
    /// A track list from a scan is reused for this long, and only while the full-name source
    /// lists as many names as at the scan and the surface shows one of its pages (by LCD names);
    /// `get_session_state` with `refresh` always rescans. Values and positions are proven again
    /// before every change.
    public var layoutReuse: Duration = .seconds(30)
    /// Safety bound for a scan.
    public var maxTracks = 1000
    /// When the surface shows 8 identical strips (same LCD name and values), a Channel Right
    /// shows no change until a different strip comes in: the scan presses up to this many times
    /// (each waits `moveTimeout`) before giving up and reporting the count as not confirmed.
    public var identicalRunProbe = 32
    /// Closed-loop fader corrections after the first move.
    public var maxVolumeCorrections = 3
    /// A volume counts as reached when Logic shows a level this close to the target...
    public var volumeToleranceDB = 0.1
    /// ...or this close below `lowLevelThresholdDB`, where one fader step spans several tenths.
    public var lowLevelToleranceDB = 1.0
    public var lowLevelThresholdDB = -60.0
    public var pollInterval: Duration = .milliseconds(5)
    /// How long the Rec LEDs of each page are watched to tell a record-armed track from the
    /// selected one (observed on Logic 13: an armed track's LED blinks by on/off messages about
    /// 0.73 s each way; the selected track's is steady while no track is armed).
    public var recordArmWindow: Duration = .milliseconds(1000)

    public init() {}

    func tolerance(for target: VolumeLevel) -> Double {
        guard let db = target.finiteDB else { return 0 }
        return db < lowLevelThresholdDB ? lowLevelToleranceDB : volumeToleranceDB
    }
}

/// One track as reported by `get_session_state`.
public struct TrackInfo: Sendable, Codable, Equatable {
    public var number: Int
    /// Full name when Accessibility supplied one that matches the LCD, else the LCD name.
    public var name: String
    public var nameSource: ResolvedTrackName.Source
    public var lcdName: String
    /// From the fader position Logic reports, through the calibration table (approximate
    /// between calibration points), or from Logic's own "x.x dB" text when it was showing.
    public var volumeDb: VolumeLevel?
    /// Raw fader position Logic reported (pitch bend 0…16383).
    public var faderPosition: Int?
    /// −64…+63 from the lower LCD line in the Pan assignment; nil when not readable.
    public var pan: Int?
    public var mute: Bool?
    public var solo: Bool?
    // No record arm: one look at the Rec LEDs cannot tell (Logic 13 blinks an armed track's LED
    // and lights the selected track's steadily); `MixerController.readRecordArms` watches them.

    enum CodingKeys: String, CodingKey {
        case number, name, pan, mute, solo
        case nameSource = "name_source"
        case lcdName = "lcd_name"
        case volumeDb = "volume_db"
        case faderPosition = "fader_position"
    }
}

/// How a track's Rec LED looked while it was watched (`MixerController.readRecordArms`).
/// Observed on Logic 13 (2026-11-21): Logic blinks the LED of every record-armed track by on/off
/// messages (in phase, about 0.73 s each way; steady while recording) and lights the selected
/// track's LED steadily while no track is armed (it is record-enabled automatically). Logic
/// records on the armed tracks; with none armed, on the selected one.
public enum RecordArmLight: String, Sendable, Codable, Equatable {
    /// Seen on and off: record-armed.
    case alternating
    /// Only seen on: the selected track, record-enabled because no track is armed (or a track
    /// armed less than about 2 s ago, before its first off phase).
    case steady
    case off
}

/// One track's Rec LED as watched by `readRecordArms`.
public struct RecordArmState: Sendable, Codable, Equatable {
    public var track: Int
    public var name: String
    /// nil when Logic sent no Rec LED for the track's strip.
    public var light: RecordArmLight?

    public init(track: Int, name: String, light: RecordArmLight?) {
        self.track = track
        self.name = name
        self.light = light
    }
}

/// Result payload of one Rec button press (`MixerController.pressRecordArm`).
public struct RecordArmPress: Sendable, Codable, Equatable {
    public var track: Int
    public var name: String
    /// The strip's Rec LED right before the press and as Logic last sent it afterwards.
    public var ledBefore: String?
    public var ledAfter: String?

    enum CodingKeys: String, CodingKey {
        case track, name
        case ledBefore = "led_before"
        case ledAfter = "led_after"
    }
}

/// One requested mixer change (`mixer_set`).
public struct MixerChange: Sendable, Equatable {
    public var track: Int
    public var expectedName: String?
    public var volume: VolumeLevel?
    public var pan: Int?
    public var mute: Bool?
    public var solo: Bool?

    public init(track: Int, expectedName: String? = nil, volume: VolumeLevel? = nil, pan: Int? = nil, mute: Bool? = nil, solo: Bool? = nil) {
        self.track = track
        self.expectedName = expectedName
        self.volume = volume
        self.pan = pan
        self.mute = mute
        self.solo = solo
    }

    public var isEmpty: Bool { volume == nil && pan == nil && mute == nil && solo == nil }
}

/// Result payload of a track scan.
public struct TrackScan: Sendable, Codable, Equatable {
    public var tracks: [TrackInfo]
    public var trackCount: Int
    /// When the surface was read (ISO 8601).
    public var asOf: String
    /// True when this came from the cache instead of a new scan.
    public var cached: Bool

    enum CodingKeys: String, CodingKey {
        case tracks
        case trackCount = "track_count"
        case asOf = "as_of"
        case cached
    }
}

extension MCULEDState {
    /// on → true, off → false; flashing is ambiguous for mute/solo/rec and reads as nil.
    var asBool: Bool? {
        switch self {
        case .on: return true
        case .off: return false
        case .flashing: return nil
        }
    }
}
