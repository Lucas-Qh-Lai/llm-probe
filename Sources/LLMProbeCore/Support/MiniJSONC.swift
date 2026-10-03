import Foundation

/// Parses the JSON/JSONC subset used by agent configuration files.
///
/// JSONC support is intentionally narrow: line/block comments and trailing
/// commas are removed outside string literals, then Foundation parses JSON.
/// No values are interpreted or executed.
public enum MiniJSONC {
    public static func parse(_ text: String) -> [String: Any]? {
        guard let data = strippingCommentsAndTrailingCommas(text).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    static func strippingCommentsAndTrailingCommas(_ text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    output.append(character)
                }
                index += 1
                continue
            }
            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 2
                } else {
                    if character == "\n" { output.append(character) }
                    index += 1
                }
                continue
            }
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
                continue
            }
            if character == "/", next == "/" {
                inLineComment = true
                index += 2
                continue
            }
            if character == "/", next == "*" {
                inBlockComment = true
                index += 2
                continue
            }
            if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, " \t\r\n".contains(characters[lookahead]) {
                    lookahead += 1
                }
                let significant = lookahead < characters.count ? characters[lookahead] : "}"
                if significant == "}" || significant == "]" {
                    index += 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }
}
