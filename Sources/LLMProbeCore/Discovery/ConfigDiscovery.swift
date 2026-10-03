import Foundation

/// Runs every reader and merges the results into one de-duplicated endpoint list.
public enum ConfigDiscovery {
    /// Known local sources, with the paths the UI should show before a scan runs.
    public static func knownSources(environment: [String: String] = ProcessInfo.processInfo.environment) -> [(id: String, name: String, path: String)] {
        let home = PathTools.homeDirectory
        var sources: [(String, String, String)] = [
            ("cc-switch", "CC Switch", CCSwitchReader.databasePath(environment: environment)),
            ("codex", "Codex CLI", CodexConfigReader.configPath(environment: environment)),
            ("claude-code", "Claude Code", home + "/.claude/settings.json"),
            ("opencode", "OpenCode", home + "/.config/opencode/opencode.json"),
            ("qwen-code", "Qwen Code", home + "/.qwen/settings.json"),
            ("deepseek-harness", "DeepSeek Harness", home + "/.dsh/profiles/web/cordis.patch.yml"),
            ("kimi-code", "Kimi Code CLI", home + "/.kimi/config.toml"),
            ("minimax-code", "MiniMax Code", home + "/.config/minimax-code/config.json"),
            ("zcode", "ZCode", home + "/.zcode/config.json"),
            ("mimo-code", "MiMo Code", home + "/.config/mimocode/mimocode.jsonc"),
            ("iflow-cli", "iFlow CLI", home + "/.iflow/settings.json"),
            ("trae-agent", "Trae Agent", home + "/.trae/trae_config.yaml"),
            ("gemini-cli", "Gemini CLI", home + "/.gemini/settings.json"),
            ("github-copilot-cli", "GitHub Copilot CLI", home + "/.copilot/config.json"),
            ("cursor-cli", "Cursor CLI", home + "/.cursor"),
            ("amazon-q-developer-cli", "Amazon Q Developer CLI", home + "/.aws/amazonq"),
            ("pi", "Pi", home + "/.pi/agent/models.json"),
            ("openclaw", "OpenClaw", home + "/.openclaw/openclaw.json"),
            ("hermes-agent", "Hermes Agent", home + "/.hermes/config.yaml"),
            ("continue", "Continue", home + "/.continue/config.json"),
            ("aider", "Aider", home + "/.aider.conf.yml"),
            ("environment", "Environment variables", "process environment"),
            ("local-scan", "Local servers", "127.0.0.1"),
        ]
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            let path = (codexHome as NSString).appendingPathComponent("config.toml")
            sources = sources.map { $0.0 == "codex" ? ("codex", "Codex CLI", path) : $0 }
        }
        return sources
    }

    public static func scan(
        includeLocalServers: Bool = true,
        includeEnvironment: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> DiscoveryResult {
        var endpoints: [ProbeEndpoint] = []
        var sources: [DiscoverySource] = []

        // CC Switch first: it owns the active configuration for most users.
        let ccSwitch = CCSwitchReader.read(environment: environment)
        endpoints.append(contentsOf: ccSwitch.endpoints)
        sources.append(ccSwitch.source)

        let codex = CodexConfigReader.read(environment: environment)
        endpoints.append(contentsOf: codex.endpoints)
        sources.append(codex.source)

        let harnessReaders: [(endpoints: [ProbeEndpoint], source: DiscoverySource)] = [
            ClaudeCodeConfigReader.read(environment: environment),
            OpenCodeConfigReader.read(environment: environment),
            AgentHarnessReaders.qwen(environment: environment),
            AgentHarnessReaders.deepSeekHarness(environment: environment),
            AgentHarnessReaders.kimi(environment: environment),
            AgentHarnessReaders.minimaxCode(environment: environment),
            AgentHarnessReaders.zcode(environment: environment),
            AgentHarnessReaders.mimoCode(environment: environment),
            AgentHarnessReaders.iflow(environment: environment),
            AgentHarnessReaders.traeAgent(environment: environment),
            GeminiCLIReader.read(environment: environment),
            AgentHarnessReaders.githubCopilotCLI(environment: environment),
            AgentHarnessReaders.cursorCLI(),
            AgentHarnessReaders.amazonQDeveloperCLI(),
            AgentHarnessReaders.pi(environment: environment),
            AgentHarnessReaders.openClaw(environment: environment),
            AgentHarnessReaders.hermes(environment: environment),
            ContinueReader.read(environment: environment),
            AiderReader.read(environment: environment),
        ]
        for reader in harnessReaders {
            endpoints.append(contentsOf: reader.endpoints)
            sources.append(reader.source)
        }

        if includeEnvironment {
            let environmentReader = EnvironmentReader.read(environment: environment)
            endpoints.append(contentsOf: environmentReader.endpoints)
            sources.append(environmentReader.source)
        }

        var localCount = 0
        if includeLocalServers {
            let local = await LocalServerScanner.scan()
            localCount = local.count
            endpoints.append(contentsOf: local)
        }
        sources.append(DiscoverySource(
            id: "local-scan",
            name: L10n.pick(zh: "本地模型服务", en: "Local servers"),
            path: "127.0.0.1",
            status: includeLocalServers ? (localCount > 0 ? .found : .notFound) : .unsupported,
            endpointCount: localCount,
            message: includeLocalServers ? nil : L10n.pick(zh: "已跳过。", en: "Skipped.")
        ))

        return DiscoveryResult(
            endpoints: DiscoveryResult.dedupe(endpoints),
            sources: sources,
            scannedAt: Date()
        )
    }
}
