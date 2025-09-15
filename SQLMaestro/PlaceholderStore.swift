import Foundation
import Combine

// Global, persistent placeholder store with order preservation
final class PlaceholderStore: ObservableObject {
    static let shared = PlaceholderStore()

    @Published private(set) var names: [String] = []
    private let fileURL: URL
    private let orderFileURL: URL

    private init() {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSup.appendingPathComponent("SQLMaestro", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("placeholders.json")
        self.orderFileURL = dir.appendingPathComponent("placeholder_order.json")
        load()
    }

    func load() {
        // Load the names
        var loadedNames: [String] = []
        do {
            let data = try Data(contentsOf: fileURL)
            let list = try JSONDecoder().decode([String].self, from: data)
            var seen = Set<String>()
            loadedNames = list.filter { seen.insert($0).inserted }
            LOG("Placeholders loaded", ctx: ["count": "\(loadedNames.count)", "file": fileURL.lastPathComponent])
        } catch {
            // Seed with a few useful tokens on first run
            loadedNames = ["Org-ID", "Acct-ID", "resourceID", "sig-id", "Date"]
            LOG("Placeholders seeded", ctx: ["count": "\(loadedNames.count)"])
        }
        
        // Load the saved order and apply it
        if let savedOrder = loadOrder() {
            self.names = applyOrder(names: loadedNames, order: savedOrder)
            LOG("Placeholder order applied", ctx: ["ordered_count": "\(self.names.count)"])
        } else {
            self.names = loadedNames
            // Save the initial order
            saveOrder()
        }
        
        // Save names to ensure file exists
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            save()
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
    
    func saveOrder() {
        do {
            let data = try JSONEncoder().encode(self.names)
            try data.write(to: orderFileURL, options: [.atomic])
            LOG("Placeholder order saved", ctx: ["count": "\(self.names.count)"])
        } catch {
            LOG("Placeholder order save failed", ctx: ["error": error.localizedDescription])
        }
    }
    
    private func loadOrder() -> [String]? {
        do {
            let data = try Data(contentsOf: orderFileURL)
            let order = try JSONDecoder().decode([String].self, from: data)
            LOG("Placeholder order loaded", ctx: ["count": "\(order.count)"])
            return order
        } catch {
            LOG("Placeholder order load failed", ctx: ["error": error.localizedDescription])
            return nil
        }
    }
    
    private func applyOrder(names: [String], order: [String]) -> [String] {
        var result: [String] = []
        var remaining = Set(names)
        
        // First, add items in the saved order if they still exist
        for orderedName in order {
            if remaining.contains(orderedName) {
                result.append(orderedName)
                remaining.remove(orderedName)
            }
        }
        
        // Then add any new items that weren't in the saved order
        for newName in remaining.sorted() {
            result.append(newName)
        }
        
        return result
    }

    // MARK: Mutators (auto-save)
    func set(_ newNames: [String]) {
        self.names = newNames
        save()
        saveOrder() // Also save the order
    }

    func add(_ name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if !self.names.contains(cleaned) {
            self.names.append(cleaned)
            save()
            saveOrder()
            LOG("Placeholder added", ctx: ["name": cleaned])
        }
    }

    func remove(_ name: String) {
        let before = self.names.count
        self.names.removeAll { $0 == name }
        if self.names.count != before {
            save()
            saveOrder()
        }
    }

    func rename(_ old: String, to new: String) {
        guard let idx = self.names.firstIndex(of: old) else { return }
        self.names[idx] = new
        save()
        saveOrder()
    }
    
    // New method for reordering
    func reorder(_ newOrder: [String]) {
        self.names = newOrder
        save()
        saveOrder()
        LOG("Placeholders reordered", ctx: ["count": "\(newOrder.count)"])
    }
}
