import MIDICore

/// Bars / beats / division / ticks as shown on the time-code display in Beats mode.
public struct BeatsPosition: Sendable, Hashable, Codable, CustomStringConvertible {
    public var bar: Int
    public var beat: Int
    public var division: Int
    public var tick: Int

    public init(bar: Int, beat: Int, division: Int, tick: Int) {
        self.bar = bar
        self.beat = beat
        self.division = division
        self.tick = tick
    }

    public var description: String { "\(bar).\(beat).\(division).\(tick)" }
}

/// Everything the host has told the emulated surface, as a plain value.
///
/// The surface model is deliberately "dumb": it records what Logic sent and offers decoding
/// helpers. Interpretation (e.g. whether the display is in Beats mode) is the caller's job.
public struct SurfaceState: Sendable, Equatable {
    public static let lcdLength = 112
    public static let lcdLineLength = 56
    public static let cellWidth = 7

    /// Raw LCD frame buffer, 2 × 56 ASCII bytes.
    public private(set) var lcd: [UInt8] = Array(repeating: 0x20, count: SurfaceState.lcdLength)
    public private(set) var leds: [UInt8: MCULEDState] = [:]
    /// Fader positions as last reported by the host (0...7 strips, 8 master). nil = never reported.
    public private(set) var faders: [UInt16?] = Array(repeating: nil, count: 9)
    /// How many positions Logic has sent per fader (also counts repeats of the same value).
    public private(set) var faderUpdates: [Int] = Array(repeating: 0, count: 9)
    public private(set) var vPotRings: [UInt8?] = Array(repeating: nil, count: 8)
    /// Raw 7-segment codes; index 0 is the rightmost digit. nil = never written.
    public private(set) var timecode: [UInt8?] = Array(repeating: nil, count: 10)
    /// Assignment display codes; index 0 = right, 1 = left.
    public private(set) var assignment: [UInt8?] = [nil, nil]
    public private(set) var meters: [UInt8] = Array(repeating: 0, count: 8)

    /// Monotonic counters, so callers can wait for "any change since".
    public private(set) var lcdRevision = 0
    public private(set) var ledRevision = 0
    public private(set) var timecodeRevision = 0
    public private(set) var faderRevision = 0
    public private(set) var ringRevision = 0
    public private(set) var assignmentRevision = 0

    /// Changes whenever the LCD, an LED, a fader, a V-Pot ring or the assignment display is
    /// written. Excludes the time display and meters, which stream continuously during playback.
    public var displayRevision: Int {
        lcdRevision + ledRevision + faderRevision + ringRevision + assignmentRevision
    }

    public init() {}

    public mutating func apply(_ message: MCUHostMessage) {
        switch message {
        case let .led(note, state):
            leds[note] = state
            ledRevision += 1
        case let .faderPosition(fader, value):
            guard faders.indices.contains(fader) else { return }
            faders[fader] = value
            faderUpdates[fader] += 1
            faderRevision += 1
        case let .vPotRing(strip, value):
            guard vPotRings.indices.contains(strip) else { return }
            vPotRings[strip] = value
            ringRevision += 1
        case let .timecodeDigit(position, code):
            guard timecode.indices.contains(position) else { return }
            timecode[position] = code
            timecodeRevision += 1
        case let .timecodeDigits(codes):
            for (index, code) in codes.prefix(10).enumerated() { timecode[index] = code }
            timecodeRevision += 1
        case let .assignmentDigit(position, code):
            guard assignment.indices.contains(position) else { return }
            assignment[position] = code
            assignmentRevision += 1
        case let .assignmentDigits(codes):
            for (index, code) in codes.prefix(2).enumerated() { assignment[index] = code }
            assignmentRevision += 1
        case let .meter(strip, level):
            guard meters.indices.contains(strip) else { return }
            if level <= 0x0D { meters[strip] = level }
        case let .lcd(offset, text):
            guard offset >= 0 else { return }
            for (index, byte) in text.enumerated() {
                let position = offset + index
                guard position < SurfaceState.lcdLength else { break }
                lcd[position] = byte
            }
            lcdRevision += 1
        default:
            break
        }
    }

    // MARK: LCD helpers

