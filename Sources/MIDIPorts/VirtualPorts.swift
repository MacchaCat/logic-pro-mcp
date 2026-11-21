import CoreMIDI
import Foundation
import MIDICore
import Synchronization

/// Fixed names of the server's virtual endpoints. Logic binds control surfaces and
/// controller assignments to ports by name, so these must never change.
public enum PortNames {
    /// Mackie Control, both directions (a source Logic reads, a destination Logic writes).
    public static let mcu = "LogicMCP MCU"
    /// Controller-assignment triggers (server → Logic).
    public static let keys = "LogicMCP Keys"
    /// Note data for recording (server → Logic).
    public static let notes = "LogicMCP Notes"
    /// MIDI Clock / Song Position Pointer from Logic (Logic → server).
    public static let sync = "LogicMCP Sync"
}

public enum MIDIPortError: Error, CustomStringConvertible {
    case os(OSStatus, String)
    case eventListFull

    public var description: String {
        switch self {
        case let .os(status, call): return "\(call) failed with OSStatus \(status)"
        case .eventListFull: return "a single UMP packet did not fit into an event list"
        }
    }
}

/// How SysEx is sent from a virtual source. UMP is the modern path; the legacy
/// `MIDIPacketList` path is a fallback in case Logic does not receive UMP SysEx intact
/// (research §8.2, unverified on Logic 13).
public enum SysExPath: String, Sendable {
    case ump
    case legacy
}

public struct EndpointInfo: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case source, destination }
    public var name: String
    public var kind: Kind
    public var uniqueID: Int32
    /// False when CoreMIDI refused the ID (usually because another endpoint already has it).
    public var uniqueIDApplied: Bool
}

/// Stable, positive, non-zero unique ID derived from the endpoint name (FNV-1a, 32-bit).
/// Swift's `Hasher` is seeded per launch and must not be used for this.
public func stableUniqueID(name: String, kind: EndpointInfo.Kind) -> Int32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in "LogicMCP|\(kind.rawValue)|\(name)".utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    let positive = Int32(bitPattern: hash & 0x7FFF_FFFF)
    return positive == 0 ? 1 : positive
}

/// A virtual MIDI source: what we send here appears to Logic as input from this port.
public final class VirtualSource: MIDIOutput {
    public let endpoint: MIDIEndpointRef
    public let sysExPath: SysExPath

    init(endpoint: MIDIEndpointRef, sysExPath: SysExPath) {
        self.endpoint = endpoint
        self.sysExPath = sysExPath
    }

    public func send(_ messages: [MIDIMessage]) throws {
        var umpPackets: [UMP.Packet] = []
        for message in messages {
            if case .sysEx = message, sysExPath == .legacy {
                try flush(&umpPackets)
                try sendLegacy(message.bytes)
            } else {
                umpPackets += UMP.encode(message)
            }
        }
        try flush(&umpPackets)
    }

    private func flush(_ packets: inout [UMP.Packet]) throws {
        guard !packets.isEmpty else { return }
        try sendUMP(packets)
        packets.removeAll()
    }

    private func sendUMP(_ packets: [UMP.Packet]) throws {
        // MIDIEventListAdd is imported as non-optional, so never let it run out of room:
        // budget each packet as a fresh MIDIEventPacket header (12 bytes) plus its words.
        let byteSize = 4096
        let listHeader = 8
        var remaining = packets[...]
        while !remaining.isEmpty {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 8)
            defer { raw.deallocate() }
            let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
            var current = MIDIEventListInit(list, ._1_0)
            var used = listHeader
            var added = 0
            while let packet = remaining.first {
                let cost = 12 + packet.count * 4
                guard used + cost <= byteSize - 64 else { break }
                current = packet.withUnsafeBufferPointer { words in
                    MIDIEventListAdd(list, byteSize, current, 0, words.count, words.baseAddress!)
                }
                used += cost
                added += 1
                remaining = remaining.dropFirst()
            }
            guard added > 0 else { throw MIDIPortError.eventListFull }
            let status = MIDIReceivedEventList(endpoint, list)
            guard status == noErr else { throw MIDIPortError.os(status, "MIDIReceivedEventList") }
        }
    }

    private func sendLegacy(_ bytes: [UInt8]) throws {
        let byteSize = 1024 + bytes.count
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteSize, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let first = MIDIPacketListInit(list)
        // Sized above so that a single packet always fits.
        _ = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(list, byteSize, first, 0, buffer.count, buffer.baseAddress!)
        }
        let status = MIDIReceived(endpoint, list)
        guard status == noErr else { throw MIDIPortError.os(status, "MIDIReceived") }
    }
}

