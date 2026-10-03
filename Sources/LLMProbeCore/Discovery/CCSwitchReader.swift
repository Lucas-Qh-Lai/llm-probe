import Foundation

/// Reads every provider managed by **CC Switch** (`~/.cc-switch/cc-switch.db`).
///
/// CC Switch keeps one row per provider slot and stores each app's native
/// configuration inside `settings_config` as JSON. Six shapes exist today:
///
/// * `codex`          → `{ auth, config (a whole config.toml), modelCatalog }`
/// * `claude`         → `{ env: { ANTHROPIC_* } }`
/// * `claude-desktop` → `{ env: { ANTHROPIC_* } }`
/// * `gemini`         → `{ env, config }`
/// * `opencode`       → one provider object (`options.baseURL`, `models`, …)
/// * `hermes`         → flat `{ base_url, api_key, api_mode, models, model }`
///
/// The database is always opened read-only (`?mode=ro`) and never written.
public enum CCSwitchReader {
    public static func databasePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["CC_SWITCH_DB"], !override.isEmpty { return override }
        return PathTools.homeDirectory + "/.cc-switch/cc-switch.db"
    }

    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let identifier = "cc-switch"
        let name = "CC Switch"
        let path = databasePath(environment: environment)

        guard PathTools.isReadableFile(path) else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .notFound))
        }
        guard let rows = fetchRows(path: path) else {
            return ([], DiscoverySource(
                id: identifier,
                name: name,
                path: path,
                status: .unreadable,
                message: L10n.pick(zh: "无法读取 provider 表：sqlite3 命令是否可用？", en: "Could not read the provider table. Is the sqlite3 command available?")
            ))
        }

        var collected: [ProbeEndpoint] = []
        var skipped: [String] = []
        var appTypes = Set<String>()

        for row in rows {
            guard let appType = row["app_type"] as? String,
                  let providerName = row["name"] as? String,
                  let rawConfig = row["settings_config"] as? String else { continue }
            appTypes.insert(appType)
            let isCurrent = (row["is_current"] as? Bool) ?? ((row["is_current"] as? Int) == 1)
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(rawConfig.utf8))) as? [String: Any] else {
                skipped.append("\(appType)/\(providerName) (unreadable config)")
                continue
            }

            let origin = EndpointOrigin(
                sourceID: identifier,
                displayName: "CC Switch",
                path: path,
                pointer: "\(appType) · \(providerName)"
            )
            let produced = parseEndpoints(
                appType: appType,
                providerName: providerName,
                config: parsed,
                origin: origin,
                isCurrent: isCurrent,
                environment: environment
            )
            if produced.isEmpty {
                skipped.append("\(appType)/\(providerName)")
            } else {
                collected.append(contentsOf: produced)
            }
        }

        let active = collected.filter { $0.tags.contains("active") }.count
        var message = L10n.pick(zh: "\(appTypes.count) 种应用类型，\(collected.count) 个端点", en: "\(appTypes.count) app types, \(collected.count) endpoints")
        if active > 0 { message += L10n.pick(zh: " · \(active) 个当前使用", en: " · \(active) active") }
        if !skipped.isEmpty { message += L10n.pick(zh: " · 已跳过：\(skipped.prefix(4).joined(separator: ", "))", en: " · skipped: \(skipped.prefix(4).joined(separator: ", "))") }

        return (collected, DiscoverySource(
            id: identifier,
            name: name,
            path: path,
            status: collected.isEmpty ? .unsupported : .found,
            endpointCount: collected.count,
            message: message
        ))
    }

    // MARK: - Per-app-type parsing

    static func parseEndpoints(
        appType: String,
        providerName: String,
        config: [String: Any],
        origin: EndpointOrigin,
        isCurrent: Bool,
        environment: [String: String]
    ) -> [ProbeEndpoint] {
        let label = "CC Switch · \(providerName)"
        var produced: [ProbeEndpoint] = []

        switch appType {
        case "codex":
            let catalog = (config["modelCatalog"] as? [String: Any]).map(CodexConfigReader.parseModelCatalog) ?? []
            var auth: [String: String] = [:]
            if let rawAuth = config["auth"] as? [String: Any] {
                for (key, value) in rawAuth {
                    if let text = value as? String { auth[key] = text }
                }
            }
            if let configText = config["config"] as? String, !configText.isEmpty {
                produced = CodexConfigReader.endpointsFromConfigTOML(
                    configText,
                    origin: EndpointOrigin(sourceID: origin.sourceID, displayName: label, path: origin.path, pointer: origin.pointer),
                    catalog: catalog,
                    auth: auth,
                    environment: environment
                )
            }
            // Some slots keep only credentials (for example an official OpenAI
            // key) with an empty TOML body. Surface them so the user can pick a
            // model, using the catalog when it has one.
            if produced.isEmpty, let key = auth["OPENAI_API_KEY"], !key.isEmpty {
                let provider = ProviderInference.kind(from: providerName)
                let baseURL = provider.defaultBaseURL ?? "https://api.openai.com/v1"
                let models = catalog.isEmpty ? [environment["OPENAI_MODEL"] ?? "gpt-5"] : catalog.prefix(3).map(\.id)
                produced = models.map { model in
                    ProbeEndpoint(
                        name: "\(label) · \(model)",
                        provider: provider,
                        wireAPI: provider == .anthropic ? .anthropicMessages : .openAIChat,
                        baseURL: baseURL,
                        model: model,
                        auth: AuthConfig(style: .bearer, secret: .inline(key)),
                        origin: origin,
                        declaredContextWindow: catalog.first { $0.id == model }?.contextWindow,
                        declaredMaxOutputTokens: catalog.first { $0.id == model }?.maxOutputTokens,
                        knownModels: catalog.map(\.id),
                        tags: [label]
                    )
                }
            }

        case "claude", "claude-desktop":
            let env = (config["env"] as? [String: Any]) ?? config
            produced = ClaudeCodeConfigReader.endpoints(fromEnv: env, origin: origin, label: label)

        case "gemini":
            produced = geminiEndpoints(config: config, origin: origin, label: label)

        case "opencode":
            if let providerTable = config["provider"] as? [String: Any] {
                let store = (config["auth"] as? [String: Any]) ?? [:]
                for (providerID, raw) in providerTable.sorted(by: { $0.key < $1.key }) {
                    guard let table = raw as? [String: Any] else { continue }
                    produced.append(contentsOf: OpenCodeConfigReader.endpoints(
                        fromProvider: table,
                        providerID: providerID,
                        origin: origin,
                        credential: OpenCodeConfigReader.credential(for: providerID, store: store),
                        label: label
                    ))
                }
            } else {
                produced = OpenCodeConfigReader.endpoints(
                    fromProvider: config,
                    providerID: providerName,
                    origin: origin,
                    credential: nil,
                    label: label
                )
            }

        case "hermes":
            produced = hermesEndpoints(config: config, providerName: providerName, origin: origin, label: label)

        default:
            produced = genericEndpoints(config: config, providerName: providerName, origin: origin, label: label)
        }

        if isCurrent, !produced.isEmpty {
            for index in produced.indices {
                if !produced[index].tags.contains("active") { produced[index].tags.append("active") }
            }
        }
        return produced
    }

    static func geminiEndpoints(config: [String: Any], origin: EndpointOrigin, label: String) -> [ProbeEndpoint] {
        let env = (config["env"] as? [String: Any]) ?? [:]
        let baseURL = ClaudeCodeConfigReader.stringValue(env["GEMINI_BASE_URL"])
            ?? ClaudeCodeConfigReader.stringValue(env["GOOGLE_GEMINI_BASE_URL"])
            ?? "https://generativelanguage.googleapis.com/v1beta"
        let key = ClaudeCodeConfigReader.stringValue(env["GEMINI_API_KEY"])
            ?? ClaudeCodeConfigReader.stringValue(env["GOOGLE_API_KEY"])
            ?? ClaudeCodeConfigReader.stringValue(env["GOOGLE_GEMINI_API_KEY"])

        var model = ClaudeCodeConfigReader.stringValue(env["GEMINI_MODEL"])
        if model == nil, let rawConfig = config["config"] as? String, !rawConfig.isEmpty,
           let parsed = (try? JSONSerialization.jsonObject(with: Data(rawConfig.utf8))) as? [String: Any] {
            model = (parsed["model"] as? String) ?? ((parsed["modelConfig"] as? [String: Any])?["model"] as? String)
        }
        if let single = config["model"] as? String, !single.isEmpty { model = single }
        let resolvedModel = model ?? "gemini-2.5-pro"

        var auth = AuthConfig(style: .none)
        if let key { auth = AuthConfig(style: .header, headerName: "x-goog-api-key", secret: .inline(key)) }

        return [ProbeEndpoint(
            name: "\(label) · \(resolvedModel)",
            provider: .google,
            wireAPI: .googleGemini,
            baseURL: baseURL,
            model: resolvedModel,
            auth: auth,
            origin: origin,
            knownModels: [resolvedModel],
            tags: [label]
        )]
    }

    static func hermesEndpoints(config: [String: Any], providerName: String, origin: EndpointOrigin, label: String) -> [ProbeEndpoint] {
        let baseURL = (config["base_url"] as? String) ?? (config["baseURL"] as? String) ?? ""
        guard !baseURL.isEmpty else { return [] }
        let apiKey = (config["api_key"] as? String) ?? (config["apiKey"] as? String)
        let apiMode = (config["api_mode"] as? String) ?? (config["apiMode"] as? String)
        let provider = ProviderInference.kind(from: providerName + " " + ((config["name"] as? String) ?? ""), baseURL: baseURL)
        let wireAPI = ProviderInference.wireAPI(hint: apiMode, provider: provider, baseURL: baseURL)

        var models: [String] = []
        if let list = config["models"] as? [Any] {
            for item in list {
                if let text = item as? String { models.append(text) }
                else if let table = item as? [String: Any], let id = (table["id"] as? String) ?? (table["model"] as? String) ?? (table["name"] as? String) {
                    models.append(id)
                }
            }
        }
        if let single = config["model"] as? String, !single.isEmpty { models.insert(single, at: 0) }
        var seen = Set<String>()
        models = models.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !models.isEmpty else { return [] }

        var auth = AuthConfig(style: .bearer, secret: apiKey.map { .inline($0) } ?? .none)
        if wireAPI == .anthropicMessages {
            auth.style = .header
            auth.headerName = "x-api-key"
        }
        return models.map { model in
            ProbeEndpoint(
                name: "\(label) · \(model)",
                provider: provider,
                wireAPI: wireAPI,
                baseURL: baseURL,
                model: model,
                auth: auth,
                origin: origin,
                knownModels: models,
                tags: [label]
            )
        }
    }

    /// Best-effort handler for app types this version does not know yet.
    static func genericEndpoints(config: [String: Any], providerName: String, origin: EndpointOrigin, label: String) -> [ProbeEndpoint] {
        if let providerTable = config["provider"] as? [String: Any] {
            return providerTable.flatMap { key, value -> [ProbeEndpoint] in
                guard let table = value as? [String: Any] else { return [] }
                return OpenCodeConfigReader.endpoints(fromProvider: table, providerID: key, origin: origin, label: label)
            }
        }
        if config["base_url"] != nil || config["baseURL"] != nil {
            return hermesEndpoints(config: config, providerName: providerName, origin: origin, label: label)
        }
        if let env = config["env"] as? [String: Any] {
            if env["ANTHROPIC_BASE_URL"] != nil || env["ANTHROPIC_AUTH_TOKEN"] != nil {
                return ClaudeCodeConfigReader.endpoints(fromEnv: env, origin: origin, label: label)
            }
            if env["GEMINI_API_KEY"] != nil || env["GOOGLE_API_KEY"] != nil {
                return geminiEndpoints(config: config, origin: origin, label: label)
            }
        }
        return OpenCodeConfigReader.endpoints(fromProvider: config, providerID: providerName, origin: origin, label: label)
    }

    // MARK: - Database access

    static func fetchRows(path: String) -> [[String: Any]]? {
        let uri = "file:\(path)?mode=ro"
        let sql = "SELECT app_type, name, is_current, settings_config FROM providers ORDER BY app_type ASC, is_current DESC, sort_index ASC;"
        guard let output = ProcessRunner.run(ProcessRunner.sqlitePath, ["-json", uri, sql], timeout: 12) else { return nil }
        if !output.isSuccess {
            // Older sqlite3 builds lack `-json`; fall back to a delimited export.
            return fetchRowsDelimited(path: path)
        }
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return fetchRowsDelimited(path: path)
        }
        return array
    }

    /// Fallback for `sqlite3` builds without `-json`.
    static func fetchRowsDelimited(path: String) -> [[String: Any]]? {
        let uri = "file:\(path)?mode=ro"
        let separator = "\u{1F}"
        let sql = "SELECT app_type || '\(separator)' || name || '\(separator)' || is_current || '\(separator)' || settings_config FROM providers ORDER BY app_type ASC, is_current DESC, sort_index ASC;"
        guard let output = ProcessRunner.run(ProcessRunner.sqlitePath, ["-separator", "\n", uri, sql], timeout: 12), output.isSuccess else { return nil }
        var rows: [[String: Any]] = []
        for line in output.stdout.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 4 else { continue }
            let settings = parts[3...].joined(separator: separator)
            rows.append([
                "app_type": parts[0],
                "name": parts[1],
                "is_current": parts[2] == "1",
                "settings_config": settings,
            ])
        }
        return rows
    }
}
