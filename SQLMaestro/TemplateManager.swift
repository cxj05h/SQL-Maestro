import Foundation

final class TemplateManager: ObservableObject {
    @Published var templates: [TemplateItem] = []
    private let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{\s*([^}]+?)\s*\}\}"#, options: [])

    init() {
        AppPaths.ensureAll()
        self.loadTemplates()
        pruneBackups(olderThanDays: 30)
        LOG("TemplateManager initialized")
    }

    func loadTemplates() {
        var items: [TemplateItem] = []
        guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.templates, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "sql" {
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let phs = extractPlaceholders(from: raw)
                let id = TemplateIdentityStore.shared.id(for: url)
                items.append(TemplateItem(id: id,
                                          name: url.deletingPathExtension().lastPathComponent,
                                          url: url,
                                          rawSQL: raw,
                                          placeholders: phs))
            }
        }
        self.templates = items.sorted{ $0.name.lowercased() < $1.name.lowercased() }
        LOG("Templates loaded", ctx: ["count":"\(self.templates.count)"])
    }

    func extractPlaceholders(from sql: String) -> [String] {
        let ns = sql as NSString
        let matches = placeholderRegex.matches(in: sql, range: NSRange(location: 0, length: ns.length))
        var set = OrderedSet<String>()
        for m in matches {
            if m.numberOfRanges >= 2 {
                let inner = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                set.append(inner)
            }
        }
        return Array(set.elements)
    }

    func saveTemplate(url: URL, newContent: String) throws {
        // backup existing
        if FileManager.default.fileExists(atPath: url.path) {
            let stamp = Self.timestamp()
            let backupName = "\(url.deletingPathExtension().lastPathComponent)-\(stamp).sql"
            let backupURL = AppPaths.backups.appendingPathComponent(backupName)
            try? FileManager.default.copyItem(at: url, to: backupURL)
            LOG("Template backup created", ctx: ["backup": backupURL.lastPathComponent])
        }
        try newContent.write(to: url, atomically: true, encoding: .utf8)
        LOG("Template saved", ctx: ["template": url.lastPathComponent])
        loadTemplates()
    }

    func zipAllTemplates() throws -> URL {
        let stamp = Self.timestamp()
        let zipURL = AppPaths.backupZips.appendingPathComponent("templates-\(stamp).zip")
        try? FileManager.default.removeItem(at: zipURL)

        // Use the built-in /usr/bin/zip for simplicity
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-r", zipURL.path, "."]
        proc.currentDirectoryURL = AppPaths.templates
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 { throw NSError(domain: "zip", code: Int(proc.terminationStatus)) }
        LOG("Templates zipped", ctx: ["zip": zipURL.lastPathComponent])
        return zipURL
    }

    func pruneBackups(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.backups, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files where f.pathExtension.lowercased() == "sql" {
                if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mdate = vals.contentModificationDate, mdate < cutoff {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }

    static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df.string(from: Date())
    }
    
    
    // Create a new template file with starter content
    func createTemplate(named rawName: String) throws -> TemplateItem {
        let safe = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else {
            throw NSError(domain: "TemplateManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty"])
        }

        var finalName = safe
        var url = AppPaths.templates.appendingPathComponent("\(finalName).sql")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            finalName = "\(safe) \(counter)"
            url = AppPaths.templates.appendingPathComponent("\(finalName).sql")
            counter += 1
        }

        let boilerplate = """
        -- \(finalName).sql
        -- Write placeholders {{Org-ID}} and {{Acct-ID}} (if needed), exactly as stated. Any other placeholders can use whatever text you want inside double curly brackets:
        SELECT <you_queries_here...>;
        """
        try boilerplate.write(to: url, atomically: true, encoding: .utf8)
        LOG("Template created", ctx: ["name": finalName])

        // Refresh list and return item
        loadTemplates()
        guard let item = self.templates.first(where: { $0.url == url }) else {
            throw NSError(domain: "TemplateManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to locate created template"])
        }
        return item
    }

    // Rename an existing template file safely
    func renameTemplate(_ item: TemplateItem, to newRawName: String) throws -> TemplateItem {
        let base = newRawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            throw NSError(domain: "TemplateManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "New name cannot be empty"])
        }

        var finalName = base
        var dest = AppPaths.templates.appendingPathComponent("\(finalName).sql")
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) && dest != item.url {
            finalName = "\(base) \(i)"
            dest = AppPaths.templates.appendingPathComponent("\(finalName).sql")
            i += 1
        }

        let originalURL = item.url

        try FileManager.default.moveItem(at: originalURL, to: dest)
        LOG("Template renamed", ctx: ["old": originalURL.lastPathComponent, "new": dest.lastPathComponent])

        TemplateIdentityStore.shared.handleTemplateRenamed(from: originalURL, to: dest)
        DBTablesStore.shared.handleTemplateRenamed(from: originalURL, to: dest)
        TemplateLinksStore.shared.handleTemplateRenamed(from: originalURL, to: dest)

        Task { @MainActor in
            TemplateGuideStore.shared.handleTemplateRenamed(from: originalURL, to: dest)
        }

        loadTemplates()
        guard let renamed = self.templates.first(where: { $0.url == dest }) else {
            throw NSError(domain: "TemplateManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to locate renamed template"])
        }
        return renamed
    }

}

// Tiny ordered set helper for stable placeholder order
struct OrderedSet<Element: Hashable> {
    private(set) var elements: [Element] = []
    private var seen: Set<Element> = []
    mutating func append(_ e: Element) {
        if !seen.contains(e) {
            elements.append(e)
            seen.insert(e)
        }
    }
}
