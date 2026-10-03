import Foundation

/// Anthropic Messages API (`/v1/messages`), also spoken by Claude Code and by
/// Anthropic-compatible proxies.
public struct AnthropicAdapter: ProviderAdapter {
    public let wireAPI: WireAPI = .anthropicMessages

    public init() {}

    /// Anthropic clients append `/v1/messages` to `ANTHROPIC_BASE_URL`, so a base
    /// like `http://127.0.0.1:3050` must still resolve to `/v1/messages`.
    private func versionedPath(_ base: URL, _ suffix: String) -> URL {
        let path = base.path.hasSuffix("/v1") ? suffix : "/v1" + suffix
        return URLTools.join(base: base, path: path)
    }

    public func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec {
        let url = URLTools.applying(queryItems: resolved.queryItems, to: versionedPath(resolved.baseURL, "/messages"))

        var messages: [[String: Any]] = []
        for message in request.messages where message.role != .system {
            var content: [[String: Any]] = []
            if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
            for image in message.images {
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": image.mimeType, "data": image.base64],
                ])
            }
            messages.append(["role": message.role.rawValue, "content": content])
        }
        // Anthropic rejects an empty message list.
        if messages.isEmpty { messages = [["role": "user", "content": [["type": "text", "text": "hi"]]]] }

        var body: [String: Any] = [
            "model": resolved.model,
            "max_tokens": request.maxOutputTokens ?? 16,
            "messages": messages,
        ]
        if let system = request.system, !system.isEmpty { body["system"] = system }
        if let temperature = request.temperature { body["temperature"] = temperature }
        if request.stream { body["stream"] = true }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["name": tool.name, "description": tool.description, "input_schema": tool.parameters] as [String: Any]
            }
            if let choice = request.toolChoice {
                switch choice {
                case .auto: body["tool_choice"] = ["type": "auto"]
                case .required: body["tool_choice"] = ["type": "any"]
                case .none: body["tool_choice"] = ["type": "none"]
                }
            }
        }
        if let schema = request.responseSchema {
            body["tools"] = (body["tools"] as? [[String: Any]] ?? []) + [[
                "name": "emit_structured_result",
                "description": "Return the answer in the required JSON shape.",
                "input_schema": schema,
            ]]
            body["tool_choice"] = ["type": "tool", "name": "emit_structured_result"]
        }
        for (key, value) in request.extraBody { body[key] = value }

        var headers = resolved.headers
        headers["Accept"] = request.stream ? "text/event-stream" : "application/json"
        return HTTPRequestSpec(url: url, method: "POST", headers: headers, body: try JSONBody.data(body), timeout: 90)
    }

    public func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse {
        guard let object = JSONBody.object(payload.body) else {
            throw AdapterError.unreadableResponse("Messages payload was not a JSON object")
        }
        if let error = JSONBody.errorPayload(object) { throw AdapterError.upstream(AdapterError.describe(error)) }

        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        for block in object["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "thinking":
                reasoning += (block["thinking"] as? String) ?? ""
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                let data = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                calls.append(ToolCall(
                    id: block["id"] as? String,
                    name: block["name"] as? String ?? "",
                    argumentsJSON: String(data: data, encoding: .utf8) ?? "{}"
                ))
            default:
                break
            }
        }
        let usageObject = object["usage"] as? [String: Any]
        let usage = UsageReport(
            inputTokens: OpenAICompatible.intValue(usageObject?["input_tokens"]) ?? 0,
            outputTokens: OpenAICompatible.intValue(usageObject?["output_tokens"]) ?? 0,
            cachedInputTokens: OpenAICompatible.intValue(usageObject?["cache_read_input_tokens"]) ?? 0
        )

        return ChatResponse(
            text: text,
            reasoning: reasoning,
            toolCalls: calls,
            usage: usage,
            finishReason: object["stop_reason"] as? String,
            modelEcho: object["model"] as? String,
            responseID: object["id"] as? String,
            rawJSON: JSONBody.prettyString(payload.body)
        )
    }

    public func makeStreamDecoder() -> ProviderStreamDecoder {
        AnthropicStreamDecoder()
    }

    public func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec? {
        let url = URLTools.applying(queryItems: resolved.queryItems, to: versionedPath(resolved.baseURL, "/models"))
        return HTTPRequestSpec(url: url, method: "GET", headers: resolved.headers, body: nil, timeout: 30)
    }

    public func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry] {
        guard let object = JSONBody.object(payload.body) else { return [] }
        let array = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]]) ?? []
        return array.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return ModelCatalogEntry(
                id: id,
                displayName: entry["display_name"] as? String,
                contextWindow: OpenAICompatible.intValue(entry["context_window"]),
                maxOutputTokens: OpenAICompatible.intValue(entry["max_output_tokens"]),
                capabilities: [:],
                supportedMethods: [],
                raw: [:]
            )
        }
    }

    public func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec? {
        guard kind == .maxOutputTokens else { return nil }
        let url = URLTools.applying(queryItems: resolved.queryItems, to: versionedPath(resolved.baseURL, "/messages"))
        let body: [String: Any] = [
            "model": resolved.model,
            "max_tokens": 9_999_999_999,
            "messages": [["role": "user", "content": "hi"]],
            "stream": true,
        ]
        return HTTPRequestSpec(url: url, method: "POST", headers: resolved.headers, body: try? JSONBody.data(body), timeout: 20)
    }

    public func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer? {
        OpenAIChatAdapter().decodeLimitQuery(payload)
    }
}

