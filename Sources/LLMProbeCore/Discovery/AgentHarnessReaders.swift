import Foundation

/// Read-only adapters for common coding-agent configuration layouts.
///
/// Some third-party tools publish behavior but not a stable on-disk schema.
/// Those readers are marked as unverified in the UI and README and only parse
/// plausible local files; they never invoke the agent or mutate its settings.
enum AgentHarnessReaders {
    struct Spec {
        var id: String
        var name: String
        var paths: [String]
        var includeFlatEndpoint = true
        var unverified = false
    }

    static func read(
        _ spec: Spec,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let paths = spec.paths.map(expandHome)
        let existing = paths.filter { PathTools.isReadableFile($0) }
        let displayPath = existing.first ?? paths.first ?? "~"
        guard !existing.isEmpty else {
            let message = spec.unverified
                ? L10n.pick(
                    zh: "自动识别格式未经过全部版本验证，仅供参考。",
                    en: "Auto-detected format is not verified across all versions and is provided for reference only."
                )
                : nil
            return ([], DiscoverySource(id: spec.id, name: spec.name, path: displayPath, status: .notFound, message: message))
        }

        var endpoints: [ProbeEndpoint] = []
        var unreadableCount = 0
        for path in existing {
            guard let root = ConfigDecoding.dictionary(at: path) else {
                unreadableCount += 1
                continue
            }
            endpoints.append(contentsOf: AgentConfigExtractor.endpoints(
                root: root,
                context: AgentConfigExtractor.EndpointContext(
                    sourceID: spec.id,
                    displayName: spec.name,
                    path: path,
                    includeFlatEndpoint: spec.includeFlatEndpoint
                )
            ))
        }
        endpoints = DiscoveryResult.dedupe(endpoints)

        if unreadableCount == existing.count {
            return ([], DiscoverySource(id: spec.id, name: spec.name, path: displayPath, status: .unreadable))
        }

        var notes: [String] = []
        if endpoints.isEmpty { notes.append(L10n.pick(zh: "配置已找到，但未解析出可测试端点。", en: "Configuration found, but no testable endpoint was parsed.")) }
        if spec.unverified {
            notes.append(L10n.pick(
                zh: "自动识别格式未经过全部版本验证，仅供参考。",
                en: "Auto-detected format is not verified across all versions and is provided for reference only."
            ))
        }
        return (endpoints, DiscoverySource(
            id: spec.id,
            name: spec.name,
            path: displayPath,
            status: .found,
            endpointCount: endpoints.count,
            message: notes.isEmpty ? nil : notes.joined(separator: " ")
        ))
    }

