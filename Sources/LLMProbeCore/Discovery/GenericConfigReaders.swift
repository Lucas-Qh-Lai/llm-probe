import Foundation

/// Reads Google Gemini CLI configuration (`~/.gemini/settings.json`, `~/.gemini/.env`).
public enum GeminiCLIReader {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = PathTools.homeDirectory
        let settingsPath = home + "/.gemini/settings.json"
        let envPath = home + "/.gemini/.env"
        let identifier = "gemini-cli"
        let name = "Gemini CLI"

        guard PathTools.isReadableFile(settingsPath) || PathTools.isReadableFile(envPath) else {
            return ([], DiscoverySource(id: identifier, name: name, path: settingsPath, status: .notFound))
        }

        var values: [String: String] = parseDotEnv(PathTools.readText(envPath))
        var model: String?
        if let settings = PathTools.readJSON(settingsPath) as? [String: Any] {
            if let rawModel = settings["model"] as? String {
                model = rawModel
            } else if let rawModel = settings["model"] as? [String: Any] {
                model = rawModel["name"] as? String
            }
            if let security = settings["security"] as? [String: Any], security["auth"] != nil {
                // Only used to explain where the credential comes from.
            }
        }
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GEMINI_MODEL"] where environment[key] != nil {
            values[key] = environment[key]
        }

        let key = values["GEMINI_API_KEY"] ?? values["GOOGLE_API_KEY"]
        let resolvedModel = values["GEMINI_MODEL"] ?? model ?? "gemini-2.5-pro"
        var auth = AuthConfig(style: .none)
        if let key { auth = AuthConfig(style: .header, headerName: "x-goog-api-key", secret: .inline(key)) }

        let endpoint = ProbeEndpoint(
            name: "Gemini CLI · \(resolvedModel)",
            provider: .google,
            wireAPI: .googleGemini,
            baseURL: "https://generativelanguage.googleapis.com/v1beta",
            model: resolvedModel,
            auth: auth,
            origin: EndpointOrigin(sourceID: identifier, displayName: name, path: settingsPath, pointer: "model"),
            knownModels: [resolvedModel],
            tags: ["gemini-cli"]
        )
        return ([endpoint], DiscoverySource(
            id: identifier,
            name: name,
            path: settingsPath,
            status: .found,
            endpointCount: 1,
            message: key == nil ? L10n.pick(zh: "环境变量和 .env 中都没有找到 API Key。", en: "No API key found in the environment or .env.") : nil
        ))
    }

    /// Minimal `KEY=value` reader for `.env` files.
    static func parseDotEnv(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

/// Reads Continue configuration (`~/.continue/config.json`).
public enum ContinueReader {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = PathTools.homeDirectory
        let path = home + "/.continue/config.json"
        let identifier = "continue"
        let name = "Continue"
        guard let object = PathTools.readJSON(path) as? [String: Any] else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .notFound))
        }
        let models = (object["models"] as? [[String: Any]]) ?? []
        var endpoints: [ProbeEndpoint] = []
        for entry in models {
            let model = (entry["model"] as? String) ?? (entry["title"] as? String) ?? ""
            guard !model.isEmpty else { continue }
            let providerID = (entry["provider"] as? String) ?? "custom"
            var baseURL = (entry["apiBase"] as? String) ?? ""
            let provider = ProviderInference.kind(from: providerID, baseURL: baseURL)
            if baseURL.isEmpty { baseURL = provider.defaultBaseURL ?? "" }
            guard !baseURL.isEmpty else { continue }
            let wireAPI = ProviderInference.wireAPI(hint: entry["apiType"] as? String, provider: provider, baseURL: baseURL)
            var auth = AuthConfig(style: .bearer)
            if let apiKey = entry["apiKey"] as? String, !apiKey.isEmpty, !apiKey.contains("$") {
                auth.secret = .inline(apiKey)
            } else if let envKey = entry["apiKey"] as? String, envKey.hasPrefix("$") {
                auth.secret = .environment(String(envKey.dropFirst()))
            }
            if wireAPI == .anthropicMessages {
                auth.style = .header
                auth.headerName = "x-api-key"
            }
            endpoints.append(ProbeEndpoint(
                name: "Continue · \(entry["title"] as? String ?? model)",
                provider: provider,
                wireAPI: wireAPI,
                baseURL: baseURL,
                model: model,
                auth: auth,
                origin: EndpointOrigin(sourceID: identifier, displayName: name, path: path, pointer: "models"),
                tags: ["continue"]
            ))
        }
        return (endpoints, DiscoverySource(
            id: identifier,
            name: name,
            path: path,
            status: endpoints.isEmpty ? .unsupported : .found,
            endpointCount: endpoints.count
        ))
    }
}

