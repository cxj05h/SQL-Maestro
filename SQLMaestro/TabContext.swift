import Foundation
import SwiftUI

/// Represents a single tab instance with its own session manager and unique identifier
/// Note: TemplateManager is shared across all tabs, only SessionManager is per-tab
@MainActor
final class TabContext: ObservableObject, Identifiable {
    let id: UUID
    let sessionManager: SessionManager
    var lastTemplateReload: Date = Date()

    init(id: UUID = UUID()) {
        self.id = id
        self.sessionManager = SessionManager()
    }

    /// Returns the tab identifier for file naming (e.g., session images)
    var tabIdentifier: String {
        // Use first 8 characters of UUID for brevity
        String(id.uuidString.prefix(8))
    }

    /// Mark that this tab has seen the latest template reload
    func markTemplateReloadSeen() {
        lastTemplateReload = Date()
    }
}

/// Environment key to pass tab ID down to ContentView
struct TabIDKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var tabID: String {
        get { self[TabIDKey.self] }
        set { self[TabIDKey.self] = newValue }
    }
}

/// Environment key to indicate if this is the active tab
struct IsActiveTabKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var isActiveTab: Bool {
        get { self[IsActiveTabKey.self] }
        set { self[IsActiveTabKey.self] = newValue }
    }
}

/// Environment key to pass the TabContext
struct TabContextKey: EnvironmentKey {
    static let defaultValue: TabContext? = nil
}

extension EnvironmentValues {
    var tabContext: TabContext? {
        get { self[TabContextKey.self] }
        set { self[TabContextKey.self] = newValue }
    }
}