    static func qwen(environment: [String: String] = [:]) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(id: "qwen-code", name: "Qwen Code", paths: ["~/.qwen/settings.json"]), environment: environment)
    }

    static func kimi(environment: [String: String] = [:]) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(id: "kimi-code", name: "Kimi Code CLI", paths: ["~/.kimi/config.toml", "~/.kimi/config.json"]), environment: environment)
    }

    static func deepSeekHarness(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = expandHome(environment["DSH_HOME"] ?? "~/.dsh")
        var paths = [home + "/profiles/web/cordis.patch.yml", home + "/profiles/default/cordis.patch.yml"]
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: home + "/profiles") {
            for entry in entries.sorted() {
                paths.append(home + "/profiles/" + entry + "/cordis.patch.yml")
                paths.append(home + "/profiles/" + entry + "/settings.yaml")
            }
        }
        return read(Spec(id: "deepseek-harness", name: "DeepSeek Harness", paths: unique(paths)), environment: environment)
    }

    static func minimaxCode(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(
            id: "minimax-code",
            name: "MiniMax Code",
            paths: [
                "~/.config/minimax-code/config.json",
                "~/.config/minimax-code/config.jsonc",
                "~/.config/mcode/config.json",
                "~/.config/mcode/config.jsonc",
                "~/.minimax-code/config.json",
                "~/Library/Application Support/MiniMax Code/config.json"
            ],
            unverified: true
        ), environment: environment)
    }

    static func iflow(environment: [String: String] = [:]) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(id: "iflow-cli", name: "iFlow CLI", paths: ["~/.iflow/settings.json"]), environment: environment)
    }

    static func traeAgent(environment: [String: String] = [:]) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(
            id: "trae-agent",
            name: "Trae Agent",
            paths: [
                "~/.trae/trae_config.yaml",
                "~/.trae-agent/trae_config.yaml",
                "~/.config/trae-agent/trae_config.yaml",
                "~/.config/trae/trae_config.yaml"
            ],
            unverified: true
        ), environment: environment)
    }

    static func zcode(environment: [String: String] = [:]) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        read(Spec(
            id: "zcode",
            name: "ZCode",
            paths: [
                "~/.zcode/config.json",
                "~/.zcode/config.jsonc",
                "~/.zcode/settings.json",
                "~/.config/zcode/config.json",
                "~/.config/zcode/config.jsonc",
                "~/Library/Application Support/ZCode/config.json",
                "~/Library/Application Support/ZCode/settings.json"
            ],
            unverified: true
        ), environment: environment)
    }

    static func mimoCode(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        var paths = [
            "~/.config/mimocode/mimocode.jsonc",
            "~/.config/mimocode/mimocode.json"
        ]
        if let home = environment["MIMOCODE_HOME"], !home.isEmpty {
            paths.insert(expandHome(home) + "/mimocode.jsonc", at: 0)
            paths.insert(expandHome(home) + "/mimocode.json", at: 1)
        }
        return read(Spec(id: "mimo-code", name: "MiMo Code", paths: unique(paths)), environment: environment)
    }

    static func pi(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        var paths = ["~/.pi/agent/models.json"]
        if let home = environment["PI_CODING_AGENT_DIR"], !home.isEmpty {
            paths.insert(expandHome(home) + "/models.json", at: 0)
        }
        return read(Spec(id: "pi", name: "Pi", paths: unique(paths)), environment: environment)
    }

    static func openClaw(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        var paths = ["~/.openclaw/openclaw.json"]
        let agentRoot = expandHome(environment["OPENCLAW_AGENT_DIR"] ?? "~/.openclaw/agents")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: agentRoot) {
            for entry in entries.sorted() {
                paths.append(agentRoot + "/" + entry + "/agent/models.json")
            }
        }
        if let explicit = environment["OPENCLAW_AGENT_DIR"], !explicit.isEmpty {
            let root = expandHome(explicit)
            paths.append(root + "/agent/models.json")
            paths.append(root + "/models.json")
            paths.append(root + "/openclaw.json")
        }
        return read(Spec(id: "openclaw", name: "OpenClaw", paths: unique(paths)), environment: environment)
    }

    static func hermes(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        var paths = ["~/.hermes/config.yaml", "~/.hermes/config.yml"]
        if let home = environment["HERMES_HOME"], !home.isEmpty {
            paths.insert(expandHome(home) + "/config.yaml", at: 0)
        }
        return read(Spec(id: "hermes-agent", name: "Hermes Agent", paths: unique(paths)), environment: environment)
    }

    static func githubCopilotCLI(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = expandHome(environment["COPILOT_HOME"] ?? "~/.copilot")
        let configPath = home + "/config.json"
        let configExists = PathTools.isReadableFile(configPath)
        let baseURL = environment["COPILOT_PROVIDER_BASE_URL"]
        let model = environment["COPILOT_MODEL"] ?? environment["COPILOT_PROVIDER_WIRE_MODEL"]

        var endpoints: [ProbeEndpoint] = []
        if let baseURL, !baseURL.isEmpty, let model, !model.isEmpty {
            let hint = environment["COPILOT_PROVIDER_TYPE"] ?? environment["COPILOT_PROVIDER_WIRE_API"]
            let provider = ProviderInference.kind(from: "github-copilot " + baseURL, baseURL: baseURL)
            let wireAPI = ProviderInference.wireAPI(hint: hint, provider: provider, baseURL: baseURL)
            var auth = AuthConfig.none
            if let key = environment["COPILOT_PROVIDER_API_KEY"], !key.isEmpty {
                auth = AuthConfig(style: wireAPI == .anthropicMessages ? .xApiKey : .bearer, secret: .environment("COPILOT_PROVIDER_API_KEY"))
            } else if let token = environment["COPILOT_PROVIDER_BEARER_TOKEN"], !token.isEmpty {
                auth = AuthConfig(style: .bearer, secret: .environment("COPILOT_PROVIDER_BEARER_TOKEN"))
            }
            var query: [String: String] = [:]
            if let version = environment["COPILOT_PROVIDER_AZURE_API_VERSION"], !version.isEmpty {
                query["api-version"] = version
            }
            endpoints.append(ProbeEndpoint(
                name: "GitHub Copilot CLI · \(model)",
                provider: provider,
                wireAPI: wireAPI,
                baseURL: baseURL,
                model: model,
                auth: auth,
                queryParams: query,
                origin: EndpointOrigin(sourceID: "github-copilot-cli", displayName: "GitHub Copilot CLI", path: configPath, pointer: "COPILOT_PROVIDER_BASE_URL"),
                knownModels: [model],
                tags: ["GitHub Copilot CLI"]
            ))
        }

        guard configExists || !endpoints.isEmpty else {
            return ([], DiscoverySource(id: "github-copilot-cli", name: "GitHub Copilot CLI", path: configPath, status: .notFound))
        }
        let message = endpoints.isEmpty
            ? L10n.pick(
                zh: "配置已找到；BYOK 端点由 COPILOT_PROVIDER_* 环境变量提供。",
                en: "Configuration found; BYOK endpoints come from COPILOT_PROVIDER_* environment variables."
            )
            : nil
        return (endpoints, DiscoverySource(
            id: "github-copilot-cli",
            name: "GitHub Copilot CLI",
            path: configPath,
            status: .found,
            endpointCount: endpoints.count,
            message: message
        ))
    }

    static func cursorCLI() -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        unsupportedDirectorySource(
            id: "cursor-cli",
            name: "Cursor CLI",
            paths: ["~/.cursor", "~/.cursor-agent"],
            message: L10n.pick(
                zh: "官方托管模型未公开稳定的本地 base URL，暂不生成可测试端点。",
                en: "The hosted model route has no stable public local base URL, so no testable endpoint is generated."
            )
        )
    }

    static func amazonQDeveloperCLI() -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        unsupportedDirectorySource(
            id: "amazon-q-developer-cli",
            name: "Amazon Q Developer CLI",
            paths: ["~/.aws/amazonq", "~/.local/share/amazon-q"],
            message: L10n.pick(
                zh: "Amazon Bedrock 托管路由未公开稳定的本地 base URL，暂不生成可测试端点。",
                en: "The Amazon Bedrock hosted route has no stable public local base URL, so no testable endpoint is generated."
            )
        )
    }

    private static func unsupportedDirectorySource(id: String, name: String, paths: [String], message: String) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let expanded = paths.map(expandHome)
        let existing = expanded.first { FileManager.default.fileExists(atPath: $0) }
        guard let existing else {
            return ([], DiscoverySource(id: id, name: name, path: expanded[0], status: .notFound))
        }
        return ([], DiscoverySource(id: id, name: name, path: existing, status: .unsupported, message: message))
    }

    static func expandHome(_ path: String) -> String {
        if path == "~" { return PathTools.homeDirectory }
        if path.hasPrefix("~/") { return PathTools.homeDirectory + String(path.dropFirst()) }
        return (path as NSString).expandingTildeInPath
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
