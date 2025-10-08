import SwiftUI

/// Container view that manages multiple tabs, each with its own ContentView instance
struct TabContainerView: View {
    @StateObject private var tabManager = TabManager()
    @StateObject private var exitCoordinator = AppExitCoordinator()
    @StateObject private var clipboardHistory = ClipboardHistory()
    @EnvironmentObject var templates: TemplateManager

    var body: some View {
        // Tab contents (all tabs exist, only active one visible)
        ZStack {
            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                ContentView()
                    .environmentObject(templates) // Shared template manager
                    .environmentObject(tab.sessionManager) // Per-tab session manager
                    .environmentObject(tabManager) // Tab manager for coordination
                    .environmentObject(exitCoordinator) // Exit workflow coordinator
                    .environmentObject(clipboardHistory) // Clipboard watcher shared across tabs
                    .environment(\.tabID, tab.tabIdentifier)
                    .environment(\.isActiveTab, index == tabManager.activeTabIndex)
                    .environment(\.tabContext, tab) // Pass tab context
                    .opacity(index == tabManager.activeTabIndex ? 1 : 0)
                    .allowsHitTesting(index == tabManager.activeTabIndex)
                    .id(tab.id) // Stable identity per tab
            }
        }
        .onAppear {
            LOG("TabContainerView appeared", ctx: ["tabs": "\(tabManager.tabs.count)"])
        }
        .overlay(
            // Hidden button for Cmd+N keyboard shortcut
            Button(action: {
                _ = tabManager.createNewTab()
            }) {
                EmptyView()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .frame(width: 0, height: 0)
            .buttonStyle(.plain)
            .opacity(0.0001)
            .allowsHitTesting(false)
        )
        .onReceive(NotificationCenter.default.publisher(for: .attemptAppExit)) { _ in
            exitCoordinator.beginExit(using: tabManager)
        }
    }
}
