import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppExitCoordinator: ObservableObject {
    struct Components: OptionSet {
        let rawValue: Int

        static let session = Components(rawValue: 1 << 0)
        static let links   = Components(rawValue: 1 << 1)
        static let tables  = Components(rawValue: 1 << 2)

        var descriptions: [String] {
            var lines: [String] = []
            if contains(.session) {
                lines.append("• Unsaved session data")
            }
            if contains(.links) {
                lines.append("• Template links sidecar")
            }
            if contains(.tables) {
                lines.append("• DB tables sidecar")
            }
            return lines
        }
    }

    struct SessionEntry {
        let session: TicketSession
        let sessionDisplayName: String
        let components: Components
    }

    struct Provider {
        let tabContextID: UUID
        let preflight: () -> Void
        let fetchSessions: () -> [SessionEntry]
        let focusSession: (TicketSession) -> Void
        let performSave: (TicketSession, Components) -> Bool
    }

    private struct QueueItem {
        let provider: Provider
        let tabIndex: Int
        let tabDisplayName: String
        let session: TicketSession
        let sessionDisplayName: String
        let components: Components
    }

    private var providers: [UUID: Provider] = [:]
    private var isProcessing = false

    func register(tabID: UUID, provider: Provider) {
        providers[tabID] = provider
    }

    func unregister(tabID: UUID) {
        providers.removeValue(forKey: tabID)
    }

    func beginExit(using tabManager: TabManager) {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        providers.values.forEach { $0.preflight() }

        let queue = buildQueue(using: tabManager)
        guard !queue.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        var index = 0
        while index < queue.count {
            let item = queue[index]
            guard tabManager.tabs.indices.contains(item.tabIndex) else {
                index += 1
                continue
            }

            tabManager.switchToTab(at: item.tabIndex)
            item.provider.focusSession(item.session)

            let allowSkip = index < queue.count - 1
            switch presentAlert(for: item, allowSkip: allowSkip) {
            case .save:
                if item.provider.performSave(item.session, item.components) {
                    index += 1
                }
            case .skip:
                index += 1
            case .cancel:
                return
            case .exit:
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.terminate(nil)
    }

    private enum AlertResult {
        case save
        case skip
        case cancel
        case exit
    }

    private func buildQueue(using tabManager: TabManager) -> [QueueItem] {
        guard !tabManager.tabs.isEmpty else { return [] }

        var orderedContexts: [TabContext] = []
        let count = tabManager.tabs.count
        let active = tabManager.activeTabIndex
        for offset in 0..<count {
            let index = (active + offset) % count
            orderedContexts.append(tabManager.tabs[index])
        }

        var queue: [QueueItem] = []

        for context in orderedContexts {
            guard let provider = providers[context.id],
                  let tabIndex = tabManager.tabs.firstIndex(where: { $0.id == context.id }) else {
                continue
            }

            let tabName = tabManager.displayName(for: tabIndex)
            let entries = provider.fetchSessions()

            for entry in entries {
                queue.append(QueueItem(provider: provider,
                                       tabIndex: tabIndex,
                                       tabDisplayName: tabName,
                                       session: entry.session,
                                       sessionDisplayName: entry.sessionDisplayName,
                                       components: entry.components))
            }
        }

        return queue
    }

    private func presentAlert(for item: QueueItem, allowSkip: Bool) -> AlertResult {
        let alert = NSAlert()
        alert.messageText = "\(item.tabDisplayName): \(item.sessionDisplayName) has unsaved items"

        var body: [String] = []
        body.append("Resolve these before exiting:")
        body.append(contentsOf: item.components.descriptions)
        body.append("")
        if allowSkip {
            body.append("Save keeps the changes, Skip moves to the next unsaved session, Cancel stops quitting, Exit quits without saving.")
        } else {
            body.append("Save keeps the changes, Cancel stops quitting, Exit quits without saving.")
        }

        alert.informativeText = body.joined(separator: "\n")
        alert.alertStyle = .warning

        var actions: [(title: String, result: AlertResult)] = []
        actions.append(("Save", .save))
        if allowSkip {
            actions.append(("Skip", .skip))
        }
        actions.append(("Cancel", .cancel))
        actions.append(("Exit", .exit))

        for action in actions {
            alert.addButton(withTitle: action.title)
        }

        let response = runAlertWithFix(alert)
        let index = Int(response.rawValue) - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard index >= 0 && index < actions.count else { return .cancel }
        return actions[index].result
    }

    private func runAlertWithFix(_ alert: NSAlert) -> NSApplication.ModalResponse {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            for button in alert.buttons where button.keyEquivalent == "\r" {
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                button.layer?.cornerRadius = 6
                button.layer?.borderWidth = 0

                let title = button.title
                let attrTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: NSColor.white
                ])
                button.attributedTitle = attrTitle
                button.needsDisplay = true
                button.layer?.setNeedsDisplay()
            }
            alert.window.displayIfNeeded()
        }

        return alert.runModal()
    }
}
