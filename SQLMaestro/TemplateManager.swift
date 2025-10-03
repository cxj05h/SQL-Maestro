import Foundation

final class TemplateManager: ObservableObject {
    @Published var templates: [TemplateItem] = []
    private let placeholderRegex = try! NSRegularExpression(pattern: #"\{\{\s*([^}]+?)\s*\}\}"#, options: [])
    private var lastBackupTimestamps: [UUID: Date] = [:]
    private let backupThrottleInterval: TimeInterval = 1.0 // Minimum 1 second between backups

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
        try newContent.write(to: url, atomically: true, encoding: .utf8)
        LOG("Template saved", ctx: ["template": url.lastPathComponent])
        loadTemplates()
    }

    func shouldBackupTemplate(_ template: TemplateItem) -> Bool {
        guard let lastBackup = lastBackupTimestamps[template.id] else { return true }
        return Date().timeIntervalSince(lastBackup) >= backupThrottleInterval
    }

    func backupTemplateIfNeeded(_ template: TemplateItem, reason: String = "manual") {
        guard shouldBackupTemplate(template) else {
            LOG("Backup skipped (throttled)", ctx: ["template": template.name, "reason": reason])
            return
        }
        do {
            try backupTemplate(template, reason: reason)
        } catch {
            WARN("Backup failed", ctx: ["template": template.name, "error": error.localizedDescription])
        }
    }

    private func backupTemplate(_ template: TemplateItem, reason: String = "manual") throws {
        let fm = FileManager.default
        let stamp = Self.timestamp()
        let sanitizedName = template.name.replacingOccurrences(of: "/", with: "-")
        let backupName = "\(sanitizedName)-\(stamp)"
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroBackup-\(UUID().uuidString)", isDirectory: true)

        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Export all template assets to temp directory
        try exportTemplateAssets(template, to: tempRoot)

        // Create zip in query history checkpoints directory
        let zipURL = AppPaths.queryHistoryCheckpoints.appendingPathComponent("\(backupName).zip")
        try zipFolder(at: tempRoot, to: zipURL)

        lastBackupTimestamps[template.id] = Date()
        LOG("Template backed up", ctx: ["template": template.name, "reason": reason, "zip": zipURL.lastPathComponent])
    }

    private func exportTemplateAssets(_ template: TemplateItem, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Save SQL file
        let sqlDestination = folder.appendingPathComponent("template.sql")
        try template.rawSQL.write(to: sqlDestination, atomically: true, encoding: .utf8)

        // Copy sidecar files
        let sidecarPairs: [(URL, String, String)] = [
            (template.url.templateLinksSidecarURL(), "links", "links.json"),
            (template.url.templateTablesSidecarURL(), "tables", "tables.json"),
            (template.url.templateTagsSidecarURL(), "tags", "tags.json")
        ]
        for (source, kind, targetName) in sidecarPairs {
            guard fm.fileExists(atPath: source.path) else { continue }
            let data = try Data(contentsOf: source)
            try data.write(to: folder.appendingPathComponent(targetName), options: .atomic)
            LOG("Template sidecar bundled", ctx: ["file": targetName, "kind": kind])
        }

        // Copy guide folder
        let templateBase = template.url.deletingPathExtension().lastPathComponent
        let guideSource = AppPaths.templateGuides.appendingPathComponent(templateBase, isDirectory: true)
        if fm.fileExists(atPath: guideSource.path) {
            let guideDestination = folder.appendingPathComponent("guide", isDirectory: true)
            if fm.fileExists(atPath: guideDestination.path) {
                try fm.removeItem(at: guideDestination)
            }
            try fm.copyItem(at: guideSource, to: guideDestination)
            LOG("Template guide bundled", ctx: ["template": template.name])
        }

        // Create metadata
        let manifest = TemplateBackupManifest(
            version: 1,
            backedUpAt: Date(),
            templateName: template.name,
            templateId: template.id.uuidString
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = folder.appendingPathComponent("metadata.json")
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
    }

    private func zipFolder(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zip", "-r", destination.path, "."]
        process.currentDirectoryURL = source
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "zip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "zip failed with status \(process.terminationStatus)"])
        }
    }

    func zipAllTemplates() throws -> URL {
        let fm = FileManager.default
        let stamp = Self.timestamp()
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroBackupAll-\(UUID().uuidString)", isDirectory: true)

        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        LOG("Backup all: temp root created", ctx: ["path": tempRoot.path])

        // Create individual template zips inside temp directory
        var successCount = 0
        for template in templates {
            do {
                let sanitizedName = template.name.replacingOccurrences(of: "/", with: "-")
                let templateTempDir = fm.temporaryDirectory.appendingPathComponent("SQLMaestroTemplateExport-\(UUID().uuidString)", isDirectory: true)

                defer { try? fm.removeItem(at: templateTempDir) }

                try fm.createDirectory(at: templateTempDir, withIntermediateDirectories: true)

                // Export template assets to temp directory
                try exportTemplateAssets(template, to: templateTempDir)

                // Create individual template zip
                let templateZipURL = tempRoot.appendingPathComponent("\(sanitizedName).zip")
                try zipFolder(at: templateTempDir, to: templateZipURL)

                successCount += 1
                LOG("Template archived for backup", ctx: ["template": template.name])
            } catch {
                WARN("Template backup failed", ctx: ["template": template.name, "error": error.localizedDescription])
            }
        }

        LOG("Individual template zips created", ctx: ["count": "\(successCount)"])

        // Now zip all the individual template zips into one master zip
        let finalZipURL = AppPaths.queryTemplateBackups.appendingPathComponent("templates-\(stamp).zip")
        LOG("Creating master zip", ctx: ["destination": finalZipURL.path])
        try zipFolder(at: tempRoot, to: finalZipURL)

        LOG("All templates backed up", ctx: ["zip": finalZipURL.lastPathComponent, "count": "\(successCount)"])
        return finalZipURL
    }

