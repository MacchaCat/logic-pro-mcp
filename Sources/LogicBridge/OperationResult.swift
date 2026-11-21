import Foundation

/// The common result envelope of every tool (design §3.1).
public struct OperationResult<State: Codable & Sendable>: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The expected feedback from Logic was observed.
        case verified
        /// Sent, but there is no feedback channel for this operation.
        case unverified
        /// Part of a batch succeeded; details in `evidence` / `warnings`.
        case partial
        /// The expected feedback did not arrive, or a precondition failed.
        case failed
        /// A destructive step needs the user's explicit confirmation first.
        case needsConfirmation = "needs_confirmation"
    }

    public var status: Status
    public var summary: String
    public var before: State?
    public var after: State?
    public var evidence: [String]
    public var warnings: [String]
    /// Set with `needs_confirmation` when the client cannot show a confirmation dialog:
    /// the user must approve in chat, then the same call is repeated with this token.
    public var confirmationToken: String?
    public var asOf: String

    public init(
        status: Status, summary: String, before: State? = nil, after: State? = nil,
        evidence: [String] = [], warnings: [String] = []
    ) {
        self.status = status
        self.summary = summary
        self.before = before
        self.after = after
        self.evidence = evidence
        self.warnings = warnings
        self.asOf = Self.timestamp()
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    enum CodingKeys: String, CodingKey {
        case status, summary, before, after, evidence, warnings
        case confirmationToken = "confirmation_token"
        case asOf = "as_of"
    }
}
