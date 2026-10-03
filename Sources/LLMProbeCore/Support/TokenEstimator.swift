import Foundation

/// Cheap, dependency-free token estimation.
///
/// Upstreams rarely expose a tokenizer we can call without spending tokens, so
/// the engine uses a conservative heuristic for *budgeting only*. Real numbers
/// always come from the provider's `usage` block when it returns one.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var tokens = 0.0
        var asciiRun = 0.0

        func flushASCII() {
            if asciiRun > 0 {
                // Roughly 4 characters per token for Latin text, minimum 1.
                tokens += max(1, (asciiRun / 4.0).rounded(.up))
                asciiRun = 0
            }
        }

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                // CJK, kana and hangul: about one token per character.
                flushASCII()
                tokens += 1
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x2D, 0x2E, 0x2F:
                asciiRun += 1
            case 0x20, 0x0A, 0x09:
                flushASCII()
                tokens += 0.25
            default:
                flushASCII()
                tokens += 0.5
            }
        }
        flushASCII()
        return max(1, Int(tokens.rounded(.up)))
    }

    public static func estimate<T: Encodable>(_ value: T) -> Int {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return estimate(text)
    }

    /// Builds a filler string of roughly `tokenCount` tokens, used by the
    /// optional context-window payload search.
    public static func filler(tokens: Int, unit: String = "amber ") -> String {
        guard tokens > 0 else { return "" }
        // `unit` is 6 ASCII characters, which the estimator scores at 2 tokens.
        let unitTokens = max(1, estimate(unit))
        let repeats = max(1, tokens / unitTokens)
        return String(repeating: unit, count: repeats).trimmingCharacters(in: .whitespaces)
    }
}

/// Exact token accounting reported by the upstream.
public struct UsageReport: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var reasoningTokens: Int
    /// True when the value came from the provider's `usage` block.
    public var isAuthoritative: Bool

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0, reasoningTokens: Int = 0, isAuthoritative: Bool = true) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.isAuthoritative = isAuthoritative
    }

    public static let none = UsageReport(inputTokens: 0, outputTokens: 0, isAuthoritative: false)

    public var total: Int { inputTokens + outputTokens }
}
