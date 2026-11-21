import AppKit
import ApplicationServices
import Foundation

/// Phase 2: read-only Accessibility access to Logic Pro, for full track names.
///
/// Only reads attributes of the process with bundle ID com.apple.logic10. It never performs an
/// action, sets a value, clicks or types; the only call that is not a read is
/// `AXUIElementSetMessagingTimeout`, a client-side timeout for our own requests.
public enum LogicAX {
    public static let bundleIdentifier = "com.apple.logic10"
}

/// One AXTextField found in Logic's main window, reduced to plain values.
public struct AXTextFieldInfo: Sendable, Equatable {
    /// AXValue, else AXTitle, else AXDescription (the first non-empty one). Logic 13's track
    /// name fields leave AXValue and AXTitle empty and carry the name in AXDescription, e.g.
    /// "Inst 1", "オーディオ 1" (observed 2026-11-21).
    public var text: String
    public var description: String?
    public var identifier: String?
    /// Top-left corner in screen points; nil when Logic did not report a position.
    public var x: Double?
    public var y: Double?
    public var width: Double?

    public init(text: String, description: String? = nil, identifier: String? = nil, x: Double?, y: Double?, width: Double? = nil) {
        self.text = text
        self.description = description
        self.identifier = identifier
        self.x = x
        self.y = y
        self.width = width
    }
}

/// Outcome of reading track names.
public struct AXTrackNameReading: Sendable, Equatable {
    /// Top to bottom; nil when the names could not be read (`failure` says why).
    public var names: [String]?
    public var failure: String?
    /// Caveats about completeness (traversal limits, scrolled-out tracks).
    public var notes: [String]

    public init(names: [String]?, failure: String? = nil, notes: [String] = []) {
        self.names = names
        self.failure = failure
        self.notes = notes
    }
}

/// Picks the track-name fields among all text fields of the main window.
public enum TrackNameFieldSelector {
    /// Track headers stack the name fields in one column: same x, increasing y. The column with
    /// the most fields wins (ties: the leftmost); fields whose description mentions a track name
    /// ("track", "トラック") are preferred when any exist. Positions within `tolerance` points
    /// count as one column.
    public static func select(_ fields: [AXTextFieldInfo], tolerance: Double = 3) -> [AXTextFieldInfo] {
        let placed = fields.filter { $0.x != nil && $0.y != nil }
        let labelled = placed.filter { field in
            let label = ((field.description ?? "") + " " + (field.identifier ?? "")).lowercased()
            return label.contains("track") || label.contains("トラック")
        }
        let pool = labelled.isEmpty ? placed : labelled
        var columns: [[AXTextFieldInfo]] = []
        for field in pool.sorted(by: { $0.x! < $1.x! }) {
            if let last = columns.last?.first, abs(last.x! - field.x!) <= tolerance {
                columns[columns.count - 1].append(field)
            } else {
                columns.append([field])
            }
        }
        guard let best = columns.max(by: { $0.count < $1.count || ($0.count == $1.count && $0.first!.x! > $1.first!.x!) }) else {
            return []
        }
        return best.sorted { $0.y! < $1.y! }
    }
}

/// Reads the full track names from Logic's main window through Accessibility.
public struct LogicTrackNameReader: Sendable {
    /// Elements visited at most (Logic's main window can contain many region elements).
    public var maxElements = 40_000
    public var maxDepth = 40
    /// Overall time budget for one read.
    public var timeBudget: TimeInterval = 3
    /// Per-request Accessibility timeout, seconds.
    public var messagingTimeout: Float = 1
    /// Injectable for tests; the real check never prompts the user.
    public var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    /// Injectable for tests: pid of the running Logic, or nil.
    public var logicProcess: @Sendable () -> pid_t? = { LogicTrackNameReader.findLogic() }

