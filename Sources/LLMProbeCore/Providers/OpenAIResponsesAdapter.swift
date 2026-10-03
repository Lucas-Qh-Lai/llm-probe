import Foundation

/// OpenAI's newer `/v1/responses` contract, also used by Codex itself.
public struct OpenAIResponsesAdapter: ProviderAdapter {
    public let wireAPI: WireAPI = .openAIResponses

    public init() {}

    public func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec {
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/responses", ensureV1: true)
        )

        var input: [[String: Any]] = []
        for message in request.messages {
            var content: [[String: Any]] = []
            if !message.text.isEmpty {
                let type = message.role == .assistant ? "output_text" : "input_text"
                content.append(["type": type, "text": message.text])
            }
            for image in message.images {
                content.append(["type": "input_image", "image_url": "data:\(image.mimeType);base64,\(image.base64)"])
            }
            input.append(["role": message.role.rawValue == "system" ? "user" : message.role.rawValue, "content": content])
        }

        var body: [String: Any] = ["model": resolved.model, "input": input, "stream": request.stream]
        if let system = request.system, !system.isEmpty { body["instructions"] = system }
        if let maxTokens = request.maxOutputTokens { body["max_output_tokens"] = maxTokens }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters,
                ] as [String: Any]
            }
            if let choice = OpenAICompatible.toolChoice(request.toolChoice) { body["tool_choice"] = choice }
        }
        if let schema = request.responseSchema {
            body["text"] = [
                "format": [
                    "type": "json_schema",
                    "name": "llm_probe_result",
                    "strict": true,
                    "schema": schema,
                ],
            ]
        } else if request.forceJSONObject {
            body["text"] = ["format": ["type": "json_object"]]
        }
        for (key, value) in request.extraBody { body[key] = value }

        return HTTPRequestSpec(url: url, method: "POST", headers: resolved.headers, body: try JSONBody.data(body), timeout: 90)
    }

    public func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        guard let object = JSONBody.object(payload.body) else {
            throw AdapterError.unreadableResponse("Responses payload was not a JSON object")
        }
        if let error = JSONBody.errorPayload(object) { throw AdapterError.upstream(AdapterError.describe(error)) }

        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        let output = object["output"] as? [[String: Any]] ?? []
        for item in output {
            let type = item["type"] as? String ?? ""
            switch type {
            case "message":
                let content = item["content"] as? [[String: Any]] ?? []
                for part in content {
                    if let value = part["text"] as? String { text += value }
                }
            case "function_call":
                calls.append(ToolCall(
                    id: item["call_id"] as? String,
                    name: item["name"] as? String ?? "",
                    argumentsJSON: item["arguments"] as? String ?? "{}"
                ))
            case "reasoning":
                if let summary = item["summary"] as? [[String: Any]] {
                    reasoning += summary.compactMap { $0["text"] as? String }.joined()
                }
            default:
                break
            }
        }
        if text.isEmpty, let direct = object["output_text"] as? String { text = direct }

        return ChatResponse(
            text: text,
            reasoning: reasoning,
            toolCalls: calls,
            usage: OpenAICompatible.usage(from: object["usage"] as? [String: Any]),
            finishReason: object["status"] as? String,
            modelEcho: object["model"] as? String,
            responseID: object["id"] as? String,
            rawJSON: JSONBody.prettyString(payload.body)
        )
    }

    public func makeStreamDecoder() -> ProviderStreamDecoder {
        OpenAIStyleStreamDecoder(mode: .responses)
    }

    public func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec? {
        OpenAIChatAdapter().modelsRequest(resolved: resolved)
    }

    public func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry] {
        try OpenAIChatAdapter().decodeModels(payload)
    }

    public func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec? {
        guard kind == .maxOutputTokens else { return nil }
        let url = URLTools.applying(
            queryItems: resolved.queryItems,
            to: URLTools.join(base: resolved.baseURL, path: "/responses", ensureV1: true)
        )
        let body: [String: Any] = [
            "model": resolved.model,
            "input": "hi",
            "max_output_tokens": 9_999_999_999,
            "stream": true,
        ]
        return HTTPRequestSpec(url: url, method: "POST", headers: resolved.headers, body: try? JSONBody.data(body), timeout: 20)
    }

    public func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer? {
        OpenAIChatAdapter().decodeLimitQuery(payload)
    }
}
