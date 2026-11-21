import CommandMap
import MIDICore

/// Logic key commands are triggered through controller assignments on the `LogicMCP Keys` port:
/// each catalog command (`CommandCatalog`) is a CC on MIDI channel 16 with value 127, which the
/// user teaches Logic once with "Learn New Assignment" (docs/setup/03-phase3-commands.md).
///
/// `KeyCommand` is the Phase 1 name of a catalog command, kept so that code written against
/// Phase 1 (e.g. `send(.goToBeginning)`) still compiles.
public typealias KeyCommand = LogicCommand

extension OutputScheduler {
    /// Sends one key-command trigger, at least `limits.keyCommandGap` after the previous message
    /// on this output (design §4.2). Used for every send on `LogicMCP Keys`.
    public func sendKeyCommand(_ command: LogicCommand, limits: RateLimits) async {
        var keyLimits = limits
        keyLimits.shortMessageGap = limits.keyCommandGap
        await send([command.message], limits: keyLimits)
    }
}
