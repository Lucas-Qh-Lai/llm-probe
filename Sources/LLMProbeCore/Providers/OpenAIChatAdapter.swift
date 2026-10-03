import Foundation

/// OpenAI Chat Completions, plus every vendor that copied it: DeepSeek, Groq,
/// Moonshot, Zhipu, DashScope, SiliconFlow, Together, Fireworks, OpenRouter,
/// xAI, Mistral, vLLM, LM Studio, LiteLLM, one-api and friends.
public struct OpenAIChatAdapter: ProviderAdapter {
    public let wireAPI: WireAPI = .openAIChat

    public init() {}

    public func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec {
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/chat/completions", ensureV1: true)
        )

        var body: [String: Any] = [
            "model": resolved.model,
            "messages": OpenAICompatible.messageObjects(request.messages),
            "stream": request.stream,
        ]
        if let system = request.system, !system.isEmpty {
            body["messages"] = [["role": "system", "content": system]] + (body["messages"] as? [[String: Any]] ?? [])
        }
        if let maxTokens = request.maxOutputTokens {
            body[OpenAICompatible.maxTokensField(model: resolved.model)] = maxTokens
        }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if !request.tools.isEmpty {
            body["tools"] = OpenAICompatible.toolObjects(request.tools)
            if let choice = OpenAICompatible.toolChoice(request.toolChoice) { body["tool_choice"] = choice }
        }
        if let schema = request.responseSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "llm_probe_result", "strict": true, "schema": schema],
            ]
        } else if request.forceJSONObject {
            body["response_format"] = ["type": "json_object"]
        }
        if request.stream {
            body["stream_options"] = ["include_usage": true]
        }
        for (key, value) in request.extraBody { body[key] = value }

        return HTTPRequestSpec(
            url: url,
            method: "POST",
            headers: resolved.headers,
            body: try JSONBody.data(body),
            timeout: 90
        )
    }

    public func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        guard let object = JSONBody.object(payload.body) else {
            throw AdapterError.unreadableResponse("Chat response was not a JSON object")
        }
        if let error = JSONBody.errorPayload(object) { throw AdapterError.upstream(AdapterError.describe(error)) }

        let choices = object["choices"] as? [[String: Any]]
        let message = (choices?.first?["message"] as? [String: Any])
        var text = ""
        var reasoning = ""
        if let content = message?["content"] as? String {
            text = content
        } else if let parts = message?["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        reasoning = (message?["reasoning_content"] as? String) ?? (message?["reasoning"] as? String) ?? ""

        var calls: [ToolCall] = []
        if let rawCalls = message?["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                let function = raw["function"] as? [String: Any]
                calls.append(ToolCall(
                    id: raw["id"] as? String,
                    name: (function?["name"] as? String) ?? "",
                    argumentsJSON: (function?["arguments"] as? String) ?? "{}"
                ))
            }
        }

        return ChatResponse(
            text: text,
            reasoning: reasoning,
            toolCalls: calls,
            usage: OpenAICompatible.usage(from: object["usage"] as? [String: Any]),
            finishReason: choices?.first?["finish_reason"] as? String,
            modelEcho: object["model"] as? String,
            responseID: object["id"] as? String,
            rawJSON: JSONBody.prettyString(payload.body)
        )
    }

    public func makeStreamDecoder() -> ProviderStreamDecoder {
        OpenAIStyleStreamDecoder(mode: .chatCompletions)
    }

    public func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec? {
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/models", ensureV1: true)
        )
        var headers = resolved.headers
        headers["Accept"] = "application/json"
        return HTTPRequestSpec(url: url, method: "GET", headers: headers, body: nil, timeout: 30)
    }

    public func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry] {
        guard let object = JSONBody.object(payload.body) else { return [] }
        let array = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return array.compactMap { entry in
            guard let id = (entry["id"] as? String) ?? (entry["name"] as? String) else { return nil }
            var capabilities: [Capability: SupportLevel] = [:]
            if let modalities = entry["modalities"] as? [String] {
                capabilities[.vision] = modalities.contains("image") || modalities.contains("vision") ? .supported : .unsupported
                capabilities[.audioInput] = modalities.contains("audio") ? .supported : .unsupported
            }
            if let supportsTools = entry["supports_tools"] as? Bool { capabilities[.tools] = supportsTools ? .supported : .unsupported }
            let context = OpenAICompatible.intValue(entry["context_window"])
                ?? OpenAICompatible.intValue(entry["context_length"])
                ?? OpenAICompatible.intValue(entry["max_context_length"])
            let maxOutput = OpenAICompatible.intValue(entry["max_output_tokens"])
                ?? OpenAICompatible.intValue(entry["max_completion_tokens"])
            return ModelCatalogEntry(
                id: id,
                displayName: (entry["name"] as? String) ?? (entry["display_name"] as? String),
                contextWindow: context,
                maxOutputTokens: maxOutput,
                capabilities: capabilities,
                supportedMethods: [],
                raw: [:]
            )
        }
    }

    /// Asks for an impossible output budget. A well-behaved upstream answers with
    /// `400` and states its real maximum, which costs zero completion tokens.
    public func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec? {
        guard kind == .maxOutputTokens else { return nil }
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/chat/completions", ensureV1: true)
        )
        let body: [String: Any] = [
            "model": resolved.model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 9_999_999_999,
            "stream": true,
        ]
        return HTTPRequestSpec(
            url: url,
            method: "POST",
            headers: resolved.headers,
            body: try? JSONBody.data(body),
            timeout: 20
        )
    }

    public func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer? {
        let classified = ErrorClassifier.classify(status: payload.status, body: payload.body, headers: payload.headers)
        guard let value = classified.extractedLimit else { return nil }
        let kind: LimitQueryKind = classified.extractedLimitKind == .maxOutputTokens ? .maxOutputTokens : .contextWindow
        return LimitQueryAnswer(kind: kind, value: value, message: classified.failure.message)
    }
}

/// Errors raised while encoding/decoding a vendor message.
public enum AdapterError: Error, Sendable {
    case unreadableResponse(String)
    case upstream(String)

    public var displayMessage: String {
        switch self {
        case .unreadableResponse(let detail): return detail
        case .upstream(let detail): return detail
        }
    }

    static func describe(_ error: Any) -> String {
        if let object = error as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty { return message }
            if let message = object["error"] as? String { return message }
        }
        if let text = error as? String { return text }
        if error is NSNull { return "The upstream reported an unspecified error." }
        return "\(error)"
    }
}
