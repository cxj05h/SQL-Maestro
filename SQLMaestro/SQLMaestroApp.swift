import SwiftUI
@main
struct SQLMaestroApp: App {
    @StateObject private var templates = TemplateManager()
    @StateObject private var sessions = SessionManager()
    init() {
        AppPaths.ensureAll()
            AppPaths.copyBundledAssets() // Add this line
        _ = AppLogger.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(templates)
                .environmentObject(sessions)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SQLMaestro") {
                    AboutWindowController.shared.show()
                }
            }
            AppMenuCommands(tmpl: templates, sessions: sessions)
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts…") {
                    NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
                }
            }
        }
    }
}
