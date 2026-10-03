import Foundation

/// One vendor's wire contract: how to build a request, how to read the answer and
/// how to list models.
public protocol ProviderAdapter: Sendable {
    var wireAPI: WireAPI { get }

    /// Chat / generation endpoint.
    func chatRequest(_ request: ChatRequest, resolved: ResolvedEndpoint) throws -> HTTPRequestSpec
    func decodeChat(_ payload: HTTPResponsePayload) throws -> ChatResponse
    func makeStreamDecoder() -> ProviderStreamDecoder

    /// Catalog endpoint. `nil` when the vendor has no listable catalog.
    func modelsRequest(resolved: ResolvedEndpoint) -> HTTPRequestSpec?
    func decodeModels(_ payload: HTTPResponsePayload) throws -> [ModelCatalogEntry]

    /// A metadata request that costs zero completion tokens and reveals the
    /// context window, for example by asking for an impossible
    /// `max_output_tokens` and reading the error.
    func limitQueryRequest(resolved: ResolvedEndpoint, kind: LimitQueryKind) -> HTTPRequestSpec?

    /// Pull a context/limit number out of a limit-query error body.
    func decodeLimitQuery(_ payload: HTTPResponsePayload) -> LimitQueryAnswer?
}

public enum LimitQueryKind: String, Sendable {
    case maxOutputTokens = "max-output-tokens"
    case contextWindow = "context-window"
}

public struct LimitQueryAnswer: Sendable {
    public var kind: LimitQueryKind
    public var value: Int
    public var message: String

    public init(kind: LimitQueryKind, value: Int, message: String) {
        self.kind = kind
        self.value = value
        self.message = message
    }
}

public enum ProviderRegistry {
    public static func adapter(for wireAPI: WireAPI) -> ProviderAdapter {
        switch wireAPI {
        case .openAIChat: return OpenAIChatAdapter()
        case .openAIResponses: return OpenAIResponsesAdapter()
        case .anthropicMessages: return AnthropicAdapter()
        case .googleGemini: return GeminiAdapter()
        case .ollamaChat: return OllamaAdapter()
        }
    }
}

public enum URLTools {
    /// Joins a base URL with a path, preserving any prefix the user configured.
    ///
    /// `ensureV1` appends `/v1` when the base has no path at all, which is the
    /// common mistake when someone pastes `https://api.openai.com`.
    public static func join(base: URL, path: String, ensureV1: Bool = false) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var basePath = components.path
        if basePath.hasSuffix("/") { basePath = String(basePath.dropLast()) }
        if ensureV1, basePath.isEmpty || basePath == "/" {
            basePath = "/v1"
        }
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = basePath + suffix
        components.query = nil
        return components.url ?? base
    }

    /// Applies stored query items to a URL that already carries a path.
    public static func applying(queryItems: [URLQueryItem], to url: URL) -> URL {
        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? url
    }

    /// Percent-encodes a model id for use inside a path (Gemini needs this).
    public static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum JSONBody {
    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Returns the error payload only when it actually carries an error.
    ///
    /// Many providers include `"error": null` on success, which a naive
    /// `if let error = object["error"]` would treat as a failure.
    static func errorPayload(_ object: [String: Any]) -> Any? {
        guard let value = object["error"] else { return nil }
        if value is NSNull { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty ? nil : dictionary }
        if let array = value as? [Any] { return array.isEmpty ? nil : array }
        return value
    }

    static func prettyString(_ data: Data, redacting secrets: [String] = []) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else {
            return Redactor.scrub(String(data: data, encoding: .utf8) ?? "", knownSecrets: secrets)
        }
        return Redactor.scrub(text, knownSecrets: secrets)
    }
}

