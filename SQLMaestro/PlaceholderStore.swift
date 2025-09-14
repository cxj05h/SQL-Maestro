import Foundation
import Combine

// Global, persistent placeholder store
final class PlaceholderStore: ObservableObject {
    static let shared = PlaceholderStore()

    @Published private(set) var names: [String] = []
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSup.appendingPathComponent("SQLMaestro", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("placeholders.json")
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([String].self, from: data)
            var seen = Set<String>()
            self.names = list.filter { seen.insert($0).inserted }
            LOG("Placeholders loaded", ctx: ["count": "\(self.names.count)", "file": fileURL.lastPathComponent])
        } catch {
            // Seed with a few useful tokens on first run
            self.names = ["Org-ID", "Acct-ID", "resourceID", "sig-id", "Date"]
            save()
            LOG("Placeholders seeded", ctx: ["count": "\(self.names.count)"])
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self.names)
            try data.write(to: fileURL, options: [.atomic])
            LOG("Placeholders saved", ctx: ["count": "\(self.names.count)"])
        } catch {
            LOG("Placeholders save failed", ctx: ["error": error.localizedDescription])
        }
    }

    // MARK: Mutators (auto-save)
    func set(_ newNames: [String]) {
        self.names = newNames
        save()
    }

    func add(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !self.names.contains(cleaned) {
            self.names.append(cleaned)
            save()
            LOG("Placeholder added", ctx: ["name": cleaned])
        }
    }

    func remove(_ name: String) {
        let before = self.names.count
        self.names.removeAll { $0 == name }
        if self.names.count != before { save() }
    }

    func rename(_ old: String, to new: String) {
        guard let idx = self.names.firstIndex(of: old) else { return }
        self.names[idx] = new
        save()
    }
}
