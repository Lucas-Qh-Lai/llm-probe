import Foundation

/// Reads Claude Code configuration (`~/.claude/settings.json` and friends).
///
/// The env-block parser is shared with the CC Switch reader, which stores the
/// same `ANTHROPIC_*` block for every Claude-family provider it manages.
public enum ClaudeCodeConfigReader {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = PathTools.homeDirectory
        let primary = home + "/.claude/settings.json"
        let identifier = "claude-code"
        let name = "Claude Code"

        var merged: [String: Any] = [:]
        var foundPaths: [String] = []
        for path in [primary, home + "/.claude/settings.local.json", home + "/.claude.json"] {
            guard let object = PathTools.readJSON(path) as? [String: Any] else { continue }
            foundPaths.append(path)
            if let env = object["env"] as? [String: Any] {
                for (key, value) in env { merged[key] = value }
            }
            for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL"] {
                if let value = object[key] { merged[key] = value }
            }
        }

        guard !foundPaths.isEmpty else {
            return ([], DiscoverySource(id: identifier, name: name, path: primary, status: .notFound))
        }

        // Environment variables override files, matching Claude Code's own order.
        for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL"] {
            if let value = environment[key], !value.isEmpty { merged[key] = value }
        }

        let origin = EndpointOrigin(sourceID: identifier, displayName: name, path: foundPaths.first, pointer: "env")
        let endpoints = endpoints(fromEnv: merged, origin: origin, label: name)
        let baseURL = stringValue(merged["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com"

        return (endpoints, DiscoverySource(
            id: identifier,
            name: name,
            path: foundPaths.joined(separator: ", "),
            status: .found,
            endpointCount: endpoints.count,
            message: "Base URL: \(baseURL)"
        ))
    }

    /// Builds Anthropic-wire endpoints from an `ANTHROPIC_*` environment block.
    public static func endpoints(
        fromEnv env: [String: Any],
        origin: EndpointOrigin,
        label: String,
        defaultBaseURL: String = "https://api.anthropic.com"
    ) -> [ProbeEndpoint] {
        let baseURL = stringValue(env["ANTHROPIC_BASE_URL"]) ?? defaultBaseURL
        let provider = ProviderInference.kind(from: baseURL, baseURL: baseURL)

        let secret: SecretSource
        if let token = stringValue(env["ANTHROPIC_AUTH_TOKEN"]) {
            secret = .inline(token)
        } else if let key = stringValue(env["ANTHROPIC_API_KEY"]) {
            secret = .inline(key)
        } else if let key = stringValue(env["ANTHROPIC_API_KEY"]) {
            secret = .inline(key)
        } else {
            secret = .none
        }

        let modelKeys = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "CLAUDE_CODE_SUBAGENT_MODEL",
        ]
        var models: [String] = []
        for key in modelKeys {
            if let text = stringValue(env[key]), !text.isEmpty { models.append(text) }
        }
        if models.isEmpty { models = ["claude-sonnet-4-5"] }

        var seen = Set<String>()
        let uniqueModels = models.filter { seen.insert($0).inserted }
        let auth = AuthConfig(style: .header, headerName: "x-api-key", secret: secret)

        return uniqueModels.map { model in
            ProbeEndpoint(
                name: "\(label) · \(model)",
                provider: provider,
                wireAPI: .anthropicMessages,
                baseURL: baseURL,
                model: model,
                auth: auth,
                origin: origin,
                knownModels: models,
                tags: [label]
            )
        }
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let value as String where !value.isEmpty: return value
        case let value as Int: return "\(value)"
        case let value as Double: return "\(value)"
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }
}
