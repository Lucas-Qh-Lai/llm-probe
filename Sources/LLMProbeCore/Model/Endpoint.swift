import Foundation

/// Where a secret lives. Secrets are resolved lazily, never copied into logs and
/// never written into the on-disk store unless the user explicitly types one in.
public enum SecretSource: Codable, Hashable, Sendable {
    case none
    /// A literal secret typed by the user or read from a config file.
    case inline(String)
    /// Name of an environment variable, resolved at probe time.
    case environment(String)
    /// A file whose entire contents are the secret (for example `~/.openai.key`).
    case file(path: String)
    /// macOS Keychain item.
    case keychain(service: String, account: String)

    public var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    /// Human readable, secret-free description.
    public var label: String {
        switch self {
        case .none: return L10n.pick(zh: "无凭据", en: "no credential")
        case .inline(let value): return Redactor.mask(value)
        case .environment(let name): return "$\(name)"
        case .file(let path): return "file:\(PathTools.abbreviate(path))"
        case .keychain(let service, let account): return "keychain:\(service)/\(account)"
        }
    }
}

/// How a secret is attached to an HTTP request.
public struct AuthConfig: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        /// `Authorization: Bearer <secret>`
        case bearer
        /// `x-api-key: <secret>`
        case xApiKey
        /// A custom header, see `headerName`.
        case header
        /// A query parameter, see `queryName`.
        case query
        case none

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .bearer: return "Bearer token"
            case .xApiKey: return "x-api-key header"
            case .header: return "Custom header"
            case .query: return "Query parameter"
            case .none: return "No authentication"
            }
        }
    }

    public var style: Style
    public var headerName: String?
    public var queryName: String?
    public var secret: SecretSource
    /// Extra headers that belong to authentication (for example `anthropic-version`).
    public var extraHeaders: [String: String]

    public init(
        style: Style = .bearer,
        headerName: String? = nil,
        queryName: String? = nil,
        secret: SecretSource = .none,
        extraHeaders: [String: String] = [:]
    ) {
        self.style = style
        self.headerName = headerName
        self.queryName = queryName
        self.secret = secret
        self.extraHeaders = extraHeaders
    }

    public static let none = AuthConfig(style: .none, secret: .none)

    /// True when a credential is configured (even if it cannot be resolved yet).
    public var hasCredential: Bool { !secret.isNone }

    public var label: String {
        guard !secret.isNone else { return L10n.pick(zh: "无凭据", en: "no credential") }
        switch style {
        case .none: return L10n.pick(zh: "无凭据", en: "no credential")
        case .bearer: return "Authorization: Bearer \(secret.label)"
        case .xApiKey: return "x-api-key: \(secret.label)"
        case .header: return "\(headerName ?? "header"): \(secret.label)"
        case .query: return "?\(queryName ?? "key")=\(secret.label)"
        }
    }
}

/// Provenance of an endpoint: which local agent config it was discovered in.
public struct EndpointOrigin: Codable, Hashable, Sendable, Identifiable {
    public var sourceID: String
    public var displayName: String
    public var path: String?
    public var pointer: String?

    public var id: String { sourceID + "|" + (path ?? "") + "|" + (pointer ?? "") }

    public init(sourceID: String, displayName: String, path: String? = nil, pointer: String? = nil) {
        self.sourceID = sourceID
        self.displayName = displayName
        self.path = path
        self.pointer = pointer
    }

    public var shortDescription: String {
        var parts: [String] = [displayName]
        if let pointer, !pointer.isEmpty { parts.append(pointer) }
        return parts.joined(separator: " · ")
    }
}

/// A fully described upstream target: base URL + model + auth + wire API.
public struct ProbeEndpoint: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: ProviderKind
    public var wireAPI: WireAPI
    public var baseURL: String
    public var model: String
    public var auth: AuthConfig
    public var extraHeaders: [String: String]
    public var queryParams: [String: String]
    public var origin: EndpointOrigin?
    /// Context window advertised by config or model metadata (no probe needed).
    public var declaredContextWindow: Int?
    /// Max output tokens advertised by config or model metadata.
    public var declaredMaxOutputTokens: Int?
    /// Models known to be served by this endpoint (from `/models` or config).
    public var knownModels: [String]
    public var tags: [String]
    public var enabled: Bool
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        provider: ProviderKind = .custom,
        wireAPI: WireAPI = .openAIChat,
        baseURL: String,
        model: String,
        auth: AuthConfig = .none,
        extraHeaders: [String: String] = [:],
        queryParams: [String: String] = [:],
        origin: EndpointOrigin? = nil,
        declaredContextWindow: Int? = nil,
        declaredMaxOutputTokens: Int? = nil,
        knownModels: [String] = [],
        tags: [String] = [],
        enabled: Bool = true,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.wireAPI = wireAPI
        self.baseURL = baseURL
        self.model = model
        self.auth = auth
        self.extraHeaders = extraHeaders
        self.queryParams = queryParams
        self.origin = origin
        self.declaredContextWindow = declaredContextWindow
        self.declaredMaxOutputTokens = declaredMaxOutputTokens
        self.knownModels = knownModels
        self.tags = tags
        self.enabled = enabled
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Identity used to de-duplicate endpoints discovered from several configs.
    public var dedupeKey: String {
        "\(wireAPI.rawValue)|\(Self.normalisedBase(baseURL))|\(Self.normalisedModel(model))"
    }

    /// Treats `http://host`, `http://host/` and `http://host/v1` as the same
    /// upstream so a provider discovered from two apps collapses into one row.
    static func normalisedBase(_ raw: String) -> String {
        var value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix("/v1") { value.removeLast(3) }
        return value
    }

    static func normalisedModel(_ raw: String) -> String {
        var value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// True when the host points at this machine, so no data leaves the device.
    public var isLocalHost: Bool {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        if host.hasPrefix("127.") { return true }
        if host.hasSuffix(".local") { return true }
        if host.isEmpty { return false }
        return false
    }

    /// Redacted, log-safe rendering of the endpoint.
    public var redactedDescription: String {
        "\(name) · \(wireAPI.rawValue) · \(baseURL) · \(model) · \(auth.label)"
    }
}

/// A saved collection of endpoints plus the user's preferences.
public struct EndpointStore: Codable, Sendable {
    public var version: Int
    public var endpoints: [ProbeEndpoint]
    public var selectedID: UUID?

    public init(version: Int = 1, endpoints: [ProbeEndpoint] = [], selectedID: UUID? = nil) {
        self.version = version
        self.endpoints = endpoints
        self.selectedID = selectedID
    }
}
