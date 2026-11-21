import Foundation

/// A fader level in dB, where silence (fader at the bottom) is minus infinity.
///
/// Encodes as a JSON number, or as the string "-inf" for silence: JSON has no infinity and
/// `JSONEncoder` refuses non-finite doubles.
public enum VolumeLevel: Sendable, Hashable, Codable, CustomStringConvertible {
    case db(Double)
    case minusInfinity

    public var description: String {
        switch self {
        case .minusInfinity: return "-inf dB"
        case .db(let value): return String(format: "%+.1f dB", value)
        }
    }

    /// nil for silence.
    public var finiteDB: Double? {
        if case .db(let value) = self { return value }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = value.isFinite ? .db(value) : .minusInfinity
        } else {
            let text = try container.decode(String.self)
            guard let level = VolumeLevel.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a volume: \(text)")
            }
            self = level
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .minusInfinity: try container.encode("-inf")
        case .db(let value): try container.encode((value * 10).rounded() / 10)
        }
    }

    /// Accepts "-inf", "-oo", "silence" (any case) or a number.
    public static func parse(_ text: String) -> VolumeLevel? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["-inf", "-infinity", "-oo", "silence", "-∞"].contains(trimmed) { return .minusInfinity }
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return .db(value)
    }
}

/// Fader position (pitch bend, 0...16383) ↔ dB, from the calibration measured on Logic 13.0
/// (docs/appendix/logic13-mcu-facts.md, "Faders"): the positions are Logic's own echoes and the
/// dB values what its LCD showed for them. Between measured points the mapping is
/// piecewise-linear, which is an approximation: Logic's LCD text is the authority when shown.
public enum FaderCalibration {
    /// (echoed position, dB shown by Logic). Position 0 is −∞.
    public static let points: [(position: Int, db: Double)] = [
        (99, -106.0), (495, -59.6), (994, -55.0), (1994, -45.3), (2995, -35.6),
        (3990, -30.0), (4995, -22.6), (5990, -17.1), (6987, -12.8), (8178, -9.0),
        (8962, -7.6), (9990, -5.8), (10969, -3.7), (11965, -1.2), (12443, 0.0),
        (12967, 1.3), (13976, 3.8), (14845, 6.0),
    ]

    /// Logic clamps surface moves above this position to +6.0 dB.
    public static let maxPosition = 14845
    public static let maxDB = 6.0
    /// The lowest finite level a target may ask for: the lowest measured point.
    public static let minFiniteDB = -106.0

    /// dB for a fader position. Positions between 1 and 98 lie below the lowest measured point
    /// and are extrapolated with 20·log10 (rough); 0 is −∞; above the maximum reads as +6.0.
    public static func level(forPosition position: Int) -> VolumeLevel {
        if position <= 0 { return .minusInfinity }
        let first = points[0]
        if position < first.position {
            return .db(first.db + 20 * log10(Double(position) / Double(first.position)))
        }
        if position >= maxPosition { return .db(maxDB) }
        if let exact = points.first(where: { $0.position == position }) { return .db(exact.db) }
        for index in 1..<points.count where position <= points[index].position {
            let lower = points[index - 1], upper = points[index]
            let fraction = Double(position - lower.position) / Double(upper.position - lower.position)
            return .db(lower.db + fraction * (upper.db - lower.db))
        }
        return .db(maxDB)
    }

    /// Fader position for a level, or nil when outside −106…+6 dB (−∞ maps to 0).
    public static func position(for level: VolumeLevel) -> Int? {
        guard case .db(let db) = level else { return 0 }
        guard db >= minFiniteDB - 0.0001, db <= maxDB + 0.0001 else { return nil }
        if db >= maxDB { return maxPosition }
        if db <= points[0].db { return points[0].position }
        if let exact = points.first(where: { $0.db == db }) { return exact.position }
        for index in 1..<points.count where db <= points[index].db {
            let lower = points[index - 1], upper = points[index]
            let fraction = (db - lower.db) / (upper.db - lower.db)
            return Int((Double(lower.position) + fraction * Double(upper.position - lower.position)).rounded())
        }
        return maxPosition
    }

    /// Local slope in dB per position step around `position` (for closed-loop corrections).
    public static func slope(atPosition position: Int) -> Double {
        let clamped = min(max(position, points[0].position), maxPosition)
        for index in 1..<points.count where clamped <= points[index].position {
            let lower = points[index - 1], upper = points[index]
            return (upper.db - lower.db) / Double(upper.position - lower.position)
        }
        let last = points.count - 1
        return (points[last].db - points[last - 1].db) / Double(points[last].position - points[last - 1].position)
    }
}

/// Parsers for the values Logic writes into the lower LCD line in the multi-track view.
public enum MixerLCD {
    /// Pan as shown in the Pan assignment: "0", "+3", "-3" (range −64…+63). Strict: anything
    /// else (dB text, "Muted", "--", a parameter name) is nil.
    public static func pan(_ cell: String) -> Int? {
        let text = cell.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 3 else { return nil }
        var digits = Substring(text)
        var sign = 1
        if let first = digits.first, first == "+" || first == "-" {
            sign = first == "-" ? -1 : 1
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit), let magnitude = Int(digits) else { return nil }
        if magnitude != 0, text.first != "+", text.first != "-" { return nil }
        let value = sign * magnitude
        return (-64...63).contains(value) ? value : nil
    }

    /// The volume text Logic shows in a strip's lower cell after a fader move: "-1.2 dB",
    /// "+0.0 dB", "-12.8 dB" (8 characters, spilling into the next cell), "-106 dB", "-oo dB".
    /// `raw` is the line from the strip's cell start; on the last strip the text is cut to
    /// "-12.8 d", which is accepted too.
    public static func volume(_ raw: String) -> VolumeLevel? {
        let text = String(raw.prefix(8)).trimmingCharacters(in: .whitespaces)
        guard let space = text.firstIndex(of: " ") else { return nil }
        let number = String(text[..<space])
        let unit = text[text.index(after: space)...]
        guard unit == "dB" || unit == "d" else { return nil }
        if number == "-oo" { return .minusInfinity }
        guard let first = number.first, first == "+" || first == "-",
              number.dropFirst().allSatisfy({ $0.isASCIIDigit || $0 == "." }),
              let value = Double(number) else { return nil }
        return .db(value)
    }

    /// Lower-cell texts Logic shows briefly after a mute toggle (observed on strip 1).
    public static func isMuteMessage(_ cell: String) -> Bool {
        let text = cell.trimmingCharacters(in: .whitespaces)
        return text == "Muted" || text == "--"
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
