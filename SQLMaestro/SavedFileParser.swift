import Foundation
import Yams

enum SavedFileValidationResult: Equatable {
    case valid(SavedFileFormat)
    case invalid(String)

    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }

    var format: SavedFileFormat? {
        if case .valid(let fmt) = self {
            return fmt
        }
        return nil
    }

    var errorMessage: String? {
        if case .invalid(let msg) = self {
            return msg
        }
        return nil
    }
}

struct SavedFileParser {

    /// Validates content and detects format (JSON or YAML)
    static func validate(_ content: String) -> SavedFileValidationResult {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .invalid("Content is empty")
        }

        // Try JSON first
        if let jsonResult = tryParseJSON(trimmed) {
            return jsonResult
        }

        // Try YAML
        if let yamlResult = tryParseYAML(trimmed) {
            return yamlResult
        }

        return .invalid("Content is neither valid JSON nor valid YAML")
    }

    /// Validates content against a specific format
    static func validate(_ content: String, as format: SavedFileFormat) -> SavedFileValidationResult {
        print("🚀 SavedFileParser.validate called")
        print("📋 Format: \(format.rawValue)")
        print("📏 Content length: \(content.count)")

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            print("⚠️ Content is empty after trimming")
            return .invalid("Content is empty")
        }

        print("✂️ Trimmed length: \(trimmed.count)")

        switch format {
        case .json:
            print("➡️ Validating as JSON")
            return tryParseJSONWithError(trimmed)
        case .yaml:
            print("➡️ Validating as YAML")
            return tryParseYAMLWithError(trimmed)
        }
    }

    /// Converts JSON or YAML content to a native Swift object for tree visualization
    static func parseToObject(_ content: String, format: SavedFileFormat) -> Any? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch format {
        case .json:
            return parseJSONToObject(trimmed)
        case .yaml:
            return parseYAMLToObject(trimmed)
        }
    }

    // MARK: - Private Helpers

    private static func tryParseJSON(_ text: String) -> SavedFileValidationResult? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .valid(.json)
        } catch {
            // If it fails, it's not valid JSON, return nil to try YAML
            return nil
        }
    }

    private static func tryParseYAML(_ text: String) -> SavedFileValidationResult? {
        do {
            // Yams.load can return nil for empty documents, which is still valid YAML
            _ = try Yams.load(yaml: text)
            // If we get here without throwing, it's valid YAML
            return .valid(.yaml)
        } catch {
            // Only return nil if there's a parsing error (to try next format)
            return nil
        }
    }

    private static func tryParseJSONWithError(_ text: String) -> SavedFileValidationResult {
        guard let data = text.data(using: .utf8) else {
            return .invalid("Unable to encode text as UTF-8")
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return .valid(.json)
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    private static func tryParseYAMLWithError(_ text: String) -> SavedFileValidationResult {
        // Debug: Print what we're trying to parse
        print("🔍 YAML Validation Debug:")
        print("📝 Content length: \(text.count)")
        print("📝 Content preview: \(text.prefix(100))")

        do {
            // Try to parse the YAML
            let result = try Yams.load(yaml: text)
            print("✅ YAML parsed successfully")
            print("📦 Result type: \(type(of: result))")
            if let dict = result as? [String: Any] {
                print("📦 Dict keys: \(dict.keys)")
            }
            // If we get here without throwing, it's valid YAML
            return .valid(.yaml)
        } catch {
            // Return detailed error description
            print("❌ YAML parsing failed")
            print("❌ Error: \(error)")
            print("❌ Error type: \(type(of: error))")
            return .invalid("\(error)")
        }
    }

    private static func parseJSONToObject(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func parseYAMLToObject(_ text: String) -> Any? {
        return try? Yams.load(yaml: text)
    }
}