    func pruneBackups(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.queryHistoryCheckpoints, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files where f.pathExtension.lowercased() == "zip" {
                if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mdate = vals.contentModificationDate, mdate < cutoff {
                    try? FileManager.default.removeItem(at: f)
                    LOG("Old backup pruned", ctx: ["file": f.lastPathComponent])
                }
            }
        }
    }

    func restoreTemplateFromHistory(archiveURL: URL) throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroRestore-\(UUID().uuidString)", isDirectory: true)

        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Unzip the archive
        try unzipArchive(archiveURL, to: tempRoot)

        // Extract template name from filename (everything before the last dash)
        let filename = archiveURL.deletingPathExtension().lastPathComponent
        let components = filename.split(separator: "-")
        guard components.count >= 2 else {
            throw NSError(domain: "TemplateManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid backup filename format"])
        }

        // Join all components except the last one (timestamp)
        let templateName = components.dropLast().joined(separator: "-")

        // Find the template.sql file in the extracted content
        guard let sqlURL = try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent == "template.sql" }) else {
            throw NSError(domain: "TemplateManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "No template.sql found in backup"])
        }

        // Destination for restored template
        let destinationURL = AppPaths.templates.appendingPathComponent("\(templateName).sql")

        // Copy SQL file (overwriting if exists)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
            LOG("Existing template removed for restore", ctx: ["template": templateName])
        }

        let sqlContent = try String(contentsOf: sqlURL, encoding: .utf8)
        try sqlContent.write(to: destinationURL, atomically: true, encoding: .utf8)

        // Get the template ID for the restored template
        let templateId = TemplateIdentityStore.shared.id(for: destinationURL)

        // Restore sidecars
        let sidecarFiles: [(String, URL)] = [
            ("links.json", destinationURL.templateLinksSidecarURL()),
            ("tables.json", destinationURL.templateTablesSidecarURL()),
            ("tags.json", destinationURL.templateTagsSidecarURL())
        ]

        for (filename, destination) in sidecarFiles {
            if let source = try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent == filename }) {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
                LOG("Sidecar restored", ctx: ["file": filename, "template": templateName])
            }
        }

        // Restore guide folder
        let guideSource = tempRoot.appendingPathComponent("guide", isDirectory: true)
        if fm.fileExists(atPath: guideSource.path) {
            let guideDestination = AppPaths.templateGuides.appendingPathComponent(templateName, isDirectory: true)
            try? fm.removeItem(at: guideDestination)
            try fm.copyItem(at: guideSource, to: guideDestination)
            LOG("Guide restored", ctx: ["template": templateName])
        }

        loadTemplates()
        LOG("Template restored from history", ctx: ["template": templateName, "source": archiveURL.lastPathComponent])
    }

    func restoreAllTemplatesFromBackup(archiveURL: URL) throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroRestoreAll-\(UUID().uuidString)", isDirectory: true)

        defer { try? fm.removeItem(at: tempRoot) }

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Unzip the master archive
        try unzipArchive(archiveURL, to: tempRoot)

        // Get all individual template zips
        guard let templateZips = try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "zip" }) else {
            throw NSError(domain: "TemplateManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "No template archives found in backup"])
        }

        LOG("Restoring all templates", ctx: ["count": "\(templateZips.count)"])

        // Clear existing templates
        if let existingTemplates = try? fm.contentsOfDirectory(at: AppPaths.templates, includingPropertiesForKeys: nil) {
            for url in existingTemplates where url.pathExtension.lowercased() == "sql" {
                try? fm.removeItem(at: url)
            }
        }

        // Clear existing sidecars and guides
        let templateBase = AppPaths.templates.deletingLastPathComponent()
        if let sidecars = try? fm.contentsOfDirectory(at: AppPaths.templates, includingPropertiesForKeys: nil) {
            for url in sidecars where url.pathExtension.lowercased() == "json" {
                try? fm.removeItem(at: url)
            }
        }

        // Restore each template
        var restoredCount = 0
        for zipURL in templateZips {
            do {
                try restoreTemplateFromHistory(archiveURL: zipURL)
                restoredCount += 1
            } catch {
                WARN("Template restore failed", ctx: ["zip": zipURL.lastPathComponent, "error": error.localizedDescription])
            }
        }

        LOG("All templates restored", ctx: ["restored": "\(restoredCount)", "total": "\(templateZips.count)"])
    }

    private func unzipArchive(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["unzip", "-q", archive.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "unzip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "unzip failed with status \(process.terminationStatus)"])
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
        TemplateTagsStore.shared.handleTemplateRenamed(from: originalURL, to: dest)

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

struct TemplateBackupManifest: Codable {
    let version: Int
    let backedUpAt: Date
    let templateName: String
    let templateId: String
}
