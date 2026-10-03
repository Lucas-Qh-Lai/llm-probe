import Foundation

/// Google Gemini `generateContent` / `streamGenerateContent`.
public struct GeminiAdapter: ProviderAdapter {
    public let wireAPI: WireAPI = .googleGemini

    public init() {}

    private func generationURL(resolved: ResolvedEndpoint, streaming: Bool) -> URL {
        let model = URLTools.encodePathComponent(resolved.model)
        let method = streaming ? ":streamGenerateContent" : ":generateContent"
        let url = URLTools.join(base: resolved.baseURL, path: "/models/\(model)\(method)")
        var items = resolved.queryItems
        if streaming { items.append(URLQueryItem(name: "alt", value: "sse")) }
        return URLTools.applying(queryItems: items, to: url)
    }

    public func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec {
        let url = generationURL(resolved: resolved, streaming: request.stream)

        var contents: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            var parts: [[String: Any]] = []
            if !message.text.isEmpty { parts.append(["text": message.text]) }
            for image in message.images {
                parts.append(["inline_data": ["mime_type": image.mimeType, "data": image.base64]])
            }
            contents.append([
                "role": message.role == .assistant ? "model" : "user",
                "parts": parts,
            ])
        }
        if contents.isEmpty { contents = [["role": "user", "parts": [["text": "hi"]]]] }

        var body: [String: Any] = ["contents": contents]
        if let system = request.system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        var generationConfig: [String: Any] = [:]
        if let maxTokens = request.maxOutputTokens { generationConfig["maxOutputTokens"] = maxTokens }
        if let temperature = request.temperature { generationConfig["temperature"] = temperature }
        if let schema = request.responseSchema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = schema
        } else if request.forceJSONObject {
            generationConfig["responseMimeType"] = "application/json"
        }
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }

        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    ["name": tool.name, "description": tool.description, "parameters": tool.parameters] as [String: Any]
                },
            ]]
            if let choice = request.toolChoice {
                let mode: String
                switch choice {
                case .auto: mode = "AUTO"
                case .required: mode = "ANY"
                case .none: mode = "NONE"
                }
                body["toolConfig"] = ["functionCallingConfig": ["mode": mode]]
            }
        }
        for (key, value) in request.extraBody { body[key] = value }

        var headers = resolved.headers
        headers["Accept"] = request.stream ? "text/event-stream" : "application/json"
        return HTTPRequestSpec(url: url, method: "POST", headers: headers, body: try JSONBody.data(body), timeout: 90)
    }

    public func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        try decodeGeminiObject(payload)
    }

    private func decodeGeminiObject(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        guard let object = JSONBody.object(payload.body) else {
            throw AdapterError.unreadableResponse("Gemini payload was not a JSON object")
        }
        if let error = JSONBody.errorPayload(object) { throw AdapterError.upstream(AdapterError.describe(error)) }

        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        let candidates = object["candidates"] as? [[String: Any]] ?? []
        if let candidate = candidates.first,
           let content = candidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if let value = part["text"] as? String { text += value }
                if let thought = part["thought"] as? Bool, thought, let value = part["text"] as? String {
                    reasoning += value
                    text = text.replacingOccurrences(of: value, with: "")
                }
                if let call = part["functionCall"] as? [String: Any] {
                    let args = (call["args"] as? [String: Any]) ?? [:]
                    let data = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    calls.append(ToolCall(
                        id: nil,
                        name: call["name"] as? String ?? "",
                        argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
                    ))
                }
            }
        }

        let usageObject = object["usageMetadata"] as? [String: Any]
        let usage = UsageReport(
            inputTokens: OpenAICompatible.intValue(usageObject?["promptTokenCount"]) ?? 0,
            outputTokens: OpenAICompatible.intValue(usageObject?["candidatesTokenCount"]) ?? 0,
            cachedInputTokens: OpenAICompatible.intValue(usageObject?["cachedContentTokenCount"]) ?? 0,
            reasoningTokens: OpenAICompatible.intValue(usageObject?["thoughtsTokenCount"]) ?? 0
        )

        var finishReason: String?
        if let candidate = candidates.first {
            finishReason = candidate["finishReason"] as? String
        }
        return ChatResponse(
            text: text,
            reasoning: reasoning,
            toolCalls: calls,
            usage: usage,
            finishReason: finishReason,
            modelEcho: object["modelVersion"] as? String,
            responseID: object["responseId"] as? String,
            rawJSON: JSONBody.prettyString(payload.body)
        )
    }

    public func makeStreamDecoder() -> ProviderStreamDecoder {
        GeminiStreamDecoder(adapter: self)
    }

    public func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec? {
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/models")
        )
        return HTTPRequestSpec(url: url, method: "GET", headers: resolved.headers, body: nil, timeout: 30)
    }

    public func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry] {
        guard let object = JSONBody.object(payload.body) else { return [] }
        let array = (object["models"] as? [[String: Any]]) ?? []
        return array.compactMap { entry in
            let rawName = (entry["name"] as? String) ?? ""
            let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst("models/".count)) : rawName
            guard !id.isEmpty else { return nil }
            let methods = entry["supportedGenerationMethods"] as? [String] ?? []
            var capabilities: [Capability: SupportLevel] = [:]
            if methods.contains("generateContent") { capabilities[.chat] = .supported }
            if methods.contains("streamGenerateContent") { capabilities[.streaming] = .supported }
            if methods.contains("embedContent") { capabilities[.embeddings] = .supported }
            return ModelCatalogEntry(
                id: id,
                displayName: entry["displayName"] as? String,
                contextWindow: OpenAICompatible.intValue(entry["inputTokenLimit"]),
                maxOutputTokens: OpenAICompatible.intValue(entry["outputTokenLimit"]),
                capabilities: capabilities,
                supportedMethods: methods,
                raw: [:]
            )
        }
    }

    public func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec? {
        guard kind == .maxOutputTokens else { return nil }
        let url = generationURL(resolved: resolved, streaming: true)
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 9_999_999_999],
        ]
        return HTTPRequestSpec(url: url, method: "POST", headers: resolved.headers, body: try? JSONBody.data(body), timeout: 20)
    }

    public func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer? {
        OpenAIChatAdapter().decodeLimitQuery(payload)
    }

    /// Reads one `generateContent` object out of a stream (used by the decoder).
    func decodeStreamObject(_ object: [String: Any]) -> ChatResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (try? decodeGeminiObject(HTTPResponsePayload(status: 200, headers: [:], body: data, durationMS: 0)))
            ?? ChatResponse()
    }
}

