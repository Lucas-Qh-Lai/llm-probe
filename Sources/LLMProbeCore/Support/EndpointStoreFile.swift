import Foundation

/// Persistent state: saved endpoints, preferences and the capability cache.
public struct AppState: Codable, Sendable {
    public var version: Int
    public var endpoints: [ProbeEndpoint]
    public var selectedID: UUID?
    public var cache: CapabilityCache
    public var lastDiscovery: Date?
    /// Speed history keyed by `ProbeEndpoint.dedupeKey`.
    public var history: [String: [HistorySample]]
    /// Run the selected endpoint once when the app opens.
    public var autoRunOnLaunch: Bool

    public init(
        version: Int = 1,
        endpoints: [ProbeEndpoint] = [],
        selectedID: UUID? = nil,
        cache: CapabilityCache = CapabilityCache(),
        lastDiscovery: Date? = nil,
        history: [String: [HistorySample]] = [:],
        autoRunOnLaunch: Bool = false
    ) {
        self.version = version
        self.endpoints = endpoints
        self.selectedID = selectedID
        self.cache = cache
        self.lastDiscovery = lastDiscovery
        self.history = history
        self.autoRunOnLaunch = autoRunOnLaunch
    }
}

/// One point on the speed chart.
public struct HistorySample: Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var timeToFirstTokenMS: Double?
    public var outputTokensPerSecond: Double?
    public var tokens: Int
    public var verdict: HealthVerdict

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        timeToFirstTokenMS: Double? = nil,
        outputTokensPerSecond: Double? = nil,
        tokens: Int = 0,
        verdict: HealthVerdict = .unknown
    ) {
        self.id = id
        self.date = date
        self.timeToFirstTokenMS = timeToFirstTokenMS
        self.outputTokensPerSecond = outputTokensPerSecond
        self.tokens = tokens
        self.verdict = verdict
    }
}

/// Capability answers remembered between runs.
///
/// This is what makes repeat runs nearly free: a model whose context window and
/// modalities are already known is not asked again.
public struct CapabilityCache: Codable, Sendable {
    public var entries: [String: [Capability: CapabilityFinding]]
    public var updatedAt: Date?

    public init(entries: [String: [Capability: CapabilityFinding]] = [:], updatedAt: Date? = nil) {
        self.entries = entries
        self.updatedAt = updatedAt
    }

    public static func key(for endpoint: ProbeEndpoint) -> String {
        "\(endpoint.wireAPI.rawValue)|\(endpoint.baseURL.lowercased())|\(endpoint.model)"
    }

    public func findings(for endpoint: ProbeEndpoint) -> [Capability: CapabilityFinding] {
        entries[Self.key(for: endpoint)] ?? [:]
    }

    public mutating func store(_ report: EndpointReport) {
        var merged = entries[Self.key(for: report.endpoint)] ?? [:]
        for finding in report.capabilityEvidence {
            if let existing = merged[finding.capability] {
                // Live evidence beats a cached guess.
                let ranking: [EvidenceKind: Int] = [.liveProbe: 3, .metadata: 2, .config: 1, .heuristic: 0, .unknown: 0]
                if (ranking[finding.evidence] ?? 0) >= (ranking[existing.evidence] ?? 0) {
                    merged[finding.capability] = finding
                }
            } else {
                merged[finding.capability] = finding
            }
        }
        entries[Self.key(for: report.endpoint)] = merged
        updatedAt = Date()
    }
}

/// Reads and writes the app state file.
///
/// The file is created with `0600` permissions because it can contain inline
/// credentials discovered from other apps. Nothing is ever uploaded.
public enum EndpointStoreFile {
    public static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["LLM_PROBE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if let override = LaunchOptions.shared.stateDirectory {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return PathTools.appSupportDirectory()
    }

    public static var stateURL: URL {
        directoryURL.appendingPathComponent("state.json")
    }

    public static func load() -> AppState {
        guard let data = try? Data(contentsOf: stateURL) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppState.self, from: data)) ?? AppState()
    }

    @discardableResult
    public static func save(_ state: AppState) -> Bool {
        let directory = directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return false }
        do {
            try data.write(to: stateURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            return true
        } catch {
            return false
        }
    }

    public static func reset() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
