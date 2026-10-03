import Foundation

/// Turns provider-shaped sections from heterogeneous agent config files into
/// endpoint candidates. It only interprets data already read locally.
enum AgentConfigExtractor {
    struct EndpointContext {
        var sourceID: String
        var displayName: String
        var path: String
        var includeFlatEndpoint = true
        var environment: [String: String] = ProcessInfo.processInfo.environment
    }

    private struct ProviderRecord {
        var id: String
        var data: [String: Any]
        var protocolHint: String?
        var groupKey: String
    }

    static func endpoints(root: [String: Any], context: EndpointContext) -> [ProbeEndpoint] {
        let bindings = modelBindings(in: root)
        var endpoints: [ProbeEndpoint] = []
        for record in collectProviders(in: root) {
            guard let endpoint = endpoint(record: record, root: root, bindings: bindings, context: context) else { continue }
            endpoints.append(endpoint)
        }
        if context.includeFlatEndpoint, endpoints.isEmpty, let endpoint = flatEndpoint(root: root, context: context) {
            endpoints.append(endpoint)
        }
        return endpoints
    }

    private static func collectProviders(in root: [String: Any]) -> [ProviderRecord] {
        var records: [ProviderRecord] = []
        let groupKeys: Set<String> = ["modelProviders", "model_providers", "providers", "custom_providers", "provider"]

        func visit(_ value: Any) {
            guard let dictionary = value as? [String: Any] else {
                if let array = value as? [Any] { array.forEach(visit) }
                return
            }
            for (key, child) in dictionary {
                guard groupKeys.contains(key) else { continue }
                if let group = child as? [String: Any] {
                    for (providerID, raw) in group {
                        if let provider = raw as? [String: Any] {
                            records.append(ProviderRecord(
                                id: providerID,
                                data: provider,
                                protocolHint: key == "modelProviders" ? providerID : nil,
                                groupKey: key
                            ))
                        } else if let list = raw as? [Any] {
                            for item in list {
                                guard let provider = item as? [String: Any] else { continue }
                                let id = stringValue(provider["id"]) ?? providerID
                                records.append(ProviderRecord(
                                    id: id,
                                    data: provider,
                                    protocolHint: key == "modelProviders" ? providerID : nil,
                                    groupKey: key
                                ))
                            }
                        }
                    }
                } else if let list = child as? [Any] {
                    for item in list {
                        guard let provider = item as? [String: Any] else { continue }
                        let id = stringValue(provider["id"]) ?? stringValue(provider["name"]) ?? "provider"
                        records.append(ProviderRecord(id: id, data: provider, protocolHint: nil, groupKey: key))
                    }
                }
            }
            dictionary.values.forEach(visit)
        }

        visit(root)
        var seen = Set<String>()
        return records.filter { record in
            let key = record.groupKey + "|" + record.id + "|" + (stringValue(record.data["baseUrl"]) ?? stringValue(record.data["baseURL"]) ?? stringValue(record.data["base_url"]) ?? "")
            return seen.insert(key).inserted
        }
    }

    private static func endpoint(
        record: ProviderRecord,
        root: [String: Any],
        bindings: [(provider: String, model: String)],
        context: EndpointContext
    ) -> ProbeEndpoint? {
        let rawBase = stringValue(record.data["baseUrl"])
            ?? stringValue(record.data["baseURL"])
            ?? stringValue(record.data["base_url"])
        let hint = stringValue(record.data["api"])
            ?? stringValue(record.data["api_mode"])
            ?? stringValue(record.data["apiType"])
            ?? stringValue(record.data["wire_api"])
            ?? stringValue(record.data["type"])
            ?? record.protocolHint
        let explicitProvider = stringValue(record.data["provider"])
        let providerIdentifier = rawBase == nil
            ? (explicitProvider ?? record.protocolHint ?? record.groupKey)
            : (explicitProvider ?? "")
        let provider = ProviderInference.kind(from: providerIdentifier + " " + (rawBase ?? ""), baseURL: rawBase)
        guard let baseURL = rawBase ?? provider.defaultBaseURL, !baseURL.isEmpty else { return nil }

        var models = models(from: record.data)
        if record.groupKey == "modelProviders", models.isEmpty { models = [record.id] }
        models.append(contentsOf: bindings.filter { $0.provider == record.id }.map(\.model))
        models.append(contentsOf: compact([stringValue(record.data["model"]), stringValue(record.data["model_id"])]))
        models = unique(models)
        guard !models.isEmpty else { return nil }

        let wireAPI = ProviderInference.wireAPI(hint: hint, provider: provider, baseURL: baseURL)
        let providerName = stringValue(record.data["name"]) ?? record.id
        let secret = secret(
            data: record.data,
            root: root,
            environment: context.environment,
            fallbackEnvironmentNames: provider.keyEnvironmentNames
        )
        return ProbeEndpoint(
            name: "\(context.displayName) · \(providerName)",
            provider: provider,
            wireAPI: wireAPI,
            baseURL: baseURL,
            model: models[0],
            auth: auth(secret: secret, wireAPI: wireAPI),
            origin: EndpointOrigin(
                sourceID: context.sourceID,
                displayName: context.displayName,
                path: context.path,
                pointer: "providers.\(record.id)"
            ),
            knownModels: models,
            tags: [context.displayName]
        )
    }