final class GeminiStreamDecoder: ProviderStreamDecoder {
    private let adapter: GeminiAdapter
    private var usage = UsageReport.none
    private var finishReason: String?
    private var seenText = ""

    init(adapter: GeminiAdapter) {
        self.adapter = adapter
    }

    func consume(_ event: SSEEvent) -> [StreamEvent] {
        if event.isDone { return [] }
        guard let data = event.data.data(using: .utf8), let object = JSONBody.object(data) else { return [] }
        let response = adapter.decodeStreamObject(object)
        var events: [StreamEvent] = []
        if !response.text.isEmpty {
            let delta = response.text.hasPrefix(seenText) ? String(response.text.dropFirst(seenText.count)) : response.text
            seenText = response.text
            if !delta.isEmpty { events.append(.textDelta(delta)) }
        }
        if !response.reasoning.isEmpty { events.append(.reasoningDelta(response.reasoning)) }
        for call in response.toolCalls {
            events.append(.toolCallDelta(index: 0, id: call.id, name: call.name, argumentsFragment: call.argumentsJSON))
        }
        if response.usage.total > 0 {
            usage = response.usage
            events.append(.usage(response.usage))
        }
        if let reason = response.finishReason, reason != "FINISH_REASON_UNSPECIFIED" {
            finishReason = reason
        }
        return events
    }

    func finish() -> [StreamEvent] {
        [.completed(finishReason: finishReason)]
    }
}
