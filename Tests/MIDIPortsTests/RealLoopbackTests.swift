import CoreMIDI
import Foundation
import MIDICore
@testable import MIDIPorts
import Synchronization
import Testing

/// Self-test of the real CoreMIDI path: our virtual endpoints, UMP send, the receive block, and
/// how CoreMIDI converts UMP SysEx for a legacy (MIDIPacketList) reader such as Logic.
///
/// Creates real ports that every MIDI app (including Logic) can see for a few seconds, so it
/// only runs with LOGIC_MCP_REAL_MIDI_TESTS=1. Test traffic is chosen to be inert for Logic:
/// SysEx with the non-commercial manufacturer ID 0x7D and one CC 14 (undefined) = 0 on channel 16.
private let realMIDI = ProcessInfo.processInfo.environment["LOGIC_MCP_REAL_MIDI_TESTS"] == "1"

final class MessageCollector: Sendable {
    private let state = Mutex<(ump: UMPDecoder, bytes: MIDIByteParser, messages: [MIDIMessage])>(
        (UMPDecoder(), MIDIByteParser(), []))

    func feed(words: [UInt32]) {
        state.withLock { $0.messages += $0.ump.decode(words: words) }
    }

    func feed(bytes: [UInt8]) {
        state.withLock { $0.messages += $0.bytes.feed(bytes) }
    }

    func add(_ message: MIDIMessage) {
        state.withLock { $0.messages.append(message) }
    }

    var messages: [MIDIMessage] { state.withLock { $0.messages } }
}

final class TimedCollector: Sendable {
    private let state = Mutex<[TimedMIDIMessage]>([])
    func add(_ item: TimedMIDIMessage) { state.withLock { $0.append(item) } }
    var items: [TimedMIDIMessage] { state.withLock { $0 } }
}

