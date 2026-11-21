import LogicBridge
import MCP
import Testing
@testable import LogicMCP

@Suite("mixer_set argument parsing")
struct MixerArgumentsTests {
    func parse(_ arguments: [String: Value]) -> Result<[MixerChange], MixerArguments.Problem> {
        MixerArguments.changes(arguments)
    }

    func problem(_ arguments: [String: Value]) -> String? {
        if case .failure(let problem) = parse(arguments) { return problem.message }
        return nil
    }

    @Test func singleChange() throws {
        let changes = try parse(["track": 3, "expected_name": "オーディオ 1", "volume_db": -6.5, "pan": -20, "mute": true, "solo": false]).get()
        #expect(changes == [MixerChange(track: 3, expectedName: "オーディオ 1", volume: .db(-6.5), pan: -20, mute: true, solo: false)])
    }

    @Test func batch() throws {
        let changes = try parse(["changes": [["track": 1, "mute": true], ["track": 2, "volume_db": "-inf"]]]).get()
        #expect(changes == [MixerChange(track: 1, mute: true), MixerChange(track: 2, volume: .minusInfinity)])
    }

    @Test func fieldsNextToChangesAreRejected() {
        for field in ["track", "mute", "volume_db", "pan", "solo", "expected_name"] {
            let value: Value = field == "expected_name" ? "Bass" : (field == "mute" || field == "solo" ? true : 1)
            let message = problem(["changes": [["track": 1, "mute": true]], field: value])
            #expect(message?.contains("not both") == true, "\(field): \(message ?? "accepted")")
        }
        #expect(problem(["changes": [["track": 1, "mute": true]], "colour": "red"]) == "Unknown field \"colour\".")
    }

    @Test func unknownFieldsAreRejected() {
        #expect(problem(["track": 1, "mute": true, "volume": -3]) == "Unknown field \"volume\".")
        #expect(problem(["changes": [["track": 1, "gain": 2]]])?.contains("changes[0]: Unknown field \"gain\"") == true)
    }

    @Test func wholeNumbersOnlyForTrackAndPan() throws {
        #expect(try parse(["track": 3.0, "pan": -2.0]).get() == [MixerChange(track: 3, pan: -2)])
        #expect(problem(["track": 3.5, "mute": true])?.contains("\"track\"") == true)
        #expect(problem(["track": 1, "pan": 3.5])?.contains("\"pan\"") == true)
        #expect(problem(["track": "3", "mute": true])?.contains("\"track\"") == true)
    }

    @Test func volumeAcceptsNumbersAndSilence() throws {
        #expect(try parse(["track": 1, "volume_db": -3]).get().first?.volume == .db(-3))
        #expect(try parse(["track": 1, "volume_db": 2.5]).get().first?.volume == .db(2.5))
        for silence in ["-inf", "-oo", "silence"] {
            #expect(try parse(["track": 1, "volume_db": .string(silence)]).get().first?.volume == .minusInfinity)
        }
        #expect(problem(["track": 1, "volume_db": "loud"])?.contains("volume_db") == true)
        #expect(problem(["track": 1, "volume_db": true])?.contains("volume_db") == true)
    }

    @Test func typesAreChecked() {
        #expect(problem(["track": 1, "mute": "yes"])?.contains("\"mute\"") == true)
        #expect(problem(["track": 1, "solo": 1])?.contains("\"solo\"") == true)
        #expect(problem(["track": 1, "expected_name": 5])?.contains("\"expected_name\"") == true)
        #expect(problem(["mute": true])?.contains("\"track\"") == true)
        #expect(problem(["changes": []]) == "\"changes\" must be a non-empty array.")
        #expect(problem(["changes": "all"]) == "\"changes\" must be a non-empty array.")
        #expect(problem(["changes": [1]]) == "changes[0] must be an object.")
    }

    @Test func atMost64Changes() throws {
        let item: Value = ["track": 1, "mute": true]
        #expect(try parse(["changes": .array(Array(repeating: item, count: 64))]).get().count == 64)
        #expect(problem(["changes": .array(Array(repeating: item, count: 65))]) == "At most 64 changes per call.")
    }
}
