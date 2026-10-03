import Foundation

/// Reads opencode configuration (`~/.config/opencode/opencode.json` plus the
/// credential store in `~/.local/share/opencode/auth.json`).
public enum OpenCodeConfigReader {
    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> (endpoints: [ProbeEndpoint], source: DiscoverySource) {
        let home = PathTools.homeDirectory
        let configPath = environment["XDG_CONFIG_HOME"].map { "\($0)/opencode/opencode.json" }
            ?? home + "/.config/opencode/opencode.json"
        let alternate = home + "/.opencode/opencode.json"
        let identifier = "opencode"
        let name = "opencode"

        var path = configPath
        if !PathTools.isReadableFile(path), PathTools.isReadableFile(alternate) { path = alternate }
        guard let object = PathTools.readJSON(path) as? [String: Any] else {
            return ([], DiscoverySource(id: identifier, name: name, path: configPath, status: .notFound))
        }

        let authPath = environment["XDG_DATA_HOME"].map { "\($0)/opencode/auth.json" }
            ?? home + "/.local/share/opencode/auth.json"
        let authStore = (PathTools.readJSON(authPath) as? [String: Any]) ?? [:]

        var result: [ProbeEndpoint] = []
        let providers = object["provider"] as? [String: Any] ?? [:]
        for (providerID, raw) in providers.sorted(by: { $0.key < $1.key }) {
            guard let table = raw as? [String: Any] else { continue }
            let origin = EndpointOrigin(sourceID: identifier, displayName: name, path: path, pointer: "provider.\(providerID)")
            result.append(contentsOf: endpoints(
                fromProvider: table,
                providerID: providerID,
                origin: origin,
                credential: credential(for: providerID, store: authStore),
                label: name
            ))
        }

        return (result, DiscoverySource(
            id: identifier,
            name: name,
            path: path,
            status: result.isEmpty ? .unsupported : .found,
            endpointCount: result.count,
            message: result.isEmpty ? "No provider with a baseURL was found." : nil
        ))
    }

    /// Builds endpoints for one opencode provider entry. Shared with the CC Switch
    /// reader, which stores the same provider shape for its opencode slots.
    public static func endpoints(
        fromProvider table: [String: Any],
        providerID: String,
        origin: EndpointOrigin,
        credential: String? = nil,
        label: String
    ) -> [ProbeEndpoint] {
        let options = table["options"] as? [String: Any] ?? table
        let baseURL = (options["baseURL"] as? String) ?? (options["base_url"] as? String) ?? (table["baseURL"] as? String) ?? ""
        guard !baseURL.isEmpty else { return [] }

        let displayName = (table["name"] as? String) ?? providerID
        let provider = ProviderInference.kind(from: providerID + " " + displayName, baseURL: baseURL)
        let npm = (table["npm"] as? String) ?? ""
        let wireHint: String?
        if npm.contains("anthropic") {
            wireHint = "anthropic"
        } else if npm.contains("google") {
            wireHint = "gemini"
        } else {
            wireHint = nil
        }
        let wireAPI = ProviderInference.wireAPI(hint: wireHint, provider: provider, baseURL: baseURL)

        let secret: SecretSource
        if let inline = (options["apiKey"] as? String) ?? (options["api_key"] as? String) {
            secret = .inline(inline)
        } else if let credential {
            secret = .inline(credential)
        } else {
            secret = .none
        }

        var auth = AuthConfig(style: .bearer, secret: secret)
        switch wireAPI {
        case .anthropicMessages:
            auth.style = .header
            auth.headerName = "x-api-key"
        case .googleGemini:
            auth.style = .header
            auth.headerName = "x-goog-api-key"
        default:
            break
        }

        var models: [String] = []
        if let modelTable = table["models"] as? [String: Any] {
            models = modelTable.keys.sorted()
        }
        if let single = table["model"] as? String, !single.isEmpty { models.insert(single, at: 0) }
        if models.isEmpty { return [] }

        return models.map { model in
            ProbeEndpoint(
                name: "\(label) · \(displayName) · \(model)",
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

    /// opencode keeps raw keys in `auth.json` under the provider id.
    public static func credential(for providerID: String, store: [String: Any]) -> String? {
        guard let entry = store[providerID] as? [String: Any] else { return nil }
        if let key = entry["key"] as? String, !key.isEmpty { return key }
        if let access = entry["access"] as? String, !access.isEmpty { return access }
        return nil
    }
}