final class AnthropicStreamDecoder: ProviderStreamDecoder {
    private var usage = UsageReport.none
    private var inputTokens = 0
    private var outputTokens = 0
    private var cachedTokens = 0
    private var stopReason: String?
    private var toolIndex = 0
    private var activeToolIndex: Int?

    func consume(_ event: SSEEvent) -> [StreamEvent] {
        guard let data = event.data.data(using: .utf8), let object = JSONBody.object(data) else { return [] }
        let type = (object["type"] as? String) ?? event.event ?? ""
        var events: [StreamEvent] = []
        switch type {
        case "message_start":
            if let message = object["message"] as? [String: Any],
               let usageObject = message["usage"] as? [String: Any] {
                inputTokens = OpenAICompatible.intValue(usageObject["input_tokens"]) ?? 0
                cachedTokens = OpenAICompatible.intValue(usageObject["cache_read_input_tokens"]) ?? 0
            }
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any],
               (block["type"] as? String) == "tool_use" {
                let index = OpenAICompatible.intValue(object["index"]) ?? toolIndex
                activeToolIndex = index
                toolIndex = max(toolIndex, index + 1)
                events.append(.toolCallDelta(index: index, id: block["id"] as? String, name: block["name"] as? String, argumentsFragment: nil))
            }
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { break }
            switch delta["type"] as? String {
            case "text_delta":
                if let text = delta["text"] as? String { events.append(.textDelta(text)) }
            case "thinking_delta":
                if let text = delta["thinking"] as? String { events.append(.reasoningDelta(text)) }
            case "input_json_delta":
                if let fragment = delta["partial_json"] as? String {
                    events.append(.toolCallDelta(
                        index: activeToolIndex ?? 0,
                        id: nil,
                        name: nil,
                        argumentsFragment: fragment
                    ))
                }
            default:
                break
            }
        case "content_block_stop":
            activeToolIndex = nil
        case "message_delta":
            if let delta = object["delta"] as? [String: Any] { stopReason = delta["stop_reason"] as? String }
            if let usageObject = object["usage"] as? [String: Any] {
                outputTokens = OpenAICompatible.intValue(usageObject["output_tokens"]) ?? outputTokens
            }
        case "message_stop":
            usage = UsageReport(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedTokens)
            events.append(.usage(usage))
            events.append(.completed(finishReason: stopReason))
        default:
            break
        }
        return events
    }

    func finish() -> [StreamEvent] {
        if usage.total == 0, inputTokens + outputTokens > 0 {
            usage = UsageReport(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedTokens)
            return [.usage(usage), .completed(finishReason: stopReason)]
        }
        return [.completed(finishReason: stopReason)]
    }
}
