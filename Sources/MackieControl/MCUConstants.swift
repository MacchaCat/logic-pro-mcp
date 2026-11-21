import MIDICore

/// Mackie Control model IDs used in the SysEx header `F0 00 00 66 <model>`.
public enum MCUModel: UInt8, Sendable {
    case logicControl = 0x10
    case logicControlXT = 0x11
    case mackieControl = 0x14
    case mackieControlXT = 0x15
}

/// Mackie Control manufacturer ID prefix (inside SysEx, after F0).
public let mcuManufacturerID: [UInt8] = [0x00, 0x00, 0x66]

/// Note numbers of Mackie Control buttons and LEDs (Note On, MIDI channel 1).
///
/// Sources: Logic Control MIDI Implementation (Logic 7 manual, appendix B, pp. 251–254),
/// Ardour `libs/surfaces/mackie/device_info.cc`, TouchMCU protocol doc. All three agree.
public enum MCUButton: UInt8, Sendable, CaseIterable {
    // Assignment
    case assignTrack = 0x28, assignSend = 0x29, assignPan = 0x2A
    case assignPlugin = 0x2B, assignEQ = 0x2C, assignInstrument = 0x2D
    // Banking
    case bankLeft = 0x2E, bankRight = 0x2F, channelLeft = 0x30, channelRight = 0x31
    // Display
    case flip = 0x32, globalView = 0x33, nameValue = 0x34, smpteBeats = 0x35
    // Function keys
    case f1 = 0x36, f2 = 0x37, f3 = 0x38, f4 = 0x39, f5 = 0x3A, f6 = 0x3B, f7 = 0x3C, f8 = 0x3D
    // Global view filters
    case midiTracks = 0x3E, inputs = 0x3F, audioTracks = 0x40, audioInstrument = 0x41
    case aux = 0x42, busses = 0x43, outputs = 0x44, user = 0x45
    // Modifiers
    case shift = 0x46, option = 0x47, control = 0x48, cmdAlt = 0x49
    // Automation
    case automationRead = 0x4A, automationWrite = 0x4B, automationTrim = 0x4C
    case automationTouch = 0x4D, automationLatch = 0x4E, group = 0x4F
    // Utilities
    case save = 0x50, undo = 0x51, cancel = 0x52, enter = 0x53
    // Transport section
    case marker = 0x54, nudge = 0x55, cycle = 0x56, drop = 0x57, replace = 0x58, click = 0x59
    case soloGlobal = 0x5A
    case rewind = 0x5B, fastForward = 0x5C, stop = 0x5D, play = 0x5E, record = 0x5F
    // Cursor
    case cursorUp = 0x60, cursorDown = 0x61, cursorLeft = 0x62, cursorRight = 0x63
    case zoom = 0x64, scrub = 0x65, userSwitchA = 0x66, userSwitchB = 0x67
    // LED-only
    case smpteLED = 0x71, beatsLED = 0x72, rudeSoloLED = 0x73

    /// Per-strip buttons (strip is 0...7).
    public static func recArm(_ strip: Int) -> UInt8 { 0x00 + UInt8(strip & 7) }
    public static func solo(_ strip: Int) -> UInt8 { 0x08 + UInt8(strip & 7) }
    public static func mute(_ strip: Int) -> UInt8 { 0x10 + UInt8(strip & 7) }
    public static func select(_ strip: Int) -> UInt8 { 0x18 + UInt8(strip & 7) }
    public static func vPotPush(_ strip: Int) -> UInt8 { 0x20 + UInt8(strip & 7) }
    /// Fader touch: strips 0...7 → 0x68...0x6F, master (index 8) → 0x70.
    public static func faderTouch(_ fader: Int) -> UInt8 { fader >= 8 ? 0x70 : 0x68 + UInt8(fader & 7) }

    /// Digits for Logic's modal dialogs: F1–F8 = 1–8, MIDI Tracks = 9, Inputs = 0
    /// (Logic Pro Control Surfaces Support Guide, function keys table; unverified on Logic 13).
    public static func dialogDigit(_ digit: Int) -> MCUButton? {
        switch digit {
        case 1...8: return MCUButton(rawValue: 0x36 + UInt8(digit - 1))
        case 9: return .midiTracks
        case 0: return .inputs
        default: return nil
        }
    }
}

/// Human-readable name for any button/LED note number, used in logs and evidence strings.
public func mcuNoteName(_ note: UInt8) -> String {
    switch note {
    case 0x00...0x07: return "recArm[\(note - 0x00 + 1)]"
    case 0x08...0x0F: return "solo[\(note - 0x08 + 1)]"
    case 0x10...0x17: return "mute[\(note - 0x10 + 1)]"
    case 0x18...0x1F: return "select[\(note - 0x18 + 1)]"
    case 0x20...0x27: return "vPotPush[\(note - 0x20 + 1)]"
    case 0x68...0x6F: return "faderTouch[\(note - 0x68 + 1)]"
    case 0x70: return "faderTouch[master]"
    default:
        if let button = MCUButton(rawValue: note) { return String(describing: button) }
        return "note[\([note].hexString)]"
    }
}
