import Foundation

/// Reads a supported local configuration file without mutating it.
public enum ConfigDecoding {
    public static func dictionary(at path: String) -> [String: Any]? {
        guard let text = PathTools.readText(path) else { return nil }
        return dictionary(text: text, path: path)
    }

    static func dictionary(text: String, path: String) -> [String: Any]? {
        let lower = path.lowercased()
        if lower.hasSuffix(".toml") { return MiniTOML.parse(text) }
        if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") {
            guard let value = MiniYAML.parseDocument(text) else { return nil }
            if let dictionary = value as? [String: Any] { return dictionary }
            if let sequence = value as? [Any] { return ["items": sequence] }
            return nil
        }
        return MiniJSONC.parse(text)
    }
}