/// Reads Aider configuration (`~/.aider.conf.yml`, `.aider.conf.yml`).
public enum AiderReader {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = PathTools.homeDirectory
        let candidates = [home + "/.aider.conf.yml", FileManager.default.currentDirectoryPath + "/.aider.conf.yml"]
        let identifier = "aider"
        let name = "Aider"
        guard let path = candidates.first(where: { PathTools.isReadableFile($0) }) else {
            return ([], DiscoverySource(id: identifier, name: name, path: candidates[0], status: .notFound))
        }
        guard let text = PathTools.readText(path) else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .unreadable))
        }
        let values = parseSimpleYAML(text)
        let baseURL = values["openai-api-base"] ?? values["openai_api_base"] ?? environment["OPENAI_API_BASE"] ?? "https://api.openai.com/v1"
        let provider = ProviderInference.kind(from: baseURL, baseURL: baseURL)
        var models: [String] = []
        for key in ["model", "weak-model", "editor-model"] {
            if let value = values[key] ?? environment[key.uppercased().replacingOccurrences(of: "-", with: "_")], !value.isEmpty {
                models.append(value)
            }
        }
        var seen = Set<String>()
        models = models.filter { seen.insert($0).inserted }
        guard !models.isEmpty else {
            return ([], DiscoverySource(id: identifier, name: name, path: path, status: .unsupported, message: L10n.pick(zh: "没有配置模型。", en: "No model configured.")))
        }

        var auth = AuthConfig(style: .bearer)
        if let key = values["openai-api-key"] ?? environment["OPENAI_API_KEY"] {
            auth.secret = .inline(key)
        }
        let endpoints = models.map { model in
            ProbeEndpoint(
                name: "Aider · \(model)",
                provider: provider,
                wireAPI: .openAIChat,
                baseURL: baseURL,
                model: model,
                auth: auth,
                origin: EndpointOrigin(sourceID: identifier, displayName: name, path: path, pointer: "model"),
                tags: ["aider"]
            )
        }
        return (endpoints, DiscoverySource(id: identifier, name: name, path: path, status: .found, endpointCount: endpoints.count))
    }

    /// Handles the flat `key: value` subset of YAML that Aider uses.
    static func parseSimpleYAML(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("-"), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty, !value.isEmpty { values[key] = value }
        }
        return values
    }
}

/// Surfaces credentials that exist only as environment variables, so a user can
/// test a vendor without writing a config file.
public enum EnvironmentReader {
    /// Well-known model ids used only when a provider exposes no catalog and the
    /// user has not set an explicit model variable. They are labelled as guesses.
    static let fallbackModels: [ProviderKind: String] = [
        .openai: "gpt-4o-mini",
        .anthropic: "claude-sonnet-4-5",
        .google: "gemini-2.5-flash",
        .deepseek: "deepseek-chat",
        .groq: "llama-3.3-70b-versatile",
        .mistral: "mistral-large-latest",
        .xai: "grok-4",
        .moonshot: "moonshot-v1-8k",
        .zhipu: "glm-4-plus",
        .dashscope: "qwen-plus",
        .siliconflow: "deepseek-ai/DeepSeek-V3",
        .cerebras: "llama-3.3-70b",
    ]

    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let identifier = "environment"
        let name = "Environment variables"
        var endpoints: [ProbeEndpoint] = []

        for provider in ProviderKind.allCases where provider != .custom {
            let names = provider.keyEnvironmentNames + provider.keyEnvironmentPrefixes
            guard let keyName = names.first(where: { name in
                guard let value = environment[name] else { return false }
                return !value.trimmingCharacters(in: .whitespaces).isEmpty
            }), environment[keyName] != nil else { continue }
            guard let baseURL = provider.defaultBaseURL else { continue }

            let modelVariable = names.first { $0.hasSuffix("_MODEL") }
            let explicitModel = modelVariable.flatMap { environment[$0] }
            let model = explicitModel ?? fallbackModels[provider]
            guard let model, !model.isEmpty else { continue }

            let wire = provider.defaultWireAPI
            var auth = AuthConfig(style: .bearer, secret: .environment(keyName))
            if wire == .anthropicMessages {
                auth = AuthConfig(style: .header, headerName: "x-api-key", secret: .environment(keyName))
            } else if wire == .googleGemini {
                auth = AuthConfig(style: .header, headerName: "x-goog-api-key", secret: .environment(keyName))
            }
            endpoints.append(ProbeEndpoint(
                name: "\(provider.displayName) · \(model)",
                provider: provider,
                wireAPI: wire,
                baseURL: baseURL,
                model: model,
                auth: auth,
                origin: EndpointOrigin(sourceID: identifier, displayName: name, path: nil, pointer: keyName),
                knownModels: [model],
                tags: ["$\(keyName)"],
                notes: explicitModel == nil ? "Model guessed; edit it to match your account." : nil
            ))
        }

        return (endpoints, DiscoverySource(
            id: identifier,
            name: name,
            path: "process environment",
            status: endpoints.isEmpty ? .notFound : .found,
            endpointCount: endpoints.count,
            message: endpoints.isEmpty ? L10n.pick(zh: "环境变量中没有找到任何 provider 凭据。", en: "No provider credentials found in the environment.") : nil
        ))
    }
}
