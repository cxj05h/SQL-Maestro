import Foundation
import AppKit

struct TemplateGuideImage: Identifiable, Codable, Equatable {
    var id: UUID
    var fileName: String
    var savedAt: Date
    var customName: String?
    
    init(id: UUID = UUID(), fileName: String, savedAt: Date = Date(), customName: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.savedAt = savedAt
        self.customName = customName
    }
    
    var displayName: String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let number = fileName.components(separatedBy: "_").last?
            .components(separatedBy: ".").first ?? fileName
        return "Image \(number)"
    }
}

private struct TemplateGuideImagesManifest: Codable {
    var templateId: UUID
    var images: [TemplateGuideImage]
    var updatedAt: String
}

private struct TemplateGuideNotesModel: Codable {
    var templateId: UUID
    var text: String
    var updatedAt: String
}

@MainActor
final class TemplateGuideStore: ObservableObject {
    static let shared = TemplateGuideStore()
    private init() {}
    
    @Published private var imageCache: [String: [TemplateGuideImage]] = [:]
    @Published private var notesCache: [String: GuideNotesState] = [:]
    
    private struct GuideNotesState {
        var text: String
        var dirty: Bool
    }
    
    // MARK: - Public API
    func prepare(for template: TemplateItem) {
        loadImagesIfNeeded(for: template)
        loadNotesIfNeeded(for: template)
    }
    
    func images(for template: TemplateItem?) -> [TemplateGuideImage] {
        guard let template else { return [] }
        return imageCache[key(for: template)] ?? []
    }
    
    func addImage(data: Data, suggestedName: String? = nil, for template: TemplateItem) -> TemplateGuideImage? {
        ensureFolder(for: template)
        let key = key(for: template)
        var images = imageCache[key] ?? []
        let sequence = images.count + 1
        let base = template.url.deletingPathExtension().lastPathComponent
        let number = String(format: "%03d", sequence)
        let fileName = "\(base)_guide_\(number).png"
        let url = imageURL(fileName: fileName, for: template)
        do {
            try data.write(to: url, options: .atomic)
            let image = TemplateGuideImage(fileName: fileName, savedAt: Date(), customName: suggestedName)
            images.append(image)
            imageCache[key] = images
            persistImages(for: template, images: images)
            return image
        } catch {
            LOG("Template guide image save failed", ctx: ["template": template.name, "error": error.localizedDescription])
            return nil
        }
    }

    @discardableResult
    func deleteImage(_ image: TemplateGuideImage, for template: TemplateItem) -> Bool {
        let key = key(for: template)
        var images = imageCache[key] ?? []
        guard let idx = images.firstIndex(where: { $0.id == image.id }) else { return false }
        let url = imageURL(fileName: image.fileName, for: template)
        try? FileManager.default.removeItem(at: url)
        images.remove(at: idx)
        imageCache[key] = images
        persistImages(for: template, images: images)
        return true
    }