private func waitFor(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Messages in `received` that are among `expected`, in arrival order.
private func matching(_ received: [MIDIMessage], _ expected: [MIDIMessage]) -> [MIDIMessage] {
    received.filter { expected.contains($0) }
}

private let inertSysEx: [MIDIMessage] = [5, 6, 7, 13, 120].map { length in
    .sysEx([0x7D] + (0..<(length - 1)).map { UInt8($0 & 0x7F) })
}
private let inertCC = MIDIMessage.controlChange(channel: 15, controller: 14, value: 0)

@Suite("Real CoreMIDI self-test", .enabled(if: realMIDI), .serialized)
struct RealLoopbackTests {
    /// All real-port tests live in this one serialized suite: two port sets alive at the same
    /// time collide on the stable unique IDs (exactly what InstanceLock prevents in production).
    @Test func uniqueIDsAreAppliedAndPortsAreVisible() throws {
        let ports = try VirtualPortSet.create()
        defer { ports.dispose() }
        #expect(ports.endpoints.count == 5)
        #expect(ports.endpoints.allSatisfy { $0.uniqueIDApplied })
        func names(_ count: Int, _ get: (Int) -> MIDIEndpointRef) -> [String] {
            (0..<count).compactMap { index in
                var name: Unmanaged<CFString>?
                guard MIDIObjectGetStringProperty(get(index), kMIDIPropertyDisplayName, &name) == noErr else { return nil }
                return name?.takeRetainedValue() as String?
            }
        }
        let sources = names(MIDIGetNumberOfSources(), MIDIGetSource)
        let destinations = names(MIDIGetNumberOfDestinations(), MIDIGetDestination)
        #expect(Set([PortNames.mcu, PortNames.keys, PortNames.notes]).isSubset(of: Set(sources)))
        #expect(Set([PortNames.mcu, PortNames.sync]).isSubset(of: Set(destinations)))
        print("[self-test] visible sources: \(sources.filter { $0.hasPrefix("LogicMCP") }), destinations: \(destinations.filter { $0.hasPrefix("LogicMCP") })")
    }

    /// What we send from a virtual source must reach both a UMP reader and a legacy byte reader intact.
    @Test(arguments: [SysExPath.ump, SysExPath.legacy])
    func sourceDeliversIntact(path: SysExPath) async throws {
        let ports = try VirtualPortSet.create(sysExPath: path)
        defer { ports.dispose() }
        #expect(ports.endpoints.count == 5)
        #expect(ports.endpoints.allSatisfy { $0.uniqueIDApplied })

        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock("logic-mcp-selftest" as CFString, &client, nil), "client")
        defer { MIDIClientDispose(client) }

        let viaUMP = MessageCollector()
        var umpPort = MIDIPortRef()
        try check(MIDIInputPortCreateWithProtocol(client, "selftest-ump" as CFString, ._1_0, &umpPort) {
            @Sendable list, _ in
            var words: [UInt32] = []
            for packet in list.unsafeSequence() { words += packet.sequence() }
            viaUMP.feed(words: words)
        }, "ump input port")

        let viaBytes = MessageCollector()
        var legacyPort = MIDIPortRef()
        try check(MIDIInputPortCreateWithBlock(client, "selftest-legacy" as CFString, &legacyPort) {
            @Sendable list, _ in
            for packet in list.unsafeSequence() { viaBytes.feed(bytes: Array(packet.sequence())) }
        }, "legacy input port")

        try check(MIDIPortConnectSource(umpPort, ports.mcuOut.endpoint, nil), "connect ump")
        try check(MIDIPortConnectSource(legacyPort, ports.mcuOut.endpoint, nil), "connect legacy")
        try await Task.sleep(for: .milliseconds(200))

        let expected = inertSysEx + [inertCC]
        try ports.mcuOut.send(expected)

        let umpOK = await waitFor(.seconds(2)) { matching(viaUMP.messages, expected).count >= expected.count }
        let bytesOK = await waitFor(.seconds(2)) { matching(viaBytes.messages, expected).count >= expected.count }
        #expect(umpOK, "UMP reader got \(viaUMP.messages)")
        #expect(bytesOK, "legacy reader got \(viaBytes.messages)")
        #expect(matching(viaUMP.messages, expected) == expected)
        #expect(matching(viaBytes.messages, expected) == expected)
        print("[self-test] sysex path \(path.rawValue): UMP reader \(umpOK ? "OK" : "FAILED"), legacy reader \(bytesOK ? "OK" : "FAILED")")
    }

    /// What others send to our destination (UMP or legacy) must come out of `mcuIn` decoded.
    /// Anything else that arrives meanwhile is printed: that is Logic probing the new port.
    @Test func destinationDecodesIncoming() async throws {
        let ports = try VirtualPortSet.create()
        defer { ports.dispose() }

        let received = MessageCollector()
        let reader = Task {
            for await message in ports.mcuIn { received.add(message) }
        }
        defer { reader.cancel() }

        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock("logic-mcp-selftest" as CFString, &client, nil), "client")
        defer { MIDIClientDispose(client) }
        var output = MIDIPortRef()
        try check(MIDIOutputPortCreate(client, "selftest-out" as CFString, &output), "output port")

        // A full-length Mackie LCD write (like Logic 12.3 sends), via UMP and via a legacy packet list.
        let lcd = MIDIMessage.sysEx([0x00, 0x00, 0x66, 0x14, 0x12, 0x00] + Array(repeating: 0x41, count: 111))
        let led = MIDIMessage.noteOn(channel: 0, note: 0x5D, velocity: 0x7F)
        try sendUMP(output, ports.mcuInEndpoint, UMP.encode(lcd) + UMP.encode(led))
        try sendLegacy(output, ports.mcuInEndpoint, lcd.bytes + led.bytes)

        let ok = await waitFor(.seconds(2)) { matching(received.messages, [lcd, led]).count >= 4 }
        #expect(ok, "received \(received.messages.count) messages")
        #expect(matching(received.messages, [lcd, led]) == [lcd, led, lcd, led])

        // Give Logic (if running) a moment to probe the new ports, then report what it sent.
        try await Task.sleep(for: .seconds(3))
        let foreign = received.messages.filter { $0 != lcd && $0 != led }
        print("[self-test] destination decode: \(ok ? "OK" : "FAILED")")
        print("[self-test] other traffic on LogicMCP MCU within ~3 s: \(foreign.isEmpty ? "none" : foreign.map(\.description).joined(separator: " | "))")
    }

    /// A packet timestamp on what others send to `LogicMCP Sync` must come out of `syncIn` as
    /// the instant it stands for, next to the receipt time (taken in the CoreMIDI callback).
    /// Also shows whether CoreMIDI delivers a future-stamped packet to a virtual destination
    /// early (lead > 0) or holds it (lead about 0).
    @Test func syncDestinationKeepsPacketTimestamps() async throws {
        let ports = try VirtualPortSet.create()
        defer { ports.dispose() }
        let received = TimedCollector()
        let reader = Task {
            for await item in ports.syncIn { received.add(item) }
        }
        defer { reader.cancel() }

        var client = MIDIClientRef()
        try check(MIDIClientCreateWithBlock("logic-mcp-selftest" as CFString, &client, nil), "client")
        defer { MIDIClientDispose(client) }
        var output = MIDIPortRef()
        try check(MIDIOutputPortCreate(client, "selftest-out" as CFString, &output), "output port")

        let timebase = HostTimebase.current
        let aheadTicks = UInt64((50_000_000 * Double(timebase.denom) / Double(timebase.numer)).rounded())
        let sentAt = ContinuousClock.now
        try sendUMP(output, ports.syncInEndpoint, UMP.encode(inertCC), timeStamp: mach_absolute_time() + aheadTicks)

        let ok = await waitFor(.seconds(2)) { !received.items.isEmpty }
        #expect(ok)
        guard let item = received.items.first else { return }
        #expect(item.message == inertCC)
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        let standsFor = ms(sentAt.duration(to: item.time))
        #expect(abs(standsFor - 50) < 5, "timestamp stands for \(standsFor) ms after sending")
        let lead = item.lead.map { "\(ms($0)) ms" } ?? "none"
        print("[self-test] sync timestamp: received \(ms(sentAt.duration(to: item.receivedAt))) ms after sending; timestamp \(standsFor) ms; lead \(lead)")
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw MIDIPortError.os(status, what) }
    }

    private func sendUMP(_ port: MIDIPortRef, _ destination: MIDIEndpointRef, _ packets: [UMP.Packet],
                         timeStamp: MIDITimeStamp = 0) throws {
        let size = 4096
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var current = MIDIEventListInit(list, ._1_0)
        for packet in packets {
            current = packet.withUnsafeBufferPointer { MIDIEventListAdd(list, size, current, timeStamp, $0.count, $0.baseAddress!) }
        }
        try check(MIDISendEventList(port, destination, list), "MIDISendEventList")
    }

    private func sendLegacy(_ port: MIDIPortRef, _ destination: MIDIEndpointRef, _ bytes: [UInt8]) throws {
        let size = 4096
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let first = MIDIPacketListInit(list)
        _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, size, first, 0, $0.count, $0.baseAddress!) }
        try check(MIDISend(port, destination, list), "MIDISend")
    }
}
