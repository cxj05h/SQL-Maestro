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
        }

        CommandMenu("View") {
            Button("Increase Font (⌘+)") {
                NotificationCenter.default.post(name: .fontBump, object: 1)
            }.keyboardShortcut("+", modifiers: [.command])

            Button("Decrease Font (⌘−)") {
                NotificationCenter.default.post(name: .fontBump, object: -1)
            }.keyboardShortcut("-", modifiers: [.command])
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
                    LOG("Open mapping file in VSCode via NSWorkspace", ctx: ["file": url.lastPathComponent])
                }
            }
        }

        if fm.fileExists(atPath: stable.path) {
            openWithApp(stable)
            LOG("Opening mapping file in VS Code (stable)", ctx: ["file": url.lastPathComponent])
            return
        }
        if fm.fileExists(atPath: insiders.path) {
            openWithApp(insiders)
            LOG("Opening mapping file in VS Code (insiders)", ctx: ["file": url.lastPathComponent])
            return
        }

        // If neither app bundle exists, try generic `open -a` as a best-effort
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["open", "-a", "Visual Studio Code", url.path]
        do {
            try task.run()
            LOG("Open mapping file in VSCode via shell fallback", ctx: ["file": url.lastPathComponent])
        } catch {
            // Final fallback: default app
            NSWorkspace.shared.open(url)
            LOG("Open mapping file in default app (VSCode not found)", ctx: ["file": url.lastPathComponent, "error": error.localizedDescription])
        }
    }
}

extension Notification.Name {
    static let fontBump = Notification.Name("FontBump")
}