    @discardableResult
    func renameImage(_ image: TemplateGuideImage, to newName: String, for template: TemplateItem) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = key(for: template)
        guard var images = imageCache[key],
              let idx = images.firstIndex(where: { $0.id == image.id }) else { return false }
        images[idx].customName = trimmed
        imageCache[key] = images
        persistImages(for: template, images: images)
        return true
    }
    
    func setImageCustomName(fileName: String, to newName: String?, for template: TemplateItem) {
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if let trimmed, !trimmed.isEmpty {
            normalized = trimmed
        } else {
            normalized = nil
        }

        let key = key(for: template)
        guard var images = imageCache[key],
              let index = images.firstIndex(where: { $0.fileName == fileName }) else { return }

        if images[index].customName == normalized { return }

        images[index].customName = normalized
        imageCache[key] = images
        persistImages(for: template, images: images)
        LOG("Template guide image name synced from notes", ctx: [
            "template": template.name,
            "fileName": fileName,
            "newName": normalized ?? "(default)"
        ])
    }

    func imageURL(for image: TemplateGuideImage, template: TemplateItem) -> URL {
        imageURL(fileName: image.fileName, for: template)
    }
    
    // Notes
    func currentNotes(for template: TemplateItem?) -> String {
        guard let template else { return "" }
        return notesCache[key(for: template)]?.text ?? ""
    }
    
    @discardableResult
    func setNotes(_ text: String, for template: TemplateItem) -> Bool {
        let key = key(for: template)
        var changed = false
        if var state = notesCache[key] {
            if state.text != text {
                state.text = text
                state.dirty = true
                notesCache[key] = state
                changed = true
            }
        } else {
            notesCache[key] = GuideNotesState(text: text, dirty: true)
            changed = true
        }
        return changed
    }
    
    func isNotesDirty(for template: TemplateItem?) -> Bool {
        guard let template else { return false }
        return notesCache[key(for: template)]?.dirty ?? false
    }
    
    func saveNotes(for template: TemplateItem) -> Bool {
        ensureFolder(for: template)
        let key = key(for: template)
        let text = notesCache[key]?.text ?? ""
        let model = TemplateGuideNotesModel(templateId: template.id, text: text, updatedAt: isoFormatter.string(from: Date()))
        let url = notesURL(for: template)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(model)
            try data.write(to: url, options: .atomic)
            notesCache[key] = GuideNotesState(text: text, dirty: false)
            LOG("Template guide notes saved", ctx: ["template": template.name])
            return true
        } catch {
            LOG("Template guide notes save failed", ctx: ["template": template.name, "error": error.localizedDescription])
            return false
        }
    }
    
    func revertNotes(for template: TemplateItem) -> String {
        loadNotes(forceReload: true, for: template)
        return currentNotes(for: template)
    }
    
    func handleTemplateRenamed(from oldURL: URL, to newURL: URL) {
        let fm = FileManager.default
        let oldFolder = folderURL(for: oldURL)
        let newFolder = folderURL(for: newURL)
        if fm.fileExists(atPath: oldFolder.path) {
            do {
                if fm.fileExists(atPath: newFolder.path) {
                    try fm.removeItem(at: newFolder)
                }
                try fm.moveItem(at: oldFolder, to: newFolder)
            } catch {
                LOG("Template guide folder rename failed", ctx: ["from": oldFolder.lastPathComponent, "to": newFolder.lastPathComponent, "error": error.localizedDescription])
            }
        }
        let oldKey = key(for: oldURL)
        let newKey = key(for: newURL)
        if let images = imageCache.removeValue(forKey: oldKey) {
            imageCache[newKey] = images
        }
        if let notes = notesCache.removeValue(forKey: oldKey) {
            notesCache[newKey] = notes
        }
    }
    
    // MARK: - Private helpers
    private func key(for template: TemplateItem) -> String {
        key(for: template.url)
    }
    
    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }
    
    private func loadImagesIfNeeded(for template: TemplateItem) {
        let key = key(for: template)
        guard imageCache[key] == nil else { return }
        loadImages(forceReload: true, for: template)
    }
    
    private func loadImages(forceReload: Bool, for template: TemplateItem) {
        let key = key(for: template)
        if !forceReload, imageCache[key] != nil { return }
        ensureFolder(for: template)
        let manifestURL = imagesManifestURL(for: template)
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? decoder.decode(TemplateGuideImagesManifest.self, from: data) {
            imageCache[key] = manifest.images
        } else {
            imageCache[key] = []
        }
    }
    
    private func loadNotesIfNeeded(for template: TemplateItem) {
        let key = key(for: template)
        guard notesCache[key] == nil else { return }
        loadNotes(forceReload: true, for: template)
    }
    
    private func loadNotes(forceReload: Bool, for template: TemplateItem) {
        let key = key(for: template)
        if !forceReload, notesCache[key] != nil { return }
        ensureFolder(for: template)
        let url = notesURL(for: template)
        if let data = try? Data(contentsOf: url),
           let model = try? decoder.decode(TemplateGuideNotesModel.self, from: data) {
            notesCache[key] = GuideNotesState(text: model.text, dirty: false)
        } else {
            notesCache[key] = GuideNotesState(text: "", dirty: false)
        }
    }
    
    private func persistImages(for template: TemplateItem, images: [TemplateGuideImage]) {
        ensureFolder(for: template)
        let manifest = TemplateGuideImagesManifest(templateId: template.id, images: images, updatedAt: isoFormatter.string(from: Date()))
        let url = imagesManifestURL(for: template)
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            LOG("Template guide manifest save failed", ctx: ["template": template.name, "error": error.localizedDescription])
        }
    }
    
    private func ensureFolder(for template: TemplateItem) {
        let folder = folderURL(for: template.url)
        let imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: imagesFolder.path) {
            try? fm.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        }
    }
    
    private func folderURL(for template: TemplateItem) -> URL {
        folderURL(for: template.url)
    }
    
    private func folderURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return AppPaths.templateGuides.appendingPathComponent(base, isDirectory: true)
    }
    
    private func imagesManifestURL(for template: TemplateItem) -> URL {
        folderURL(for: template).appendingPathComponent("images.json")
    }
    
    private func notesURL(for template: TemplateItem) -> URL {
        folderURL(for: template).appendingPathComponent("guide.json")
    }
    
    private func imageURL(fileName: String, for template: TemplateItem) -> URL {
        folderURL(for: template).appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(fileName)
    }
    
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()
    
    private let decoder = JSONDecoder()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
