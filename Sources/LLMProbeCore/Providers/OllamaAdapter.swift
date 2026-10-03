import Foundation

/// Ollama.
///
/// Chat uses Ollama's OpenAI-compatible route (`/v1/chat/completions`) because it
/// is the same shape as every other local server, while the model catalog comes
/// from the native `/api/tags` endpoint, which also reports family and size.
public struct OllamaAdapter: ProviderAdapter {
    public let wireAPI: WireAPI = .ollamaChat

    public init() {}

    private var inner: OpenAIChatAdapter { OpenAIChatAdapter() }

    public func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec {
        try inner.chatRequest(request, resolved: resolved)
    }

    public func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        try inner.decodeChat(payload)
    }

    public func makeStreamDecoder() -> ProviderStreamDecoder {
        OpenAIStyleStreamDecoder(mode: .chatCompletions)
    }

    /// Strips a trailing `/v1` so native Ollama routes resolve correctly.
    private func nativeBase(_ base: URL) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return base }
        if components.path.hasSuffix("/v1") { components.path = String(components.path.dropLast(3)) }
        if components.path.hasSuffix("/") { components.path = String(components.path.dropLast()) }
        components.query = nil
        return components.url ?? base
    }

    public func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec? {
        let url = URLTools.join(base: nativeBase(resolved.baseURL), path: "/api/tags")
        return HTTPRequestSpec(url: url, method: "GET", headers: resolved.headers, body: nil, timeout: 30)
    }

    public func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry] {
        guard let object = JSONBody.object(payload.body) else { return [] }
        let array = object["models"] as? [[String: Any]] ?? []
        return array.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let details = entry["details"] as? [String: Any]
            var raw: [String: String] = [:]
            for key in ["family", "parameter_size", "quantization_level", "format"] {
                if let value = details?[key] as? String { raw[key] = value }
            }
            return ModelCatalogEntry(
                id: name,
                displayName: details?["family"] as? String,
                contextWindow: nil,
                maxOutputTokens: nil,
                capabilities: [.chat: .supported, .streaming: .supported],
                supportedMethods: [],
                raw: raw
            )
        }
    }

    public func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec? {
        inner.limitQueryRequest(resolved: resolved, kind: kind)
    }

    public func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer? {
        inner.decodeLimitQuery(payload)
    }
}
