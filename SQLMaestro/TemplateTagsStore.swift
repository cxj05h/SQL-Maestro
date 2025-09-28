import Foundation
import SwiftUI

/// Persisted tag metadata for query templates.
struct TemplateTags: Codable {
    var templateId: UUID
    var tags: [String]
    var updatedAt: String

    init(templateId: UUID, tags: [String], updatedAt: Date = Date()) {
        self.templateId = templateId
        self.tags = tags
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.updatedAt = iso.string(from: updatedAt)
    }
}

/// Centralized store for managing template tag sidecars and in-memory working sets.
final class TemplateTagsStore: ObservableObject {
    static let shared = TemplateTagsStore()
    private init() {}

    /// Working set of tags keyed by template identifier.
    @Published private var workingTags: [UUID: [String]] = [:]
    /// Dirty flags for sidecar persistence.
    private var dirty: Set<UUID> = []
    /// Tracks which templates have been hydrated from disk.
    private var loadedTemplates: Set<UUID> = []

    // MARK: - Public API

    func tags(for template: TemplateItem?) -> [String] {
        guard let template = template else { return [] }
        if let cached = workingTags[template.id] {
            return cached
        }
        return loadSidecar(for: template)
    }

    func setTags(_ tags: [String], for template: TemplateItem) {
        let normalized = normalize(tags: tags)
        workingTags[template.id] = normalized
        dirty.insert(template.id)
    }

    func addTags(_ tags: [String], to template: TemplateItem) {
        var existing = self.tags(for: template)
        existing.append(contentsOf: tags)
        setTags(existing, for: template)
    }

    func removeTag(_ tag: String, from template: TemplateItem) {
        var existing = self.tags(for: template)
        existing.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        setTags(existing, for: template)
    }

    func isDirty(for template: TemplateItem) -> Bool {
        dirty.contains(template.id)
    }

    /// Loads the sidecar from disk, caching the result.
    @discardableResult
    func loadSidecar(for template: TemplateItem) -> [String] {
        let sidecarURL = template.url.templateTagsSidecarURL()
        defer { loadedTemplates.insert(template.id) }

        guard let data = try? Data(contentsOf: sidecarURL) else {
            workingTags[template.id] = []
            dirty.remove(template.id)
            LOG("Template tags missing (initialized empty)", ctx: ["template": template.name])
            return []
        }

        do {
            let decoder = JSONDecoder()
            let model = try decoder.decode(TemplateTags.self, from: data)
            if model.templateId != template.id {
                LOG("Tags sidecar templateId mismatch", ctx: ["expected": template.id.uuidString, "found": model.templateId.uuidString, "file": sidecarURL.lastPathComponent])
            }
            let normalized = normalize(tags: model.tags)
            workingTags[template.id] = normalized
            dirty.remove(template.id)
            LOG("Template tags loaded", ctx: ["template": template.name, "count": "\(normalized.count)"])
            return normalized
        } catch {
            workingTags[template.id] = []
            dirty.remove(template.id)
            LOG("Template tags load failed", ctx: ["template": template.name, "error": error.localizedDescription])
            return []
        }
    }

    /// Persists the current working set to the template's sidecar file.
    @discardableResult
    func saveSidecar(for template: TemplateItem) -> Bool {
        let tags = normalize(tags: workingTags[template.id] ?? [])
        let model = TemplateTags(templateId: template.id, tags: tags, updatedAt: Date())
        let url = template.url.templateTagsSidecarURL()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(model)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            workingTags[template.id] = tags
            dirty.remove(template.id)
            LOG("Template tags saved", ctx: ["template": template.name, "count": "\(tags.count)"])
            return true
        } catch {
            LOG("Template tags save failed", ctx: ["template": template.name, "error": error.localizedDescription])
            return false
        }
    }

    func handleTemplateRenamed(from oldURL: URL, to newURL: URL) {
        let fm = FileManager.default
        let oldSidecar = oldURL.templateTagsSidecarURL()
        let newSidecar = newURL.templateTagsSidecarURL()

        guard fm.fileExists(atPath: oldSidecar.path) else { return }

        do {
            try? fm.createDirectory(at: newSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: newSidecar.path) {
                try fm.removeItem(at: newSidecar)
            }
            try fm.moveItem(at: oldSidecar, to: newSidecar)
            LOG("Template tags sidecar renamed", ctx: ["from": oldSidecar.lastPathComponent, "to": newSidecar.lastPathComponent])
        } catch {
            LOG("Template tags sidecar rename failed", ctx: [
                "from": oldSidecar.lastPathComponent,
                "to": newSidecar.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    func removeSidecar(for template: TemplateItem) {
        let url = template.url.templateTagsSidecarURL()
        try? FileManager.default.removeItem(at: url)
        workingTags.removeValue(forKey: template.id)
        dirty.remove(template.id)
        loadedTemplates.remove(template.id)
        LOG("Template tags sidecar removed", ctx: ["template": template.name])
    }

    func templateIds(matchingTag query: String) -> Set<UUID> {
        let normalizedQuery = normalize(tag: query) ?? ""
        guard !normalizedQuery.isEmpty else { return [] }

        var matches: Set<UUID> = []
        for (templateId, tags) in workingTags {
            if tags.contains(where: { $0 == normalizedQuery }) {
                matches.insert(templateId)
            }
        }
        return matches
    }

    func ensureLoaded(_ template: TemplateItem) {
        if !loadedTemplates.contains(template.id) {
            _ = loadSidecar(for: template)
        }
    }

    // MARK: - Helpers

    private func normalize(tag raw: String) -> String? {
        TemplateTagsStore.sanitize(raw)
    }

    private func normalize(tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            guard let normalized = TemplateTagsStore.sanitize(raw) else { continue }
            if !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(normalized)
            }
        }
        return result
    }

    static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        // Collapse whitespace to hyphens and replace delimiter punctuation
        text = text.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: "[,;]+", with: "-", options: .regularExpression)
        text = text.lowercased()
        // Allow only letters, numbers, hyphen, and underscore by normalizing the rest
        text = text.replacingOccurrences(of: "[^a-z0-9-_]", with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return text.isEmpty ? nil : text
    }
}
