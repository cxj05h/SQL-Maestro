// DBTablesModels.swift
import Foundation

/// Sidecar payload for per-template DB tables association.
/// Stored next to the template file as "<templateBase>.tables.json".
struct TemplateTables: Codable {
    /// UUID to link the sidecar back to the logical template.
    /// NOTE: At first save, we will populate this from the current TemplateItem.id
    /// (later steps may introduce a persistent ID if needed).
    var templateId: UUID
    /// Flat list of base table names (no "spotinst_<org-id>." prefix).
    var tables: [String]
    /// ISO8601 timestamp of last update, mainly for troubleshooting.
    var updatedAt: String

    init(templateId: UUID, tables: [String], updatedAt: Date = Date()) {
        self.templateId = templateId
        self.tables = tables
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.updatedAt = iso.string(from: updatedAt)
    }
}

extension URL {
    /// Returns the expected sidecar URL for a given template file URL.
    /// Example: ".../templates/MyQuery.sql" -> ".../templates/MyQuery.tables.json"
    func templateTablesSidecarURL() -> URL {
        let base = self.deletingPathExtension().lastPathComponent
        let dir = self.deletingLastPathComponent()
        return dir.appendingPathComponent("\(base).tables.json")
    }
}
