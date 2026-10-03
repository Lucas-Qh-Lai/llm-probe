import Foundation

/// Reads Codex CLI / IDE configuration (`~/.codex/config.toml`).
///
/// The parsing entry point is shared with the CC Switch reader, which stores an
/// entire Codex `config.toml` as a string inside its SQLite database.
public enum CodexConfigReader {
    public static func configPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("config.toml")
        }
        return PathTools.homeDirectory + "/.codex/config.toml"
    }

    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let path = configPath(environment: environment)
        let identifier = "codex"
        let name = "Codex CLI"
        guard PathTools.isReadableFile(path) else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .notFound))
        }
        guard let text = PathTools.readText(path) else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .unreadable, message: L10n.pick(zh: "无法读取该文件。", en: "Could not read the file.")))
        }

        let root = MiniTOML.parse(text)
        let catalog = readModelCatalog(root: root, configPath: path)
        let auth = readAuthJSON(environment: environment)
        let origin = EndpointOrigin(sourceID: identifier, displayName: name, path: path, pointer: "model_providers")
        let endpoints = endpointsFromConfigTOML(text, origin: origin, catalog: catalog, auth: auth, environment: environment)
        let declaredCompact = root.int("model_auto_compact_token_limit")

        var message: String?
        if let declaredCompact { message = "Auto-compact threshold: \(declaredCompact.formattedTokens) tokens." }
        return (endpoints, DiscoverySource(
            id: identifier,
            name: name,
            path: path,
            status: endpoints.isEmpty ? .unsupported : .found,
            endpointCount: endpoints.count,
            message: endpoints.isEmpty ? L10n.pick(zh: "没有找到带 base_url 的 provider。", en: "No provider with a base_url was found.") : message
        ))
    }

    /// Builds endpoints from a Codex `config.toml` body.
    ///
    /// Shared with `CCSwitchReader`, which embeds a whole `config.toml` inside its
    /// per-provider JSON.
    public static func endpointsFromConfigTOML(
        _ text: String,
        origin: EndpointOrigin,
        catalog: [ModelCatalogEntry] = [],
        auth: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ProbeEndpoint] {
        let root = MiniTOML.parse(text)
        let activeModel = root.string("model")
        let activeProviderID = root.string("model_provider")
        let declaredContext = root.int("model_context_window")
        let providers = root["model_providers"] as? [String: Any] ?? [:]
        var endpoints: [ProbeEndpoint] = []

        for (providerID, raw) in providers.sorted(by: { $0.key < $1.key }) {
            guard let table = raw as? [String: Any] else { continue }
            let baseURL = table.string("base_url") ?? table.string("baseURL") ?? ""
            guard !baseURL.isEmpty else { continue }
            let provider = ProviderInference.kind(from: providerID + " " + (table.string("name") ?? ""), baseURL: baseURL)
            let wireAPI = ProviderInference.wireAPI(hint: table.string("wire_api"), provider: provider, baseURL: baseURL)
            let isActive = activeProviderID == providerID

            var headers = table.stringMap("http_headers")
            if let envHeaders = table.table("env_http_headers") {
                for (headerName, variable) in envHeaders {
                    if let variable = variable as? String, let value = environment[variable] { headers[headerName] = value }
                }
            }

            var authConfig = AuthConfig(style: .bearer, extraHeaders: headers)
            if wireAPI == .anthropicMessages {
                authConfig.style = .header
                authConfig.headerName = "x-api-key"
            } else if wireAPI == .googleGemini {
                authConfig.style = .header
                authConfig.headerName = "x-goog-api-key"
            }
            if let token = table.string("experimental_bearer_token"), !token.isEmpty {
                authConfig.secret = .inline(token)
            } else if let envKey = table.string("env_key"), !envKey.isEmpty {
                authConfig.secret = .environment(envKey)
            } else if table.bool("requires_openai_auth") == true || isActive {
                if let key = auth["OPENAI_API_KEY"], !key.isEmpty {
                    authConfig.secret = .inline(key)
                } else if let key = environment["OPENAI_API_KEY"], !key.isEmpty {
                    authConfig.secret = .environment("OPENAI_API_KEY")
                }
            }

            let models = modelsForProvider(
                providerID: providerID,
                isActive: isActive,
                activeModel: activeModel,
                root: root,
                catalog: catalog
            )
            for model in models {
                let catalogEntry = catalog.first { $0.id == model }
                endpoints.append(ProbeEndpoint(
                    name: "\(table.string("name") ?? providerID) · \(model)",
                    provider: provider,
                    wireAPI: wireAPI,
                    baseURL: baseURL,
                    model: model,
                    auth: authConfig,
                    extraHeaders: headers,
                    origin: EndpointOrigin(
                        sourceID: origin.sourceID,
                        displayName: origin.displayName,
                        path: origin.path,
                        pointer: "\(origin.pointer ?? "config").\(providerID)"
                    ),
                    declaredContextWindow: catalogEntry?.contextWindow ?? (isActive ? declaredContext : nil),
                    declaredMaxOutputTokens: catalogEntry?.maxOutputTokens,
                    knownModels: catalog.map(\.id),
                    tags: [origin.displayName]
                ))
            }
        }

        // Codex also accepts a bare `base_url` plus `model` for single-provider
        // setups; surface that when no provider table exists.
        if endpoints.isEmpty, let baseURL = root.string("base_url"), !baseURL.isEmpty, let model = root.string("model") {
            let provider = ProviderInference.kind(from: activeProviderID ?? "custom", baseURL: baseURL)
            let wireAPI = ProviderInference.wireAPI(hint: root.string("wire_api"), provider: provider, baseURL: baseURL)
            endpoints.append(ProbeEndpoint(
                name: "\(origin.displayName) · \(model)",
                provider: provider,
                wireAPI: wireAPI,
                baseURL: baseURL,
                model: model,
                auth: AuthConfig(secret: environment["OPENAI_API_KEY"] != nil ? .environment("OPENAI_API_KEY") : .none),
                origin: EndpointOrigin(sourceID: origin.sourceID, displayName: origin.displayName, path: origin.path, pointer: "base_url"),
                declaredContextWindow: declaredContext,
                knownModels: catalog.map(\.id),
                tags: [origin.displayName]
            ))
        }
        return endpoints
    }

    private static func modelsForProvider(
        providerID: String,
        isActive: Bool,
        activeModel: String?,
        root: [String: Any],
        catalog: [ModelCatalogEntry]
    ) -> [String] {
        var models: [String] = []
        if isActive, let activeModel { models.append(activeModel) }

        if let profiles = root["profiles"] as? [String: Any] {
            for (_, value) in profiles.sorted(by: { $0.key < $1.key }) {
                guard let profile = value as? [String: Any] else { continue }
                if let profileProvider = profile.string("model_provider"), profileProvider != providerID { continue }
                if let model = profile.string("model") { models.append(model) }
            }
        }
        if models.isEmpty { models.append(contentsOf: catalog.prefix(3).map(\.id)) }
        if models.isEmpty, let activeModel { models.append(activeModel) }
        var seen = Set<String>()
        return models.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Codex stores a model catalog next to its config when the user runs a proxy
    /// that advertises context limits.
    static func readModelCatalog(root: [String: Any], configPath: String) -> [ModelCatalogEntry] {
        guard let relative = root.string("model_catalog_json"), !relative.isEmpty else { return [] }
        let directory = (configPath as NSString).deletingLastPathComponent
        var candidate = relative.hasPrefix("/") ? relative : (directory as NSString).appendingPathComponent(relative)
        if !PathTools.isReadableFile(candidate), !relative.hasSuffix(".json") { candidate += ".json" }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: PathTools.expand(candidate))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseModelCatalog(object)
    }

    /// Parses Codex's `modelCatalog` shape (`{"models": [...]}`).
    public static func parseModelCatalog(_ object: [String: Any]) -> [ModelCatalogEntry] {
        let rawModels = (object["models"] as? [[String: Any]]) ?? (object["data"] as? [[String: Any]]) ?? []
        return rawModels.compactMap { entry in
            let id = (entry["id"] as? String) ?? (entry["model"] as? String) ?? (entry["slug"] as? String)
            guard let id else { return nil }
            let context = OpenAICompatible.intValue(entry["context_window"])
                ?? OpenAICompatible.intValue(entry["context_length"])
                ?? OpenAICompatible.intValue(entry["max_context_window"])
                ?? OpenAICompatible.intValue(entry["max_input_tokens"])
            let maxOutput = OpenAICompatible.intValue(entry["max_output_tokens"])
                ?? OpenAICompatible.intValue(entry["max_completion_tokens"])
            return ModelCatalogEntry(
                id: id,
                displayName: (entry["display_name"] as? String) ?? (entry["name"] as? String),
                contextWindow: context,
                maxOutputTokens: maxOutput
            )
        }
    }

    static func readAuthJSON(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let directory = (configPath(environment: environment) as NSString).deletingLastPathComponent
        let path = (directory as NSString).appendingPathComponent("auth.json")
        guard let object = PathTools.readJSON(path) as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in object where value is String {
            if let text = value as? String { result[key] = text }
        }
        if let tokens = object["tokens"] as? [String: Any] {
            for (key, value) in tokens {
                if let text = value as? String { result[key] = text }
            }
        }
        return result
    }
}