/// The four endpoints of the server, created together and owned for the process lifetime.
public final class VirtualPortSet: Sendable {
    public let mcuOut: VirtualSource
    public let keysOut: VirtualSource
    public let notesOut: VirtualSource
    public let mcuIn: AsyncStream<MIDIMessage>
    /// Logic's MIDI clock / SPP, each message with its receipt time (taken in the CoreMIDI
    /// callback) and its packet timestamp, so that note timing does not depend on how soon the
    /// server gets to the message.
    public let syncIn: AsyncStream<TimedMIDIMessage>
    /// The destination endpoints behind `mcuIn` / `syncIn` (Logic sends to these).
    public let mcuInEndpoint: MIDIEndpointRef
    public let syncInEndpoint: MIDIEndpointRef
    public let endpoints: [EndpointInfo]

    private let client: MIDIClientRef
    private let finishStreams: @Sendable () -> Void

    private init(
        client: MIDIClientRef, mcuOut: VirtualSource, keysOut: VirtualSource, notesOut: VirtualSource,
        mcuIn: AsyncStream<MIDIMessage>, syncIn: AsyncStream<TimedMIDIMessage>,
        mcuInEndpoint: MIDIEndpointRef, syncInEndpoint: MIDIEndpointRef,
        endpoints: [EndpointInfo], finishStreams: @escaping @Sendable () -> Void
    ) {
        self.mcuInEndpoint = mcuInEndpoint
        self.syncInEndpoint = syncInEndpoint
        self.client = client
        self.mcuOut = mcuOut
        self.keysOut = keysOut
        self.notesOut = notesOut
        self.mcuIn = mcuIn
        self.syncIn = syncIn
        self.endpoints = endpoints
        self.finishStreams = finishStreams
    }

    /// Creates the client and all endpoints. Must not be called from a main-actor context's
    /// closure: CoreMIDI invokes the receive blocks on its own thread (research §8.2).
    public static func create(sysExPath: SysExPath = .ump) throws -> VirtualPortSet {
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("logic-mcp" as CFString, &client, nil)
        guard status == noErr else { throw MIDIPortError.os(status, "MIDIClientCreateWithBlock") }

        var endpoints: [EndpointInfo] = []

        func makeSource(_ name: String) throws -> VirtualSource {
            var ref = MIDIEndpointRef()
            let status = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &ref)
            guard status == noErr else { throw MIDIPortError.os(status, "MIDISourceCreateWithProtocol(\(name))") }
            endpoints.append(applyUniqueID(ref, name: name, kind: .source))
            return VirtualSource(endpoint: ref, sysExPath: sysExPath)
        }

        let mcuOut = try makeSource(PortNames.mcu)
        let keysOut = try makeSource(PortNames.keys)
        let notesOut = try makeSource(PortNames.notes)

        let (mcuIn, mcuContinuation) = AsyncStream.makeStream(of: MIDIMessage.self, bufferingPolicy: .bufferingNewest(8192))
        let (syncIn, syncContinuation) = AsyncStream.makeStream(of: TimedMIDIMessage.self, bufferingPolicy: .bufferingNewest(8192))

