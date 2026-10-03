import Foundation

/// Finds model servers already running on this Mac.
///
/// Only loopback addresses are probed, and only a `GET /v1/models` request is
/// sent, so nothing is uploaded and remote hosts are never contacted.
public enum LocalServerScanner {
    public struct Candidate: Sendable {
        public var port: Int
        public var name: String
        public var provider: ProviderKind
        public var requiresKey: Bool
        public var path: String
    }

    public static let candidates: [Candidate] = [
        Candidate(port: 11434, name: "Ollama", provider: .ollama, requiresKey: false, path: "/v1/models"),
        Candidate(port: 1234, name: "LM Studio", provider: .lmstudio, requiresKey: false, path: "/v1/models"),
        Candidate(port: 8000, name: "vLLM / MLX", provider: .vllm, requiresKey: true, path: "/v1/models"),
        Candidate(port: 8080, name: "MLX server", provider: .mlx, requiresKey: false, path: "/v1/models"),
        Candidate(port: 4000, name: "LiteLLM", provider: .litellm, requiresKey: true, path: "/v1/models"),
        Candidate(port: 3000, name: "One API", provider: .oneapi, requiresKey: true, path: "/v1/models"),
        Candidate(port: 3050, name: "Command Code proxy", provider: .commandCode, requiresKey: true, path: "/v1/models"),
        Candidate(port: 5000, name: "Local OpenAI-compatible server", provider: .custom, requiresKey: false, path: "/v1/models"),
    ]

    public static func scan(client: HTTPClient = .shared, timeout: TimeInterval = 1.8) async -> [ProbeEndpoint] {
        var found: [ProbeEndpoint] = []
        await withTaskGroup(of: ProbeEndpoint?.self) { group in
            for candidate in candidates {
                group.addTask {
                    await probe(candidate: candidate, client: client, timeout: timeout)
                }
            }
            for await endpoint in group {
                if let endpoint { found.append(endpoint) }
            }
        }
        return found.sorted { $0.baseURL < $1.baseURL }
    }

    static func probe(candidate: Candidate, client: HTTPClient, timeout: TimeInterval) async -> ProbeEndpoint? {
        guard let url = URL(string: "http://127.0.0.1:\(candidate.port)\(candidate.path)") else { return nil }
        let request = HTTPRequestSpec(
            url: url,
            method: "GET",
            headers: ["Accept": "application/json", "User-Agent": "LLMProbe/\(LLMProbeVersion.short)"],
            body: nil,
            timeout: timeout
        )
        guard let payload = try? await client.send(request) else { return nil }
        // 404 means something else owns the port; 401/403 means a server is there.
        guard payload.status != 404, payload.status < 500 else { return nil }

        var models: [String] = []
        if payload.isSuccess, let object = JSONBody.object(payload.body) {
            let array = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
            models = array.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
        }
        let auth: AuthConfig = candidate.requiresKey
            ? AuthConfig(style: .bearer, secret: .environment("LLM_PROBE_LOCAL_KEY"))
            : AuthConfig(style: .none, secret: .none)
        let wire: WireAPI = candidate.provider == .ollama ? .ollamaChat : .openAIChat

        return ProbeEndpoint(
            name: "\(candidate.name) :\(candidate.port)",
            provider: candidate.provider,
            wireAPI: wire,
            baseURL: "http://127.0.0.1:\(candidate.port)/v1",
            model: models.first ?? "local-model",
            auth: auth,
            origin: EndpointOrigin(sourceID: "local-scan", displayName: "Local scan", path: nil, pointer: "127.0.0.1:\(candidate.port)"),
            knownModels: models,
            tags: ["local"],
            notes: models.isEmpty ? "Server detected; pick a model id." : nil
        )
    }
}
