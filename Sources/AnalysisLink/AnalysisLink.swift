/// Phase 5: the loopback TCP link between the analysis plug-in (client) and the MCP server
/// (listener on 127.0.0.1): frame format and validation, listener, client, the plug-in side frame
/// builder, and a fake plug-in for tests and `serve --fake`.
///
/// Wire format, version 1 (all integers big-endian):
///
/// | offset | size | field |
/// |---|---|---|
/// | 0 | 4 | magic `LMAF` (0x4C 0x4D 0x41 0x46) |
/// | 4 | 2 | protocol version (1) |
/// | 6 | 2 | frame type: 1 = analysis (plug-in -> server), 2 = hello (server -> plug-in) |
/// | 8 | 4 | payload length in bytes (at most 65536) |
/// | 12 | n | payload: one UTF-8 JSON object (`AnalysisFrame` or `ServerHello`) |
///
/// The server sends a hello frame as soon as a connection is accepted; the client only treats a
/// connection as established after it has seen a valid hello, so it never streams into some other
/// program that happens to listen on one of the ports. Every frame the server receives is
/// untrusted input: a bad header closes the connection, a bad payload is rejected and counted.
public enum AnalysisLink {
    /// The listener takes the first free port of these; the client tries them in order.
    public static let defaultPorts: [UInt16] = [47_810, 47_811, 47_812, 47_813]
    public static let protocolVersion: UInt16 = 1
    public static let magic: [UInt8] = Array("LMAF".utf8)
    public static let headerSize = 12
    public static let maxPayload = 65_536
    public static let serverName = "logic-mcp"
}

/// Errors on the link. Header errors make the stream unusable; payload errors only reject one frame.
public enum LinkError: Error, Sendable, Equatable, CustomStringConvertible {
    case badMagic
    case unsupportedVersion(UInt16)
    case unknownFrameType(UInt16)
    case payloadTooLarge(Int)
    case malformedPayload(String)
    case invalidFrame(String)

    public var description: String {
        switch self {
        case .badMagic: return "bad magic (not a LogicMCP analysis stream)"
        case let .unsupportedVersion(version): return "unsupported protocol version \(version)"
        case let .unknownFrameType(type): return "unknown frame type \(type)"
        case let .payloadTooLarge(size): return "payload of \(size) bytes exceeds \(AnalysisLink.maxPayload)"
        case let .malformedPayload(detail): return "malformed payload: \(detail)"
        case let .invalidFrame(detail): return "invalid frame: \(detail)"
        }
    }

    /// True when the byte stream can no longer be trusted (the connection must be closed).
    public var isFatal: Bool {
        switch self {
        case .badMagic, .unsupportedVersion, .payloadTooLarge: return true
        case .unknownFrameType, .malformedPayload, .invalidFrame: return false
        }
    }
}
