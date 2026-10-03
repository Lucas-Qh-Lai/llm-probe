import Foundation

/// A completely fictional discovery result.
///
/// Used by `--demo-discovery` so documentation screenshots can show the
/// discovery panel without revealing anything about the machine that produced
/// them: no real file paths beyond the public, documented locations of each
/// tool, and no real endpoints, model ids or credentials.
public enum DemoDiscovery {
    public static func result(now: Date = Date()) -> DiscoveryResult {
        let demoBase = "http://127.0.0.1:8899/v1"
        let endpoint = ProbeEndpoint(
            name: "Acme AI Gateway · demo-large-1",
            provider: .custom,
            wireAPI: .openAIChat,
            baseURL: demoBase,
            model: "demo-large-1",
            auth: AuthConfig(style: .none, secret: .none),
            origin: EndpointOrigin(sourceID: "demo", displayName: "Acme AI Gateway", path: nil, pointer: "providers.acme"),
            declaredContextWindow: 1_000_000,
            declaredMaxOutputTokens: 65_536,
            knownModels: ["demo-large-1", "demo-small-1", "demo-reasoner-1"],
            tags: ["Acme AI Gateway", "active"]
        )
        let local = ProbeEndpoint(
            name: "Local Demo Server :11434",
            provider: .ollama,
            wireAPI: .ollamaChat,
            baseURL: "http://127.0.0.1:11434/v1",
            model: "demo-local-7b",
            auth: AuthConfig(style: .none, secret: .none),
            origin: EndpointOrigin(sourceID: "local-scan", displayName: "Local scan", path: nil, pointer: "127.0.0.1:11434"),
            knownModels: ["demo-local-7b"],
            tags: ["Local scan"]
        )
        let gateway = ProbeEndpoint(
            name: "Acme Cloud · demo-small-1",
            provider: .openai,
            wireAPI: .openAIResponses,
            baseURL: "https://api.acme-ai.example/v1",
            model: "demo-small-1",
            auth: AuthConfig(style: .bearer, secret: .environment("ACME_API_KEY")),
            origin: EndpointOrigin(sourceID: "demo", displayName: "Acme Cloud", path: nil, pointer: "model_providers.acme"),
            knownModels: ["demo-small-1", "demo-reasoner-1"],
            tags: ["Acme Cloud"]
        )

        let sources: [DiscoverySource] = [
            DiscoverySource(id: "cc-switch", name: "CC Switch", path: "~/.cc-switch/cc-switch.db", status: .found, endpointCount: 3, message: "3 app types, 3 endpoints · 1 active"),
            DiscoverySource(id: "codex", name: "OpenAI Codex", path: "~/.codex/config.toml", status: .found, endpointCount: 2, message: "Auto-compact threshold: 900K tokens."),
            DiscoverySource(id: "claude-code", name: "Claude Code", path: "~/.claude/settings.json", status: .found, endpointCount: 1, message: "Base URL: http://127.0.0.1:8899"),
            DiscoverySource(id: "opencode", name: "opencode", path: "~/.config/opencode/opencode.json", status: .notFound),
            DiscoverySource(id: "gemini-cli", name: "Gemini CLI", path: "~/.gemini/settings.json", status: .notFound),
            DiscoverySource(id: "continue", name: "Continue", path: "~/.continue/config.json", status: .notFound),
            DiscoverySource(id: "aider", name: "Aider", path: "~/.aider.conf.yml", status: .notFound),
            DiscoverySource(id: "environment", name: "Environment variables", path: "process environment", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "local-scan", name: "Local servers", path: "127.0.0.1", status: .found, endpointCount: 1, message: nil),
        ]

        return DiscoveryResult(
            endpoints: DiscoveryResult.dedupe([endpoint, gateway, local]),
            sources: sources,
            scannedAt: now
        )
    }
}
