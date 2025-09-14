import Foundation

/// Persists per-session lists of tables to auto-open in Querious.
/// Stored at: ~/Library/Application Support/SQLMaestro/auto_open_tables.json
/// /// Stored at: ~/Library/Application Support/SQLMaestro/mappings/auto_open_tables.json
/// In a sandboxed build: ~/Library/Containers/<bundle-id>/Data/Library/Application Support/SQLMaestro/mappings/


final class AutoOpenTablesStore: ObservableObject {
    static let shared = AutoOpenTablesStore()

    @Published private(set) var tablesBySession: [Int: [String]] = [:]
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSup.appendingPathComponent("SQLMaestro", isDirectory: true)
        let mappingsDir = base.appendingPathComponent("mappings", isDirectory: true)
        try? fm.createDirectory(at: mappingsDir, withIntermediateDirectories: true)
        self.fileURL = mappingsDir.appendingPathComponent("auto_open_tables.json")
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([Int:[String]].self, from: data)
            // normalize: trim whitespace, drop empties, de-dup per session
            var normalized: [Int:[String]] = [:]
            for (k, list) in decoded {
                var seen = Set<String>()
                let clean = list
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .filter { seen.insert($0).inserted }
                if !clean.isEmpty { normalized[k] = clean }
            }
            self.tablesBySession = normalized
            LOG("AutoOpenTables loaded", ctx: ["sessions": "\(normalized.count)"])
        } catch {
            self.tablesBySession = [:]
            save() // seed empty file
            LOG("AutoOpenTables seeded empty", ctx: [:])
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(tablesBySession)
            try data.write(to: fileURL, options: [.atomic])
            LOG("AutoOpenTables saved", ctx: ["sessions": "\(tablesBySession.count)"])
        } catch {
            LOG("AutoOpenTables save failed", ctx: ["error": error.localizedDescription])
        }
    }

    func tables(for sessionRaw: Int) -> [String] {
        tablesBySession[sessionRaw] ?? []
    }

    func set(tables: [String], for sessionRaw: Int) {
        var seen = Set<String>()
        let clean = tables
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        tablesBySession[sessionRaw] = clean
        save()
    }

    func append(table: String, for sessionRaw: Int) {
        var list = tablesBySession[sessionRaw] ?? []
        let trimmed = table.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !list.contains(trimmed) {
            list.append(trimmed)
            tablesBySession[sessionRaw] = list
            save()
        }
    }
    
    func remove(table: String, for sessionRaw: Int) {
        guard var list = tablesBySession[sessionRaw] else { return }
        let before = list.count
        list.removeAll { $0.caseInsensitiveCompare(table) == .orderedSame }
        if list.count != before {
            tablesBySession[sessionRaw] = list
            save()
        }
    }
}


