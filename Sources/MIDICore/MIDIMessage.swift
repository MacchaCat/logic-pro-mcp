/// A MIDI 1.0 message. Channels are 0-based (0...15).
public enum MIDIMessage: Sendable, Hashable {
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case polyPressure(channel: UInt8, note: UInt8, pressure: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case channelPressure(channel: UInt8, pressure: UInt8)
    /// 14-bit value, 0...16383 (8192 = centre).
    case pitchBend(channel: UInt8, value: UInt16)
    /// System exclusive payload **without** the leading F0 and trailing F7.
    case sysEx([UInt8])
    case mtcQuarterFrame(UInt8)
    /// Song Position Pointer in MIDI beats (one MIDI beat = a sixteenth note).
    case songPosition(UInt16)
    case songSelect(UInt8)
    case tuneRequest
    case timingClock
    case start
    case `continue`
    case stop
    case activeSensing
    case systemReset

    /// Encodes the message as a MIDI 1.0 byte stream (with F0/F7 framing for SysEx).
    public var bytes: [UInt8] {
        switch self {
        case let .noteOff(c, n, v): return [0x80 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case let .noteOn(c, n, v): return [0x90 | (c & 0x0F), n & 0x7F, v & 0x7F]
        case let .polyPressure(c, n, p): return [0xA0 | (c & 0x0F), n & 0x7F, p & 0x7F]
        case let .controlChange(c, cc, v): return [0xB0 | (c & 0x0F), cc & 0x7F, v & 0x7F]
        case let .programChange(c, p): return [0xC0 | (c & 0x0F), p & 0x7F]
        case let .channelPressure(c, p): return [0xD0 | (c & 0x0F), p & 0x7F]
        case let .pitchBend(c, v):
            let clamped = min(v, 0x3FFF)
            return [0xE0 | (c & 0x0F), UInt8(clamped & 0x7F), UInt8(clamped >> 7)]
        case let .sysEx(payload): return [0xF0] + payload.map { $0 & 0x7F } + [0xF7]
        case let .mtcQuarterFrame(v): return [0xF1, v & 0x7F]
        case let .songPosition(v):
            let clamped = min(v, 0x3FFF)
            return [0xF2, UInt8(clamped & 0x7F), UInt8(clamped >> 7)]
        case let .songSelect(v): return [0xF3, v & 0x7F]
        case .tuneRequest: return [0xF6]
        case .timingClock: return [0xF8]
        case .start: return [0xFA]
        case .continue: return [0xFB]
        case .stop: return [0xFC]
        case .activeSensing: return [0xFE]
        case .systemReset: return [0xFF]
        }
    }

    /// True for System Real-Time messages (F8–FF).
    public var isRealTime: Bool {
        switch self {
        case .timingClock, .start, .continue, .stop, .activeSensing, .systemReset: return true
        default: return false
        }
    }
}

extension MIDIMessage: CustomStringConvertible {
    public var description: String { bytes.hexString }
}

extension Sequence where Element == UInt8 {
    /// Space-separated upper-case hex, e.g. "90 5E 7F".
    public var hexString: String {
        map { byte in
            let s = String(byte, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: " ")
    }
}

/// Parses a hex string such as "F0 00 00 66 14 00 F7" into bytes. Returns nil on malformed input.
public func parseHexBytes(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
        guard let value = UInt8(token, radix: 16) else { return nil }
        out.append(value)
    }
    return out
}
