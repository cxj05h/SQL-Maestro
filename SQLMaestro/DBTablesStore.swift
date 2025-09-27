// DBTablesStore.swift
import Foundation
import SwiftUI

/// Store for per-session working sets and per-template sidecar persistence.
final class DBTablesStore: ObservableObject {
    static let shared = DBTablesStore()
    private init() {}

    /// Working sets: session → (templateId → tables)
    @Published private var working: [TicketSession: [UUID: [String]]] = [:]
    /// Dirty flags: session → (templateId → isDirty)
    @Published private var dirty:   [TicketSession: [UUID: Bool]] = [:]

    // MARK: - Working Set API

    func workingSet(for session: TicketSession, template: TemplateItem?) -> [String] {
        guard let t = template else { return [] }
        return working[session]?[t.id] ?? []
    }

    func setWorkingSet(_ tables: [String],
                       for session: TicketSession,
                       template: TemplateItem?,
                       markDirty: Bool = true) {
        guard let t = template else { return }
        var s = working[session] ?? [:]
        // Keep raw list (allow blank rows while editing)
        s[t.id] = tables
        working[session] = s
        setDirty(markDirty, for: session, templateId: t.id)
    }

    func isDirty(for session: TicketSession, template: TemplateItem?) -> Bool {
        guard let t = template else { return false }
        return dirty[session]?[t.id] ?? false
    }

    private func setDirty(_ val: Bool, for session: TicketSession, templateId: UUID) {
        var s = dirty[session] ?? [:]
        s[templateId] = val
        dirty[session] = s
    }

    // MARK: - Sidecar Persistence

    /// Loads sidecar from disk into the current session's working set.
    /// If no sidecar exists, initializes empty working set.
    @discardableResult
    func loadSidecar(for session: TicketSession, template: TemplateItem) -> [String] {
        let url = template.url.templateTablesSidecarURL()
        if let data = try? Data(contentsOf: url),
           let model = try? JSONDecoder().decode(TemplateTables.self, from: data) {
            if model.templateId != template.id {
                LOG("Sidecar templateId mismatch", ctx: ["sidecar": url.lastPathComponent, "expected": template.id.uuidString, "found": model.templateId.uuidString])
            }
            let tables = normalized(model.tables)
            var s = working[session] ?? [:]
            s[template.id] = tables
            working[session] = s
            setDirty(false, for: session, templateId: template.id)
            LOG("Sidecar loaded", ctx: ["template": template.name, "count": "\(tables.count)"])
            return tables
        } else {
            // No sidecar yet; start empty
            var s = working[session] ?? [:]
            s[template.id] = []
            working[session] = s
            setDirty(false, for: session, templateId: template.id)
            LOG("Sidecar missing (initialized empty)", ctx: ["template": template.name])
            return []
        }
    }

    /// Saves the working set for the given session/template to the sidecar file.
    @discardableResult
    func saveSidecar(for session: TicketSession, template: TemplateItem) -> Bool {
        let url = template.url.templateTablesSidecarURL()
        // Clean up: trim, validate, de-dup, DROP empties before saving
        let cleaned = normalized(workingSet(for: session, template: template))
        let model = TemplateTables(templateId: template.id, tables: cleaned, updatedAt: Date())
        
        // Reflect cleaned list back into the working set so UI drops blank/dupe rows
        var s = working[session] ?? [:]
        s[template.id] = cleaned
        working[session] = s

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(model)

            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            try data.write(to: url, options: .atomic)
            setDirty(false, for: session, templateId: template.id)
            LOG("Sidecar saved", ctx: ["file": url.lastPathComponent, "count": "\(cleaned.count)"])
            return true
        } catch {
            LOG("Sidecar save failed", ctx: ["file": url.lastPathComponent, "error": error.localizedDescription])
            return false
        }
    }

    func handleTemplateRenamed(from oldURL: URL, to newURL: URL) {
        let fm = FileManager.default
        let oldSidecar = oldURL.templateTablesSidecarURL()
        let newSidecar = newURL.templateTablesSidecarURL()

        guard fm.fileExists(atPath: oldSidecar.path) else { return }

        do {
            try? fm.createDirectory(at: newSidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: newSidecar.path) {
                try fm.removeItem(at: newSidecar)
            }
            try fm.moveItem(at: oldSidecar, to: newSidecar)
            LOG("Template tables sidecar renamed", ctx: ["from": oldSidecar.lastPathComponent, "to": newSidecar.lastPathComponent])
        } catch {
            LOG("Template tables sidecar rename failed", ctx: [
                "from": oldSidecar.lastPathComponent,
                "to": newSidecar.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Utilities

    /// Trim, lowercase for comparison, remove duplicates, and validate charset.
    private func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>() // case-insensitive uniqueness
        var out: [String] = []
        for t in raw {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard isValidTableName(trimmed) else {
                LOG("Invalid table name skipped", ctx: ["value": trimmed])
                continue
            }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                out.append(trimmed)
                seen.insert(key)
            }
        }
        return out
    }

    /// Only alphanumerics + underscores are allowed (no spaces).
    private func isValidTableName(_ s: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
