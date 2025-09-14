import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - Temporary Shims (compile-time stand-ins)

/// Minimal Keyboard Shortcuts viewer so the sheet compiles.
struct KeyboardShortcutsSheet: View {
    let onClose: () -> Void
    @ObservedObject private var registry = ShortcutRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            if registry.items.isEmpty {
                Text("No shortcuts registered yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(registry.items) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.scope).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.display).monospaced()
                    }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 280)
    }
}

/// Lightweight numeric wheel field replacement used by the Date row.
/// Supports integer editing within a range; includes a Stepper.
struct WheelNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let width: CGFloat
    let label: String
    let sensitivity: Double
    var onReturn: () -> Void = {}
    var onTabToApply: (() -> Void)? = nil

    private let formatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.allowsFloats = false
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 0
        return nf
    }()

    var body: some View {
        HStack(spacing: 6) {
            TextField(label, value: $value, formatter: formatter)
                .frame(width: width)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    clamp()
                    onReturn()
                }
                // Focus traversal hint for Tab -> Apply (no-op if nil)
                .onExitCommand {
                    onTabToApply?()
                }

            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
        .onChange(of: value) { _, _ in clamp() }
    }

    private func clamp() {
        if value < range.lowerBound { value = range.lowerBound }
        if value > range.upperBound { value = range.upperBound }
    }
}

// Satisfy references used by the scroll-wheel redirection logic.
extension WheelNumberField {
    final class WheelTextField {
        static var focusedInstance: WheelTextField?
        var onScrollDelta: ((CGFloat, Bool) -> Void)?
    }
}

/// Minimal stub that opens the template file in the default editor.
/// Replaced by the full-featured editor when that file is linked.
enum TemplateEditorWindow {
    static func present(for t: TemplateItem, manager: TemplateManager) {
        NSWorkspace.shared.open(t.url)
        LOG("TemplateEditorWindow shim invoked", ctx: ["file": t.url.lastPathComponent])
    }
}

private extension Notification.Name {
    static let wheelFieldDidFocus = Notification.Name("WheelFieldDidFocus")
}

extension Notification.Name {
    static let showKeyboardShortcuts = Notification.Name("ShowKeyboardShortcuts")
    // `showDatabaseSettings` is declared elsewhere to avoid duplicate symbol errors.
}

// Central registry for keyboard shortcuts used across the app
final class ShortcutRegistry: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let name: String
        let keyLabel: String
        let modifiers: EventModifiers
        let scope: String
        var display: String {
            ShortcutRegistry.format(keyLabel: keyLabel, modifiers: modifiers)
        }
    }

    static let shared = ShortcutRegistry()
    @Published private(set) var items: [Item] = []

    func register(name: String, keyLabel: String, modifiers: EventModifiers, scope: String) {
        let candidate = Item(name: name, keyLabel: keyLabel, modifiers: modifiers, scope: scope)
        // Avoid duplicates by full identity
        if !items.contains(where: { $0.name == candidate.name && $0.keyLabel == candidate.keyLabel && $0.modifiers == candidate.modifiers && $0.scope == candidate.scope }) {
            items.append(candidate)
            items.sort { (a, b) in
                if a.scope == b.scope {
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                return a.scope.localizedCaseInsensitiveCompare(b.scope) == .orderedAscending
            }
            LOG("Shortcut registered", ctx: ["name": name, "combo": candidate.display, "scope": scope])
        }
    }

    static func format(keyLabel: String, modifiers: EventModifiers) -> String {
        var parts = ""
        if modifiers.contains(.command) { parts += "⌘" }
        if modifiers.contains(.option)  { parts += "⌥" }
        if modifiers.contains(.shift)   { parts += "⇧" }
        if modifiers.contains(.control) { parts += "⌃" }
        return parts + keyLabel.uppercased()
    }
}

// View helper to auto-register a shortcut in the global registry
fileprivate extension View {
    /// Register using a visible key label (e.g. "K", "/", "1")
    func registerShortcut(name: String, keyLabel: String, modifiers: EventModifiers, scope: String) -> some View {
        self.onAppear {
            ShortcutRegistry.shared.register(name: name, keyLabel: keyLabel, modifiers: modifiers, scope: scope)
        }
    }
    /// Convenience overload that extracts a label from a KeyEquivalent when possible.
    func registerShortcut(name: String, key: KeyEquivalent, modifiers: EventModifiers, scope: String) -> some View {
        let label: String
        switch key {
        case .return: label = "↩"
        case .escape: label = "⎋"
        case .tab:    label = "⇥"
        case .space:  label = "Space"
        case .delete: label = "⌫"
        default:
            let desc = String(describing: key)
            if desc.count == 1 {
                label = desc.uppercased()
            } else {
                // Fallback — still usable in the list, though not symbolic
                label = desc.uppercased()
            }
        }
        return registerShortcut(name: name, keyLabel: label, modifiers: modifiers, scope: scope)
    }
}

// Runtime Help menu item that opens the Keyboard Shortcuts sheet
private final class MenuBridge: NSObject {
    static let shared = MenuBridge()
    private static var installed = false

    @objc func showShortcuts(_ sender: Any?) {
        NotificationCenter.default.post(name: .showKeyboardShortcuts, object: nil)
    }

