import Foundation

/// A local agent application the app knows how to read.
public struct DiscoverySource: Identifiable, Sendable, Hashable {
    public enum Status: String, Sendable {
        case found
        case notFound = "not-found"
        case unreadable
        case unsupported

        public var displayName: String {
            switch self {
            case .found: return "Found"
            case .notFound: return "Not installed"
            case .unreadable: return "Unreadable"
            case .unsupported: return "Skipped"
            }
        }
    }

    public var id: String
    public var name: String
    public var path: String
    public var status: Status
    public var endpointCount: Int
    public var message: String?

    public init(id: String, name: String, path: String, status: Status, endpointCount: Int = 0, message: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.status = status
        self.endpointCount = endpointCount
        self.message = message
    }

    public var abbreviatedPath: String { PathTools.abbreviate(path) }
}

/// Result of one discovery sweep.
public struct DiscoveryResult: Sendable {
    public var endpoints: [ProbeEndpoint]
    public var sources: [DiscoverySource]
    public var scannedAt: Date

    public init(endpoints: [ProbeEndpoint] = [], sources: [DiscoverySource] = [], scannedAt: Date = Date()) {
        self.endpoints = endpoints
        self.sources = sources
        self.scannedAt = scannedAt
    }

    /// De-duplicates endpoints discovered from several configs, keeping the
    /// richest entry and merging the origins together.
    public static func dedupe(_ endpoints: [ProbeEndpoint]) -> [ProbeEndpoint] {
        var ordered: [ProbeEndpoint] = []
        var indexByKey: [String: Int] = [:]
        for endpoint in endpoints {
            let key = endpoint.dedupeKey
            if let index = indexByKey[key] {
                var existing = ordered[index]
                var origins = existing.tags
                if let origin = endpoint.origin, !origins.contains(origin.displayName) {
                    origins.append(origin.displayName)
                }
                existing.tags = origins
                existing.declaredContextWindow = existing.declaredContextWindow ?? endpoint.declaredContextWindow
                existing.declaredMaxOutputTokens = existing.declaredMaxOutputTokens ?? endpoint.declaredMaxOutputTokens
                if existing.knownModels.isEmpty { existing.knownModels = endpoint.knownModels }
                if existing.auth.secret.isNone, !endpoint.auth.secret.isNone { existing.auth = endpoint.auth }
                ordered[index] = existing
            } else {
                indexByKey[key] = ordered.count
                var value = endpoint
                if let origin = endpoint.origin { value.tags = [origin.displayName] }
                ordered.append(value)
            }
        }
        return ordered
    }
}

/// Shared helpers for turning loose provider keys into `ProviderKind`.
public enum ProviderInference {
    public static func kind(from identifier: String, baseURL: String? = nil) -> ProviderKind {
        let haystack = (identifier + " " + (baseURL ?? "")).lowercased()
        let table: [(String, ProviderKind)] = [
            ("openai", .openai),
            ("anthropic", .anthropic),
            ("claude", .anthropic),
            ("google", .google),
            ("gemini", .google),
            ("generativelanguage", .google),
            ("azure", .azureOpenAI),
            ("openrouter", .openrouter),
            ("deepseek", .deepseek),
            ("moonshot", .moonshot),
            ("kimi", .moonshot),
            ("zhipu", .zhipu),
            ("bigmodel", .zhipu),
            ("glm", .zhipu),
            ("dashscope", .dashscope),
            ("qwen", .dashscope),
            ("siliconflow", .siliconflow),
            ("groq", .groq),
            ("mistral", .mistral),
            ("xai", .xai),
            ("together", .together),
            ("fireworks", .fireworks),
            ("perplexity", .perplexity),
            ("cerebras", .cerebras),
            ("ollama", .ollama),
            ("lmstudio", .lmstudio),
            ("lm-studio", .lmstudio),
            ("mlx", .mlx),
            ("vllm", .vllm),
            ("litellm", .litellm),
            ("one-api", .oneapi),
            ("oneapi", .oneapi),
            ("new-api", .oneapi),
            ("command-code", .commandCode),
            ("commandcode", .commandCode),
            ("command code", .commandCode),
        ]
        for (needle, kind) in table where haystack.contains(needle) { return kind }
        return .custom
    }

    /// Guesses the wire API from a base URL and an optional explicit hint.
    public static func wireAPI(hint: String?, provider: ProviderKind, baseURL: String? = nil) -> WireAPI {
        if let hint {
            switch hint.lowercased() {
            case "chat", "chat_completions", "openai-chat", "openai": return .openAIChat
            case "responses", "openai-responses": return .openAIResponses
            case "messages", "anthropic", "anthropic-messages": return .anthropicMessages
            case "gemini", "google", "generatecontent": return .googleGemini
            case "ollama": return .ollamaChat
            default: break
            }
        }
        if let baseURL {
            let lowered = baseURL.lowercased()
            if lowered.contains("anthropic") { return .anthropicMessages }
            if lowered.contains("generativelanguage.googleapis.com") { return .googleGemini }
        }
        if provider == .anthropic { return .anthropicMessages }
        if provider == .google { return .googleGemini }
        if provider == .ollama { return .ollamaChat }
        return .openAIChat
    }

    /// Best-effort authentication style for a vendor.
    public static func authStyle(provider: ProviderKind, wireAPI: WireAPI) -> AuthConfig.Style {
        switch wireAPI {
        case .anthropicMessages, .googleGemini: return .none
        default: return .bearer
        }
    }
}
