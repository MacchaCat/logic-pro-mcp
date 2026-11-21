import Foundation

private let usage = """
    Usage: logic-mcp [serve|console|version] [options]

      serve      MCP server on stdin/stdout (default). Registered with Claude Code.
      console    Interactive tool for setting up and testing Logic: opens the same ports,
                 logs Mackie Control traffic, sends key-command triggers, runs locate tests.
                 Cannot run while a server holds the ports.
      version    Print the version.

    Options:
      --var-dir <path>     Runtime directory for logs and the console FIFO (default: <repo>/var when run
                           from a checkout's .build, else ~/Library/Application Support/logic-mcp;
                           LOGIC_MCP_VAR_DIR also sets it)
      --lock-dir <path>    Directory of the instance lock that keeps one owner of the LogicMCP ports
                           (default: ~/Library/Application Support/logic-mcp; LOGIC_MCP_LOCK_DIR)
      --sysex ump|legacy   How SysEx is sent to Logic (default: ump)
      --confirm chat|dialog  serve: confirm destructive steps with a chat token (default) or an
                           MCP elicitation dialog
      --run "<cmds>"       console: run ';'-separated commands, then exit
      --verbose, -v        console: also print meter and time-code traffic
      --fifo               console: read commands from <var-dir>/console.fifo instead of stdin
      --fake               Use an in-memory FakeLogic instead of CoreMIDI ports (no ports are created)
      --fake-replace-on    Same, with Replace mode on
    """

@main
struct LogicMCPMain {
    static func main() async {
        // A closed stdout must surface as a write error, not kill the process.
        signal(SIGPIPE, SIG_IGN)
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case "serve": try await runServer(options)
            case "console": try await runConsole(options)
            case "version": print("logic-mcp \(serverVersion)")
            case "help": print(usage)
            default: throw RuntimeError("Unknown command \(options.command).\n\(usage)")
            }
        } catch {
            logError("logic-mcp: \(error)")
            exit(1)
        }
    }
}