    private static func flatEndpoint(root: [String: Any], context: EndpointContext) -> ProbeEndpoint? {
        let base = stringValue(root["baseUrl"]) ?? stringValue(root["baseURL"]) ?? stringValue(root["base_url"])
        let model = stringValue(root["modelName"]) ?? stringValue(root["model_name"]) ?? stringValue(root["model"])
        guard let base, let model, !base.isEmpty, !model.isEmpty else { return nil }
        let provider = ProviderInference.kind(from: context.sourceID + " " + base, baseURL: base)
        let wireAPI = ProviderInference.wireAPI(hint: stringValue(root["selectedAuthType"]), provider: provider, baseURL: base)
        let secret = secret(
            data: root,
            root: root,
            environment: context.environment,
            fallbackEnvironmentNames: provider.keyEnvironmentNames
        )
        return ProbeEndpoint(
            name: "\(context.displayName) · \(model)",
            provider: provider,
            wireAPI: wireAPI,
            baseURL: base,
            model: model,
            auth: auth(secret: secret, wireAPI: wireAPI),
            origin: EndpointOrigin(sourceID: context.sourceID, displayName: context.displayName, path: context.path, pointer: "model"),
            knownModels: [model],
            tags: [context.displayName]
        )
    }

    private static func models(from data: [String: Any]) -> [String] {
        var result: [String] = []
        if let list = data["models"] as? [Any] {
            for item in list {
                if let dictionary = item as? [String: Any] {
                    result.append(contentsOf: compact([
                        stringValue(dictionary["id"]),
                        stringValue(dictionary["model"]),
                        stringValue(dictionary["model_id"])
                    ]))
                } else if let value = stringValue(item) {
                    result.append(value)
                }
            }
        } else if let map = data["models"] as? [String: Any] {
            for (key, value) in map {
                if let dictionary = value as? [String: Any] {
                    result.append(stringValue(dictionary["id"]) ?? stringValue(dictionary["model"]) ?? key)
                } else {
                    result.append(key)
                }
            }
        }
        return unique(result)
    }

    private static func modelBindings(in root: [String: Any]) -> [(provider: String, model: String)] {
        var result: [(String, String)] = []
        func visit(_ value: Any) {
            guard let dictionary = value as? [String: Any] else {
                if let array = value as? [Any] { array.forEach(visit) }
                return
            }
            if let models = dictionary["models"] as? [String: Any] {
                for (key, value) in models {
                    guard let model = value as? [String: Any] else { continue }
                    let provider = stringValue(model["provider"]) ?? stringValue(model["model_provider"])
                    let modelID = stringValue(model["model"]) ?? stringValue(model["id"]) ?? key
                    if let provider { result.append((provider, modelID)) }
                }
            }
            dictionary.values.forEach(visit)
        }
        visit(root)
        return result
    }

    private static func secret(
        data: [String: Any],
        root: [String: Any],
        environment: [String: String],
        fallbackEnvironmentNames: [String]
    ) -> SecretSource {
        if let envName = stringValue(data["envKey"])
            ?? stringValue(data["apiKeyEnv"])
            ?? stringValue(data["key_env"])
            ?? stringValue(data["apiKeyEnvKey"]) {
            if let configEnv = (root["env"] as? [String: Any])?[envName], let value = stringValue(configEnv) {
                return .inline(value)
            }
            return .environment(envName)
        }
        let raw = stringValue(data["apiKey"]) ?? stringValue(data["api_key"]) ?? stringValue(data["key"])
        if let raw {
            if raw.hasPrefix("!") { return .none }
            if let envName = environmentReference(raw) { return .environment(envName) }
            return .inline(raw)
        }
        for name in fallbackEnvironmentNames {
            if let value = stringValue((root["env"] as? [String: Any])?[name]) { return .inline(value) }
            if let value = environment[name], !value.isEmpty { return .inline(value) }
        }
        return .none
    }

    private static func auth(secret: SecretSource, wireAPI: WireAPI) -> AuthConfig {
        guard !secret.isNone else { return .none }
        switch wireAPI {
        case .anthropicMessages:
            return AuthConfig(style: .xApiKey, secret: secret)
        case .googleGemini:
            return AuthConfig(style: .header, headerName: "x-goog-api-key", secret: secret)
        default:
            return AuthConfig(style: .bearer, secret: secret)
        }
    }

    private static func environmentReference(_ value: String) -> String? {
        guard value.hasPrefix("$") else { return nil }
        var name = String(value.dropFirst())
        if name.hasPrefix("{"), name.hasSuffix("}") { name = String(name.dropFirst().dropLast()) }
        return name.isEmpty ? nil : name
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func compact(_ values: [String?]) -> [String] {
        values.compactMap { $0 }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