        let mcuRef = try makeDestination(client: client, name: PortNames.mcu) { message, _, _ in
            mcuContinuation.yield(message)
        }
        endpoints.append(applyUniqueID(mcuRef, name: PortNames.mcu, kind: .destination))
        let syncRef = try makeDestination(client: client, name: PortNames.sync) { message, receivedAt, timestamp in
            syncContinuation.yield(TimedMIDIMessage(message: message, receivedAt: receivedAt, timestamp: timestamp))
        }
        endpoints.append(applyUniqueID(syncRef, name: PortNames.sync, kind: .destination))

        return VirtualPortSet(
            client: client, mcuOut: mcuOut, keysOut: keysOut, notesOut: notesOut,
            mcuIn: mcuIn, syncIn: syncIn, mcuInEndpoint: mcuRef, syncInEndpoint: syncRef, endpoints: endpoints,
            finishStreams: {
                mcuContinuation.finish()
                syncContinuation.finish()
            }
        )
    }

    /// Tears the endpoints down (also happens automatically when the process exits).
    public func dispose() {
        finishStreams()
        for endpoint in [mcuOut.endpoint, keysOut.endpoint, notesOut.endpoint, mcuInEndpoint, syncInEndpoint] {
            MIDIEndpointDispose(endpoint)
        }
        MIDIClientDispose(client)
    }

    private static func applyUniqueID(_ ref: MIDIEndpointRef, name: String, kind: EndpointInfo.Kind) -> EndpointInfo {
        let id = stableUniqueID(name: name, kind: kind)
        let status = MIDIObjectSetIntegerProperty(ref, kMIDIPropertyUniqueID, id)
        return EndpointInfo(name: name, kind: kind, uniqueID: id, uniqueIDApplied: status == noErr)
    }

    /// Creates a destination whose receive block first notes the receipt time (host time and
    /// `ContinuousClock` together), then copies each packet's UMP words out synchronously,
    /// decodes them and delivers every message with the receipt time and its packet's
    /// timestamp (nil for 0 = "now"). No awaiting, locking beyond a short mutex, or unbounded
    /// work happens on CoreMIDI's thread.
    private static func makeDestination(
        client: MIDIClientRef, name: String,
        deliver: @escaping @Sendable (MIDIMessage, ContinuousClock.Instant, ContinuousClock.Instant?) -> Void
    ) throws -> MIDIEndpointRef {
        let decoder = DecoderBox()
        let timebase = HostTimebase.current
        var ref = MIDIEndpointRef()
        let status = MIDIDestinationCreateWithProtocol(client, name as CFString, ._1_0, &ref) {
            @Sendable eventList, _ in
            let receivedHost = mach_absolute_time()
            let receivedAt = ContinuousClock.now
            var budget = DecoderBox.maxWordsPerCallback
            var words: [UInt32] = []
            words.reserveCapacity(64)
            for packet in eventList.unsafeSequence() {
                guard budget > 0 else { break }
                words.removeAll(keepingCapacity: true)
                for word in packet.sequence() {
                    words.append(word)
                    budget -= 1
                    if budget == 0 { break }
                }
                let timestamp = HostTime.instant(timestamp: packet.pointee.timeStamp, receivedHost: receivedHost,
                                                 receivedAt: receivedAt, numer: timebase.numer, denom: timebase.denom)
                for message in decoder.decode(words) { deliver(message, receivedAt, timestamp) }
            }
        }
        guard status == noErr else { throw MIDIPortError.os(status, "MIDIDestinationCreateWithProtocol(\(name))") }
        return ref
    }
}

/// The host-time timebase (nanoseconds per `mach_absolute_time` tick = numer / denom).
struct HostTimebase: Sendable {
    var numer: UInt32
    var denom: UInt32

    static var current: HostTimebase {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom > 0 else { return HostTimebase(numer: 1, denom: 1) }
        return HostTimebase(numer: info.numer, denom: info.denom)
    }
}

private final class DecoderBox: Sendable {
    static let maxWordsPerCallback = 16384
    private let state = Mutex(UMPDecoder())

    func decode(_ words: [UInt32]) -> [MIDIMessage] {
        state.withLock { $0.decode(words: words) }
    }
}
