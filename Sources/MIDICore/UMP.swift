/// Conversion between `MIDIMessage` and Universal MIDI Packets (MIDI 1.0 protocol subset).
///
/// - Channel voice → message type 0x2 (32-bit).
/// - System common / real-time → message type 0x1 (32-bit).
/// - SysEx → message type 0x3 (64-bit "Data 64"), at most **6** payload bytes per packet,
///   F0/F7 not carried; status nibble 0 = complete, 1 = start, 2 = continue, 3 = end.
///
/// Words are always built and read with shifts, never by reinterpreting memory, so the
/// result does not depend on host byte order.
public enum UMP {
    public static let maxSysExBytesPerPacket = 6

    /// One UMP packet: 1, 2, 3 or 4 words.
    public typealias Packet = [UInt32]

    public static func encode(_ message: MIDIMessage, group: UInt8 = 0) -> [Packet] {
        let g = UInt32(group & 0x0F) << 24
        switch message {
        case .sysEx(let payload):
            return encodeSysEx(payload, group: group)
        default:
            let bytes = message.bytes
            let status = UInt32(bytes[0])
            let d1 = bytes.count > 1 ? UInt32(bytes[1]) : 0
            let d2 = bytes.count > 2 ? UInt32(bytes[2]) : 0
            let type: UInt32 = bytes[0] >= 0xF0 ? 0x1 : 0x2
            return [[(type << 28) | g | (status << 16) | (d1 << 8) | d2]]
        }
    }

    public static func encodeSysEx(_ payload: [UInt8], group: UInt8 = 0) -> [Packet] {
        let g = UInt32(group & 0x0F) << 24
        var chunks: [[UInt8]] = stride(from: 0, to: payload.count, by: maxSysExBytesPerPacket).map {
            Array(payload[$0..<min($0 + maxSysExBytesPerPacket, payload.count)])
        }
        if chunks.isEmpty { chunks = [[]] }
        var packets: [Packet] = []
        for (index, chunk) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 {
                status = 0
            } else if index == 0 {
                status = 1
            } else if index == chunks.count - 1 {
                status = 3
            } else {
                status = 2
            }
            var data = chunk.map { UInt32($0 & 0x7F) }
            while data.count < 6 { data.append(0) }
            let w0 = (UInt32(0x3) << 28) | g | (status << 20) | (UInt32(chunk.count) << 16) | (data[0] << 8) | data[1]
            let w1 = (data[2] << 24) | (data[3] << 16) | (data[4] << 8) | data[5]
            packets.append([w0, w1])
        }
        return packets
    }

    /// Number of 32-bit words in a packet, from its message type (top nibble of the first word).
    public static func wordCount(forFirstWord word: UInt32) -> Int {
        switch word >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}

/// Stateful UMP → `MIDIMessage` decoder that reassembles multi-packet SysEx.
public struct UMPDecoder: Sendable {
    public let maxSysExLength: Int
    private var sysExBuffer: [UInt8]?
    private var sysExOverflowed = false

    public init(maxSysExLength: Int = 4096) {
        self.maxSysExLength = maxSysExLength
    }

    /// Decodes a flat word stream. Incomplete trailing packets are ignored.
    public mutating func decode(words: [UInt32]) -> [MIDIMessage] {
        var out: [MIDIMessage] = []
        var index = 0
        while index < words.count {
            let count = UMP.wordCount(forFirstWord: words[index])
            guard index + count <= words.count else { break }
            if let message = decode(packet: Array(words[index..<(index + count)])) {
                out.append(message)
            }
            index += count
        }
        return out
    }

    public mutating func decode(packet: UMP.Packet) -> MIDIMessage? {
        guard let w0 = packet.first else { return nil }
        switch w0 >> 28 {
        case 0x1:
            let status = UInt8((w0 >> 16) & 0xFF)
            let d1 = UInt8((w0 >> 8) & 0x7F)
            let d2 = UInt8(w0 & 0x7F)
            var parser = MIDIByteParser()
            let length = status >= 0xF8 ? 0 : MIDIByteParser.dataLength(for: status)
            let bytes = [status, d1, d2].prefix(1 + length)
            return parser.feed(bytes).first
        case 0x2:
            let status = UInt8((w0 >> 16) & 0xFF)
            guard status >= 0x80, status < 0xF0 else { return nil }
            let d1 = UInt8((w0 >> 8) & 0x7F)
            let d2 = UInt8(w0 & 0x7F)
            return MIDIByteParser.makeMessage([status, d1, d2])
        case 0x3:
            guard packet.count >= 2 else { return nil }
            let w1 = packet[1]
            let status = (w0 >> 20) & 0x0F
            let count = min(Int((w0 >> 16) & 0x0F), UMP.maxSysExBytesPerPacket)
            let all: [UInt8] = [
                UInt8((w0 >> 8) & 0x7F), UInt8(w0 & 0x7F),
                UInt8((w1 >> 24) & 0x7F), UInt8((w1 >> 16) & 0x7F),
                UInt8((w1 >> 8) & 0x7F), UInt8(w1 & 0x7F),
            ]
            let data = Array(all.prefix(count))
            switch status {
            case 0:  // complete in one packet
                sysExBuffer = nil
                return .sysEx(data)
            case 1:  // start
                sysExBuffer = data
                sysExOverflowed = false
                return nil
            case 2:  // continue
                append(data)
                return nil
            case 3:  // end
                append(data)
                defer { sysExBuffer = nil; sysExOverflowed = false }
                guard let buffer = sysExBuffer, !sysExOverflowed else { return nil }
                return .sysEx(buffer)
            default:
                return nil
            }
        default:
            return nil  // utility, MIDI 2.0 and other types are ignored
        }
    }

    private mutating func append(_ data: [UInt8]) {
        guard sysExBuffer != nil else { return }  // continue/end without start: drop
        if sysExBuffer!.count + data.count > maxSysExLength {
            sysExOverflowed = true
        } else {
            sysExBuffer!.append(contentsOf: data)
        }
    }
}
