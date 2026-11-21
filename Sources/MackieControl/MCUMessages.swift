import MIDICore

/// LED state sent by the host: `90 id 00` off, `90 id 01` flashing, `90 id 7F` on.
public enum MCULEDState: Sendable, Hashable {
    case off, flashing, on

    init(velocity: UInt8) {
        switch velocity {
        case 0x00: self = .off
        case 0x01: self = .flashing
        default: self = .on
        }
    }
}

/// A message from the host (Logic) to the surface (us), already interpreted.
public enum MCUHostMessage: Sendable, Hashable {
    case led(note: UInt8, state: MCULEDState)
    /// Fader 0...7 = strips, 8 = master. Value 0...16383.
    case faderPosition(fader: Int, value: UInt16)
    /// V-Pot LED ring, raw `0 p mm vvvv` byte.
    case vPotRing(strip: Int, value: UInt8)
    /// One time-code digit. Position 0 is the rightmost digit. Raw 7-segment code.
    case timecodeDigit(position: Int, code: UInt8)
    /// Several time-code digits; the first element is the rightmost digit.
    case timecodeDigits([UInt8])
    /// Assignment display digit: position 0 = right, 1 = left.
    case assignmentDigit(position: Int, code: UInt8)
    case assignmentDigits([UInt8])
    /// Meter level: strip 0...7, level nibble (0...0xD, 0xE set overload, 0xF clear overload).
    case meter(strip: Int, level: UInt8)
    /// LCD write: offset 0...0x6F, ASCII bytes.
    case lcd(offset: Int, text: [UInt8])
    case deviceQuery
    case hostConnectionReply(serial: [UInt8], response: [UInt8])
    case firmwareVersionRequest
    case goOffline
    /// Configuration and other recognised-but-unmodelled host commands (0A, 0B, 0C, 0E, 20, 21, 61–63, 72 …).
    case command(id: UInt8, data: [UInt8])
    /// A Mackie SysEx addressed to a different model (Logic probes several). Ignored by the surface.
    case otherModel(model: UInt8, payload: [UInt8])
    /// Anything we do not interpret (e.g. pitch bend on channel 10).
    case unknown(MIDIMessage)
}

/// A message from the surface (us) to the host (Logic).
public enum MCUSurfaceMessage: Sendable, Hashable {
    case button(note: UInt8, pressed: Bool)
    case faderTouch(fader: Int, touched: Bool)
    case fader(fader: Int, value: UInt16)
    /// Relative V-Pot rotation; positive = clockwise. Magnitude is clamped to 1...63.
    case vPot(strip: Int, delta: Int)
    /// Relative jog wheel movement; positive = forward.
    case jog(delta: Int)
    case hostConnectionQuery(serial: [UInt8], challenge: [UInt8])
    case hostConnectionConfirmation(serial: [UInt8])
    case firmwareVersion([UInt8])
}

public struct MCUCodec: Sendable {
    public let model: MCUModel

    public init(model: MCUModel = .mackieControl) {
        self.model = model
    }

    public var sysExHeader: [UInt8] { mcuManufacturerID + [model.rawValue] }

    // MARK: Host → surface

    public func decode(_ message: MIDIMessage) -> MCUHostMessage {
        switch message {
        case let .noteOn(channel, note, velocity) where channel == 0:
            return .led(note: note, state: MCULEDState(velocity: velocity))
        case let .noteOff(channel, note, _) where channel == 0:
            return .led(note: note, state: .off)
        case let .pitchBend(channel, value) where channel <= 8:
            return .faderPosition(fader: Int(channel), value: value)
        case let .controlChange(channel, controller, value) where channel == 0:
            switch controller {
            case 0x30...0x37: return .vPotRing(strip: Int(controller - 0x30), value: value)
            case 0x40...0x49: return .timecodeDigit(position: Int(controller - 0x40), code: value)
            case 0x4A...0x4B: return .assignmentDigit(position: Int(controller - 0x4A), code: value)
            default: return .unknown(message)
            }
        case let .channelPressure(channel, pressure) where channel == 0:
            return .meter(strip: Int((pressure >> 4) & 0x07), level: pressure & 0x0F)
        case let .sysEx(payload):
            return decodeSysEx(payload, original: message)
        default:
            return .unknown(message)
        }
    }

    private func decodeSysEx(_ payload: [UInt8], original: MIDIMessage) -> MCUHostMessage {
        guard payload.count >= 5, Array(payload[0..<3]) == mcuManufacturerID else {
            return .unknown(original)
        }
        let modelByte = payload[3]
        guard modelByte == model.rawValue else {
            return .otherModel(model: modelByte, payload: Array(payload[4...]))
        }
        let id = payload[4]
        let data = Array(payload[5...])
        switch id {
        case 0x00: return .deviceQuery
        case 0x02:
            guard data.count >= 11 else { return .command(id: id, data: data) }
            return .hostConnectionReply(serial: Array(data[0..<7]), response: Array(data[7..<11]))
        case 0x0F: return .goOffline
        case 0x10: return .timecodeDigits(data)
        case 0x11: return .assignmentDigits(data)
        case 0x12:
            guard let offset = data.first else { return .command(id: id, data: data) }
            return .lcd(offset: Int(offset), text: Array(data.dropFirst()))
        case 0x13: return .firmwareVersionRequest
        default: return .command(id: id, data: data)
        }
    }

    // MARK: Surface → host

    public func encode(_ message: MCUSurfaceMessage) -> MIDIMessage {
        switch message {
        case let .button(note, pressed):
            return .noteOn(channel: 0, note: note, velocity: pressed ? 0x7F : 0x00)
        case let .faderTouch(fader, touched):
            return .noteOn(channel: 0, note: MCUButton.faderTouch(fader), velocity: touched ? 0x7F : 0x00)
        case let .fader(fader, value):
            return .pitchBend(channel: UInt8(min(max(fader, 0), 8)), value: min(value, 0x3FFF))
        case let .vPot(strip, delta):
            return .controlChange(channel: 0, controller: 0x10 + UInt8(strip & 7), value: Self.relative(delta))
        case let .jog(delta):
            return .controlChange(channel: 0, controller: 0x3C, value: Self.relative(delta))
        case let .hostConnectionQuery(serial, challenge):
            return .sysEx(sysExHeader + [0x01] + Self.fixed(serial, 7) + Self.fixed(challenge, 4))
        case let .hostConnectionConfirmation(serial):
            return .sysEx(sysExHeader + [0x03] + Self.fixed(serial, 7))
        case let .firmwareVersion(version):
            return .sysEx(sysExHeader + [0x14] + Self.fixed(version, 5))
        }
    }

    /// Sign-magnitude relative encoding `0 s nnnnnn`: s = 0 clockwise / forward, 1 counter-clockwise.
    static func relative(_ delta: Int) -> UInt8 {
        let magnitude = UInt8(min(max(abs(delta), 1), 63))
        return delta < 0 ? (0x40 | magnitude) : magnitude
    }

    private static func fixed(_ bytes: [UInt8], _ length: Int) -> [UInt8] {
        var out = Array(bytes.prefix(length)).map { $0 & 0x7F }
        while out.count < length { out.append(0x20) }
        return out
    }
}
