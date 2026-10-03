import Foundation

/// Turns an upstream HTTP failure into a categorised, actionable verdict.
///
/// The wording matters: a 400 caused by "max_tokens too large" is *evidence*
/// (it reveals the real limit) while a 400 caused by a broken request shape is a
/// genuine failure. The classifier keeps that distinction.
public enum ErrorClassifier {
    public enum LimitKind: String, Sendable {
        case contextWindow = "context-window"
        case maxOutputTokens = "max-output-tokens"
        case maxInputTokens = "max-input-tokens"
    }

    public struct Classified: Sendable {
        public var failure: ProbeFailure
        /// The upstream said the request shape was valid but a parameter was out of range.
        public var isValidationOnly: Bool
        public var extractedLimit: Int?
        public var extractedLimitKind: LimitKind?
    }

    public static func classify(status: Int, body: Data, headers: [String: String] = [:]) -> Classified {
        let text = String(data: body, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let (message, code, type) = extractError(json: json, fallback: text)
        let rawSnippet = text.isEmpty ? nil : String(text.prefix(1200))

        var category: ProbeFailure.Category
        switch status {
        case 400, 422: category = .invalidRequest
        case 401: category = .authentication
        case 402: category = .quotaExceeded
        case 403: category = .authorization
        case 404: category = .modelNotFound
        case 408: category = .timeout
        case 413: category = .contextOverflow
        case 429: category = .rateLimited
        case 500...599: category = .serverError
        case 0: category = .network
        default: category = status >= 400 ? .invalidRequest : .unknown
        }

        let lowered = (message + " " + (type ?? "") + " " + (code ?? "")).lowercased()
        var extractedLimit: Int?
        var limitKind: LimitKind?
        var isValidationOnly = false

        if containsAny(lowered, ["context length", "context window", "maximum context", "too many tokens",
                                 "prompt is too long", "exceeds the maximum number of tokens",
                                 "maximum number of tokens", "input is too long", "token limit",
                                 "prompt too long", "reduce the length", "context_length_exceeded"]) {
            category = .contextOverflow
            if let limit = extractLimit(from: lowered, keywords: ["context length is", "context window is",
                                                                  "maximum context length is", "maximum context length",
                                                                  "maximum number of tokens is", "context length",
                                                                  "context window", "maximum number of tokens"]) {
                extractedLimit = limit
                limitKind = .contextWindow
            }
        }

        if containsAny(lowered, ["max_tokens", "max output tokens", "maximum output", "max_completion_tokens",
                                 "output token limit", "maxoutputtokens"]) {
            if let limit = extractLimit(from: lowered, keywords: ["max_tokens", "max output tokens", "maximum output",
                                                                  "max_completion_tokens", "output token limit",
                                                                  "maxoutputtokens", "maximum tokens"]) {
                extractedLimit = limit
                limitKind = .maxOutputTokens
            }
            isValidationOnly = status == 400 || status == 422
            if category == .invalidRequest { category = .invalidRequest }
        }

        if containsAny(lowered, ["budget", "insufficient", "balance", "quota", "credit", "arrears", "欠费"]) {
            category = .quotaExceeded
        }
        if containsAny(lowered, ["unsupported", "not supported", "does not support", "unknown field",
                                 "unrecognized", "invalid schema", "not implemented"]) {
            if category == .invalidRequest { category = .unsupportedCapability }
        }
        if containsAny(lowered, ["model not found", "no such model", "does not exist", "unknown model",
                                 "model_not_found", "invalid model"]) {
            category = .modelNotFound
        }
        if containsAny(lowered, ["rate limit", "too many requests", "tpm", "rpm", "overloaded"]) {
            category = .rateLimited
        }
        if containsAny(lowered, ["internal server error", "server error", "service unavailable", "bad gateway",
                                 "upstream", "temporarily unavailable", "overloaded_error"]) {
            if category == .invalidRequest { category = .serverError }
        }

        let retryAfter = headers.first { $0.key.caseInsensitiveCompare("retry-after") == .orderedSame }?.value
        var fullMessage = message
        if let retryAfter, !fullMessage.isEmpty {
            fullMessage += " (retry-after: \(retryAfter)s)"
        }
        if fullMessage.isEmpty {
            fullMessage = "HTTP \(status)"
        }

        let failure = ProbeFailure(
            category: category,
            httpStatus: status == 0 ? nil : status,
            providerCode: code ?? type,
            message: String(fullMessage.prefix(600)),
            rawBodySnippet: rawSnippet
        )
        return Classified(failure: failure, isValidationOnly: isValidationOnly, extractedLimit: extractedLimit, extractedLimitKind: limitKind)
    }

    /// Extracts a limit from messages such as
    /// "max_tokens: 999999 > 65536, which is the maximum allowed" or
    /// "max_tokens is too large: 999999. This model supports at most 8192
    /// completion tokens".
    ///
    /// Upstreams quote the *rejected* value first and the real limit second, so
    /// the first number in the message is usually the wrong answer. The
    /// extraction therefore prefers a number that follows an explicit limit
    /// marker, and otherwise falls back to the smallest number in the message,
    /// which is the limit whenever the rejected value is larger than it.
    public static func extractLimit(from text: String, keywords: [String]) -> Int? {
        let lowered = text.lowercased()
        for keyword in keywords {
            guard let range = lowered.range(of: keyword) else { continue }
            let tail = String(lowered[range.upperBound...].prefix(200))
            let candidates = numbers(in: tail)
            guard !candidates.isEmpty else { continue }

            // 1. An explicit limit marker: "> 65536", "at most 8192", ...
            let markers = [">", "at most", "up to", "maximum", "max allowed", "must be", "limit is", "allowed", "supports"]
            for marker in markers {
                guard let markerRange = tail.range(of: marker) else { continue }
                let after = String(tail[markerRange.upperBound...])
                if let value = numbers(in: after).first?.value, value >= 256 { return value }
            }

            // 2. The rejected value is normally larger than the limit.
            let values = candidates.map(\.value)
            if values.count > 1, let smallest = values.min(), let first = values.first,
               smallest >= 256, smallest != first {
                return smallest
            }
            if let first = values.first, first >= 256 { return first }
        }
        // Suffix form: "128k", "1M", "200000 tokens".
        let suffixed = matches(pattern: #"([0-9]{2,4})\s*([kKmM])\b"#, in: text)
        if let first = suffixed.first {
            let digits = first.filter { $0.isNumber }
            let suffix = first.lowercased().suffix(1)
            if let base = Int(digits) {
                return suffix == "k" ? base * 1000 : base * 1_000_000
            }
        }
        return nil
    }

    /// Every standalone integer in `text`, with its position, ignoring the
    /// thousand separators upstreams sometimes use ("65,536").
    private static func numbers(in text: String) -> [(value: Int, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9][0-9,_]*[0-9]|[0-9]"#) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let cleaned = text[range].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
            guard let value = Int(cleaned) else { return nil }
            return (value, range)
        }
    }

    public static func extractError(json: [String: Any]?, fallback: String) -> (message: String, code: String?, type: String?) {
        if let json {
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? (error["error"] as? String) ?? ""
                let code = (error["code"] as? String) ?? (error["code"].map { "\($0)" })
                let type = error["type"] as? String
                if !message.isEmpty { return (message, code, type) }
            }
            if let error = json["error"] as? String {
                return (error, json["code"] as? String, nil)
            }
            if let message = json["message"] as? String {
                return (message, json["code"].map { "\($0)" }, json["type"] as? String)
            }
            if let error = json["error"] as? [String: Any], let status = error["status"] as? String {
                return ((error["message"] as? String) ?? status, status, nil)
            }
        }
        if !fallback.isEmpty {
            return (String(fallback.prefix(400)), nil, nil)
        }
        return ("", nil, nil)
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }
}
