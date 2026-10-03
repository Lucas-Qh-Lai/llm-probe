import Foundation

/// Secret-safe rendering. Everything user visible goes through here so keys can
/// never leak into logs, screenshots or exported reports.
public enum Redactor {
    /// Keep a short prefix and suffix so a user can tell two keys apart.
    public static func mask(_ secret: String, keepPrefix: Int = 5, keepSuffix: Int = 4) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "—" }
        if trimmed.count <= keepPrefix + keepSuffix + 3 {
            return String(repeating: "•", count: max(4, trimmed.count))
        }
        let prefix = trimmed.prefix(keepPrefix)
        let suffix = trimmed.suffix(keepSuffix)
        return "\(prefix)…\(suffix)"
    }

    /// Masks anything that looks like a credential in free text.
    public static func scrub(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(sk-[A-Za-z0-9_\-]{6,})"#, "sk-…"),
            (#"(sk-ant-[A-Za-z0-9_\-]{6,})"#, "sk-ant-…"),
            (#"(gho_[A-Za-z0-9]{10,})"#, "gho_…"),
            (#"(ghp_[A-Za-z0-9]{10,})"#, "ghp_…"),
            (#"(user_[A-Za-z0-9]{16,})"#, "user_…"),
            (#"(ms-[a-f0-9\-]{16,})"#, "ms-…"),
            (#"(AIza[0-9A-Za-z_\-]{20,})"#, "AIza…"),
            (#"("?(?:api[_-]?key|apikey|auth[_-]?token|access[_-]?token|secret|password|authorization)"?\s*[:=]\s*")([^"]{6,})"#, "$1•••\""),
            (#"(Bearer\s+)([A-Za-z0-9_\-\.]{12,})"#, "$1•••"),
            (#"(ya29\.[A-Za-z0-9_\-\.]{10,})"#, "ya29.…"),
            (#"(1//[A-Za-z0-9_\-\.]{10,})"#, "1//…"),
        ]
        for (pattern, replacement) in patterns {
            result = replace(pattern: pattern, in: result, with: replacement)
        }
        return result
    }

    /// Replaces known secrets verbatim, then applies the generic patterns.
    public static func scrub(_ text: String, knownSecrets: [String]) -> String {
        var result = text
        for secret in knownSecrets where secret.count >= 6 {
            result = result.replacingOccurrences(of: secret, with: mask(secret))
        }
        return scrub(result)
    }

    /// Header dictionary safe for display: auth-shaped headers are masked.
    public static func safeHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            let lowered = key.lowercased()
            if lowered == "authorization" || lowered == "x-api-key" || lowered.contains("token")
                || lowered.contains("secret") || lowered.contains("key") {
                result[key] = mask(value)
            } else {
                result[key] = scrub(value)
            }
        }
        return result
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
