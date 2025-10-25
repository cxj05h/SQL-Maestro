import SwiftUI
import MarkdownUI

// MARK: - Markdown Code Syntax Highlighter

struct MarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        guard let language = language?.lowercased(), !language.isEmpty else {
            // No language specified - return plain black text
            return Text(code)
        }

        switch language {
        case "yaml", "yml":
            return highlightYAML(code)
        case "json":
            return highlightJSON(code)
        case "sql", "mysql":
            return highlightSQL(code)
        default:
            // Unknown language - return plain black text
            return Text(code)
        }
    }

    // MARK: - YAML Highlighting

    private func highlightYAML(_ code: String) -> Text {
        let lines = code.components(separatedBy: .newlines)
        var result = Text("")

        for (index, line) in lines.enumerated() {
            let highlightedLine = highlightYAMLLine(line)
            result = result + highlightedLine

            if index < lines.count - 1 {
                result = result + Text("\n")
            }
        }

        return result
    }

    private func highlightYAMLLine(_ line: String) -> Text {
        // Check for comments first (they take precedence)
        if let commentRange = line.range(of: "#") {
            let beforeComment = String(line[..<commentRange.lowerBound])
            let comment = String(line[commentRange.lowerBound...])
            return highlightYAMLLineWithoutComment(beforeComment) + Text(comment).foregroundColor(Color(hex: "#808080"))
        }

        return highlightYAMLLineWithoutComment(line)
    }

    private func highlightYAMLLineWithoutComment(_ line: String) -> Text {
        var result = Text("")

        // Pattern: key followed by colon
        let keyPattern = try! NSRegularExpression(pattern: "^([ ]*)([a-zA-Z_][a-zA-Z0-9_-]*)(?=:)")

        // Pattern: quoted strings
        let stringPattern = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\'|[^'])*'")

        let nsLine = line as NSString
        let lineRange = NSRange(location: 0, length: nsLine.length)

        // Find all matches
        var matches: [(range: NSRange, type: String)] = []

        keyPattern.enumerateMatches(in: line, range: lineRange) { match, _, _ in
            if let match = match, let keyRange = Range(match.range(at: 2), in: line) {
                matches.append((NSRange(keyRange, in: line), "key"))
            }
        }

        stringPattern.enumerateMatches(in: line, range: lineRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "string"))
            }
        }

        // Sort matches by position
        matches.sort { $0.range.location < $1.range.location }

        // Build result with highlighted sections
        var lastPosition = 0
        for match in matches {
            // Add text before this match
            if match.range.location > lastPosition {
                let beforeRange = NSRange(location: lastPosition, length: match.range.location - lastPosition)
                let beforeText = nsLine.substring(with: beforeRange)

                // Check for numbers and booleans in the before text
                result = result + highlightYAMLPlainText(beforeText)
            }

            // Add the matched text with color
            let matchedText = nsLine.substring(with: match.range)
            switch match.type {
            case "key":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#6366F1")) // Indigo
            case "string":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#34D399")) // Emerald
            default:
                result = result + Text(matchedText)
            }

            lastPosition = match.range.location + match.range.length
        }

        // Add remaining text
        if lastPosition < nsLine.length {
            let remainingRange = NSRange(location: lastPosition, length: nsLine.length - lastPosition)
            let remainingText = nsLine.substring(with: remainingRange)
            result = result + highlightYAMLPlainText(remainingText)
        }

        return result
    }

    private func highlightYAMLPlainText(_ text: String) -> Text {
        let numberPattern = try! NSRegularExpression(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b")
        let boolPattern = try! NSRegularExpression(pattern: "\\b(?:true|false|yes|no|on|off|null|~)\\b")

        let nsText = text as NSString
        let textRange = NSRange(location: 0, length: nsText.length)

        var matches: [(range: NSRange, type: String)] = []

        numberPattern.enumerateMatches(in: text, range: textRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "number"))
            }
        }

        boolPattern.enumerateMatches(in: text, range: textRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "bool"))
            }
        }

        matches.sort { $0.range.location < $1.range.location }

        var result = Text("")
        var lastPosition = 0

        for match in matches {
            if match.range.location > lastPosition {
                let beforeRange = NSRange(location: lastPosition, length: match.range.location - lastPosition)
                result = result + Text(nsText.substring(with: beforeRange))
            }

            let matchedText = nsText.substring(with: match.range)
            switch match.type {
            case "number":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#FBBF24")) // Amber
            case "bool":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#EF44C0")) // Pink
            default:
                result = result + Text(matchedText)
            }

            lastPosition = match.range.location + match.range.length
        }

        if lastPosition < nsText.length {
            let remainingRange = NSRange(location: lastPosition, length: nsText.length - lastPosition)
            result = result + Text(nsText.substring(with: remainingRange))
        }

        return result
    }

    // MARK: - JSON Highlighting

    private func highlightJSON(_ code: String) -> Text {
        let nsCode = code as NSString
        let codeRange = NSRange(location: 0, length: nsCode.length)

        // Patterns
        let stringPattern = try! NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"")
        let numberPattern = try! NSRegularExpression(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b")
        let boolNullPattern = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b")

        // Find all matches
        var matches: [(range: NSRange, type: String)] = []

        stringPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                // Check if this string is a key (followed by colon)
                let afterRange = NSRange(location: match.range.location + match.range.length, length: min(10, nsCode.length - match.range.location - match.range.length))
                let afterText = nsCode.substring(with: afterRange)

                if afterText.trimmingCharacters(in: .whitespaces).hasPrefix(":") {
                    matches.append((match.range, "key"))
                } else {
                    matches.append((match.range, "string"))
                }
            }
        }

        numberPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                // Make sure it's not inside a string
                let isInsideString = matches.contains { $0.range.location <= match.range.location && match.range.location < $0.range.location + $0.range.length }
                if !isInsideString {
                    matches.append((match.range, "number"))
                }
            }
        }

        boolNullPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                // Make sure it's not inside a string
                let isInsideString = matches.contains { $0.range.location <= match.range.location && match.range.location < $0.range.location + $0.range.length }
                if !isInsideString {
                    matches.append((match.range, "bool"))
                }
            }
        }

        // Sort matches by position
        matches.sort { $0.range.location < $1.range.location }

        // Build result
        var result = Text("")
        var lastPosition = 0

        for match in matches {
            // Add text before this match
            if match.range.location > lastPosition {
                let beforeRange = NSRange(location: lastPosition, length: match.range.location - lastPosition)
                result = result + Text(nsCode.substring(with: beforeRange))
            }

            // Add the matched text with color
            let matchedText = nsCode.substring(with: match.range)
            switch match.type {
            case "key":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#6366F1")) // Indigo
            case "string":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#34D399")) // Emerald
            case "number":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#FBBF24")) // Amber
            case "bool":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#EF44C0")) // Pink
            default:
                result = result + Text(matchedText)
            }

            lastPosition = match.range.location + match.range.length
        }

        // Add remaining text
        if lastPosition < nsCode.length {
            let remainingRange = NSRange(location: lastPosition, length: nsCode.length - lastPosition)
            result = result + Text(nsCode.substring(with: remainingRange))
        }

        return result
    }

    // MARK: - SQL Highlighting

    private func highlightSQL(_ code: String) -> Text {
        let nsCode = code as NSString
        let codeRange = NSRange(location: 0, length: nsCode.length)

        // SQL Keywords
        let keywords = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN",
            "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "DATABASE",
            "INDEX", "VIEW", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "ON", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET", "UNION", "ALL",
            "DISTINCT", "INTO", "VALUES", "SET", "CASE", "WHEN", "THEN", "ELSE", "END",
            "NULL", "IS", "LIKE", "DESC", "ASC", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
            "CONSTRAINT", "DEFAULT", "AUTO_INCREMENT", "UNIQUE", "CHECK"
        ]

        // SQL Functions
        let functions = [
            "COUNT", "SUM", "AVG", "MAX", "MIN", "ROUND", "CONCAT", "SUBSTRING",
            "UPPER", "LOWER", "TRIM", "LENGTH", "COALESCE", "IFNULL", "NOW", "CURDATE",
            "CURTIME", "DATE", "TIME", "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND"
        ]

        // Patterns
        let stringPattern = try! NSRegularExpression(pattern: "'(?:\\\\'|[^'])*'")
        let backtickPattern = try! NSRegularExpression(pattern: "`[^`]+`")
        let numberPattern = try! NSRegularExpression(pattern: "\\b-?(?:0|[1-9]\\d*)(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b")
        let commentPattern = try! NSRegularExpression(pattern: "--[^\\n]*|/\\*[\\s\\S]*?\\*/")
        let boolPattern = try! NSRegularExpression(pattern: "\\b(?:TRUE|FALSE|NULL)\\b", options: .caseInsensitive)

        // Build keyword and function patterns
        let keywordPattern = try! NSRegularExpression(pattern: "\\b(" + keywords.joined(separator: "|") + ")\\b", options: .caseInsensitive)
        let functionPattern = try! NSRegularExpression(pattern: "\\b(" + functions.joined(separator: "|") + ")\\b", options: .caseInsensitive)

        // Find all matches
        var matches: [(range: NSRange, type: String)] = []

        // Comments first (highest priority)
        commentPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "comment"))
            }
        }

        // Strings
        stringPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "string"))
            }
        }

        // Backtick identifiers (table/column names)
        backtickPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "backtick"))
            }
        }

        // Keywords
        keywordPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "keyword"))
            }
        }

        // Functions
        functionPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "function"))
            }
        }

        // Booleans/NULL
        boolPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "bool"))
            }
        }

        // Numbers
        numberPattern.enumerateMatches(in: code, range: codeRange) { match, _, _ in
            if let match = match {
                matches.append((match.range, "number"))
            }
        }

        // Sort and remove overlapping matches (comments and strings take precedence)
        matches.sort { $0.range.location < $1.range.location }
        var filteredMatches: [(range: NSRange, type: String)] = []

        for match in matches {
            let overlaps = filteredMatches.contains { existing in
                // Check if match overlaps with existing
                let existingEnd = existing.range.location + existing.range.length
                let matchEnd = match.range.location + match.range.length

                return !(matchEnd <= existing.range.location || match.range.location >= existingEnd)
            }

            if !overlaps {
                filteredMatches.append(match)
            }
        }

        // Sort again by position
        filteredMatches.sort { $0.range.location < $1.range.location }

        // Build result
        var result = Text("")
        var lastPosition = 0

        for match in filteredMatches {
            // Add text before this match
            if match.range.location > lastPosition {
                let beforeRange = NSRange(location: lastPosition, length: match.range.location - lastPosition)
                result = result + Text(nsCode.substring(with: beforeRange))
            }

            // Add the matched text with color
            let matchedText = nsCode.substring(with: match.range)
            switch match.type {
            case "keyword":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#6366F1")) // Indigo
            case "string":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#34D399")) // Emerald
            case "number":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#FBBF24")) // Gold
            case "bool":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#EF44C0")) // Pink
            case "function":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#EF44C0")) // Pink
            case "backtick":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#EF44C0")) // Pink
            case "comment":
                result = result + Text(matchedText).foregroundColor(Color(hex: "#808080")) // Gray
            default:
                result = result + Text(matchedText)
            }

            lastPosition = match.range.location + match.range.length
        }

        // Add remaining text
        if lastPosition < nsCode.length {
            let remainingRange = NSRange(location: lastPosition, length: nsCode.length - lastPosition)
            result = result + Text(nsCode.substring(with: remainingRange))
        }

        return result
    }
}
