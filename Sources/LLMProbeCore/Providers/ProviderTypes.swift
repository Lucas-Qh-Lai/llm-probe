import Foundation

public enum ChatRole: String, Sendable {
    case system
    case user
    case assistant
}

public struct ImageAttachment: Sendable, Hashable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }
}

public struct ChatMessage: Sendable {
    public var role: ChatRole
    public var text: String
    public var images: [ImageAttachment]

    public init(role: ChatRole, text: String, images: [ImageAttachment] = []) {
        self.role = role
        self.text = text
        self.images = images
    }

    public static func user(_ text: String, images: [ImageAttachment] = []) -> ChatMessage {
        ChatMessage(role: .user, text: text, images: images)
    }

    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, text: text)
    }

    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }
}

public struct ToolSpec: @unchecked Sendable {
    public var name: String
    public var description: String
    /// JSON Schema object for the arguments.
    public var parameters: [String: Any]

    public init(name: String, description: String, parameters: [String: Any]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The canonical probe tool: a single required string argument.
    public static func echoProbe() -> ToolSpec {
        ToolSpec(
            name: "report_upstream_status",
            description: "Report the upstream status token that the user asked for.",
            parameters: [
                "type": "object",
                "properties": [
                    "status_token": [
                        "type": "string",
                        "description": "The exact status token supplied by the user.",
                    ],
                ],
                "required": ["status_token"],
                "additionalProperties": false,
            ]
        )
    }
}

public enum ToolChoiceMode: String, Sendable {
    /// Let the model decide.
    case auto
    /// Force at least one tool call. Translated per vendor.
    case required
    case none
}

public struct ChatRequest: @unchecked Sendable {
    public var messages: [ChatMessage]
    public var system: String?
    public var tools: [ToolSpec]
    public var toolChoice: ToolChoiceMode?
    /// `max_tokens` / `max_output_tokens` / `maxOutputTokens` depending on vendor.
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var stream: Bool
    /// JSON schema that constrains the answer (structured output probe).
    public var responseSchema: [String: Any]?
    /// Ask for `application/json` without a schema (JSON mode probe).
    public var forceJSONObject: Bool
    public var extraBody: [String: Any]

    public init(
        messages: [ChatMessage],
        system: String? = nil,
        tools: [ToolSpec] = [],
        toolChoice: ToolChoiceMode? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        stream: Bool = false,
        responseSchema: [String: Any]? = nil,
        forceJSONObject: Bool = false,
        extraBody: [String: Any] = [:]
    ) {
        self.messages = messages
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.stream = stream
        self.responseSchema = responseSchema
        self.forceJSONObject = forceJSONObject
        self.extraBody = extraBody
    }
}

public struct ToolCall: Sendable, Hashable {
    public var id: String?
    public var name: String
    public var argumentsJSON: String

    public init(id: String? = nil, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// Best-effort parse of the arguments into a dictionary.
    public var arguments: [String: Any]? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public struct ChatResponse: Sendable {
    public var text: String
    public var reasoning: String
    public var toolCalls: [ToolCall]
    public var usage: UsageReport
    public var finishReason: String?
    public var modelEcho: String?
    /// Provider-native response id, useful for support tickets.
    public var responseID: String?
    /// Redacted raw JSON, kept for the "raw response" inspector.
    public var rawJSON: String

    public init(
        text: String = "",
        reasoning: String = "",
        toolCalls: [ToolCall] = [],
        usage: UsageReport = .none,
        finishReason: String? = nil,
        modelEcho: String? = nil,
        responseID: String? = nil,
        rawJSON: String = ""
    ) {
        self.text = text
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.usage = usage
        self.finishReason = finishReason
        self.modelEcho = modelEcho
        self.responseID = responseID
        self.rawJSON = rawJSON
    }
}

public enum StreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String?)
    case usage(UsageReport)
    case completed(finishReason: String?)
}

public struct ModelCatalogEntry: Sendable, Hashable {
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var capabilities: [Capability: SupportLevel]
    public var supportedMethods: [String]
    public var raw: [String: String]

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        capabilities: [Capability: SupportLevel] = [:],
        supportedMethods: [String] = [],
        raw: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.capabilities = capabilities
        self.supportedMethods = supportedMethods
        self.raw = raw
    }
}

/// Transport encoding used by a vendor's stream.
public enum StreamEncoding: Sendable {
    case serverSentEvents
    case newlineDelimitedJSON
}

/// Incremental parser state for one streamed response.
public protocol ProviderStreamDecoder: AnyObject {
    func consume(_ event: SSEEvent) -> [StreamEvent]
    func finish() -> [StreamEvent]
}
