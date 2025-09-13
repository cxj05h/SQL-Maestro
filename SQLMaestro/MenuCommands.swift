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
}

extension Notification.Name {
    static let fontBump = Notification.Name("FontBump")
}
