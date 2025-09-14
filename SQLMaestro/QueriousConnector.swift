import Foundation
import AppKit

// MARK: - Errors reported back to the UI
enum DBConnectError: LocalizedError {
    case missingOrgId
    case missingMysqlDbKey
    case missingCredentials
    case queriousNotFound(String)
    case hostMappingNotFound(dbKey: String)
    case urlBuildFailed

    var errorDescription: String? {
        switch self {
        case .missingOrgId:
            return "Org-ID is required before connecting."
        case .missingMysqlDbKey:
            return "Couldn’t resolve the MySQL DB key for this Org-ID."
        case .missingCredentials:
            return "Database username and password are required."
        case .queriousNotFound(let path):
            return "Querious wasn’t found at: \(path)"
        case .hostMappingNotFound(let dbKey):
            return "No host mapping found for “\(dbKey)”."
        case .urlBuildFailed:
            return "Failed to construct a valid MySQL connection URL."
        }
    }
}

// MARK: - Connector
enum QueriousConnector {
    /// Main entrypoint. Minimal assumptions; returns fast on preflight errors and logs the open() result.
    static func connect(
        orgId rawOrgId: String?,
        mysqlDbKey rawDbKey: String?,
        username rawUser: String?,
        password rawPass: String?,
        queriousPath rawAppPath: String?
    ) throws {
        // 1) Validate Org-ID
        let orgId = (rawOrgId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !orgId.isEmpty else { throw DBConnectError.missingOrgId }

        // 2) Resolve DB key: prefer the provided field, else read mapping file
        var dbKey = (rawDbKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if dbKey.isEmpty, let mapped = resolveMysqlDbKeyFromOrg(orgId) {
            dbKey = mapped
            LOG("DB key resolved via org mapping", ctx: ["orgId": orgId, "mysqlDb": dbKey])
        }
        guard !dbKey.isEmpty else { throw DBConnectError.missingMysqlDbKey }

        // 3) Resolve host mapping
        guard let host = resolveMysqlHost(for: dbKey) else {
            throw DBConnectError.hostMappingNotFound(dbKey: dbKey)
        }

        // 4) Credentials + app path
        let username = (rawUser ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = rawPass ?? ""
        guard !username.isEmpty, !password.isEmpty else { throw DBConnectError.missingCredentials }

        let appPath = ((rawAppPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ? "/Applications/Querious.app"
            : (rawAppPath ?? "")
        guard FileManager.default.fileExists(atPath: appPath) else {
            throw DBConnectError.queriousNotFound(appPath)
        }

        // 5) Build DB name and Querious URL
        let database = "spotinst_\(orgId)"
        guard let url = makeQueriousURL(host: host.hostname,
                                        port: host.port,
                                        user: username,
                                        password: password,
                                        database: database) else {
            throw DBConnectError.urlBuildFailed
        }

        // 6) Prefer existing instance; otherwise launch then send URL
        let appURL = URL(fileURLWithPath: appPath)
        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            if let b = app.bundleURL { return b == appURL }
            return app.localizedName == "Querious"
        }

        if isRunning {
            // Try targeted AppleEvent first so it reuses the existing instance/window.
            let asSource = """
            set theURL to "\(url.absoluteString)"
            -- Capture current window count
            tell application "System Events"
                set winCount to 0
                if exists process "Querious" then
                    tell process "Querious"
                        try
                            set winCount to count of windows
                        on error
                            set winCount to 0
                        end try
                    end tell
                end if
            end tell

            -- Send the URL to Querious (this may open a new window)
            tell application "Querious"
                activate
                open location theURL
            end tell

            -- Wait briefly for a new window to appear
            set maxTries to 30
            repeat with i from 1 to maxTries
                delay 0.12
                tell application "System Events"
                    if exists process "Querious" then
                        tell process "Querious"
                            try
                                set newCount to count of windows
                                if newCount > winCount then exit repeat
                            end try
                        end tell
                    end if
                end tell
            end repeat

            -- Best-effort: Merge All Windows into tabs
            try
                tell application "System Events"
                    if exists process "Querious" then
                        tell process "Querious"
                            tell menu bar 1
                                tell menu bar item "Window"
                                    tell menu 1
                                        if exists menu item "Merge All Windows" then
                                            click menu item "Merge All Windows"
                                        end if
                                    end tell
                                end tell
                            end tell
                        end tell
                    end if
                end tell
            end try
            """
            var asError: NSDictionary?
            if let asObj = NSAppleScript(source: asSource) {
                let result = asObj.executeAndReturnError(&asError)
                if let asError = asError {
                    LOG("AppleScript open location failed; falling back to NSWorkspace.open", ctx: ["error": String(describing: asError), "url": url.absoluteString])
                    NSWorkspace.shared.open(url)
                } else {
                    LOG("Sent URL to existing Querious instance via AppleScript", ctx: ["result": result.stringValue ?? "ok"])
                }
            } else {
                LOG("Failed to create AppleScript object; falling back to NSWorkspace.open", ctx: [:])
                NSWorkspace.shared.open(url)
            }
        } else {
            LOG("Launching Querious, then sending URL", ctx: ["appPath": appPath, "url": url.absoluteString])
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, err in
                if let err = err {
                    LOG("Querious launch failed; falling back to direct URL open", ctx: ["error": err.localizedDescription])
                    NSWorkspace.shared.open(url)
                    return
                }
                // small delay to allow the app to register URL handlers
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - File loaders (lenient)
private struct MysqlHost: Decodable { let hostname: String; let port: Int? }

private func appSupportSQLMaestro() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("SQLMaestro", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func resolveMysqlDbKeyFromOrg(_ orgId: String) -> String? {
    // ~/Library/Application Support/SQLMaestro/mappings/org_mysql_map.json
    let url = appSupportSQLMaestro()
        .appendingPathComponent("mappings", isDirectory: true)
        .appendingPathComponent("org_mysql_map.json")

    guard let data = try? Data(contentsOf: url) else {
        LOG("org_mysql_map.json missing", ctx: ["path": url.path])
        return nil
    }

    // Accept either {"6060..":{"mysqlDb":"mysql04",...}} OR {"6060..":"mysql04"} styles
    if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        if let v = dict[orgId] as? [String: Any], let db = v["mysqlDb"] as? String { return db }
        if let v = dict[orgId] as? String { return v }
    }
    LOG("orgId not found in org_mysql_map.json", ctx: ["orgId": orgId])
    return nil
}

private func resolveMysqlHost(for dbKey: String) -> (hostname: String, port: Int)? {
    // ~/Library/Application Support/SQLMaestro/mappings/mysql_hosts_map.json
    let url = appSupportSQLMaestro()
        .appendingPathComponent("mappings", isDirectory: true)
        .appendingPathComponent("mysql_hosts_map.json")

    guard let data = try? Data(contentsOf: url) else {
        LOG("mysql_hosts_map.json missing", ctx: ["path": url.path])
        return nil
    }

    // Decode as [String: MysqlHost] with lowercase keys
    if let raw = try? JSONDecoder().decode([String: MysqlHost].self, from: data) {
        var map: [String: MysqlHost] = [:]
        for (k, v) in raw { map[k.lowercased()] = v }
        let key = dbKey.lowercased()
        if let hit = map[key] { return (hit.hostname, hit.port ?? 3306) }
        // a few lenient variants
        if let hit = map[key.replacingOccurrences(of: "_", with: "-")] { return (hit.hostname, hit.port ?? 3306) }
        if let hit = map[key.replacingOccurrences(of: "-", with: "")] { return (hit.hostname, hit.port ?? 3306) }
        if let hit = map[key.replacingOccurrences(of: "mysql", with: "")] { return (hit.hostname, hit.port ?? 3306) }
    }

    // Fallback: permissive JSON (e.g., hand-written)
    if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        let key = dbKey.lowercased()
        let cands = [
            key,
            key.replacingOccurrences(of: "_", with: "-"),
            key.replacingOccurrences(of: "-", with: ""),
            key.replacingOccurrences(of: "mysql", with: "")
        ]
        for cand in cands {
            if let entry = dict[cand] as? [String: Any],
               let host = entry["hostname"] as? String {
                let port = (entry["port"] as? Int) ?? 3306
                return (host, port)
            }
        }
    }

    return nil
}

private func makeQueriousURL(host: String,
                             port: Int,
                             user: String,
                             password: String,
                             database: String) -> URL? {
    var comps = URLComponents()
    comps.scheme = "querious"
    comps.host = "connect"
    comps.path = "/new"
    comps.queryItems = [
        URLQueryItem(name: "host", value: host),
        URLQueryItem(name: "port", value: String(port)),
        URLQueryItem(name: "user", value: user),
        URLQueryItem(name: "password", value: password),
        URLQueryItem(name: "database", value: database)
    ]
    return comps.url
}
