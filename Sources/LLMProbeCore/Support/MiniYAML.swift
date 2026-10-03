import Foundation

/// Parses the indentation-based YAML subset used by agent config files:
/// mappings, sequences, quoted/plain scalars and inline arrays/maps.
///
/// It deliberately does not implement anchors, aliases, multi-line scalars or
/// tags. Those constructs are ignored rather than guessed at.
public enum MiniYAML {
    private struct Line {
        var indent: Int
        var content: String
        var number: Int
    }

    public static func parse(_ text: String) -> [String: Any]? {
        parseDocument(text) as? [String: Any]
    }

    /// Parses either a YAML mapping or a top-level sequence. DeepSeek Harness
    /// profile patches use the sequence form.
    public static func parseDocument(_ text: String) -> Any? {
        let lines = preparedLines(text)
        guard !lines.isEmpty else { return [String: Any]() }
        var index = 0
        let indent = lines[0].indent
        if isSequenceLine(lines[index].content) {
            return parseSequence(lines, index: &index, indent: indent)
        }
        return parseMapping(lines, index: &index, indent: indent)
    }

    private static func preparedLines(_ text: String) -> [Line] {
        var result: [Line] = []
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let withoutComment = stripComment(raw)
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indent = withoutComment.prefix { $0 == " " }.count
            let content = String(withoutComment.dropFirst(indent)).trimmingCharacters(in: .whitespaces)
            guard content != "---", content != "...", !content.hasPrefix("%") else { continue }
            result.append(Line(indent: indent, content: content, number: offset + 1))
        }
        return result
    }

    private static func parseBlock(_ lines: [Line], index: inout Int, indent: Int) -> Any {
        guard index < lines.count else { return [String: Any]() }
        if isSequenceLine(lines[index].content) {
            return parseSequence(lines, index: &index, indent: indent)
        }
        return parseMapping(lines, index: &index, indent: indent)
    }

    private static func parseMapping(_ lines: [Line], index: inout Int, indent: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent { index += 1; continue }
            if isSequenceLine(line.content) { break }
            guard let colon = splitColon(line.content) else {
                index += 1
                continue
            }
            let key = unquote(String(line.content[line.content.startIndex..<colon]).trimmingCharacters(in: .whitespaces))
            let rawValue = String(line.content[line.content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            index += 1
            if !rawValue.isEmpty {
                result[key] = parseScalar(rawValue)
                continue
            }
            if index < lines.count, lines[index].indent > indent {
                result[key] = parseBlock(lines, index: &index, indent: lines[index].indent)
            } else if index < lines.count,
                      lines[index].indent == indent,
                      isSequenceLine(lines[index].content) {
                // YAML permits an indentless block sequence directly below a
                // mapping key; Hermes Agent uses this form.
                result[key] = parseSequence(lines, index: &index, indent: indent)
            } else {
                result[key] = [String: Any]()
            }
        }
        return result
    }

    private static func isSequenceLine(_ content: String) -> Bool {
        content.hasPrefix("- ") || content == "-"
    }

    private static func parseSequence(_ lines: [Line], index: inout Int, indent: Int) -> [Any] {
        var result: [Any] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent != indent || !(line.content.hasPrefix("- ") || line.content == "-") { break }
            let rest = line.content == "-" ? "" : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1

            if rest.isEmpty {
                if index < lines.count, lines[index].indent > indent {
                    result.append(parseBlock(lines, index: &index, indent: lines[index].indent))
                } else {
                    result.append("")
                }
                continue
            }
            if let colon = splitColon(rest) {
                var item: [String: Any] = [:]
                let firstKey = unquote(String(rest[rest.startIndex..<colon]).trimmingCharacters(in: .whitespaces))
                let firstValue = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if firstValue.isEmpty {
                    if index < lines.count, lines[index].indent > indent {
                        item[firstKey] = parseBlock(lines, index: &index, indent: lines[index].indent)
                    } else {
                        item[firstKey] = [String: Any]()
                    }
                } else {
                    item[firstKey] = parseScalar(firstValue)
                }
                if index < lines.count, lines[index].indent > indent, !lines[index].content.hasPrefix("- ") {
                    let continuationIndent = lines[index].indent
                    let continuation = parseMapping(lines, index: &index, indent: continuationIndent)
                    item.merge(continuation) { _, new in new }
                }
                result.append(item)
            } else {
                result.append(parseScalar(rest))
            }
        }
        return result
    }

    static func parseScalar(_ raw: String) -> Any {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") || value.hasPrefix("{") { return MiniTOML.parseValue(value) }
        if value.hasPrefix("\"") || value.hasPrefix("'") { return MiniTOML.parseValue(value) }
        switch value {
        case "true": return true
        case "false": return false
        case "null", "~": return NSNull()
        default: break
        }
        if let integer = Int(value) { return integer }
        if let double = Double(value) { return double }
        return value
    }

    private static func stripComment(_ raw: String) -> String {
        let characters = Array(raw)
        var inString = false
        var quote: Character?
        var escaped = false
        for (index, character) in characters.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    inString = false
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                inString = true
                quote = character
                continue
            }
            if character == "#", index == 0 || characters[index - 1].isWhitespace {
                return String(raw.prefix(index))
            }
        }
        return raw
    }

    private static func splitColon(_ text: String) -> String.Index? {
        let characters = Array(text)
        var depth = 0
        var inString = false
        var quote: Character?
        var escaped = false
        for (offset, character) in characters.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == quote {
                    inString = false
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                inString = true
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth -= 1
            } else if character == ":", depth == 0 {
                return text.index(text.startIndex, offsetBy: offset)
            }
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
              (value.hasPrefix("'") && value.hasSuffix("'")) else { return value }
        return String(value.dropFirst().dropLast())
    }
}