    public var lcdUpperLine: String { Self.ascii(lcd[0..<56]) }
    public var lcdLowerLine: String { Self.ascii(lcd[56..<112]) }

    /// Raw LCD text from `offset`, at most `length` characters, clipped to the end of that line
    /// (the upper line ends at 56, the lower at 112). Not trimmed.
    public func lcdText(offset: Int, length: Int) -> String {
        guard offset >= 0, offset < Self.lcdLength, length > 0 else { return "" }
        let lineEnd = offset < Self.lcdLineLength ? Self.lcdLineLength : Self.lcdLength
        return Self.ascii(lcd[offset..<min(offset + length, lineEnd)])
    }

    /// The 7-character cell of a strip (0...7) on the upper or lower line, trimmed.
    public func lcdCell(strip: Int, lower: Bool = false) -> String {
        guard (0..<8).contains(strip) else { return "" }
        let start = (lower ? 56 : 0) + strip * Self.cellWidth
        let end = min(start + Self.cellWidth, lower ? 112 : 56)
        return Self.ascii(lcd[start..<end]).trimmingCharacters(in: " ")
    }

    // MARK: LED helpers

    public func led(_ note: UInt8) -> MCULEDState? { leds[note] }
    public func led(_ button: MCUButton) -> MCULEDState? { leds[button.rawValue] }

    // MARK: Time-code helpers

    /// Decodes one 7-segment code: returns the character and whether its decimal point is lit.
    /// Codes 0x00–0x1F map to ASCII 0x40–0x5F, 0x20–0x3F map to ASCII 0x20–0x3F, +0x40 = dot.
    /// Code 0x00 ('@') cannot be drawn on a 7-segment digit and is rendered as a blank.
    public static func sevenSegment(_ code: UInt8) -> (character: Character, dot: Bool) {
        let base = code & 0x3F
        let dot = code & 0x40 != 0
        if base == 0x00 { return (" ", dot) }
        let ascii = base < 0x20 ? base + 0x40 : base
        return (Character(Unicode.Scalar(ascii)), dot)
    }

    /// The display as text, left to right, with "." after digits whose dot is lit.
    /// nil if no digit has been written yet.
    public var timecodeText: String? {
        guard timecode.contains(where: { $0 != nil }) else { return nil }
        var out = ""
        for position in stride(from: 9, through: 0, by: -1) {
            let (character, dot) = Self.sevenSegment(timecode[position] ?? 0x20)
            out.append(character)
            if dot { out.append(".") }
        }
        return out
    }

    /// Digit characters left to right (no dots), length 10.
    public var timecodeCharacters: [Character] {
        stride(from: 9, through: 0, by: -1).map { Self.sevenSegment(timecode[$0] ?? 0x20).character }
    }

    /// Interprets the display as Beats (3/2/2/3 digit groups: bars, beats, division, ticks).
    /// Returns nil if any group is not numeric. Whether the display is actually in Beats mode
    /// must be established separately (SMPTE/BEATS LEDs); this layout is unverified on Logic 13.
    public var beatsPosition: BeatsPosition? {
        let chars = timecodeCharacters
        func number(_ range: Range<Int>) -> Int? {
            let text = String(chars[range]).trimmingCharacters(in: " ")
            guard !text.isEmpty else { return nil }
            return Int(text)
        }
        guard let bar = number(0..<3), let beat = number(3..<5),
              let division = number(5..<7), let tick = number(7..<10)
        else { return nil }
        return BeatsPosition(bar: bar, beat: beat, division: division, tick: tick)
    }

    public var assignmentText: String {
        let left = Self.sevenSegment(assignment[1] ?? 0x20)
        let right = Self.sevenSegment(assignment[0] ?? 0x20)
        return String([left.character, right.character]) + (right.dot ? "." : "")
    }

    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { $0 >= 0x20 && $0 < 0x7F ? $0 : 0x20 }, as: UTF8.self)
    }
}

extension String {
    func trimmingCharacters(in character: Character) -> String {
        var s = Substring(self)
        while s.first == character { s = s.dropFirst() }
        while s.last == character { s = s.dropLast() }
        return String(s)
    }
}
