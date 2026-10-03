import Foundation

/// Every prompt the engine sends. They are deliberately tiny: the goal is to
/// spend the fewest possible tokens while still proving the capability.
public enum ProbePrompts {
    /// Cheapest proof that generation works.
    public static let chat = "Reply with the single word: ok"

    /// Enough output to measure time-to-first-token and tokens per second, and to
    /// give the speed estimate a stable denominator.
    public static let streaming = "Count from 1 to 24. Separate the numbers with single spaces and output nothing else."

    /// Forces a single tool call with deterministic arguments.
    public static let tool = "Call the tool `report_upstream_status` with the argument status_token set exactly to OK-1234. Do not answer in text."

    /// Parallel tool calling: two independent tools, both required.
    public static let parallelTools = "Call both available tools now: set status_token to OK-1234 and report the value 7. Do not answer in text."

    /// Vision: a 64x64 image of a mostly red field with a white square.
    public static let vision = "What is the dominant background colour of this image? Answer with one word."

    /// Structured output.
    public static let structured = "Return a JSON object where status is the string \"ok\" and value is the number 7."

    /// Reasoning.
    public static let reasoning = "How many times does the letter r appear in the word strawberry? Think step by step, then answer."

    /// JSON-schema used by the structured-output probe.
    public static let structuredSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "status": ["type": "string", "enum": ["ok"]],
            "value": ["type": "number"],
        ],
        "required": ["status", "value"],
        "additionalProperties": false,
    ]

    /// A second tool used to detect parallel tool calling.
    public static func reportValueTool() -> ToolSpec {
        ToolSpec(
            name: "report_numeric_value",
            description: "Report the numeric value supplied by the user.",
            parameters: [
                "type": "object",
                "properties": [
                    "value": ["type": "integer", "description": "The numeric value supplied by the user."],
                ],
                "required": ["value"],
                "additionalProperties": false,
            ]
        )
    }

    /// 64x64 PNG: red field with a white square. 159 bytes, small enough to send
    /// to any provider without a meaningful input-token cost.
    public static let tinyImageBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAZklEQVR42u3ZsQkAIAwAQRXn0ML9N9LCTZxBEES8r0PgSJnYSwkvl8LjAQAAAAAAAAAAAAAAAAAAANwpn1rU5tyaH7W6AAAAAAAAAAAAAMDdoj8xAAAAAAAAAAAAAAAAAAAAwJeABWb2BbE5gO7YAAAAAElFTkSuQmCC"

    public static func tinyImageAttachment() -> ImageAttachment {
        ImageAttachment(mimeType: "image/png", base64: tinyImageBase64)
    }
}
