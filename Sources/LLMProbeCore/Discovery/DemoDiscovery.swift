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
            DiscoverySource(id: "cc-switch", name: "CC Switch", path: "~/.cc-switch/cc-switch.db", status: .found, endpointCount: 3, message: L10n.pick(zh: "3 种应用、3 个端点 · 1 个当前项", en: "3 app types, 3 endpoints · 1 active")),
            DiscoverySource(id: "codex", name: "Codex CLI", path: "~/.codex/config.toml", status: .found, endpointCount: 2, message: L10n.pick(zh: "2 个自定义 Provider", en: "2 custom providers")),
            DiscoverySource(id: "claude-code", name: "Claude Code", path: "~/.claude/settings.json", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "opencode", name: "OpenCode", path: "~/.config/opencode/opencode.json", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "qwen-code", name: "Qwen Code", path: "~/.qwen/settings.json", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "deepseek-harness", name: "DeepSeek Harness", path: "~/.dsh/profiles/web/cordis.patch.yml", status: .found, endpointCount: 1, message: L10n.pick(zh: "自动识别格式未经过全部版本验证，仅供参考。", en: "Auto-detected format is provided for reference only.")),
            DiscoverySource(id: "kimi-code", name: "Kimi Code CLI", path: "~/.kimi/config.toml", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "minimax-code", name: "MiniMax Code", path: "~/.config/minimax-code/config.json", status: .notFound, message: L10n.pick(zh: "自动识别格式未经过全部版本验证，仅供参考。", en: "Auto-detected format is provided for reference only.")),
            DiscoverySource(id: "zcode", name: "ZCode", path: "~/.zcode/config.json", status: .notFound, message: L10n.pick(zh: "自动识别格式未经过全部版本验证，仅供参考。", en: "Auto-detected format is provided for reference only.")),
            DiscoverySource(id: "mimo-code", name: "MiMo Code", path: "~/.config/mimocode/mimocode.jsonc", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "iflow-cli", name: "iFlow CLI", path: "~/.iflow/settings.json", status: .notFound),
            DiscoverySource(id: "trae-agent", name: "Trae Agent", path: "~/.trae/trae_config.yaml", status: .notFound, message: L10n.pick(zh: "自动识别格式未经过全部版本验证，仅供参考。", en: "Auto-detected format is provided for reference only.")),
            DiscoverySource(id: "gemini-cli", name: "Gemini CLI", path: "~/.gemini/settings.json", status: .notFound),
            DiscoverySource(id: "github-copilot-cli", name: "GitHub Copilot CLI", path: "~/.copilot/config.json", status: .found, endpointCount: 1, message: L10n.pick(zh: "BYOK 端点来自环境变量", en: "BYOK endpoint from environment variables")),
            DiscoverySource(id: "cursor-cli", name: "Cursor CLI", path: "~/.cursor", status: .unsupported, message: L10n.pick(zh: "官方托管路由没有稳定的公开本地 base URL", en: "Hosted route has no stable public base URL")),
            DiscoverySource(id: "amazon-q-developer-cli", name: "Amazon Q Developer CLI", path: "~/.aws/amazonq", status: .unsupported, message: L10n.pick(zh: "官方托管路由没有稳定的公开本地 base URL", en: "Hosted route has no stable public base URL")),
            DiscoverySource(id: "pi", name: "Pi", path: "~/.pi/agent/models.json", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "openclaw", name: "OpenClaw", path: "~/.openclaw/openclaw.json", status: .found, endpointCount: 1, message: nil),
            DiscoverySource(id: "hermes-agent", name: "Hermes Agent", path: "~/.hermes/config.yaml", status: .found, endpointCount: 1, message: nil),
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
