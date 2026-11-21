import Foundation

public struct InstanceLockError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Process-wide exclusive lock so only one process owns the LogicMCP ports (research §7.3 #10).
/// Uses flock(2): the kernel releases it when the process exits, even after a crash.
public final class InstanceLock {
    private let fd: Int32
    public let path: String

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("logic-mcp.lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw InstanceLockError("Cannot open lock file \(path): errno \(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw InstanceLockError(
                "Another logic-mcp process already owns the LogicMCP ports (lock: \(path)). " +
                "Quit it first (a Claude Code session using this server, or `logic-mcp console`).")
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

