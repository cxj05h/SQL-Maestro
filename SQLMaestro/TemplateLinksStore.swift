// TemplateLinksStore.swift
import Foundation
import SwiftUI

/// Store for per-template hyperlinks persistence.
final class TemplateLinksStore: ObservableObject {
    static let shared = TemplateLinksStore()
    private init() {}

    /// Working sets: templateId -> links
    @Published private var workingLinks: [UUID: [TemplateLink]] = [:]
    /// Dirty flags: templateId -> isDirty
    @Published private var dirty: [UUID: Bool] = [:]

    // MARK: - Working Set API

    func links(for template: TemplateItem?) -> [TemplateLink] {
        guard let t = template else { return [] }
        return workingLinks[t.id] ?? []
    }

    func setLinks(_ links: [TemplateLink], for template: TemplateItem?) {
        guard let t = template else { return }
        workingLinks[t.id] = links
        setDirty(true, for: t.id)
    }

    func addLink(title: String, url: String, for template: TemplateItem?) {
        guard let t = template else { return }
        var links = workingLinks[t.id] ?? []
        links.append(TemplateLink(title: title, url: url))
        workingLinks[t.id] = links
        setDirty(true, for: t.id)
    }

    func removeLink(withId id: UUID, for template: TemplateItem?) {
        guard let t = template else { return }
        var links = workingLinks[t.id] ?? []
        links.removeAll { $0.id == id }
        workingLinks[t.id] = links
        setDirty(true, for: t.id)
    }

    func isDirty(for template: TemplateItem?) -> Bool {
        guard let t = template else { return false }
        return dirty[t.id] ?? false
    }

    private func setDirty(_ val: Bool, for templateId: UUID) {
        dirty[templateId] = val
    }

    // MARK: - Sidecar Persistence

    /// Loads sidecar from disk into working set.
    @discardableResult
    func loadSidecar(for template: TemplateItem) -> [TemplateLink] {
        let url = template.url.templateLinksSidecarURL()
        if let data = try? Data(contentsOf: url),
           let model = try? JSONDecoder().decode(TemplateLinks.self, from: data) {
            if model.templateId != template.id {
                LOG("Links sidecar templateId mismatch", ctx: ["sidecar": url.lastPathComponent, "expected": template.id.uuidString, "found": model.templateId.uuidString])
            }
            let links = model.links
            workingLinks[template.id] = links
            setDirty(false, for: template.id)
            LOG("Template links loaded", ctx: ["template": template.name, "count": "\(links.count)"])
            return links
        } else {
            // No sidecar yet; start empty
            workingLinks[template.id] = []
            setDirty(false, for: template.id)
            LOG("Template links missing (initialized empty)", ctx: ["template": template.name])
            return []
        }
    }

    /// Saves the working set to the sidecar file.
    @discardableResult
    func saveSidecar(for template: TemplateItem) -> Bool {
        let url = template.url.templateLinksSidecarURL()
        let links = workingLinks[template.id] ?? []
        let model = TemplateLinks(templateId: template.id, links: links, updatedAt: Date())

        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(model)

            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)

            try data.write(to: url, options: .atomic)
            setDirty(false, for: template.id)
            LOG("Template links saved", ctx: ["file": url.lastPathComponent, "count": "\(links.count)"])
            return true
        } catch {
            LOG("Template links save failed", ctx: ["file": url.lastPathComponent, "error": error.localizedDescription])
            return false
        }
    }
}