    static func installHelpMenuItem() {
        guard !installed else { return }
        guard let mainMenu = NSApp.mainMenu else {
            LOG("Help menu install aborted: mainMenu is nil")
            return
        }

        // Prefer the app's helpMenu if already set
        var submenu: NSMenu? = NSApp.helpMenu

        // Try to find an existing top-level "Help" item if helpMenu isn't set yet
        if submenu == nil {
            if let helpItem = mainMenu.items.first(where: { $0.title == "Help" }),
               let found = helpItem.submenu {
                submenu = found
                NSApp.helpMenu = found
            }
        }

        // Create a Help menu if still missing (some SwiftUI setups don't create one)
        if submenu == nil {
            let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
            let helpSub = NSMenu(title: "Help")
            helpItem.submenu = helpSub
            mainMenu.addItem(helpItem)
            NSApp.helpMenu = helpSub
            submenu = helpSub
            LOG("Help menu created")
        }

        guard let helpMenu = submenu else {
            LOG("Help menu install failed: no submenu available")
            return
        }

        // Avoid duplicates
        if !helpMenu.items.contains(where: { $0.title == "Keyboard Shortcuts…" }) {
            helpMenu.addItem(.separator())
            let item = NSMenuItem(title: "Keyboard Shortcuts…",
                                  action: #selector(MenuBridge.shared.showShortcuts(_:)),
                                  keyEquivalent: "")
            item.target = MenuBridge.shared
            helpMenu.addItem(item)
            installed = true
            LOG("Help menu: Keyboard Shortcuts… added")
        } else {
            installed = true
            LOG("Help menu: Keyboard Shortcuts… already present")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var templates: TemplateManager
    @StateObject private var mapping = MappingStore()
    @StateObject private var mysqlHosts = MysqlHostStore()
    @StateObject private var userConfig = UserConfigStore()
    @EnvironmentObject var sessions: SessionManager
    
    @State private var selectedTemplate: TemplateItem?
    @State private var currentSQL: String = ""
    @State private var populatedSQL: String = ""
    @State private var toastCopied: Bool = false
    @State private var toastOpenDB: Bool = false
    @State private var fontSize: CGFloat = 13
    @State private var hoverRecentKey: String? = nil
    
    @State private var searchText: String = ""
    @State private var showShortcutsSheet: Bool = false
    @State private var showDatabaseSettings: Bool = false
    @State private var showTemplateEditor: Bool = false // (no longer controls presentation)
    @State private var editorTemplate: TemplateItem? = nil
    @State private var editorText: String = ""

    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    
    // Track static fields per session - but now using SessionManager for global cache too
    @State private var sessionStaticFields: [TicketSession: (orgId: String, acctId: String, mysqlDb: String, company: String)] = [
        .one: ("", "", "", ""),
        .two: ("", "", "", ""),
        .three: ("", "", "", "")
    ]
    // Static fields are now session-aware and track global cache
    @State private var orgId: String = ""
    @State private var acctId: String = ""
    @State private var mysqlDb: String = ""
    @State private var companyLabel: String = ""
    @State private var draftDynamicValues: [TicketSession:[String:String]] = [:]
    @State private var sessionSelectedTemplate: [TicketSession: UUID] = [:]
    @State private var openRecentsKey: String? = nil
    @State private var showScrollSettings: Bool = false
    @AppStorage("dateScrollSensitivity") private var dateScrollSensitivity: Double = 1.0  // 0.5 (slower) … 3.0 (faster)
    @State private var dateFocusScrollMode: Bool = false
    @State private var scrollMonitor: Any? = nil

    // Date picker working components
    @State private var dpYear: Int = Calendar.current.component(.year, from: Date())
    @State private var dpMonth: Int = Calendar.current.component(.month, from: Date())
    @State private var dpDay: Int = Calendar.current.component(.day, from: Date())
    @State private var dpHour: Int = Calendar.current.component(.hour, from: Date())
    @State private var dpMinute: Int = Calendar.current.component(.minute, from: Date())
    @State private var dpSecond: Int = Calendar.current.component(.second, from: Date())

    var body: some View {
        NavigationSplitView {
            // Query Templates Pane
            VStack(spacing: 8) {
                // Header with buttons
                HStack(spacing: 8) {
                    Text("Query Templates")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    Spacer()
                    Button("New Template") { createNewTemplateFlow() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize))
                    Button("Reload") { templates.loadTemplates() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .font(.system(size: fontSize))
                }
                
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: fontSize))
                    TextField("Search templates...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: fontSize))
                        .focused($isSearchFocused)
                        .onTapGesture {
                            LOG("Template search focused")
                        }
                        .onChange(of: searchText) { oldVal, newVal in
                            LOG("Template search", ctx: ["query": newVal, "results": "\(filteredTemplates.count)"])
                        }
                        .onKeyPress(.return) {
                            if !filteredTemplates.isEmpty {
                                if selectedTemplate == nil {
                                    selectedTemplate = filteredTemplates.first
                                }
                                isSearchFocused = false
                                isListFocused = true
                                LOG("Focus transferred from search to list", ctx: ["selectedTemplate": selectedTemplate?.name ?? "none"])
                            }
                            return .handled
                        }
                    if !searchText.isEmpty {
                        Button("Clear") {
                            searchText = ""
                            selectedTemplate = nil
                            isSearchFocused = true
                            LOG("Template search cleared")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.pink)
                        .font(.system(size: fontSize))
                    }
                }
                .contextMenu {
                    if let sel = selectedTemplate {
                        Button("Open JSON") { openTemplateJSON(sel) }
                        Button("Show in Finder") { revealTemplateInFinder(sel) }
                        Divider()
                        Button(role: .destructive) { deleteTemplateFlow(sel) } label: {
                            Text("Delete Selected Template…")
                        }
                    } else {
                        Text("No template selected").foregroundStyle(.secondary)
                    }
                }
                
                // Template List
                List(filteredTemplates, selection: $selectedTemplate) { template in
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(selectedTemplate?.id == template.id ? .white : Theme.gold.opacity(0.6))
                            .font(.system(size: fontSize + 1))
                        
                        Text(template.name)
                            .font(.system(size: fontSize, weight: selectedTemplate?.id == template.id ? .medium : .regular))
                            .foregroundStyle(selectedTemplate?.id == template.id ? .white : .primary)
                        
                        Spacer()
                        
                        if !template.placeholders.isEmpty {
                            Text("\(template.placeholders.count)")
                                .font(.system(size: fontSize - 3))
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(selectedTemplate?.id == template.id ? .white.opacity(0.3) : Theme.gold.opacity(0.15))
                                .foregroundStyle(selectedTemplate?.id == template.id ? .white : Theme.gold)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTemplate?.id == template.id ? Theme.purple.opacity(0.1) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedTemplate?.id == template.id ? Theme.purple.opacity(0.3) : Color.clear, lineWidth: 1.5)
                            )
                    )
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Open in VS Code") { openInVSCode(template.url) }
                        Button("Edit in App") { editTemplateInline(template) }

                        Button("Open JSON") { openTemplateJSON(template) }
                        Button("Show in Finder") { revealTemplateInFinder(template) }

                        Divider()
                        Button("Rename…") { renameTemplateFlow(template) }

                        Divider()
                        Button(role: .destructive) { deleteTemplateFlow(template) } label: {
                            Text("Delete Template…")
                        }
                    }
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded {
                            editTemplateInline(template)
                        }
                    )
                    .onTapGesture {
                        selectTemplate(template)
                        LOG("Template selected", ctx: ["template": template.name])
                    }
                }
                .animation(nil, value: selectedTemplate?.id)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    if !filteredTemplates.isEmpty {
                        if selectedTemplate == nil {
                            selectTemplate(filteredTemplates.first)
                        }
                        if let selected = selectedTemplate {
                            loadTemplate(selected)
                            LOG("Template loaded via Enter key", ctx: ["template": selected.name])
                            return .handled
                        }
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    navigateTemplate(direction: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    navigateTemplate(direction: 1)
                    return .handled
                }
                .focused($isListFocused)
                
                if !searchText.isEmpty {
                    Text("\(filteredTemplates.count) of \(templates.templates.count) templates")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Theme.grayBG)
        } detail: {
            // Right side: Fields + Output
            VStack(spacing: 12) {
                // Session and Template Info Header
                VStack(spacing: 8) {
                    HStack {
                        // Session info
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Session")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                            Text(sessions.sessionNames[sessions.current] ?? "#\(sessions.current.rawValue)")
                                .font(.system(size: fontSize + 3, weight: .semibold))
                                .foregroundStyle(Theme.purple)
                        }
                        
                        Spacer()
                        
                        // Company info (center)
                        if !companyLabel.isEmpty {
                            VStack(alignment: .center, spacing: 4) {
                                Text("Company")
                                    .font(.system(size: fontSize - 2))
                                    .foregroundStyle(.secondary)
                                Text(companyLabel)
                                    .font(.system(size: fontSize + 3, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                        } else {
                            // Empty spacer to maintain balance when no company
                            VStack(alignment: .center) {
                                Text(" ")
                                    .font(.system(size: fontSize - 2))
                                Text(" ")
                                    .font(.system(size: fontSize + 3))
                            }
                        }
                        
                        Spacer()
                        
                        // Active Template info (right)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Active Template")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                            Text(selectedTemplate?.name ?? "No template loaded")
                                .font(.system(size: fontSize + 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.grayBG.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.purple.opacity(0.2), lineWidth: 1)
                            )
                    )
                }
                
                Divider()
                
                staticFields
                Divider()
                dynamicFields
                
                ZStack {
                    // Left-aligned action buttons row
                    HStack {
                        Button("Populate Query") { populateQuery() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.pink)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .font(.system(size: fontSize))
                            .registerShortcut(name: "Populate Query", key: .return, modifiers: [.command], scope: "Global")
                        
                        Button("Clear Session #\(sessions.current.rawValue)") {
                            commitDraftsForCurrentSession()
                            sessions.clearAllFieldsForCurrentSession()
                            orgId = ""
                            acctId = ""
                            mysqlDb = ""
                            companyLabel = ""
                            draftDynamicValues[sessions.current] = [:]
                            // Clear static fields for current session
                            sessionStaticFields[sessions.current] = ("", "", "", "")
                            LOG("All fields cleared (including static)", ctx: ["session": "\(sessions.current.rawValue)"])
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent) // <- same green used for Company label
                        .keyboardShortcut("k", modifiers: [.command])
                        .font(.system(size: fontSize))
                        .registerShortcut(name: "Clear Session", keyLabel: "K", modifiers: [.command], scope: "Global")
                        
                        Spacer()
                    }
                    
                    // Centered session buttons overlay
                    sessionButtons
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                
                outputView
                
                Button("Focus Search") {
                    isSearchFocused = true
                    LOG("Search focused via keyboard shortcut")
                }
                .keyboardShortcut("f", modifiers: [.command])
                .hidden()
                .registerShortcut(name: "Search Queries", keyLabel: "F", modifiers: [.command], scope: "Global")
            }
            .padding()
            .background(Theme.grayBG)
        }
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if toastCopied {
                    Text("Copied to clipboard")
                        .font(.system(size: fontSize))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.aqua.opacity(0.9)).foregroundStyle(.black)
                        .clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if toastOpenDB {
                    Text("Opening in Querious…")
                        .font(.system(size: fontSize))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.aqua.opacity(0.9)).foregroundStyle(.black)
                        .clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 16)
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontBump)) { note in
            if let delta = note.object as? Int {
                fontSize = max(10, min(22, fontSize + CGFloat(delta)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wheelFieldDidFocus)) { _ in
            dateFocusScrollMode = true
            LOG("Date focus-scroll enabled")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showKeyboardShortcuts)) { _ in
            showShortcutsSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDatabaseSettings)) { _ in
            showDatabaseSettings = true
        }
        .sheet(isPresented: $showShortcutsSheet) {
            KeyboardShortcutsSheet(onClose: { showShortcutsSheet = false })
        }
        .sheet(isPresented: $showDatabaseSettings) {
            DatabaseSettingsSheet(userConfig: userConfig)
        }
        .sheet(item: $editorTemplate) { t in
            TemplateInlineEditorSheet(
                template: t,
                text: $editorText,
                fontSize: fontSize,
                onSave: { updated in
                    saveTemplateEdits(template: t, newText: updated)
                    editorTemplate = nil
                },
                onCancel: {
                    editorTemplate = nil
                }
            )
            .frame(minWidth: 720, minHeight: 520)
        }
     
        .onAppear {
            LOG("App started")
            // Initialize with session 1
            sessions.setCurrent(.one)
            if let tid = sessionSelectedTemplate[sessions.current],
               let found = templates.templates.first(where: { $0.id == tid }) {
                selectedTemplate = found
                currentSQL = found.rawSQL
            }
            // Install local scroll monitor to redirect wheel to focused date field while focus-scroll mode is ON
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    if dateFocusScrollMode, let tf = WheelNumberField.WheelTextField.focusedInstance {
                        tf.onScrollDelta?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                        LOG("Date wheel redirected", ctx: [
                            "deltaY": String(format: "%.2f", event.scrollingDeltaY),
                            "precise": event.hasPreciseScrollingDeltas ? "true" : "false"
                        ])
                        return nil // consume so hovered fields don't also react
                    }
                    return event
                }
            }
            // Ensure Help ▸ Keyboard Shortcuts… exists
            MenuBridge.installHelpMenuItem()
        }
        .onDisappear {
            if let m = scrollMonitor {
                NSEvent.removeMonitor(m)
                scrollMonitor = nil
                LOG("Scroll monitor removed")
            }
        }
    }

    // Commit any non-empty draft values for the CURRENT session to global history
    private func commitDraftsForCurrentSession() {
        let cur = sessions.current
        let bucket = draftDynamicValues[cur] ?? [:]
        for (ph, val) in bucket {
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sessions.setValue(trimmed, for: ph)
            LOG("Draft committed", ctx: ["session": "\(cur.rawValue)", "ph": ph, "value": trimmed])
        }
    }
    
    private var filteredTemplates: [TemplateItem] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return templates.templates
        } else {
            let query = searchText.lowercased()
            return templates.templates.filter { template in
                template.name.lowercased().contains(query)
            }
        }
    }
    
    // MARK: – Static fields (now with dropdown history)
    private var staticFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Static Info")
                .font(.system(size: fontSize + 4, weight: .semibold))
                .foregroundStyle(Theme.purple)
            HStack {
                fieldWithDropdown(
                    label: "Org-ID",
                    placeholder: "e.g., 606079893960",
                    value: $orgId,
                    historyKey: "Org-ID",
                    onCommit: { newVal in
                        // Remove all whitespace from Org-ID before saving/using it
                        let cleaned = newVal.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                        if cleaned != newVal { orgId = cleaned }
                        // Force-save the cleaned value to global cache/history
                        sessions.setValue(cleaned, for: "Org-ID")

                        // Update session cache
                        sessionStaticFields[sessions.current] = (cleaned, acctId, mysqlDb, companyLabel)

                        // Lookup mapping only on commit
                        if let m = mapping.lookup(orgId: cleaned) {
                            mysqlDb = m.mysqlDb
                            companyLabel = m.companyName ?? ""
                            sessionStaticFields[sessions.current] = (cleaned, acctId, mysqlDb, companyLabel)
                        } else {
                            companyLabel = ""
                            sessionStaticFields[sessions.current] = (cleaned, acctId, mysqlDb, "")
                        }
                        LOG("OrgID committed", ctx: ["value": cleaned])
                    }
                )
                fieldWithDropdown(
                    label: "Acct-ID",
                    placeholder: "e.g., 123456",
                    value: $acctId,
                    historyKey: "Acct-ID",
                    onCommit: { newVal in
                        sessionStaticFields[sessions.current] = (orgId, newVal, mysqlDb, companyLabel)
                        LOG("AcctID committed", ctx: ["value": newVal])
                    }
                )
                VStack(alignment: .leading) {
                    HStack {
                        fieldWithDropdown(
                            label: "MySQL DB",
                            placeholder: "e.g., mySQL04",
                            value: $mysqlDb,
                            historyKey: "MySQL-DB",
                            onCommit: { newVal in
                                // Remove all whitespace from MySQL DB before saving/using it
                                let cleaned = newVal.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                                if cleaned != newVal { mysqlDb = cleaned }
                                // Force-save the cleaned value to global cache/history
                                sessions.setValue(cleaned, for: "MySQL-DB")

                                sessionStaticFields[sessions.current] = (orgId, acctId, cleaned, companyLabel)
                                LOG("MySQL DB committed", ctx: ["value": cleaned])
                            }
                        )
                        Button("Save") {
                            saveMapping()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink) // <- same pink as Apply/Populate Query
                        .font(.system(size: fontSize))
                    }
                    Button("Connect to Database") {
                        connectToQuerious()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent) // Using the green accent color
                    .font(.system(size: fontSize))
                    .frame(maxWidth: .infinity) // Full width like you wanted
                    .disabled(orgId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
    
    // MARK: – Dynamic fields from template placeholders
    private var dynamicFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Field Names")
                .font(.system(size: fontSize + 4, weight: .semibold))
                .foregroundStyle(Theme.pink)
            if let t = selectedTemplate {
                // Better handling of case variations for static placeholders
                let staticPlaceholders = Set(["Org-ID", "Org-id", "org-id", "Acct-ID", "Acct-id", "acct-id"].map { $0.lowercased() })
                let dynamicPlaceholders = t.placeholders.filter { !staticPlaceholders.contains($0.lowercased()) }
                
                if dynamicPlaceholders.isEmpty {
                    Text("This template only uses static fields (Org-ID, Acct-ID).")
                        .foregroundStyle(.secondary)
                        .font(.system(size: fontSize))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(dynamicPlaceholders, id: \.self) { ph in
                                if ph.lowercased() == "date" {
                                    dateFieldRow("Date")
                                } else {
                                    dynamicFieldRow(ph)
                                }
                            }
                        }
                    }.frame(maxHeight: 260)
                }
            } else {
                Text("Load a template to see its fields.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: fontSize))
            }
        }
        .frame(maxWidth: 540, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: NEW: Field with dropdown component for both static and dynamic fields, with onCommit
    private func fieldWithDropdown(
        label: String,
        placeholder: String,
        value: Binding<String>,
        historyKey: String,
        onCommit: ((String) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {

                // Text field
                TextField(placeholder, text: value, onEditingChanged: { isEditing in
                    // Commit when editing ENDS (blur / click-away / tab out)
                    if !isEditing {
                        let finalVal = value.wrappedValue
                        if !finalVal.isEmpty {
                            sessions.setValue(finalVal, for: historyKey)
                            LOG("Global cache updated (commit)", ctx: ["field": label, "value": finalVal])
                        }
                        onCommit?(finalVal)
                    }
                })
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .font(.system(size: fontSize))
                .frame(maxWidth: 420)
                // NEW: Commit when user presses Enter while still in the field
                .onSubmit {
                    let finalVal = value.wrappedValue
                    if !finalVal.isEmpty {
                        sessions.setValue(finalVal, for: historyKey)
                        LOG("Global cache updated (submit)", ctx: ["field": label, "value": finalVal])
                    }
                    onCommit?(finalVal)
                }

                // Recents popover trigger
                Button {
                    openRecentsKey = historyKey
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderless)
                .help("Recent values")
                .popover(isPresented: Binding<Bool>(
                    get: { openRecentsKey == historyKey },
                    set: { show in if !show { openRecentsKey = nil } }
                )) {
                    let recents = sessions.globalRecents[historyKey] ?? []
                    VStack(alignment: .leading, spacing: 0) {
                        if recents.isEmpty {
                            Text("No recent values")
                                .padding(8)
                        } else {
                            ForEach(recents, id: \.self) { recentValue in
                                Button(action: {
                                    value.wrappedValue = recentValue
                                    LOG("Recent value selected", ctx: ["field": label, "value": recentValue])
                                    sessions.setValue(recentValue, for: historyKey)
                                    onCommit?(recentValue)
                                    openRecentsKey = nil
                                }) {
                                    HStack {
                                        Text(recentValue)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle()) // full-row click
                                    .background(hoverRecentKey == recentValue ? Color.secondary.opacity(0.12) : Color.clear) // hover highlight
                                    .onHover { inside in
                                        hoverRecentKey = inside ? recentValue : nil
                                    }
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(width: 260)
                }
            }
        }
    }
    
    private func openTemplateJSON(_ item: TemplateItem) {
        let ext = item.url.pathExtension.lowercased()
        if ext == "json" {
            NSWorkspace.shared.open(item.url)
            LOG("Open JSON", ctx: ["file": item.url.lastPathComponent])
        } else {
            // For .sql files, prefer in-app editor
            editTemplateInline(item)
        }
    }

    private func revealTemplateInFinder(_ item: TemplateItem) {
        // Highlights the file in Finder
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
        LOG("Reveal in Finder", ctx: ["file": item.url.lastPathComponent])
    }

    private func deleteTemplateFlow(_ item: TemplateItem) {
        let alert = NSAlert()
        alert.messageText = "Delete Template"
        alert.informativeText = "Are you sure you want to delete \(item.name)? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                // Delete the file from disk
                try FileManager.default.removeItem(at: item.url)
                LOG("Template file removed", ctx: ["file": item.url.path])

                // Clear selection if we just deleted the selected item
                if selectedTemplate?.id == item.id {
                    selectedTemplate = nil
                }

                // Remove session memory pointing to this template
                for s in TicketSession.allCases {
                    if sessionSelectedTemplate[s] == item.id {
                        sessionSelectedTemplate[s] = nil
                    }
                }

                // Reload templates from disk
                templates.loadTemplates()
                LOG("Template deleted", ctx: ["template": item.name])
            } catch {
                NSSound.beep()
                showAlert(title: "Error", message: "Failed to delete template: \(error.localizedDescription)")
                LOG("Delete template failed", ctx: ["error": error.localizedDescription])
            }
        }
    }
    private func navigateTemplate(direction: Int) {
        guard !filteredTemplates.isEmpty else { return }
        
        if let currentIndex = filteredTemplates.firstIndex(where: { $0.id == selectedTemplate?.id }) {
            let newIndex = currentIndex + direction
            if newIndex >= 0 && newIndex < filteredTemplates.count {
                selectTemplate(filteredTemplates[newIndex])
                LOG("Template navigation", ctx: ["direction": "\(direction)", "template": filteredTemplates[newIndex].name])
            }
        } else {
            selectTemplate(direction > 0 ? filteredTemplates.first : filteredTemplates.last)
            LOG("Template navigation start", ctx: ["template": selectedTemplate?.name ?? "none"])
        }
    }
    
    private func dynamicFieldRow(_ placeholder: String) -> some View {
        let currentSession = sessions.current
        let valBinding = Binding<String>(
            get: {
                (draftDynamicValues[currentSession]?[placeholder]) ?? sessions.value(for: placeholder)
            },
            set: { newVal in
                var bucket = draftDynamicValues[currentSession] ?? [:]
                bucket[placeholder] = newVal
                draftDynamicValues[currentSession] = bucket
            }
        )
        return fieldWithDropdown(
            label: placeholder,
            placeholder: "Value for \(placeholder)",
            value: valBinding,
            historyKey: placeholder,
            onCommit: { finalVal in
                // Write-through to global cache ONLY when the user leaves the field
                sessions.setValue(finalVal, for: placeholder)
                LOG("Dynamic field committed", ctx: ["ph": placeholder, "value": finalVal])
            }
        )
    }

    @FocusState private var applyButtonFocused: Bool
    // MARK: NEW — Date field row specialized UI for {{Date}} with inline "wheel" spinners (no popovers)
    private func dateFieldRow(_ placeholder: String) -> some View {
        let currentSession = sessions.current
        let valBinding = Binding<String>(
            get: {
                (draftDynamicValues[currentSession]?[placeholder]) ?? sessions.value(for: placeholder)
            },
            set: { newVal in
                var bucket = draftDynamicValues[currentSession] ?? [:]
                bucket[placeholder] = newVal
                draftDynamicValues[currentSession] = bucket
            }
        )

        // Prefill components from current value (or "now") when this row appears
        let _ = {
            prefillDateComponents(from: valBinding.wrappedValue)
        }()

        return VStack(alignment: .leading, spacing: 4) {
            Text(placeholder)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)

            // Row: value field + inline "wheel" controls + Apply
            HStack(spacing: 8) {
                // The visible text field showing the formatted date string
                TextField("YYYY-MM-DD HH:MM:SS", text: valBinding, onEditingChanged: { isEditing in
                    if !isEditing {
                        let finalVal = valBinding.wrappedValue
                        if !finalVal.isEmpty {
                            sessions.setValue(finalVal, for: placeholder)
                            LOG("Date field commit", ctx: ["value": finalVal])
                        }
                    }
                })
                .textFieldStyle(PlainTextFieldStyle())
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .font(.system(size: fontSize, design: .monospaced))
                .frame(minWidth: 420, maxWidth: 640)
                .layoutPriority(2)
                .onSubmit {
                    performDateApply(for: placeholder, binding: valBinding)
                }

                // Inline numeric "wheels": Year / Month / Day / Hour / Minute / Second
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: 4) {
                        Text("Year")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 72, alignment: .center)
                        WheelNumberField(value: $dpYear,   range: yearsRange(),    width: 72,  label: "YYYY", sensitivity: dateScrollSensitivity, onReturn: {
                            performDateApply(for: placeholder, binding: valBinding)
                        })
                    }
                    VStack(spacing: 4) {
                        Text("Month")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 54, alignment: .center)
                        WheelNumberField(value: $dpMonth,  range: 1...12,          width: 54,  label: "MM",   sensitivity: dateScrollSensitivity, onReturn: {
                            performDateApply(for: placeholder, binding: valBinding)
                        })
                    }
                    VStack(spacing: 4) {
                        Text("Day")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 54, alignment: .center)
                        WheelNumberField(value: $dpDay,    range: 1...daysInMonth(year: dpYear, month: dpMonth), width: 54,  label: "DD", sensitivity: dateScrollSensitivity, onReturn: {
                            performDateApply(for: placeholder, binding: valBinding)
                        })
                    }
                    Text("—")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                    VStack(spacing: 4) {
                        Text("Hour")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 54, alignment: .center)
                        WheelNumberField(value: $dpHour,   range: 0...23,          width: 54,  label: "hh", sensitivity: dateScrollSensitivity, onReturn: {
                            performDateApply(for: placeholder, binding: valBinding)
                        })
                    }
                    VStack(spacing: 4) {
                        Text("Minute")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 54, alignment: .center)
                        WheelNumberField(value: $dpMinute, range: 0...59,          width: 54,  label: "mm", sensitivity: dateScrollSensitivity, onReturn: {
                            performDateApply(for: placeholder, binding: valBinding)
                        })
                    }
                    VStack(spacing: 4) {
                        Text("Second")
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 54, alignment: .center)
                        WheelNumberField(
                            value: $dpSecond,
                            range: 0...59,
                            width: 54,
                            label: "ss",
                            sensitivity: dateScrollSensitivity,
                            onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            },
                            onTabToApply: { applyButtonFocused = true }
                        )
                    }
                    // Small settings button to tune scroll sensitivity
                    Button {
                        showScrollSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: fontSize - 1, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showScrollSettings) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scroll sensitivity")
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundStyle(Theme.purple)
                            HStack {
                                Text("Slower")
                                    .font(.system(size: fontSize - 2)).foregroundStyle(.secondary)
                                Slider(value: $dateScrollSensitivity, in: 0.5...3.0, step: 0.1)
                                Text("Faster")
                                    .font(.system(size: fontSize - 2)).foregroundStyle(.secondary)
                            }
                            Text("Controls how much wheel movement is needed for a 1-step change.")
                                .font(.system(size: fontSize - 3)).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(width: 320)
                        .onChange(of: dateScrollSensitivity) { oldVal, newVal in
                            LOG("Date scroll speed changed", ctx: ["from": String(format: "%.2f", oldVal), "to": String(format: "%.2f", newVal)])
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .frame(minHeight: 48)

                Button("Apply") {
                    performDateApply(for: placeholder, binding: valBinding)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .font(.system(size: fontSize))
                .keyboardShortcut(.defaultAction)               // allow Enter/Return to trigger Apply
                .keyboardShortcut(.return, modifiers: [.command]) // Cmd+Enter also applies
                .focusable(true)                                  // ensure it can be focused via Tab
                .focused($applyButtonFocused)
                .fixedSize(horizontal: true, vertical: false)   // <- keeps width to fit "Apply"
                .layoutPriority(3)                               // <- resists compression
            }

            // Helper hint
            Text("Tip: Use ↑/↓ or the mouse wheel to change values. Press Tab to move across fields.")
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.secondary)
        }
        .onKeyPress(.escape) {
            if dateFocusScrollMode {
                dateFocusScrollMode = false
                WheelNumberField.WheelTextField.focusedInstance = nil
                NSApp.keyWindow?.makeFirstResponder(nil)
                LOG("Date focus-scroll disabled via ESC")
                return .handled
            }
            return .ignored
        }
    }

    private func performDateApply(for placeholder: String, binding valBinding: Binding<String>) {
        let maxDay = daysInMonth(year: dpYear, month: dpMonth)
        if dpDay > maxDay { dpDay = maxDay }
        let str = formatDateString(
            year: dpYear, month: dpMonth, day: dpDay,
            hour: dpHour, minute: dpMinute, second: dpSecond
        )
        valBinding.wrappedValue = str
        sessions.setValue(str, for: placeholder)
        LOG("Date inline apply (Enter/Apply)", ctx: ["value": str])
    }

    // Helpers for date math/format/parse
    private func yearsRange() -> ClosedRange<Int> {
        let current = Calendar.current.component(.year, from: Date())
        // Generous range around current year; adjust if desired
        return (current - 30)...(current + 30)
    }

    private func daysInMonth(year: Int, month: Int) -> Int {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        let calendar = Calendar.current
        let date = calendar.date(from: comps)!
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 31
    }

    private func formatDateString(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> String {
        // Always "YYYY-MM-DD HH:MM:SS"
        String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    private func prefillDateComponents(from str: String) {
        // Try parse "YYYY-MM-DD HH:MM:SS"
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        if let d = formatter.date(from: trimmed) {
            let cal = Calendar.current
            dpYear = cal.component(.year, from: d)
            dpMonth = cal.component(.month, from: d)
            dpDay = cal.component(.day, from: d)
            dpHour = cal.component(.hour, from: d)
            dpMinute = cal.component(.minute, from: d)
            dpSecond = cal.component(.second, from: d)
        } else {
            let now = Date()
            let cal = Calendar.current
            dpYear = cal.component(.year, from: now)
            dpMonth = cal.component(.month, from: now)
            dpDay = cal.component(.day, from: now)
            dpHour = cal.component(.hour, from: now)
            dpMinute = cal.component(.minute, from: now)
            dpSecond = cal.component(.second, from: now)
        }
    }
    
    // MARK: – Output area
    private var outputView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output SQL")
                .font(.system(size: fontSize + 4, weight: .semibold))
                .foregroundStyle(Theme.aqua)
            TextEditor(text: $populatedSQL)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.aqua.opacity(0.3)))
                .disableAutocorrection(true)
                .autocorrectionDisabled(true)
                .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { _ in
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                        textView.isAutomaticQuoteSubstitutionEnabled = false
                        textView.isAutomaticDashSubstitutionEnabled = false
                        textView.isAutomaticTextReplacementEnabled = false
                    }
                }
        }
    }
    
    // Session buttons with proper functionality
    private var sessionButtons: some View {
        HStack(spacing: 12) {
            Text("Session:")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 70, alignment: .leading)
            ForEach(TicketSession.allCases, id: \.self) { s in
                Button(action: {
                    switchToSession(s)
                }) {
                    Text(sessions.sessionNames[s] ?? "#\(s.rawValue)")
                        .font(.system(size: fontSize - 1, weight: sessions.current == s ? .semibold : .regular))
                        .frame(minWidth: 60)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(sessions.current == s ? Theme.purple : Theme.purple.opacity(0.3))
                .keyboardShortcut(KeyEquivalent(Character("\(s.rawValue)")), modifiers: [.command])
                .contextMenu {
                    Button("Rename…") { promptRename(for: s) }
                    if sessions.current == s {
                        Button("Clear This Session") {
                            sessions.clearAllFieldsForCurrentSession()
                            sessionStaticFields[sessions.current] = ("", "", "", "")
                            LOG("Session cleared from context menu", ctx: ["session": "\(s.rawValue)"])
                        }
                    } else {
                        Button("Switch to This Session") {
                            switchToSession(s)
                        }
                    }
                }
            }
        }
    }
    
    // Helper to set selection and persist for current session (no draft commit here for responsiveness)
    private func selectTemplate(_ t: TemplateItem?) {
        selectedTemplate = t
        if let t = t {
            sessionSelectedTemplate[sessions.current] = t.id
        }
    }

    // MARK: – Actions
    // Function to handle session switching
    private func switchToSession(_ newSession: TicketSession) {
        guard newSession != sessions.current else { return }
        commitDraftsForCurrentSession()
        let previousSession = sessions.current
        
        // Save current session's static fields
        sessionStaticFields[sessions.current] = (orgId, acctId, mysqlDb, companyLabel)
        
        // Switch to new session
        sessions.setCurrent(newSession)
        
        // Load new session's static fields
        let staticData = sessionStaticFields[newSession] ?? ("", "", "", "")
        orgId = staticData.orgId
        acctId = staticData.acctId
        mysqlDb = staticData.mysqlDb
        companyLabel = staticData.company
        
        // Restore this session's selected template, if any
        if let tid = sessionSelectedTemplate[newSession],
           let found = templates.templates.first(where: { $0.id == tid }) {
            selectedTemplate = found
            currentSQL = found.rawSQL
        } else {
            selectedTemplate = nil
        }
        
        LOG("Session switched", ctx: ["from": "\(previousSession.rawValue)", "to": "\(newSession.rawValue)"])
    }
    
    private func loadTemplate(_ t: TemplateItem) {
        commitDraftsForCurrentSession()
        selectedTemplate = t
        currentSQL = t.rawSQL
        // Remember the template per session
        sessionSelectedTemplate[sessions.current] = t.id
        LOG("Template loaded", ctx: ["template": t.name, "phCount":"\(t.placeholders.count)"])
    }
    
    private func editTemplateInline(_ t: TemplateItem) {
        commitDraftsForCurrentSession()
        do {
            let contents = try String(contentsOf: t.url, encoding: .utf8)
            DispatchQueue.main.async {
                self.editorText = contents
                self.editorTemplate = t
                LOG("Inline editor opened", ctx: ["template": t.name, "bytes": "\(contents.utf8.count)"])
            }
        } catch {
            NSSound.beep()
            showAlert(title: "Open Failed", message: "Could not read the template file.\n\n\(error.localizedDescription)")
            LOG("Inline editor open failed", ctx: ["template": t.name, "error": error.localizedDescription])
        }
    }

    private func saveTemplateEdits(template: TemplateItem, newText: String) {
        let fm = FileManager.default
        let url = template.url
        do {
            // 1) Create a time-stamped backup BEFORE overwriting
            let original = (try? Data(contentsOf: url)) ?? Data()
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let backupsDir = appSupport
                .appendingPathComponent("SQLMaestro", isDirectory: true)
                .appendingPathComponent("backups", isDirectory: true)
            try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

            let ext = url.pathExtension.isEmpty ? "sql" : url.pathExtension
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = df.string(from: Date())
            let backupName = "\(template.name)-\(stamp).\(ext)"
            let backupURL = backupsDir.appendingPathComponent(backupName)
            try original.write(to: backupURL, options: .atomic)
            LOG("Template backup created", ctx: ["file": backupName])

            // 2) Save new contents
            try newText.data(using: .utf8)?.write(to: url, options: .atomic)
            LOG("Template saved", ctx: ["template": template.name, "bytes": "\(newText.utf8.count)"])

            // 3) Reload templates so UI reflects latest
            templates.loadTemplates()
        } catch {
            NSSound.beep()
            showAlert(title: "Save Failed", message: "Could not save changes.\n\n\(error.localizedDescription)")
            LOG("Template save failed", ctx: ["template": template.name, "error": error.localizedDescription])
        }
    }
    
    private func openInVSCode(_ url: URL) {
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
                    LOG("Open in VSCode via NSWorkspace", ctx: ["file": url.lastPathComponent])
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
            LOG("Open in VSCode via shell fallback", ctx: ["file": url.lastPathComponent])
        } catch {
            // Final fallback: default app
            NSWorkspace.shared.open(url)
            LOG("Open in default app (VSCode not found)", ctx: ["file": url.lastPathComponent, "error": error.localizedDescription])
        }
    }
    
    // Now handles case variations for static placeholders
    private func populateQuery() {
        commitDraftsForCurrentSession()
        guard let t = selectedTemplate else { return }
        var sql = t.rawSQL
        
        // Static placeholders that should always use static field values
        let staticPlaceholderMap = [
            "Org-ID": orgId,
            "Org-id": orgId,
            "org-id": orgId,
            "Acct-ID": acctId,
            "Acct-id": acctId,
            "acct-id": acctId
        ]
        
        var values: [String:String] = [:]
        for ph in t.placeholders {
            let staticValue = staticPlaceholderMap.first { key, _ in
                key.lowercased() == ph.lowercased()
            }?.value
            
            if let staticValue = staticValue {
                values[ph] = staticValue
            } else {
                values[ph] = sessions.value(for: ph)
            }
        }
        
        // Replace {{placeholder}} with values
        for (k, v) in values {
            let patterns = ["{{\(k)}}", "{{ \(k) }}", "{{\(k) }}", "{{ \(k)}"]
            for pattern in patterns {
                sql = sql.replacingOccurrences(of: pattern, with: v)
            }
        }
        
        populatedSQL = sql
        Clipboard.copy(sql)
        withAnimation { toastCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now()+1.8) {
            withAnimation { toastCopied = false }
        }
        LOG("Populate Query", ctx: ["template": t.name, "bytes":"\(sql.count)"])
        
        if let entry = mapping.lookup(orgId: orgId) {
            mysqlDb = entry.mysqlDb
            companyLabel = entry.companyName ?? ""
        }
    }
    
    private func promptRename(for s: TicketSession) {
        let alert = NSAlert()
        alert.messageText = "Rename Session #\(s.rawValue)"
        alert.informativeText = "Enter a new name"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = sessions.sessionNames[s] ?? "#\(s.rawValue)"
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            sessions.setCurrent(s)
            sessions.renameCurrent(to: input.stringValue)
        }
    }
    
    private func promptForString(title: String, message: String, defaultValue: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultValue
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        return result == .alertFirstButtonReturn ? input.stringValue : nil
    }
    
    private func createNewTemplateFlow() {
        guard let name = promptForString(title: "New Template", message: "Enter a template name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        
        do {
            let item = try templates.createTemplate(named: name)
            let edit = NSAlert()
            edit.messageText = "Edit Template"
            edit.informativeText = "Open in VS Code or edit inside the app?"
            edit.addButton(withTitle: "VS Code")
            edit.addButton(withTitle: "In App")
            edit.addButton(withTitle: "Later")
            let choice = edit.runModal()
            
            loadTemplate(item)
            
            switch choice {
            case .alertFirstButtonReturn:
                openInVSCode(item.url)
            case .alertSecondButtonReturn:
                editTemplateInline(item)
            default:
                break
            }
        } catch {
            NSSound.beep()
        }
    }
    
    private func renameTemplateFlow(_ item: TemplateItem) {
        guard let newName = promptForString(title: "Rename Template",
                                            message: "Enter a new name for '\(item.name)'",
                                            defaultValue: item.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !newName.isEmpty else { return }
        
        do {
            let renamed = try templates.renameTemplate(item, to: newName)
            if selectedTemplate?.id == item.id {
                selectTemplate(renamed)
            }
        } catch {
            NSSound.beep()
        }
    }
    
    private func saveMapping() {
        LOG("Save button clicked", ctx: ["orgId": orgId, "mysqlDb": mysqlDb])
        
        guard !orgId.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert(title: "Error", message: "Org-ID is required")
            LOG("Save mapping failed - empty Org ID")
            return
        }
        
        guard !mysqlDb.trimmingCharacters(in: .whitespaces).isEmpty else {
            showAlert(title: "Error", message: "MySQL DB is required")
            LOG("Save mapping failed - empty MySQL DB")
            return
        }

        // Disallow any whitespace in Org-ID
        if orgId.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            showAlert(title: "Error", message: "Org-ID cannot contain spaces")
            LOG("Save mapping failed - Org-ID contains spaces", ctx: ["orgId": orgId])
            return
        }
        // Disallow any whitespace in MySQL DB
        if mysqlDb.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            showAlert(title: "Error", message: "MySQL DB cannot contain spaces")
            LOG("Save mapping failed - MySQL DB contains spaces", ctx: ["mysqlDb": mysqlDb])
            return
        }
        
        if mapping.lookup(orgId: orgId) != nil {
            showAlert(
                title: "Org Already Exists",
                message: "Org ID \(orgId) already has a mapping.\n\nTo avoid editing JSON files, please use a different Org-ID or clear the fields and start over."
            )
            LOG("Save mapping failed - org already exists", ctx: ["orgId": orgId])
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Company Name Required"
        alert.informativeText = "Enter the company name for Org ID: \(orgId)\n(This field is required and cannot be left empty)"
        alert.alertStyle = .informational
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "Company name is required..."
        alert.accessoryView = input
        
        alert.addButton(withTitle: "Save Mapping")
        alert.addButton(withTitle: "Cancel")
        
        repeat {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let companyName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if companyName.isEmpty {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Company Name Required"
                    errorAlert.informativeText = "Company name cannot be empty. Please enter a company name."
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "Try Again")
                    errorAlert.runModal()
                    continue
                }
                
                do {
                    try mapping.saveIfNew(
                        orgId: orgId,
                        mysqlDb: mysqlDb,
                        companyName: companyName
                    )
                    self.prettyRewriteMappingFile()
                    
                    companyLabel = companyName
                    
                    // Update session static fields
                    sessionStaticFields[sessions.current] = (orgId, acctId, mysqlDb, companyName)
                    
                    showAlert(title: "Success", message: "Mapping saved successfully!\n\nOrg: \(orgId)\nMySQL: \(mysqlDb)\nCompany: \(companyName)")
                    
                    LOG("Mapping saved with company", ctx: [
                        "orgId": orgId,
                        "mysqlDb": mysqlDb,
                        "company": companyName
                    ])
                    return
                } catch {
                    showAlert(title: "Error", message: "Failed to save mapping: \(error.localizedDescription)")
                    LOG("Save mapping failed", ctx: ["error": error.localizedDescription])
                    return
                }
            } else {
                LOG("Save mapping cancelled")
                return
            }
        } while true
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Rewrites the org→mysql mapping JSON with pretty formatting so each entry
    // is on its own line (instead of raw string appends).
    private func prettyRewriteMappingFile() {
        let fm = FileManager.default
        do {
            // App Support inside the sandbox, e.g. .../Library/Application Support/
            let appSupport = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let fileURL = appSupport
                .appendingPathComponent("SQLMaestro")
                .appendingPathComponent("mappings")
                .appendingPathComponent("org_mysql_map.json")

            guard fm.fileExists(atPath: fileURL.path) else {
                LOG("Pretty rewrite skipped — mapping file missing", ctx: ["path": fileURL.path])
                return
            }

            let data = try Data(contentsOf: fileURL)
            let obj = try JSONSerialization.jsonObject(with: data, options: [])

            // Pretty-print (and keep keys stable if available on this macOS SDK)
            var options: JSONSerialization.WritingOptions = [.prettyPrinted]
            #if swift(>=5.0)
            if #available(macOS 10.13, *) { options.insert(.sortedKeys) }
            #endif

            var output = try JSONSerialization.data(withJSONObject: obj, options: options)

            // Ensure a trailing newline for nicer diffs / editors
            if output.last != 0x0A { output.append(0x0A) }

            try output.write(to: fileURL, options: .atomic)
            LOG("Mapping file pretty-printed", ctx: ["path": fileURL.path])
        } catch {
            LOG("Pretty rewrite failed", ctx: ["error": error.localizedDescription])
        }
    }
    
    private func connectToQuerious() {
        LOG("Connect to Database button clicked", ctx: ["orgId": orgId, "mysqlDb": mysqlDb])
        withAnimation { toastOpenDB = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toastOpenDB = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            do {
                try QueriousConnector.connect(
                    orgId: orgId,
                    mysqlDbKey: mysqlDb,
                    username: userConfig.config.mysql_username,
                    password: userConfig.config.mysql_password,
                    queriousPath: userConfig.config.querious_path
                )
            } catch {
                if let derr = error as? DBConnectError, case .missingCredentials = derr {
                    NotificationCenter.default.post(name: .showDatabaseSettings, object: nil)
                }
                showAlert(title: "Connection Error", message: error.localizedDescription)
                LOG("Connect to DB failed", ctx: ["error": error.localizedDescription])
            }
        }
    }
}

