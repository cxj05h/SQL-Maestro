import Foundation

enum AppPaths {
    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("SQLMaestro", isDirectory: true)

    static let templates = appSupport.appendingPathComponent("templates", isDirectory: true)
    static let templateIdentities = templates.appendingPathComponent("template-identities.json", conformingTo: .json)
    static let backups = appSupport.appendingPathComponent("backups", isDirectory: true)
    static let queryHistoryCheckpoints = backups.appendingPathComponent("query_history_checkpoints", isDirectory: true)
    static let queryTemplateBackups = backups.appendingPathComponent("query_template_backups", isDirectory: true)
    static let logs = appSupport.appendingPathComponent("logs", isDirectory: true)
    static let mappings = appSupport.appendingPathComponent("mappings", isDirectory: true)
    static let templateGuides = appSupport.appendingPathComponent("template_guides", isDirectory: true)
    static let orgMysqlMap = mappings.appendingPathComponent("org_mysql_map.json", conformingTo: .json)
    static let mysqlHostsMap = mappings.appendingPathComponent("mysql_hosts_map.json", conformingTo: .json)
    static let userConfig = mappings.appendingPathComponent("user_config.json", conformingTo: .json)
    static let sessions = appSupport.appendingPathComponent("sessions", isDirectory: true)
    static let sessionImages = appSupport.appendingPathComponent("session_images", isDirectory: true)
    
    static func ensureAll() {
        [appSupport, templates, backups, queryHistoryCheckpoints, queryTemplateBackups, logs, mappings, templateGuides].forEach { url in
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
                "hostname": "xxxxxx",
                "port": xxxx
              },
              "mysql04": {
                "hostname": "xxxxx",
                "port": xxxx
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

    static func copyBundledAssets() {
        let bundle = Bundle.main
        let fm = FileManager.default
        
        // Define the files we want to copy from bundle
        let bundledFiles = [
            "demo.sql",
            "sumo demo.sql",
            "db_tables_catalog.json",
            "placeholders.json",
            "placeholder_order.json"
        ]
        
        let bundledMappings = [
            "mysql_hosts_map.json",
            "org_mysql_map.json",
            "user_config.json"
        ]
        
        // Copy templates if templates folder doesn't exist
        if !fm.fileExists(atPath: templates.path) {
            try? fm.createDirectory(at: templates, withIntermediateDirectories: true)
            for templateFile in bundledFiles.filter({ $0.hasSuffix(".sql") }) {
                if let bundlePath = bundle.path(forResource: templateFile.replacingOccurrences(of: ".sql", with: ""), ofType: "sql") {
                    let dest = templates.appendingPathComponent(templateFile)
                    try? fm.copyItem(at: URL(fileURLWithPath: bundlePath), to: dest)
                    LOG("Bundled template copied", ctx: ["file": templateFile])
                }
            }
        }
        
        // Copy mappings if mappings folder doesn't exist
        if !fm.fileExists(atPath: mappings.path) {
            try? fm.createDirectory(at: mappings, withIntermediateDirectories: true)
            for mappingFile in bundledMappings {
                if let bundlePath = bundle.path(forResource: mappingFile.replacingOccurrences(of: ".json", with: ""), ofType: "json") {
                    let dest = mappings.appendingPathComponent(mappingFile)
                    try? fm.copyItem(at: URL(fileURLWithPath: bundlePath), to: dest)
                    LOG("Bundled mapping copied", ctx: ["file": mappingFile])
                }
            }
        }
        
        // Copy root JSON files
        let rootFiles = ["db_tables_catalog.json", "placeholders.json", "placeholder_order.json"]
        for file in rootFiles {
            let dest = appSupport.appendingPathComponent(file)
            if !fm.fileExists(atPath: dest.path) {
                if let bundlePath = bundle.path(forResource: file.replacingOccurrences(of: ".json", with: ""), ofType: "json") {
                    try? fm.copyItem(at: URL(fileURLWithPath: bundlePath), to: dest)
                    LOG("Bundled root asset copied", ctx: ["file": file])
                }
            }
        }
        
        LOG("First launch asset check complete")
    }
    
    
}
