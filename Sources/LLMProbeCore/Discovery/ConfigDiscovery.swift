import Foundation

/// Runs every reader and merges the results into one de-duplicated endpoint list.
public enum ConfigDiscovery {
    /// Known local sources, with the paths the UI should show before a scan runs.
    public static func knownSources(environment: [String: String] = ProcessInfo.processInfo.environment) -> [(id: String, name: String, path: String)] {
        let home = PathTools.homeDirectory
        var sources: [(String, String, String)] = [
            ("cc-switch", "CC Switch", CCSwitchReader.databasePath(environment: environment)),
            ("codex", "OpenAI Codex", CodexConfigReader.configPath(environment: environment)),
            ("claude-code", "Claude Code", home + "/.claude/settings.json"),
            ("opencode", "opencode", home + "/.config/opencode/opencode.json"),
            ("gemini-cli", "Gemini CLI", home + "/.gemini/settings.json"),
            ("continue", "Continue", home + "/.continue/config.json"),
            ("aider", "Aider", home + "/.aider.conf.yml"),
            ("environment", "Environment variables", "process environment"),
            ("local-scan", "Local servers", "127.0.0.1"),
        ]
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            sources[1] = ("codex", "OpenAI Codex", (codexHome as NSString).appendingPathComponent("config.toml"))
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

        let claude = ClaudeCodeConfigReader.read(environment: environment)
        endpoints.append(contentsOf: claude.endpoints)
        sources.append(claude.source)

        let opencode = OpenCodeConfigReader.read(environment: environment)
        endpoints.append(contentsOf: opencode.endpoints)
        sources.append(opencode.source)

        let gemini = GeminiCLIReader.read(environment: environment)
        endpoints.append(contentsOf: gemini.endpoints)
        sources.append(gemini.source)

        let continueReader = ContinueReader.read(environment: environment)
        endpoints.append(contentsOf: continueReader.endpoints)
        sources.append(continueReader.source)

        let aider = AiderReader.read(environment: environment)
        endpoints.append(contentsOf: aider.endpoints)
        sources.append(aider.source)

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
