/// Incremental MIDI 1.0 byte-stream parser.
///
/// Handles running status, System Real-Time bytes interleaved anywhere (including inside SysEx),
/// SysEx framing, and stray data bytes. SysEx payloads longer than `maxSysExLength` are dropped
/// so a malformed stream cannot grow memory without bound.
public struct MIDIByteParser: Sendable {
    public let maxSysExLength: Int

    private var runningStatus: UInt8?
    private var pending: [UInt8] = []
    private var sysEx: [UInt8]?
    private var sysExOverflowed = false

    public init(maxSysExLength: Int = 4096) {
        self.maxSysExLength = maxSysExLength
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        for byte in bytes {
            if let message = feed(byte) { out.append(message) }
        }
        return out
    }

    public mutating func feed(_ byte: UInt8) -> MIDIMessage? {
        // System Real-Time: may appear anywhere and does not affect running status.
        if byte >= 0xF8 {
            switch byte {
            case 0xF8: return .timingClock
            case 0xFA: return .start
            case 0xFB: return .continue
            case 0xFC: return .stop
            case 0xFE: return .activeSensing
            case 0xFF: return .systemReset
            default: return nil  // F9, FD undefined
            }
        }

        if byte == 0xF0 {
            sysEx = []
            sysExOverflowed = false
            runningStatus = nil
            pending.removeAll()
            return nil
        }

        if byte == 0xF7 {
            defer { sysEx = nil; sysExOverflowed = false }
            guard let payload = sysEx, !sysExOverflowed else { return nil }
            return .sysEx(payload)
        }

        if sysEx != nil {
            if byte < 0x80 {
                if sysEx!.count < maxSysExLength {
                    sysEx!.append(byte)
                } else {
                    sysExOverflowed = true
                }
                return nil
            }
            // Any other status byte terminates an unterminated SysEx (which is discarded).
            sysEx = nil
            sysExOverflowed = false
        }

        if byte >= 0x80 {
            pending.removeAll()
            if byte >= 0xF0 {
                // System Common cancels running status.
                runningStatus = nil
                switch byte {
                case 0xF6: return .tuneRequest
                case 0xF1, 0xF2, 0xF3:
                    pending = [byte]
                    return nil
                default: return nil  // F4, F5 undefined
                }
            }
            runningStatus = byte
            pending = [byte]
            return nil
        }

        // Data byte.
        if pending.isEmpty {
            guard let status = runningStatus else { return nil }  // stray data byte
            pending = [status]
        }
        pending.append(byte)

        let status = pending[0]
        let needed = Self.dataLength(for: status)
        guard pending.count - 1 >= needed else { return nil }
        let message = Self.makeMessage(pending)
        pending.removeAll()
        return message
    }

    static func dataLength(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0xF0:
            switch status {
            case 0xF1, 0xF3: return 1
            case 0xF2: return 2
            default: return 0
            }
        default: return 2
        }
    }

    static func makeMessage(_ b: [UInt8]) -> MIDIMessage? {
        let status = b[0]
        let channel = status & 0x0F
        switch status & 0xF0 {
        case 0x80: return .noteOff(channel: channel, note: b[1], velocity: b[2])
        case 0x90: return .noteOn(channel: channel, note: b[1], velocity: b[2])
        case 0xA0: return .polyPressure(channel: channel, note: b[1], pressure: b[2])
        case 0xB0: return .controlChange(channel: channel, controller: b[1], value: b[2])
        case 0xC0: return .programChange(channel: channel, program: b[1])
        case 0xD0: return .channelPressure(channel: channel, pressure: b[1])
        case 0xE0: return .pitchBend(channel: channel, value: UInt16(b[1]) | (UInt16(b[2]) << 7))
        default:
            switch status {
            case 0xF1: return .mtcQuarterFrame(b[1])
            case 0xF2: return .songPosition(UInt16(b[1]) | (UInt16(b[2]) << 7))
            case 0xF3: return .songSelect(b[1])
            default: return nil
            }
        }
    }
}
