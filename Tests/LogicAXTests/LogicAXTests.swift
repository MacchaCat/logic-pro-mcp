import Testing
@testable import LogicAX

/// None of these tests reads the real Accessibility tree: the trust check and the Logic
/// process lookup are injected, so no request ever reaches Logic.
@Suite("LogicAX")
struct LogicAXTests {
    @Test func untrustedProcessReportsWhyWithoutReading() {
        var reader = LogicTrackNameReader()
        reader.isTrusted = { false }
        reader.logicProcess = {
            Issue.record("must not look for Logic when not trusted")
            return nil
        }
        let reading = reader.readSync()
        #expect(reading.names == nil)
        #expect(reading.failure?.contains("Accessibility") == true)
        #expect(reading.failure?.contains("02-phase2-accessibility") == true)
    }

    @Test func logicNotRunning() {
        var reader = LogicTrackNameReader()
        reader.isTrusted = { true }
        reader.logicProcess = { nil }
        let reading = reader.readSync()
        #expect(reading.names == nil)
        #expect(reading.failure?.contains("not running") == true)
    }

    @Test func selectsTheTrackHeaderColumnInOrder() {
        let fields = [
            // Track headers: one column, listed out of order.
            AXTextFieldInfo(text: "オーディオ 1", x: 120, y: 260),
            AXTextFieldInfo(text: "Inst 1", x: 120, y: 160),
            AXTextFieldInfo(text: "Inst 2", x: 121, y: 210),
            AXTextFieldInfo(text: "オーディオ 2", x: 119.5, y: 310),
            // Inspector channel strips: same row, different x.
            AXTextFieldInfo(text: "Inst 1", x: 10, y: 600),
            AXTextFieldInfo(text: "Stereo Out", x: 70, y: 600),
            // A field with no position is ignored.
            AXTextFieldInfo(text: "Search", x: nil, y: nil),
        ]
        #expect(TrackNameFieldSelector.select(fields).map(\.text) == ["Inst 1", "Inst 2", "オーディオ 1", "オーディオ 2"])
    }

    @Test func labelledFieldsArePreferred() {
        let fields = [
            AXTextFieldInfo(text: "A", description: "Track Name", x: 300, y: 10),
            AXTextFieldInfo(text: "B", description: "トラック名", x: 300, y: 40),
            AXTextFieldInfo(text: "x", x: 50, y: 10),
            AXTextFieldInfo(text: "y", x: 50, y: 40),
            AXTextFieldInfo(text: "z", x: 50, y: 70),
        ]
        #expect(TrackNameFieldSelector.select(fields).map(\.text) == ["A", "B"])
    }

    @Test func emptyInputSelectsNothing() {
        #expect(TrackNameFieldSelector.select([]).isEmpty)
    }
}