// Database Connection Settings Sheet
struct DatabaseSettingsSheet: View {
    @ObservedObject var userConfig: UserConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var fontSize: CGFloat = 13
    
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var queriousPath: String = ""
    @State private var saveError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Database Connection Settings")
                .font(.system(size: fontSize + 4, weight: .semibold))
                .foregroundStyle(Theme.purple)
            
            Text("Configure your MySQL credentials for connecting to Querious.")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("MySQL Username")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                
                TextField("e.g., chris_jones_ro", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: fontSize))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("MySQL Password")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                
                SecureField("Enter your MySQL password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: fontSize))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Querious Application Path")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
                
                HStack {
                    TextField("/Applications/Querious.app", text: $queriousPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: fontSize))
                    
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowedContentTypes = [UTType.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            queriousPath = url.path
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: fontSize))
                }
            }
            
            if let error = saveError {
                Text(error)
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.red)
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: fontSize))
                
                Spacer()
                
                Button("Save") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .font(.system(size: fontSize))
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
        .onAppear {
            loadCurrentSettings()
        }
    }
    
    private func loadCurrentSettings() {
        username = userConfig.config.mysql_username
        password = userConfig.config.mysql_password
        queriousPath = userConfig.config.querious_path
    }
    
    private func saveSettings() {
        saveError = nil
        
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let trimmedPassword = password.trimmingCharacters(in: .whitespaces)
        let trimmedPath = queriousPath.trimmingCharacters(in: .whitespaces)
        
        if trimmedUsername.isEmpty {
            saveError = "Username cannot be empty"
            return
        }
        
        if trimmedPassword.isEmpty {
            saveError = "Password cannot be empty"
            return
        }
        
        if trimmedPath.isEmpty {
            saveError = "Querious path cannot be empty"
            return
        }
        
        do {
            try userConfig.updateCredentials(
                username: trimmedUsername,
                password: trimmedPassword,
                queriousPath: trimmedPath
            )
            LOG("Database settings saved successfully")
            dismiss()
        } catch {
            saveError = "Failed to save settings: \(error.localizedDescription)"
            LOG("Database settings save failed", ctx: ["error": error.localizedDescription])
        }
    }
}

// Inline template editor sheet view
struct TemplateInlineEditorSheet: View {
    let template: TemplateItem
    @Binding var text: String
    var fontSize: CGFloat
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var localText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Editing: \(template.name)")
                        .font(.system(size: fontSize + 2, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    Text(template.url.lastPathComponent)
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .font(.system(size: fontSize))
                Button("Save") {
                    onSave(localText)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.pink)
                .keyboardShortcut(.defaultAction)                 // Return to save
                .keyboardShortcut("s", modifiers: [.command])     // ⌘S to save
                .font(.system(size: fontSize))
            }
            Divider()

            TextEditor(text: $localText)
                .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                .frame(minWidth: 620, minHeight: 380)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.purple.opacity(0.25))
                )
                .onAppear {
                    self.localText = text
                }
                .onChange(of: localText) { _, newVal in
                    // keep binding loosely in sync so external tools could read it if needed
                    self.text = newVal
                }

            Text("Tip: ⌘S to save, ⎋ to cancel")
                .font(.system(size: fontSize - 3))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .onExitCommand { onCancel() }
    }
}
