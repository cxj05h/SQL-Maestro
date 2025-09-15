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
    static let mysqlHostsMap = mappings.appendingPathComponent("mysql_hosts_map.json", conformingTo: .json)
    static let userConfig = mappings.appendingPathComponent("user_config.json", conformingTo: .json)
    static let sessions = appSupport.appendingPathComponent("sessions", isDirectory: true)
    
    static func ensureAll() {
        [appSupport, templates, backups, backupZips, logs, mappings].forEach { url in
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // Ensure sessions directory exists for saved ticket sessions
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
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
        // Seed mysql hosts mapping file if missing
        if !FileManager.default.fileExists(atPath: mysqlHostsMap.path) {
            let exampleHosts = """
            {
              "mysql01": {
                "hostname": "mysql01-replica.internal.spotinst.io",
                "port": 3306
              },
              "mysql04": {
                "hostname": "mysqlcore-replica.internal.spotinst.io",
                "port": 3306
              }
            }
            """
            try? exampleHosts.write(to: mysqlHostsMap, atomically: true, encoding: .utf8)
        }

        // Seed user config file if missing
        if !FileManager.default.fileExists(atPath: userConfig.path) {
            let emptyConfig = """
            {
              "mysql_username": "",
              "mysql_password": "",
              "querious_path": "/Applications/Querious.app"
            }
            """
            try? emptyConfig.write(to: userConfig, atomically: true, encoding: .utf8)
        }
    }
}
