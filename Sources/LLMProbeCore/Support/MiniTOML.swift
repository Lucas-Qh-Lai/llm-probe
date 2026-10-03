import Foundation

/// A small TOML reader for the subset used by agent configuration files:
/// tables, dotted keys, strings, numbers, booleans, arrays and inline tables.
///
/// It exists so the app can read `~/.codex/config.toml` without pulling a
/// dependency into a tool whose whole point is to stay auditable and local.
public enum MiniTOML {
    public static func parse(_ text: String) -> [String: Any] {
        var root: [String: Any] = [:]
        var currentPath: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let path = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                currentPath = splitPath(path)
                // Array-of-tables: keep a list so repeated blocks accumulate.
                appendTable(at: currentPath, root: &root)
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let path = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentPath = splitPath(path)
                ensureTable(at: currentPath, in: &root)
                continue
            }
            guard let equals = indexOfTopLevelEquals(line) else { continue }
            let keyPart = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let valuePart = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !keyPart.isEmpty else { continue }
            let keyPath = currentPath + splitPath(keyPart, allowDots: true)
            let value = parseValue(valuePart)
            set(value, at: keyPath, in: &root)
        }
        return root
    }

    // MARK: - Value parsing

    static func parseValue(_ raw: String) -> Any {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("\"\"\"") { return String(value.dropFirst(3).dropLast(3)) }
        if value.hasPrefix("\"") { return parseBasicString(value) }
        if value.hasPrefix("'") { return parseLiteralString(value) }
        if value.hasPrefix("[") { return parseArray(value) }
        if value.hasPrefix("{") { return parseInlineTable(value) }
        if value == "true" { return true }
        if value == "false" { return false }
        if let intValue = Int(value) { return intValue }
        if let doubleValue = Double(value) { return doubleValue }
        return value
    }

    private static func parseBasicString(_ value: String) -> String {
        var result = ""
        var iterator = value.dropFirst().makeIterator()
        var escaped = false
        while let character = iterator.next() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { break }
            result.append(character)
        }
        return result
    }

    private static func parseLiteralString(_ value: String) -> String {
        var result = ""
        var seenOpening = false
        for character in value {
            if !seenOpening {
                seenOpening = true
                continue
            }
            if character == "'" { break }
            result.append(character)
        }
        return result
    }

    private static func parseArray(_ value: String) -> [Any] {
        let inner = String(value.dropFirst().dropLast())
        return splitTopLevel(inner, separator: ",").map { parseValue($0) }
    }

    private static func parseInlineTable(_ value: String) -> [String: Any] {
        let inner = String(value.dropFirst().dropLast())
        var table: [String: Any] = [:]
        for pair in splitTopLevel(inner, separator: ",") {
            guard let equals = indexOfTopLevelEquals(pair) else { continue }
            let key = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            table[key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))] = parseValue(rawValue)
        }
        return table
    }

    // MARK: - Helpers

    static func stripComment(_ line: String) -> String {
        var inBasic = false
        var inLiteral = false
        var escaped = false
        var result = ""
        for character in line {
            if escaped { result.append(character); escaped = false; continue }
            if character == "\\" && inBasic { result.append(character); escaped = true; continue }
            if character == "\"" && !inLiteral { inBasic.toggle(); result.append(character); continue }
            if character == "'" && !inBasic { inLiteral.toggle(); result.append(character); continue }
            if character == "#" && !inBasic && !inLiteral { break }
            result.append(character)
        }
        return result
    }

    static func indexOfTopLevelEquals(_ line: String) -> String.Index? {
        var inBasic = false
        var inLiteral = false
        var depth = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" && !inLiteral { inBasic.toggle() }
            else if character == "'" && !inBasic { inLiteral.toggle() }
            else if !inBasic && !inLiteral {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == "=" && depth == 0 { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inBasic = false
        var inLiteral = false
        var depth = 0
        for character in text {
            if character == "\"" && !inLiteral { inBasic.toggle() }
            else if character == "'" && !inBasic { inLiteral.toggle() }
            else if !inBasic && !inLiteral {
                if character == "[" || character == "{" { depth += 1 }
                if character == "]" || character == "}" { depth -= 1 }
                if character == separator && depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func splitPath(_ path: String, allowDots: Bool = true) -> [String] {
        guard allowDots else { return [path] }
        return splitTopLevel(path, separator: ".").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }.filter { !$0.isEmpty }
    }

    // MARK: - Mutation

    static func ensureTable(at path: [String], in root: inout [String: Any]) {
        guard !path.isEmpty else { return }
        setTable(path: path, root: &root)
    }

    private static func setTable(path: [String], root: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            if root[first] as? [String: Any] == nil { root[first] = [String: Any]() }
            return
        }
        var child = (root[first] as? [String: Any]) ?? [String: Any]()
        setTable(path: Array(path.dropFirst()), root: &child)
        root[first] = child
    }

    private static func appendTable(at path: [String], root: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            var list = (root[first] as? [[String: Any]]) ?? []
            list.append([String: Any]())
            root[first] = list
            return
        }
        var child = (root[first] as? [String: Any]) ?? [String: Any]()
        appendTable(at: Array(path.dropFirst()), root: &child)
        root[first] = child
    }

    static func set(_ value: Any, at path: [String], in root: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 {
            root[first] = value
            return
        }
        var child = (root[first] as? [String: Any]) ?? [String: Any]()
        set(value, at: Array(path.dropFirst()), in: &child)
        root[first] = child
    }
}

// MARK: - Typed lookups

public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        switch self[key] {
        case let value as String: return value
        case let value as Int: return "\(value)"
        case let value as Double: return "\(value)"
        case let value as Bool: return value ? "true" : "false"
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        switch self[key] {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as String: return Int(value)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let value as Bool: return value
        case let value as String: return ["true", "1", "yes"].contains(value.lowercased())
        case let value as Int: return value != 0
        default: return nil
        }
    }

    func table(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func stringMap(_ key: String) -> [String: String] {
        guard let raw = self[key] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String { result[key] = text }
        }
        return result
    }
}
