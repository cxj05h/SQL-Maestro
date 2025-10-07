import SwiftUI
import AppKit

struct AppMenuCommands: Commands {
    @Environment(\.openURL) private var openURL
    @ObservedObject var tmpl: TemplateManager

    @State private var fontScale: Double = 1.0

    var body: some Commands {
        CommandMenu("Queries") {
            Button("Backup Queries") {
                do {
                    let url = try tmpl.zipAllTemplates()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    NotificationCenter.default.post(name: .queriesBackedUp, object: nil)
                } catch {
                    NSSound.beep()
                }
            }

            Button("Query Template History") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.queryHistoryCheckpoints.path)
            }

            Divider()

            Button("Import Shared Query Template…") {
                NotificationCenter.default.post(name: .importQueryTemplatesRequested, object: nil)
            }

            Divider()

            Button("Restore Query Template…") {
                NotificationCenter.default.post(name: .restoreQueryTemplateRequested, object: nil)
            }

            Button("Restore Query Backups…") {
                NotificationCenter.default.post(name: .restoreQueryBackupsRequested, object: nil)
            }
        }

        CommandMenu("Debug") {
            Button("View Logs") {
                NSWorkspace.shared.open(AppLogger.logFileURLForToday())
            }
            
            Divider()
            
            Button("Edit Org/MySQL Mappings") {
                openMappingFileInVSCode()
            }
            
            Button("Edit MySQL Host Mappings...") {
                openHostMappingFileInVSCode()
            }
            
            Divider()

            Button("Import Orgs…") {
                importOrgMappings()
            }

            Button("Import Hosts…") {
                importHostMappings()
            }

            Divider()
            
            Button("Database Connection Settings...") {
                NotificationCenter.default.post(name: .showDatabaseSettings, object: nil)
            }
        }

        CommandMenu("View") {
            Button("Increase Font (⌘+)") {
                NotificationCenter.default.post(name: .fontBump, object: 1)
            }.keyboardShortcut("+", modifiers: [.command])

            Button("Decrease Font (⌘−)") {
                NotificationCenter.default.post(name: .fontBump, object: -1)
            }.keyboardShortcut("-", modifiers: [.command])
        }

        CommandMenu("Workspace") {
            Button("Focus Search") {
                NotificationCenter.default.post(name: .focusSearchRequested, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])

            Button("Show Guide Notes") {
                NotificationCenter.default.post(name: .showGuideNotesRequested, object: nil)
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Show Session Notes") {
                NotificationCenter.default.post(name: .showSessionNotesRequested, object: nil)
            }
            .keyboardShortcut("2", modifiers: [.command])

            Button("Show Saved Files") {
                NotificationCenter.default.post(name: .showSavedFilesRequested, object: nil)
            }
            .keyboardShortcut("3", modifiers: [.command])

            Divider()

            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebarRequested, object: nil)
            }
            .keyboardShortcut("t", modifiers: [.command])
        }

        CommandGroup(after: .saveItem) {
            Menu("Ticket Sessions") {
                Button("Save Ticket Session…") {
                    NotificationCenter.default.post(name: .saveTicketSession, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Load Ticket Session…") {
                    NotificationCenter.default.post(name: .loadTicketSession, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button("Open Sessions Folder") {
                    NotificationCenter.default.post(name: .openSessionsFolder, object: nil)
                }
            }
        }
    }
    
    // Helper function to open the mapping JSON file in VS Code
    private func openMappingFileInVSCode() {
        let url = AppPaths.orgMysqlMap
        
        // Ensure the file exists first, create empty JSON if it doesn't
        if !FileManager.default.fileExists(atPath: url.path) {
            let emptyJson = "{}"
            try? emptyJson.write(to: url, atomically: true, encoding: .utf8)
            LOG("Created empty mapping file for VS Code editing", ctx: ["path": url.path])
        }
        
        openFileInVSCode(url)
    }
    
    private func importOrgMappings() {
        runImport(
            title: "Import Orgs",
            itemName: "Org mappings",
            prompt: "Select the org_mysql_map.json file you want to import.",
            destination: AppPaths.orgMysqlMap,
            notification: .orgMappingsDidImport
        ) { data in
            let decoded = try JSONDecoder().decode(OrgMysqlMap.self, from: data)
            return decoded.count
        }
    }

    private func importHostMappings() {
        runImport(
            title: "Import Hosts",
            itemName: "MySQL host mappings",
            prompt: "Select the mysql_hosts_map.json file you want to import.",
            destination: AppPaths.mysqlHostsMap,
            notification: .mysqlHostsDidImport
        ) { data in
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(MysqlHostsMap.self, from: data)
            return decoded.count
        }
    }

    private func runImport(
        title: String,
        itemName: String,
        prompt: String,
        destination: URL,
        notification: Notification.Name,
        validate: (Data) throws -> Int
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Import"
        panel.message = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]

        let response = panel.runModal()
        guard response == .OK, let sourceURL = panel.url else {
            LOG("Import cancelled", ctx: ["item": itemName])
            return
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            let count = try validate(data)
            AppPaths.ensureAll()
            try data.write(to: destination, options: [.atomic])
            NotificationCenter.default.post(name: notification, object: nil)
            LOG("\(itemName) import succeeded", ctx: ["source": sourceURL.lastPathComponent, "count": "\(count)"])
            presentAlert(
                title: "\(itemName) Imported",
                message: "Replaced \(destination.lastPathComponent) with \(sourceURL.lastPathComponent). Entries: \(count)."
            )
        } catch {
            NSSound.beep()
            WARN("\(itemName) import failed", ctx: ["error": error.localizedDescription])
            presentAlert(
                title: "\(itemName) Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Helper function to open the MySQL hosts mapping file in VS Code
    private func openHostMappingFileInVSCode() {
        let url = AppPaths.mysqlHostsMap
        openFileInVSCode(url)
        LOG("Opening MySQL hosts mapping file", ctx: ["file": url.lastPathComponent])
    }
    
    // Shared VS Code opening logic
    private func openFileInVSCode(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true

        // Prefer stable VS Code
        let stable = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
        // Fallback to Insiders build if present
        let insiders = URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")

        let fm = FileManager.default

        let openWithApp: (URL) -> Void = { appURL in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, err in
                if let err = err {
                    // Final fallback: system default app
                    NSWorkspace.shared.open(url)
                    LOG("VSCode open fallback via default app", ctx: ["file": url.lastPathComponent, "error": err.localizedDescription])
                } else {
                    LOG("Open file in VSCode via NSWorkspace", ctx: ["file": url.lastPathComponent])
                }
            }
        }

        if fm.fileExists(atPath: stable.path) {
            openWithApp(stable)
            return
        }
        if fm.fileExists(atPath: insiders.path) {
            openWithApp(insiders)
            return
        }

        // If neither app bundle exists, try generic `open -a` as a best-effort
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["open", "-a", "Visual Studio Code", url.path]
        do {
            try task.run()
            LOG("Open file in VSCode via shell fallback", ctx: ["file": url.lastPathComponent])
        } catch {
            // Final fallback: default app
            NSWorkspace.shared.open(url)
            LOG("Open file in default app (VSCode not found)", ctx: ["file": url.lastPathComponent, "error": error.localizedDescription])
        }
    }
}

extension Notification.Name {
    static let fontBump = Notification.Name("FontBump")
    static let showDatabaseSettings = Notification.Name("ShowDatabaseSettings")
    static let saveTicketSession = Notification.Name("SaveTicketSession")
    static let loadTicketSession = Notification.Name("LoadTicketSession")
    static let openSessionsFolder = Notification.Name("OpenSessionsFolder")
    static let orgMappingsDidImport = Notification.Name("OrgMappingsDidImport")
    static let mysqlHostsDidImport = Notification.Name("MysqlHostsDidImport")
    static let importQueryTemplatesRequested = Notification.Name("ImportQueryTemplatesRequested")
    static let restoreQueryTemplateRequested = Notification.Name("RestoreQueryTemplateRequested")
    static let restoreQueryBackupsRequested = Notification.Name("RestoreQueryBackupsRequested")
    static let queriesBackedUp = Notification.Name("QueriesBackedUp")
    static let focusSearchRequested = Notification.Name("FocusSearchRequested")
    static let showGuideNotesRequested = Notification.Name("ShowGuideNotesRequested")
    static let showSessionNotesRequested = Notification.Name("ShowSessionNotesRequested")
    static let showSavedFilesRequested = Notification.Name("ShowSavedFilesRequested")
    static let toggleSidebarRequested = Notification.Name("ToggleSidebarRequested")
}
