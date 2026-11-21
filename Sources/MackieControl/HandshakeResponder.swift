/// Answers the host's identification requests the way a Mackie Control does.
///
/// The surface issues the challenge, so any response from the host is accepted
/// (Logic Control MIDI Implementation, p. 240). Requests for other models are ignored.
public struct HandshakeResponder: Sendable {
    public enum Phase: String, Sendable, Codable {
        /// No identification traffic seen yet.
        case idle
        /// Host sent Device Query; we answered with Host Connection Query.
        case queried
        /// Host sent Host Connection Reply; we confirmed.
        case confirmed
        /// Host sent Go Offline.
        case offline
    }

    public let serial: [UInt8]
    public let challenge: [UInt8]
    public let firmware: [UInt8]
    public private(set) var phase: Phase = .idle

    public init(serial: String = "LMCP001", challenge: [UInt8] = [0x01, 0x02, 0x03, 0x04], firmware: String = "V1.00") {
        self.serial = Array(serial.utf8.prefix(7))
        self.challenge = challenge
        self.firmware = Array(firmware.utf8.prefix(5))
    }

    /// Returns the replies to send for a host message (usually zero or one).
    public mutating func respond(to message: MCUHostMessage) -> [MCUSurfaceMessage] {
        switch message {
        case .deviceQuery:
            phase = .queried
            return [.hostConnectionQuery(serial: serial, challenge: challenge)]
        case .hostConnectionReply:
            phase = .confirmed
            return [.hostConnectionConfirmation(serial: serial)]
        case .firmwareVersionRequest:
            return [.firmwareVersion(firmware)]
        case .goOffline:
            phase = .offline
            return []
        default:
            return []
        }
    }
}
