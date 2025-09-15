import SwiftUI

struct AppMenuCommands: Commands {
    @Environment(\.openURL) private var openURL
    @ObservedObject var tmpl: TemplateManager
    @ObservedObject var sessions: SessionManager

    @State private var fontScale: Double = 1.0

    var body: some Commands {
        CommandMenu("Queries") {
            Button("Backup Queries") {
                do {
                    let url = try tmpl.zipAllTemplates()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    NSSound.beep()
                }
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
}
