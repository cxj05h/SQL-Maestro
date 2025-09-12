import Foundation

enum AppPaths {
    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("SQLMaestro", isDirectory: true)

    static let templates = appSupport.appendingPathComponent("templates", isDirectory: true)
    static let backups = appSupport.appendingPathComponent("backups", isDirectory: true)
    static let backupZips = backups.appendingPathComponent("zips", isDirectory: true)
    static let logs = appSupport.appendingPathComponent("logs", isDirectory: true)
    static let mappings = appSupport.appendingPathComponent("mappings", isDirectory: true)
    static let orgMysqlMap = mappings.appendingPathComponent("org_mysql_map.json", conformingTo: .json)

    static func ensureAll() {
        [appSupport, templates, backups, backupZips, logs, mappings].forEach { url in
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Seed example template once
        let example = templates.appendingPathComponent("example.sql")
        if !FileManager.default.fileExists(atPath: example.path) {
            let sample = """
            -- Example template with placeholders
            SELECT * FROM `{{Org-id}}`.`_audited_events`
            WHERE `resourceId` = {{sig-id}}
            ORDER BY createdAt DESC;
            """
            try? sample.write(to: example, atomically: true, encoding: .utf8)
        }
        // Seed mapping file if missing
        if !FileManager.default.fileExists(atPath: orgMysqlMap.path) {
            let empty = "{}"
            try? empty.write(to: orgMysqlMap, atomically: true, encoding: .utf8)
        }
    }
}