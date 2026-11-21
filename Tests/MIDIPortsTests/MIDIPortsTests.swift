import Foundation
import Testing
@testable import MIDIPorts

@Suite("Virtual port identity")
struct PortIdentityTests {
    @Test func uniqueIDsAreStableAndDistinct() {
        let mcuSource = stableUniqueID(name: PortNames.mcu, kind: .source)
        #expect(mcuSource == stableUniqueID(name: PortNames.mcu, kind: .source))
        let all = [
            mcuSource,
            stableUniqueID(name: PortNames.mcu, kind: .destination),
            stableUniqueID(name: PortNames.keys, kind: .source),
            stableUniqueID(name: PortNames.notes, kind: .source),
            stableUniqueID(name: PortNames.sync, kind: .destination),
        ]
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 > 0 })
    }

    @Test func hostTimebaseIsUsable() {
        let timebase = HostTimebase.current
        #expect(timebase.numer > 0)
        #expect(timebase.denom > 0)
    }
}
