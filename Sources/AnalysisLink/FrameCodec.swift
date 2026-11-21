import Foundation

/// Frame types of the wire format.
public enum FrameType: UInt16, Sendable {
    case analysis = 1
    case hello = 2
}

/// A frame as cut from the byte stream, before its payload is parsed.
public struct RawFrame: Sendable, Equatable {
    public var type: UInt16
    public var payload: Data
}

public enum FrameCodec {
    /// Header + payload for one frame.
    public static func encode(type: FrameType, payload: Data) throws(LinkError) -> Data {
        guard payload.count <= AnalysisLink.maxPayload else { throw .payloadTooLarge(payload.count) }
        var data = Data(capacity: AnalysisLink.headerSize + payload.count)
        data.append(contentsOf: AnalysisLink.magic)
        appendBigEndian(AnalysisLink.protocolVersion, to: &data)
        appendBigEndian(type.rawValue, to: &data)
        appendBigEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    public static func encode(_ frame: AnalysisFrame) throws(LinkError) -> Data {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(frame)
        } catch {
            throw .malformedPayload("cannot encode: \(error)")
        }
        return try encode(type: .analysis, payload: payload)
    }

    public static func encode(_ hello: ServerHello) -> Data {
        // A hello is a few dozen bytes of plain strings; encoding cannot fail.
        let payload = (try? JSONEncoder().encode(hello)) ?? Data()
        return (try? encode(type: .hello, payload: payload)) ?? Data()
    }

    /// Parses and validates an analysis payload.
    public static func decodeAnalysis(_ payload: Data) throws(LinkError) -> AnalysisFrame {
        let frame: AnalysisFrame
        do {
            // The default strategy rejects NaN / Infinity, which JSON cannot carry anyway.
            frame = try JSONDecoder().decode(AnalysisFrame.self, from: payload)
        } catch {
            throw .malformedPayload(Self.describe(error))
        }
        try frame.validate()
        return frame
    }

    public static func decodeHello(_ payload: Data) throws(LinkError) -> ServerHello {
        let hello: ServerHello
        do {
            hello = try JSONDecoder().decode(ServerHello.self, from: payload)
        } catch {
            throw .malformedPayload(Self.describe(error))
        }
        guard hello.isValid else { throw .invalidFrame("not a logic-mcp hello for protocol \(AnalysisLink.protocolVersion)") }
        return hello
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, _): return "missing \"\(key.stringValue)\""
        case let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context):
            return "wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case let DecodingError.dataCorrupted(context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "not valid JSON" : "invalid value at \(path)"
        default: return "not valid JSON"
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Cuts frames out of a byte stream that arrives in arbitrary pieces. After a fatal error it
/// stays failed: the stream position can no longer be trusted.
public struct FrameStreamDecoder: Sendable {
    public let maxPayload: Int
    private var buffer: [UInt8] = []
    private var start = 0
    public private(set) var failure: LinkError?

    public init(maxPayload: Int = AnalysisLink.maxPayload) {
        self.maxPayload = min(maxPayload, AnalysisLink.maxPayload)
    }

    /// Bytes held while waiting for the rest of a frame (bounded by header + max payload + one read).
    public var bufferedBytes: Int { buffer.count - start }

    public mutating func feed(_ bytes: Data) throws(LinkError) -> [RawFrame] {
        if let failure { throw failure }
        buffer.append(contentsOf: bytes)
        var frames: [RawFrame] = []
        while true {
            let available = buffer.count - start
            // Check the magic as soon as its bytes are here, so garbage fails fast.
            let magicBytes = min(available, AnalysisLink.magic.count)
            for index in 0..<magicBytes where buffer[start + index] != AnalysisLink.magic[index] {
                return try fail(.badMagic, keeping: frames)
            }
            guard available >= AnalysisLink.headerSize else { break }
            let version = readUInt16(at: start + 4)
            guard version == AnalysisLink.protocolVersion else { return try fail(.unsupportedVersion(version), keeping: frames) }
            let type = readUInt16(at: start + 6)
            let length = Int(readUInt32(at: start + 8))
            guard length <= maxPayload else { return try fail(.payloadTooLarge(length), keeping: frames) }
            guard available >= AnalysisLink.headerSize + length else { break }
            let payloadStart = start + AnalysisLink.headerSize
            frames.append(RawFrame(type: type, payload: Data(buffer[payloadStart..<(payloadStart + length)])))
            start = payloadStart + length
        }
        if start > 0, start * 2 >= buffer.count {
            buffer.removeFirst(start)
            start = 0
        }
        return frames
    }

    /// Records a fatal error. Frames completed before it in the same chunk are still returned;
    /// the error is thrown then, or on the next call.
    private mutating func fail(_ error: LinkError, keeping frames: [RawFrame]) throws(LinkError) -> [RawFrame] {
        failure = error
        buffer = []
        start = 0
        if frames.isEmpty { throw error }
        return frames
    }

    private func readUInt16(at offset: Int) -> UInt16 {
        UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16 | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
    }
}
