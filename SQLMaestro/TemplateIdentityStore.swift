import Foundation

/// Maintains a persistent UUID for each template file so sidecars survive renames.
final class TemplateIdentityStore {
    static let shared = TemplateIdentityStore()

    private let queue = DispatchQueue(label: "TemplateIdentityStore.queue")
    private var identities: [String: UUID]

    private init() {
        self.identities = Self.readFromDisk()
    }

    /// Returns the stable UUID for a template file, creating one if missing.
    func id(for url: URL) -> UUID {
        let key = key(for: url)
        return queue.sync {
            if let existing = identities[key] {
                return existing
            }

            if let migrated = migrateIdentityLocked(forKey: key, url: url) {
                identities[key] = migrated
                persistLocked()
                return migrated
            }

            let generated = UUID()
            identities[key] = generated
            persistLocked()
            return generated
        }
    }

    /// Updates the mapping when a template file is renamed.
    func handleTemplateRenamed(from oldURL: URL, to newURL: URL) {
        let oldKey = key(for: oldURL)
        let newKey = key(for: newURL)
        queue.sync {
            let carried = identities.removeValue(forKey: oldKey)
            if let id = carried {
                identities[newKey] = id
            } else if let migrated = migrateIdentityLocked(forKey: newKey, url: newURL) {
                identities[newKey] = migrated
            } else {
                identities[newKey] = identities[newKey] ?? UUID()
            }
            persistLocked()
        }
    }

    /// Removes a mapping if the underlying template is deleted.
    func removeIdentity(for url: URL) {
        let key = key(for: url)
        queue.sync {
            if identities.removeValue(forKey: key) != nil {
                persistLocked()
            }
        }
    }

    // MARK: - Persistence helpers

    private func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func migrateIdentityLocked(forKey key: String, url: URL) -> UUID? {
        if let current = identities[key] { return current }

        let decoder = JSONDecoder()
        var candidate: UUID?
        var seen: Set<UUID> = []

        if let data = try? Data(contentsOf: url.templateTablesSidecarURL()),
           let model = try? decoder.decode(TemplateTables.self, from: data) {
            candidate = model.templateId
            seen.insert(model.templateId)
        }
        if let data = try? Data(contentsOf: url.templateLinksSidecarURL()),
           let model = try? decoder.decode(TemplateLinks.self, from: data) {
            if candidate == nil {
                candidate = model.templateId
            }
            seen.insert(model.templateId)
        }

        if seen.count > 1 {
            LOG("TemplateIdentityStore migrate mismatch", ctx: ["path": url.lastPathComponent])
        }

        return candidate
    }

    private func persistLocked() {
        let dict = identities.mapValues { $0.uuidString }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try? FileManager.default.createDirectory(at: AppPaths.templates, withIntermediateDirectories: true)
            try data.write(to: AppPaths.templateIdentities, options: .atomic)
        } catch {
            LOG("TemplateIdentityStore persist failed", ctx: ["error": error.localizedDescription])
        }
    }

    private static func readFromDisk() -> [String: UUID] {
        let url = AppPaths.templateIdentities
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return [:]
            }
            var out: [String: UUID] = [:]
            for (path, idString) in raw {
                if let id = UUID(uuidString: idString) {
                    out[path] = id
                }
            }
            return out
        } catch {
            LOG("TemplateIdentityStore load failed", ctx: ["error": error.localizedDescription])
            return [:]
        }
    }
}
