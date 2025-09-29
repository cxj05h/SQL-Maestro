import SwiftUI
import AppKit
import Carbon

final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    private init() {}

    func registerBeginShortcut(handler: @escaping () -> Void) {
        unregisterCurrentShortcut()
        self.handler = handler

        var localHotKeyRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID(signature: OSType(UInt32(truncatingIfNeeded: "SQLB".fourCharCodeValue)),
                                     id: 1)

        let modifiers: UInt32 = UInt32(controlKey) | UInt32(shiftKey)
        let keyCode: UInt32 = UInt32(kVK_ANSI_B)

        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &localHotKeyRef)

        guard status == noErr, let hotKey = localHotKeyRef else {
            LOG("Global shortcut registration failed", ctx: ["status": "\(status)"])
            return
        }

        hotKeyRef = hotKey

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, eventRef, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)

            if hotKeyID.id == 1 {
                DispatchQueue.main.async {
                    GlobalShortcutManager.shared.handler?()
                }
            }

            return noErr
        }

        let installStatus = InstallEventHandler(GetEventDispatcherTarget(),
                                               callback,
                                               1,
                                               &eventSpec,
                                               nil,
                                               &eventHandlerRef)

        if installStatus != noErr {
            LOG("Global shortcut handler install failed", ctx: ["status": "\(installStatus)"])
        } else {
            LOG("Global shortcut registered", ctx: ["combo": "Ctrl+Shift+B"])
        }
    }

    func unregisterCurrentShortcut() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handlerRef = eventHandlerRef {
            RemoveEventHandler(handlerRef)
            eventHandlerRef = nil
        }
    }

    deinit {
        unregisterCurrentShortcut()
    }
}

private extension String {
    var fourCharCodeValue: UInt32 {
        var result: UInt32 = 0
        for scalar in unicodeScalars {
            result = (result << 8) + UInt32(scalar.value)
        }
        return result
    }
}
#if canImport(AppKit)
private final class MainWindowConfigurator {
    static let shared = MainWindowConfigurator()

    private var observer: NSObjectProtocol?

    func activate() {
        guard observer == nil else { return }

        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification,
                                                          object: nil,
                                                          queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.apply(to: window)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApplication.shared.windows {
                self.apply(to: window)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func apply(to window: NSWindow) {
        window.styleMask.insert([.titled, .resizable, .fullSizeContentView])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = ""
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .line

        let hasAccessory = window.titlebarAccessoryViewControllers.contains { controller in
            controller is AppTitleAccessoryViewController
        }
        if !hasAccessory {
            window.addTitlebarAccessoryViewController(AppTitleAccessoryViewController())
        }
    }
}

private final class AppTitleAccessoryViewController: NSTitlebarAccessoryViewController {
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        layoutAttribute = .leading
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let label = NSTextField(labelWithString: "SQL Maestro")
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor.labelColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            container.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        view = container
    }
}
#endif
@main
struct SQLMaestroApp: App {
    @StateObject private var templates = TemplateManager()
    @StateObject private var sessions = SessionManager()
    init() {
        AppPaths.ensureAll()
            AppPaths.copyBundledAssets() // Add this line
        _ = AppLogger.shared
#if canImport(AppKit)
        MainWindowConfigurator.shared.activate()
#endif
        GlobalShortcutManager.shared.registerBeginShortcut {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .beginQuickCaptureRequested, object: nil)
        }
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
            CommandGroup(replacing: .appTermination) {
                Button("Quit SQLMaestro") {
                    NotificationCenter.default.post(name: .attemptAppExit, object: nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