/// Shared helpers for OpenAI-shaped payloads.
enum OpenAICompatible {
    static func messageObjects(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { message in
            var object: [String: Any] = ["role": message.role.rawValue]
            if message.images.isEmpty {
                object["content"] = message.text
            } else {
                var parts: [[String: Any]] = []
                if !message.text.isEmpty {
                    parts.append(["type": "text", "text": message.text])
                }
                for image in message.images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"],
                    ])
                }
                object["content"] = parts
            }
            return object
        }
    }

    static func toolObjects(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters,
                ],
            ]
        }
    }

    static func toolChoice(_ mode: ToolChoiceMode?) -> Any? {
        guard let mode else { return nil }
        switch mode {
        case .auto: return "auto"
        case .none: return "none"
        case .required: return "required"
        }
    }

    /// Newer OpenAI reasoning models reject `max_tokens`; everyone else is happy
    /// with it. Pick the field that the target model actually understands.
    static func maxTokensField(model: String) -> String {
        let lowered = model.lowercased()
        let needsCompletionTokens = lowered.hasPrefix("gpt-5")
            || lowered.hasPrefix("o1")
            || lowered.hasPrefix("o3")
            || lowered.hasPrefix("o4")
            || lowered.contains("gpt-5")
            || lowered.contains("/o1-")
            || lowered.contains("/o3-")
        return needsCompletionTokens ? "max_completion_tokens" : "max_tokens"
    }

    static func usage(from object: [String: Any]?) -> UsageReport {
        guard let object else { return .none }
        let input = intValue(object["prompt_tokens"]) ?? intValue(object["input_tokens"]) ?? 0
        let output = intValue(object["completion_tokens"]) ?? intValue(object["output_tokens"]) ?? 0
        let cached = intValue((object["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? intValue((object["input_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? 0
        let reasoning = intValue((object["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"])
            ?? intValue((object["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
            ?? 0
        return UsageReport(inputTokens: input, outputTokens: output, cachedInputTokens: cached, reasoningTokens: reasoning)
    }

    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value)
        default: return nil
        }
    }

    static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }
}

/// Decodes an OpenAI-style `data: {...}` stream, shared by the Chat and
/// Responses adapters plus every OpenAI-compatible vendor.
final class OpenAIStyleStreamDecoder: ProviderStreamDecoder {
    private let mode: Mode
    private var accumulatedText = ""
    private var accumulatedReasoning = ""
    private var toolCalls: [Int: (id: String?, name: String?, arguments: String)] = [:]
    private var usage: UsageReport = .none
    private var finishReason: String?
    private var isDone = false

    enum Mode {
        case chatCompletions
        case responses
    }

    init(mode: Mode) {
        self.mode = mode
    }

    func consume(_ event: SSEEvent) -> [StreamEvent] {
        if event.isDone {
            isDone = true
            return []
        }
        guard let data = event.data.data(using: .utf8),
              let object = JSONBody.object(data) else { return [] }

        switch mode {
        case .chatCompletions:
            return consumeChat(object)
        case .responses:
            return consumeResponses(object, eventName: event.event)
        }
    }

    func finish() -> [StreamEvent] {
        var events: [StreamEvent] = []
        if usage.total > 0 { events.append(.usage(usage)) }
        events.append(.completed(finishReason: finishReason ?? (isDone ? "stop" : nil)))
        return events
    }

    private func consumeChat(_ object: [String: Any]) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let usageObject = object["usage"] as? [String: Any] {
            let parsed = OpenAICompatible.usage(from: usageObject)
            if parsed.total > 0 {
                usage = parsed
                events.append(.usage(parsed))
            }
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return events }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                accumulatedText += content
                events.append(.textDelta(content))
            }
            if let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !reasoning.isEmpty {
                accumulatedReasoning += reasoning
                events.append(.reasoningDelta(reasoning))
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let index = OpenAICompatible.intValue(call["index"]) ?? 0
                    var entry = toolCalls[index] ?? (nil, nil, "")
                    if let id = call["id"] as? String { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                        if let fragment = function["arguments"] as? String { entry.arguments += fragment }
                    }
                    toolCalls[index] = entry
                    events.append(.toolCallDelta(
                        index: index,
                        id: entry.id,
                        name: entry.name,
                        argumentsFragment: (call["function"] as? [String: Any])?["arguments"] as? String
                    ))
                }
            }
        }
        return events
    }

    private func consumeResponses(_ object: [String: Any], eventName: String?) -> [StreamEvent] {
        var events: [StreamEvent] = []
        let type = (object["type"] as? String) ?? eventName ?? ""
        switch type {
        case "response.output_text.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                accumulatedText += delta
                events.append(.textDelta(delta))
            }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                accumulatedReasoning += delta
                events.append(.reasoningDelta(delta))
            }
        case "response.output_item.added":
            if let item = object["item"] as? [String: Any],
               (item["type"] as? String) == "function_call",
               let name = item["name"] as? String {
                let index = toolCalls.count
                let id = item["call_id"] as? String
                toolCalls[index] = (id, name, "")
                events.append(.toolCallDelta(index: index, id: id, name: name, argumentsFragment: nil))
            }
        case "response.function_call_arguments.delta":
            let itemID = object["item_id"] as? String
            let index = toolCalls.first(where: { $0.value.id == itemID })?.key ?? (toolCalls.count - 1)
            if let delta = object["delta"] as? String, index >= 0, var entry = toolCalls[index] {
                entry.arguments += delta
                toolCalls[index] = entry
                events.append(.toolCallDelta(index: index, id: entry.id, name: entry.name, argumentsFragment: delta))
            }
        case "response.completed", "response.done":
            if let response = object["response"] as? [String: Any] {
                if let usageObject = response["usage"] as? [String: Any] {
                    let parsed = OpenAICompatible.usage(from: usageObject)
                    usage = parsed
                    events.append(.usage(parsed))
                }
                if let status = response["status"] as? String { finishReason = status }
            }
            isDone = true
        default:
            break
        }
        return events
    }
}
