/// Extra lines for `logic_status.notes`, contributed by tool modules (e.g. the analysis link's
/// listener state), so modules do not need to edit the status report itself.
actor StatusNotes {
    static let shared = StatusNotes()

    private var providers: [(key: String, provider: @Sendable () async -> [String])] = []

    /// Registers (or replaces) the provider for `key`; providers are asked in registration order.
    func register(_ key: String, _ provider: @escaping @Sendable () async -> [String]) {
        providers.removeAll { $0.key == key }
        providers.append((key, provider))
    }

    func notes() async -> [String] {
        var lines: [String] = []
        for entry in providers { lines += await entry.provider() }
        return lines
    }
}
