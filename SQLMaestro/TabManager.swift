import Foundation
import SwiftUI

/// Manages multiple tab contexts with a maximum of 2 tabs
@MainActor
final class TabManager: ObservableObject {
    static let maxTabs = 2

    @Published private(set) var tabs: [TabContext] = []
    @Published var activeTabIndex: Int = 0
    @Published private(set) var lastTemplateReload: Date = Date()

    var activeTab: TabContext {
        tabs[activeTabIndex]
    }

    init() {
        // Start with one tab
        createNewTab()
    }

    /// Notify that templates were reloaded
    func notifyTemplateReload() {
        lastTemplateReload = Date()
        LOG("Template reload notification", ctx: ["timestamp": "\(lastTemplateReload)"])
    }

    /// Creates a new tab if under the limit
    @discardableResult
    func createNewTab() -> Bool {
        guard tabs.count < Self.maxTabs else {
            LOG("Cannot create new tab", ctx: ["reason": "max tabs reached", "max": "\(Self.maxTabs)"])
            return false
        }

        let newTab = TabContext()
        tabs.append(newTab)
        activeTabIndex = tabs.count - 1

        LOG("Tab created", ctx: [
            "tabId": newTab.id.uuidString,
            "tabIdentifier": newTab.tabIdentifier,
            "totalTabs": "\(tabs.count)"
        ])

        return true
    }

    /// Switches to a specific tab index
    func switchToTab(at index: Int) {
        guard index >= 0 && index < tabs.count else {
            LOG("Invalid tab index", ctx: ["index": "\(index)", "totalTabs": "\(tabs.count)"])
            return
        }

        activeTabIndex = index
        LOG("Tab switched", ctx: [
            "index": "\(index)",
            "tabId": tabs[index].id.uuidString
        ])
    }

    /// Closes a tab at the specified index
    func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        guard tabs.count > 1 else {
            LOG("Cannot close last tab")
            return
        }

        let removedTab = tabs.remove(at: index)

        // Cleanup: remove session images from disk
        cleanupSessionImages(for: removedTab)

        // Adjust active index if needed
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }

        LOG("Tab closed", ctx: [
            "tabId": removedTab.id.uuidString,
            "remainingTabs": "\(tabs.count)"
        ])
    }

    /// Cleanup session images for a closed tab
    private func cleanupSessionImages(for tab: TabContext) {
        let fm = FileManager.default
        let sessionImages = tab.sessionManager.sessionImages

        for (_, images) in sessionImages {
            for image in images {
                let imageURL = AppPaths.sessionImages.appendingPathComponent(image.fileName)
                try? fm.removeItem(at: imageURL)
            }
        }

        LOG("Tab session images cleaned", ctx: ["tabId": tab.id.uuidString])
    }

    /// Returns a display name for a tab
    func displayName(for index: Int) -> String {
        "SQL Maestro \(index + 1)"
    }

    /// Returns a color for a tab (blue for tab 1, green for tab 2)
    func color(for index: Int) -> Color {
        switch index {
        case 0: return .blue
        case 1: return .green
        default: return .gray
        }
    }
}