    /// Finds Logic among the running processes. `NSRunningApplication.runningApplications` is
    /// kept up to date through the main run loop, which this command-line server does not run,
    /// so a Logic launched after the server could be missed; this asks the kernel instead and
    /// confirms the bundle identifier for candidates inside an app bundle.
    public static func findLogic() -> pid_t? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0 else { continue }
            let executable = String(decoding: path.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard executable.contains(".app/Contents/MacOS/"), executable.contains("Logic") else { continue }
            if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == LogicAX.bundleIdentifier { return pid }
        }
        return nil
    }

    public init() {}

    /// Reads on a background queue so the blocking Accessibility calls stay off the
    /// cooperative thread pool.
    public func read() async -> AXTrackNameReading {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readSync())
            }
        }
    }

    public func readSync() -> AXTrackNameReading {
        guard isTrusted() else {
            return AXTrackNameReading(names: nil, failure: "this process is not allowed to use Accessibility. Grant Accessibility to the app that launches logic-mcp (System Settings > Privacy & Security > Accessibility), then restart it (docs/setup/02-phase2-accessibility.md)")
        }
        guard let pid = logicProcess() else {
            return AXTrackNameReading(names: nil, failure: "Logic Pro (\(LogicAX.bundleIdentifier)) is not running")
        }
        // Client-side timeout for each request this process makes (set on the system-wide
        // element it applies to every element, including Logic's children).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
        let app = AXUIElementCreateApplication(pid)
        let session = Session(deadline: Date().addingTimeInterval(timeBudget))
        guard let window = mainWindow(of: app, session) else {
            let reason = session.unresponsive
                ? "Logic did not answer Accessibility requests (it may be busy or showing a modal dialog)"
                : "Logic's main window was not found through Accessibility"
            return AXTrackNameReading(names: nil, failure: reason)
        }
        var notes: [String] = []
        let fields = textFields(in: window, session, notes: &notes)
        let selected = TrackNameFieldSelector.select(fields)
        guard !selected.isEmpty else {
            return AXTrackNameReading(names: nil, failure: "no track-name text fields were found in Logic's main window (\(fields.count) text fields in total)", notes: notes)
        }
        return AXTrackNameReading(names: selected.map(\.text), notes: notes)
    }

    // MARK: Accessibility reads (attribute copies only)

    /// One read: its deadline, and whether Logic stopped answering.
    private final class Session {
        let deadline: Date
        var unresponsive = false
        init(deadline: Date) { self.deadline = deadline }
        var expired: Bool { unresponsive || Date() > deadline }
    }

    private func mainWindow(of app: AXUIElement, _ session: Session) -> AXUIElement? {
        if let main: AXUIElement = attribute(app, kAXMainWindowAttribute, session) { return main }
        if session.expired { return nil }
        if let focused: AXUIElement = attribute(app, kAXFocusedWindowAttribute, session) { return focused }
        if session.expired { return nil }
        let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute, session) ?? []
        return windows.first { (attribute($0, kAXMainAttribute, session) as Bool?) == true } ?? windows.first
    }

    private func textFields(in root: AXUIElement, _ session: Session, notes: inout [String]) -> [AXTextFieldInfo] {
        var found: [AXTextFieldInfo] = []
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            visited += 1
            if visited > maxElements {
                notes.append("Stopped after \(maxElements) interface elements; some track names may be missing.")
                break
            }
            if session.unresponsive {
                notes.append("Logic stopped answering Accessibility requests; some track names may be missing.")
                break
            }
            if session.expired {
                notes.append("Stopped after \(timeBudget) s; some track names may be missing.")
                break
            }
            let role: String? = attribute(element, kAXRoleAttribute, session)
            if role == (kAXTextFieldRole as String) {
                found.append(info(element, session))
                continue
            }
            guard depth < maxDepth else { continue }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute, session) ?? []
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return found
    }

    private func info(_ element: AXUIElement, _ session: Session) -> AXTextFieldInfo {
        let value: String? = attribute(element, kAXValueAttribute, session)
        let title: String? = attribute(element, kAXTitleAttribute, session)
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        if let raw: AXValue = attribute(element, kAXPositionAttribute, session), AXValueGetValue(raw, .cgPoint, &point) { hasPoint = true }
        if let raw: AXValue = attribute(element, kAXSizeAttribute, session) { _ = AXValueGetValue(raw, .cgSize, &size) }
        let description: String? = attribute(element, kAXDescriptionAttribute, session)
        let text = [value, title, description].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return AXTextFieldInfo(
            text: text,
            description: description,
            identifier: attribute(element, kAXIdentifierAttribute, session),
            x: hasPoint ? Double(point.x) : nil,
            y: hasPoint ? Double(point.y) : nil,
            width: hasPoint ? Double(size.width) : nil
        )
    }

    /// Copies one attribute; records when Logic does not answer (`cannotComplete`), after
    /// which the read stops.
    private func attribute<T>(_ element: AXUIElement, _ name: String, _ session: Session) -> T? {
        guard !session.unresponsive else { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .cannotComplete { session.unresponsive = true }
        guard error == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        if T.self == AXValue.self {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }
}
