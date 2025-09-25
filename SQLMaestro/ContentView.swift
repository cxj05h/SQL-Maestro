import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SessionTemplateTab {
    case sessionImages
    case guideImages
    case templateLinks
}

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
    // Cocoa bridge for native key + wheel handling (NSTextField subclass)
    private struct CocoaField: NSViewRepresentable {
        @Binding var value: Int
        let range: ClosedRange<Int>
        let label: String
        let sensitivity: Double
        let onReturn: () -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        func makeNSView(context: Context) -> WheelTextField {
            let tf = WheelTextField()
            tf.isBezeled = true
            tf.bezelStyle = .roundedBezel
            tf.alignment = .center
            tf.placeholderString = label
            tf.stringValue = String(value)
            tf.isEditable = true
            tf.isSelectable = true
            tf.usesSingleLineMode = true
            tf.lineBreakMode = .byClipping
            tf.focusRingType = .default
            tf.target = context.coordinator
            tf.action = #selector(Coordinator.commitFromTextField)
            tf.delegate = context.coordinator

            tf.onAdjust = { step in
                context.coordinator.adjust(by: step)
            }
            tf.onCommitText = {
                context.coordinator.commitFromText()
            }
            tf.onReturn = {
                onReturn()
            }
            tf.onScrollDelta = { delta, precise in
                context.coordinator.handleScroll(deltaY: delta, precise: precise)
            }

            return tf
        }

        func updateNSView(_ nsView: WheelTextField, context: Context) {
            let newText = String(value)
            if nsView.stringValue != newText {
                nsView.stringValue = newText
            }
            context.coordinator.range = range
            context.coordinator.sensitivity = sensitivity
        }

        final class Coordinator: NSObject, NSTextFieldDelegate, NSControlTextEditingDelegate {
            var parent: CocoaField
            var range: ClosedRange<Int>
            var sensitivity: Double = 1.0
            private var accum: CGFloat = 0

            init(_ parent: CocoaField) {
                self.parent = parent
                self.range = parent.range
            }

            // Clamp and assign to binding
            private func setValue(_ v: Int) {
                let clamped = min(max(v, range.lowerBound), range.upperBound)
                if clamped != parent.value {
                    parent.value = clamped
                }
            }

            @objc func commitFromTextField(_ sender: Any?) {
                commitFromText()
            }

            func commitFromText() {
                // Parse current text; fallback to existing binding if invalid
                if let tf = currentTextField(),
                   let n = Int(tf.stringValue.trimmingCharacters(in: .whitespaces)) {
                    setValue(n)
                } else {
                    // keep existing value
                }
            }

            func adjust(by step: Int) {
                setValue(parent.value + step)
            }

            // Intercept arrow keys and Return from the field editor (NSTextView)
            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    adjust(by: +1)
                    LOG("Date wheel arrow", ctx: ["label": parent.label, "dir": "up"])
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    adjust(by: -1)
                    LOG("Date wheel arrow", ctx: ["label": parent.label, "dir": "down"])
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    commitFromText()
                    parent.onReturn()
                    LOG("Date wheel return", ctx: ["label": parent.label])
                    return true
                default:
                    return false
                }
            }

            func handleScroll(deltaY: CGFloat, precise: Bool) {
                // Invert so "scroll up" increases value
                let inverted = -deltaY
                // Base scale: precise devices send larger continuous deltas
                let base: CGFloat = precise ? 40.0 : 8.0
                // Treat slider as "speed": 0.5 = slower, 3.0 = faster
                let speed = max(0.5, min(3.0, CGFloat(sensitivity)))
                // Convert delta to fractional steps (higher speed → larger increments)
                let increment = (inverted * speed) / base
                accum += increment
                // Step once per whole unit; handle fast flicks (multi-steps)
                while abs(accum) >= 1.0 {
                    let step = accum > 0 ? 1 : -1
                    adjust(by: step)
                    LOG("Date wheel step", ctx: [
                        "label": parent.label,
                        "step": "\(step)",
                        "accum": String(format: "%.2f", accum),
                        "precise": precise ? "true" : "false",
                        "speed": String(format: "%.2f", Double(sensitivity))
                    ])
                    accum -= CGFloat(step)
                }
            }

            private func currentTextField() -> WheelTextField? {
                // Try the view hierarchy first (most reliable)
                if let tv = NSApp.keyWindow?.firstResponder as? WheelTextField {
                    return tv
                }
                // Fallback: use the static focusedInstance marker
                if let tf = WheelTextField.focusedInstance {
                    return tf
                }
                return nil
            }
        }
    }
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
            CocoaField(
                value: $value,
                range: range,
                label: label,
                sensitivity: sensitivity,
                onReturn: {
                    clamp()
                    onReturn()
                }
            )
            .frame(width: width)
            // Preserve Tab-to-Apply behavior
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
    // Native NSTextField subclass that exposes key + wheel events via closures.
    final class WheelTextField: NSTextField {
        static weak var focusedInstance: WheelTextField?

        var onAdjust: ((Int) -> Void)?          // +1 / -1 from arrow keys
        var onCommitText: (() -> Void)?         // Return triggers a commit
        var onReturn: (() -> Void)?             // Optional extra action on Return
        var onScrollDelta: ((CGFloat, Bool) -> Void)? // deltaY, hasPreciseScrollingDeltas

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok {
                WheelTextField.focusedInstance = self
                NotificationCenter.default.post(name: .wheelFieldDidFocus, object: nil)
            }
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            if ok, WheelTextField.focusedInstance === self {
                WheelTextField.focusedInstance = nil
            }
            return ok
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: // up
                onAdjust?(+1)
            case 125: // down
                onAdjust?(-1)
            case 36:  // return
                onCommitText?()
                onReturn?()
            default:
                super.keyDown(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            onScrollDelta?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        }
    }
}

struct MarkdownPreviewView: View {
    var text: String
    var fontSize: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownPreviewRepresentable(markdown: text, fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
    }
}

struct MarkdownPreviewRepresentable: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        updateText(in: textView)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        updateText(in: nsView)
    }

    private func updateText(in textView: NSTextView) {
        LOG("Markdown preview render", ctx: ["length": "\(markdown.count)"])
        let rendered = MarkdownEditor.renderPreview(markdown: markdown, fontSize: fontSize)
        textView.textStorage?.setAttributedString(rendered)
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
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



//MARK: Content View
struct ContentView: View {
    @EnvironmentObject var templates: TemplateManager
    @StateObject private var mapping = MappingStore()
    @StateObject private var mysqlHosts = MysqlHostStore()
    @StateObject private var userConfig = UserConfigStore()
    @State private var selectedSessionTemplateTab: SessionTemplateTab = .templateLinks
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject private var dbTablesStore = DBTablesStore.shared
    @ObservedObject private var dbTablesCatalog = DBTablesCatalog.shared
    @ObservedObject private var templateLinksStore = TemplateLinksStore.shared
    @ObservedObject private var templateGuideStore = TemplateGuideStore.shared
    @ObservedObject private var usedTemplates = UsedTemplatesStore.shared
    @State private var selectedTemplate: TemplateItem?
    @State private var currentSQL: String = ""
    @State private var populatedSQL: String = ""
    // Toasts
    @State private var toastCopied: Bool = false
    @State private var toastOpenDB: Bool = false
    @State private var toastReloaded: Bool = false

    @State private var alternateFieldsLocked: Bool = false

    @State private var fontSize: CGFloat = 13
    @State private var hoverRecentKey: String? = nil
    @State private var previewingSessionImage: SessionImage? = nil
    @State private var previewingGuideImage: TemplateGuideImage? = nil
    @State private var showTroubleshootingGuide: Bool = false
    @State private var guideNotesDraft: String = ""
    @State private var hoveredTemplateLinkID: UUID? = nil
    @State private var sessionNotesDrafts: [TicketSession: String] = [:]
    @StateObject private var sessionNotesEditor = MarkdownEditorController()
    @StateObject private var guideNotesEditor = MarkdownEditorController()
    @State private var notesPreviewMode: Bool = false
    @State private var guidePreviewMode: Bool = false
    
    @State private var searchText: String = ""
    @State private var showShortcutsSheet: Bool = false
    @State private var showDatabaseSettings: Bool = false
    @State private var showTemplateEditor: Bool = false // (no longer controls presentation)
    @State private var editorTemplate: TemplateItem? = nil
    @State private var editorText: String = ""
    
    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    @FocusState private var focusedDBTableRow: Int?
    @State private var dbTablesLocked: Bool = true
    @State private var suggestionIndexByRow: [Int: Int] = [:]
    @State private var keyEventMonitor: Any?
    
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
            // Query Templates Pane
            VStack(spacing: 8) {
                // Header with buttons
                HStack(spacing: 8) {
                    Text("Query Templates")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)
                    Spacer()
                    Button("New Template") { createNewTemplateFlow() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize))
                    Button("Reload") {
                        templates.loadTemplates()
                        withAnimation { toastReloaded = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toastReloaded = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .font(.system(size: fontSize))
                    .keyboardShortcut("r", modifiers: [.command])
                    .registerShortcut(name: "Reload Templates", keyLabel: "R", modifiers: [.command], scope: "Templates")
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
                List(filteredTemplates, id: \.id, selection: $selectedTemplate) { template in                    HStack(spacing: 8) {
                    let isUsed = UsedTemplatesStore.shared.isTemplateUsed(in: sessions.current, templateId: template.id)
                    let isSelected = selectedTemplate?.id == template.id
                    
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(
                            isSelected
                            ? (isUsed ? Theme.pink : .white)
                            : (isUsed ? Theme.pink.opacity(0.8) : Theme.gold.opacity(0.6))
                        )
                        .font(.system(size: fontSize + 1))
                    
                    // Template name
                    Text(template.name)
                        .font(.system(size: fontSize))
                        .foregroundStyle(isSelected ? .white : .primary)
                    
                    Spacer()
                    
                    // Placeholder count capsule
                    if !template.placeholders.isEmpty {
                        Text("\(template.placeholders.count)")
                            .font(.system(size: fontSize - 3))
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                isSelected
                                ? (isUsed ? Theme.pink.opacity(0.3) : .white.opacity(0.3))
                                : (isUsed ? Theme.pink.opacity(0.15) : Theme.gold.opacity(0.15))
                            )
                            .foregroundStyle(
                                isSelected
                                ? (isUsed ? Theme.pink : .white)
                                : (isUsed ? Theme.pink : Theme.gold)
                            )
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
            .frame(minWidth: 300, idealWidth: 320) // expanded by ~50px
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
                    .padding(.bottom, 8)
                Divider()
                
                // Field Names and DB Tables side by side
                HStack(alignment: .top, spacing: 20) {
                    // Left: Dynamic Fields
                    dynamicFields
                        .frame(maxWidth: 540, alignment: .leading)
                    
                    // Middle-Left: DB Tables pane
                    dbTablesPane
                        .frame(width: 360)
                    
                    // Middle-Right: Session & Template Tabbed Pane (Images + Links)
                    sessionAndTemplatePane
                        .frame(width: 320)
                    
                    // Right: Alternate Fields pane
                    alternateFieldsPane
                        .frame(width: 320)
                    
                    // Push everything to the left
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                
                ZStack {
                    // Left-aligned action buttons row
                    HStack {
                        Button("Populate Query") { populateQuery() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.pink)
                            .keyboardShortcut(.return, modifiers: [.command])
                            .font(.system(size: fontSize))
                            .registerShortcut(name: "Populate Query", key: .return, modifiers: [.command], scope: "Global")
                        
                        Button(showTroubleshootingGuide ? "Hide Guide" : "Troubleshooting Guide") {
                            if let template = selectedTemplate {
                                templateGuideStore.prepare(for: template)
                                guideNotesDraft = templateGuideStore.currentNotes(for: template)
                                withAnimation { showTroubleshootingGuide.toggle() }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .font(.system(size: fontSize))
                        .disabled(selectedTemplate == nil)
                        
                        Button("Clear Session #\(sessions.current.rawValue)") {
                            commitDraftsForCurrentSession()
                            sessions.clearAllFieldsForCurrentSession()
                            orgId = ""
                            acctId = ""
                            mysqlDb = ""
                            companyLabel = ""
                            draftDynamicValues[sessions.current] = [:]
                            sessionStaticFields[sessions.current] = ("", "", "", "")
                            sessionNotesDrafts[sessions.current] = ""
                        
                            // NEW: also clear used templates
                            UsedTemplatesStore.shared.clearSession(sessions.current)
                            
                            LOG("All fields cleared (including static + used templates)", ctx: ["session": "\(sessions.current.rawValue)"])
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.aqua)
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
                if toastReloaded {
                    Text("Templates reloaded")
                        .font(.system(size: fontSize))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.9)).foregroundStyle(.black)
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
            .frame(minWidth: 760, minHeight: 520)
        }
        
        .onAppear {
            LOG("App started")
            // Clear all sessions & used templates on launch (full reset)
            for s in TicketSession.allCases {
                sessions.clearAllFields(for: s)
                draftDynamicValues[s] = [:]
                sessionStaticFields[s] = ("", "", "", "")
                UsedTemplatesStore.shared.clearSession(s)
                sessionNotesDrafts[s] = sessions.sessionNotes[s] ?? ""
            }
            orgId = ""
            acctId = ""
            mysqlDb = ""
            companyLabel = ""

            // Reinitialize session #1 clean
            sessions.setCurrent(.one)
            selectedTemplate = nil
            currentSQL = ""

            if let t = selectedTemplate {
                _ = DBTablesStore.shared.loadSidecar(for: sessions.current, template: t)
                LOG("DBTables sidecar hydrated (onAppear)", ctx: ["template": t.name, "session": "\(sessions.current.rawValue)"])
            }

            // Install local scroll monitor …
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    if dateFocusScrollMode, let tf = WheelNumberField.WheelTextField.focusedInstance {
                        tf.onScrollDelta?(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                        LOG("Date wheel redirected (focused)", ctx: [
                            "deltaY": String(format: "%.2f", event.scrollingDeltaY),
                            "precise": event.hasPreciseScrollingDeltas ? "true" : "false"
                        ])
                        return nil
                    }
                    return event
                }
            }

            MenuBridge.installHelpMenuItem()
#if os(macOS)
            if keyEventMonitor == nil {
                keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    return handleDBSuggestKeyEvent(event)
                }
            }
#endif
        }
        .onDisappear {
#if os(macOS)
            if let m = keyEventMonitor {
                NSEvent.removeMonitor(m)
                keyEventMonitor = nil
            }
#endif
            if let m = scrollMonitor {
                NSEvent.removeMonitor(m)
                scrollMonitor = nil
                LOG("Scroll monitor removed")
            }
        }
        .onChange(of: sessions.current) { _, newSession in
            sessionNotesDrafts[newSession] = sessions.sessionNotes[newSession] ?? ""
        }
        .onReceive(sessions.$sessionNotes) { newValue in
            for session in TicketSession.allCases {
                if !isSessionNotesDirty(session: session) {
                    sessionNotesDrafts[session] = newValue[session] ?? ""
                }
            }
        }
        }
        private func renameSessionImage(_ image: SessionImage) {
            let alert = NSAlert()
            alert.messageText = "Rename Image"
            alert.informativeText = "Enter a new name for this image:"
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.stringValue = image.displayName
            input.placeholderString = "Enter image name..."
            
            alert.accessoryView = input
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    sessions.renameSessionImage(imageId: image.id, newName: newName, for: sessions.current)
                }
            }
        }
        // MARK: - Template Links Functions
        
        private func addNewLink() {
            guard let template = selectedTemplate else { return }
            
            let alert = NSAlert()
            alert.messageText = "Add New Link"
            alert.informativeText = "Enter a title and URL for this link:"
            
            let inputContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            
            let titleField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
            titleField.placeholderString = "Link title (e.g., 'Documentation')"
            
            let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            urlField.placeholderString = "https://..."
            
            inputContainer.addSubview(titleField)
            inputContainer.addSubview(urlField)
            
            alert.accessoryView = inputContainer
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !title.isEmpty, !url.isEmpty else { return }
                
                templateLinksStore.addLink(title: title, url: url, for: template)
                touchTemplateActivity(for: template)
            }
        }
        
        private func editTemplateLink(_ link: TemplateLink) {
            guard let template = selectedTemplate else { return }
            
            let alert = NSAlert()
            alert.messageText = "Edit Link"
            alert.informativeText = "Update the title and URL for this link:"
            
            let inputContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            
            let titleField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
            titleField.stringValue = link.title
            titleField.placeholderString = "Link title"
            
            let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            urlField.stringValue = link.url
            urlField.placeholderString = "https://..."
            
            inputContainer.addSubview(titleField)
            inputContainer.addSubview(urlField)
            
            alert.accessoryView = inputContainer
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                let newTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let newUrl = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !newTitle.isEmpty, !newUrl.isEmpty else { return }
                
                // Update the link in the store
                var links = templateLinksStore.links(for: template)
                if let index = links.firstIndex(where: { $0.id == link.id }) {
                    links[index] = TemplateLink(id: link.id, title: newTitle, url: newUrl)
                    templateLinksStore.setLinks(links, for: template)
                    touchTemplateActivity(for: template)
                }
            }
        }

        private func deleteTemplateLink(_ link: TemplateLink) {
            guard let template = selectedTemplate else { return }
            templateLinksStore.removeLink(withId: link.id, for: template)
            touchTemplateActivity(for: template)
        }
        
        private func openTemplateLink(_ link: TemplateLink) {
            var urlString = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Add https:// if no scheme is present
            if !urlString.contains("://") {
                urlString = "https://" + urlString
            }
            
            // Handle common typos
            urlString = urlString.replacingOccurrences(of: " ", with: "%20")
            
            guard let url = URL(string: urlString) else {
                LOG("Invalid URL format", ctx: ["title": link.title, "url": link.url])
                
                // Show error to user
                let alert = NSAlert()
                alert.messageText = "Invalid URL"
                alert.informativeText = "The URL '\(link.url)' is not valid. Please edit the link and ensure it's a proper web address."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            
            // Validate it's a web URL
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                LOG("Non-web URL rejected", ctx: ["title": link.title, "url": urlString])
                
                let alert = NSAlert()
                alert.messageText = "Unsupported URL"
                alert.informativeText = "Only web URLs (http/https) are supported."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            
            NSWorkspace.shared.open(url)
            LOG("Opened template link", ctx: ["title": link.title, "originalUrl": link.url, "finalUrl": urlString])
        }

        private func deleteSessionImage(_ image: SessionImage) {
            // Remove from file system
            let imageURL = AppPaths.sessionImages.appendingPathComponent(image.fileName)
            try? FileManager.default.removeItem(at: imageURL)
            
            // Remove from session manager
            var images = sessions.sessionImages[sessions.current] ?? []
            images.removeAll { $0.id == image.id }
            sessions.sessionImages[sessions.current] = images
            
            LOG("Session image deleted", ctx: ["fileName": image.fileName])
        }

        private func handleGuideImagePaste() {
            guard let template = selectedTemplate else { return }
#if os(macOS)
            let pasteboard = NSPasteboard.general
            guard pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue]) else {
                LOG("No PNG image found in clipboard for guide paste")
                return
            }
            guard let imageData = pasteboard.data(forType: .png) else {
                LOG("Failed to read PNG data for guide image paste")
                return
            }
            templateGuideStore.prepare(for: template)
            if let newImage = templateGuideStore.addImage(data: imageData, for: template) {
                touchTemplateActivity(for: template)
                LOG("Guide image added", ctx: ["template": template.name, "fileName": newImage.fileName])
            }
#endif
        }

        private func deleteGuideImage(_ image: TemplateGuideImage) {
            guard let template = selectedTemplate else { return }
            if templateGuideStore.deleteImage(image, for: template) {
                touchTemplateActivity(for: template)
                LOG("Guide image deleted", ctx: ["template": template.name, "fileName": image.fileName])
            }
        }

        private func renameGuideImage(_ image: TemplateGuideImage) {
            guard let template = selectedTemplate else { return }
#if os(macOS)
            let alert = NSAlert()
            alert.messageText = "Rename Guide Image"
            alert.informativeText = "Enter a new name for this guide image:" 
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            input.stringValue = image.displayName
            input.placeholderString = "Enter image name..."
            alert.accessoryView = input
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty else { return }
                if templateGuideStore.renameImage(image, to: newName, for: template) {
                    touchTemplateActivity(for: template)
                    LOG("Guide image renamed", ctx: ["template": template.name, "fileName": image.fileName, "newName": newName])
                }
            }
#endif
        }

        private func openGuideImage(_ image: TemplateGuideImage) {
            guard let template = selectedTemplate else { return }
            let url = templateGuideStore.imageURL(for: image, template: template)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            }
        }

        private func touchTemplateActivity(for template: TemplateItem) {
            UsedTemplatesStore.shared.touch(session: sessions.current, templateId: template.id)
        }
        
        private func trimTrailingWhitespace(_ string: String) -> String {
            string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        
        private func normalizedSearchText(_ string: String) -> String {
            string.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
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
            let baseList: [TemplateItem]
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseList = templates.templates
            } else {
                let query = normalizedSearchText(searchText)
                if query.isEmpty {
                    baseList = templates.templates
                } else {
                    baseList = templates.templates.filter { template in
                        normalizedSearchText(template.name).contains(query)
                    }
                }
            }
            
            // Promote "used" templates for the current session to the top
            let usedIds = Set(UsedTemplatesStore.shared.records(for: sessions.current).map { $0.templateId })
            return baseList.sorted { a, b in
                let aUsed = usedIds.contains(a.id)
                let bUsed = usedIds.contains(b.id)
                if aUsed != bUsed {
                    return aUsed && !bUsed
                } else {
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
        }
#if os(macOS)
        @discardableResult
        private func ensureAccessibilityPermission() -> Bool {
            let opts: CFDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            let ok = AXIsProcessTrustedWithOptions(opts)
            LOG("AX permission check", ctx: ["granted": ok ? "1" : "0"])
            return ok
        }
        
        private func openAccessibilitySettings() {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
#endif
        
        
        // MARK: — Static fields (now with dropdown history)
        private var staticFields: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Static Info")
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .foregroundStyle(Theme.purple)
                
                HStack(alignment: .top) {
                    fieldWithDropdown(
                        label: "Org-ID",
                        placeholder: "e.g., 606079893960",
                        value: $orgId,
                        historyKey: "Org-ID",
                        onCommit: { newVal in
                            let cleaned = newVal.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                            if cleaned != newVal { orgId = cleaned }
                            sessions.setValue(cleaned, for: "Org-ID")
                            sessionStaticFields[sessions.current] = (cleaned, acctId, mysqlDb, companyLabel)
                            
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
                    
                    // MySQL DB + Save button row
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            fieldWithDropdown(
                                label: "MySQL DB",
                                placeholder: "e.g., mySQL04",
                                value: $mysqlDb,
                                historyKey: "MySQL-DB",
                                onCommit: { newVal in
                                    let cleaned = newVal.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
                                    if cleaned != newVal { mysqlDb = cleaned }
                                    sessions.setValue(cleaned, for: "MySQL-DB")
                                    sessionStaticFields[sessions.current] = (orgId, acctId, cleaned, companyLabel)
                                    LOG("MySQL DB committed", ctx: ["value": cleaned])
                                }
                            )
                            
                            Button("Save") {
                                saveMapping()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.pink)
                            .font(.system(size: fontSize))
                        }
                        
                        HStack {
                            Button("Connect to Database") {
                                connectToQuerious()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .font(.system(size: fontSize))
                            .disabled(orgId.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .frame(width: 420, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.bottom, 16)
        }
        
        // MARK: — Dynamic fields from template placeholders
        private var dynamicFields: some View {
            return VStack(alignment: .leading, spacing: 6) {
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
                    .onChange(of: value.wrappedValue) { _, newVal in
                        let trimmed = trimTrailingWhitespace(newVal)
                        if trimmed != newVal {
                            value.wrappedValue = trimmed
                        }
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
        
        // Suggest tables using the global catalog (substring/fuzzy provided by the catalog)
        private func suggestTables(_ query: String, limit: Int = 15) -> [String] {
            DBTablesCatalog.shared.suggest(query, limit: limit)
        }
        
#if os(macOS)
        /// Handle ↑/↓ to move through suggestions, Return/Enter to accept, Esc to close.
        private func handleDBSuggestKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard let row = focusedDBTableRow else { return event }
            // Must have a selected template and a visible suggestions context
            guard selectedTemplate != nil else { return event }
            
            // Build suggestions for the focused row
            let current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
            let query = (row < current.count ? current[row] : "").trimmingCharacters(in: .whitespaces)
            let suggestions = suggestTables(query, limit: 15)
            guard !suggestions.isEmpty else { return event }
            
            var idx = suggestionIndexByRow[row] ?? -1
            
            switch event.keyCode {
            case 125: // ↓
                idx = (idx + 1) % suggestions.count
                suggestionIndexByRow[row] = idx
                return nil // consume
            case 126: // ↑
                idx = (idx - 1 + suggestions.count) % suggestions.count
                suggestionIndexByRow[row] = idx
                return nil // consume
            case 36, 76: // Return or Enter
                if idx >= 0 && idx < suggestions.count {
                    var arr = current
                    let value = suggestions[idx]
                    if row < arr.count {
                        arr[row] = value
                    } else if row == arr.count {
                        arr.append(value)
                    }
                    dbTablesStore.setWorkingSet(arr, for: sessions.current, template: selectedTemplate)
                    focusedDBTableRow = nil
                    suggestionIndexByRow[row] = nil
                    LOG("DBTables suggest selected (kbd)", ctx: ["row": "\(row)", "value": value])
                    return nil // consume
                }
                return event
            case 53: // Esc
                focusedDBTableRow = nil
                suggestionIndexByRow[row] = nil
                return nil // consume
            default:
                return event
            }
        }
#endif
        
        
        private func openTemplateJSON(_ item: TemplateItem) {
            // Sidecar file naming convention: "<base>.tables.json"
            let jsonURL = item.url.deletingPathExtension()
                .appendingPathExtension("tables.json")
            
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                openInVSCode(jsonURL)
                LOG("Open JSON", ctx: ["file": jsonURL.lastPathComponent])
            } else {
                LOG("JSON sidecar missing", ctx: ["file": jsonURL.lastPathComponent])
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
                    
                    // 🔥 Mark template as used immediately when user types something
                    if let t = selectedTemplate, !newVal.trimmingCharacters(in: .whitespaces).isEmpty {
                        UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: t.id)
                        UsedTemplatesStore.shared.setValue(newVal, for: placeholder, session: sessions.current, templateId: t.id)
                        LOG("UsedTemplates updated (typing)", ctx: [
                            "session": "\(sessions.current.rawValue)",
                            "templateId": t.id.uuidString,
                            "ph": placeholder,
                            "value": newVal
                        ])
                    }
                }
            )
            
            return fieldWithDropdown(
                label: placeholder,
                placeholder: "Value for \(placeholder)",
                value: valBinding,
                historyKey: placeholder,
                onCommit: { finalVal in
                    sessions.setValue(finalVal, for: placeholder)
                    LOG("Dynamic field committed", ctx: ["ph": placeholder, "value": finalVal])
                    
                    if let t = selectedTemplate {
                        UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: t.id)
                        UsedTemplatesStore.shared.setValue(finalVal, for: placeholder, session: sessions.current, templateId: t.id)
                        LOG("UsedTemplates updated (commit)", ctx: [
                            "session": "\(sessions.current.rawValue)",
                            "templateId": t.id.uuidString,
                            "ph": placeholder,
                            "value": finalVal
                        ])
                    }
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
                
                // Date selector components above the field - arranged compactly
                VStack(spacing: 6) {
                    // Top row: Year, Month, Day
                    HStack(alignment: .center, spacing: 6) {
                        // ... keep all existing content exactly the same ...
                        VStack(spacing: 2) {
                            Text("Year")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(value: $dpYear, range: yearsRange(), width: 60, label: "YYYY", sensitivity: dateScrollSensitivity, onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            })
                        }
                        VStack(spacing: 2) {
                            Text("Month")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(value: $dpMonth, range: 1...12, width: 45, label: "MM", sensitivity: dateScrollSensitivity, onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            })
                        }
                        VStack(spacing: 2) {
                            Text("Day")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(value: $dpDay, range: 1...daysInMonth(year: dpYear, month: dpMonth), width: 45, label: "DD", sensitivity: dateScrollSensitivity, onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            })
                        }
                        
                        // Small settings button
                        Button {
                            showScrollSettings.toggle()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: fontSize - 2, weight: .semibold))
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
                        
                        Spacer()
                    }
                    
                    // Bottom row: Hour, Minute, Second + Apply button
                    HStack(alignment: .center, spacing: 6) {
                        VStack(spacing: 2) {
                            Text("Hour")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(value: $dpHour, range: 0...23, width: 45, label: "hh", sensitivity: dateScrollSensitivity, onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            })
                        }
                        VStack(spacing: 2) {
                            Text("Minute")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(value: $dpMinute, range: 0...59, width: 45, label: "mm", sensitivity: dateScrollSensitivity, onReturn: {
                                performDateApply(for: placeholder, binding: valBinding)
                            })
                        }
                        VStack(spacing: 2) {
                            Text("Second")
                                .font(.system(size: fontSize - 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                                .lineLimit(1)
                            WheelNumberField(
                                value: $dpSecond,
                                range: 0...59,
                                width: 45,
                                label: "ss",
                                sensitivity: dateScrollSensitivity,
                                onReturn: {
                                    performDateApply(for: placeholder, binding: valBinding)
                                },
                                onTabToApply: { applyButtonFocused = true }
                            )
                        }
                        
                        // Apply button
                        Button("Apply") {
                            performDateApply(for: placeholder, binding: valBinding)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 1))
                        .keyboardShortcut(.defaultAction)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .focusable(true)
                        .focused($applyButtonFocused)
                        .fixedSize(horizontal: true, vertical: false)
                        
                        Spacer()
                    }
                }
                .frame(maxWidth: 407, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                
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
                .frame(maxWidth: 420)
                .onSubmit {
                    performDateApply(for: placeholder, binding: valBinding)
                }
                
                // Helper hint
                Text("Tip: Use ↑/↓ or the mouse wheel to change values. Press Tab to move across fields.")
                    .font(.system(size: fontSize - 3))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 540, alignment: .leading)
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
            LOG("Date inline apply (Enter/Apply)", ctx: ["value": str, "ph": placeholder])
            
            // Record usage in UsedTemplatesStore for (session + template)
            if let t = selectedTemplate {
                UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: t.id)
                UsedTemplatesStore.shared.setValue(str, for: placeholder, session: sessions.current, templateId: t.id)
                LOG("UsedTemplates updated (date apply)", ctx: [
                    "session": "\(sessions.current.rawValue)",
                    "templateId": t.id.uuidString,
                    "ph": placeholder,
                    "value": str
                ])
            }
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
        
        // MARK: — DB Tables pane (per-template, per-session working set)
        private var dbTablesPane: some View {
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("DB Tables for this Template")
                        .font(.system(size: fontSize + 1, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Toggle(isOn: $dbTablesLocked) {
                        HStack(spacing: 4) {
                            Image(systemName: dbTablesLocked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: fontSize - 2))
                            Text(dbTablesLocked ? "Locked" : "Unlocked")
                                .font(.system(size: fontSize - 2))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(dbTablesLocked ? "Tables are locked for copying. Uncheck to edit." : "Tables are editable. Check to lock for easy copying.")
                }
                
                if let t = selectedTemplate {
                    let isDirty = dbTablesStore.isDirty(for: sessions.current, template: t)
                    let rows = dbTablesStore.workingSet(for: sessions.current, template: t)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        // Rows
                        ForEach(Array(rows.enumerated()), id: \.offset) { idx, value in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if dbTablesLocked {
                                        // Read-only mode: easy copying, no editing
                                        let tableValue = {
                                            let current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                            return idx < current.count ? current[idx] : ""
                                        }()
                                        
                                        Text(tableValue.isEmpty ? "empty" : tableValue)
                                            .font(.system(size: fontSize))
                                            .foregroundStyle(tableValue.isEmpty ? .secondary : .primary)
                                            .textSelection(.enabled) // Allows text selection for copying
                                            .padding(.vertical, 6)
                                            .padding(.horizontal, 8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color.secondary.opacity(0.1))
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                                    )
                                            )
                                    } else {
                                        // Editable mode: original functionality
                                        TextField("table_name_here", text: Binding(
                                            get: {
                                                let current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                                return idx < current.count ? current[idx] : ""
                                            },
                                            set: { newVal in
                                                var current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                                if idx < current.count {
                                                    current[idx] = newVal
                                                } else if idx == current.count {
                                                    current.append(newVal)
                                                }
                                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: selectedTemplate)
                                                // Reset keyboard highlight for this row on text change
                                                suggestionIndexByRow[idx] = nil
                                            }
                                        ))
                                        .textFieldStyle(PlainTextFieldStyle())
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                                        )
                                        .font(.system(size: fontSize))
                                        .lineLimit(1)
                                        .focused($focusedDBTableRow, equals: idx)
                                        .help("Enter a base table name (letters, numbers, underscores).")
                                        
                                        Button {
                                            var current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                            if idx < current.count {
                                                current.remove(at: idx)
                                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: selectedTemplate)
                                                LOG("DBTables row removed", ctx: ["newCount": "\(current.count)"])
                                            }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(Theme.pink)
                                        .help("Remove this row")
                                    }
                                }
                                // Inline suggestions (appear when the row is focused and query has matches)
                                let current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                let query = (idx < current.count ? current[idx] : "").trimmingCharacters(in: .whitespaces)
                                if focusedDBTableRow == idx && !dbTablesLocked {
                                    let suggestions = suggestTables(query, limit: 15)
                                    if !query.isEmpty && !suggestions.isEmpty {
                                        let selectedIdx = suggestionIndexByRow[idx] ?? -1
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(Array(suggestions.enumerated()), id: \.1) { (sIndex, s) in
                                                Button {
                                                    var arr = current
                                                    if idx < arr.count {
                                                        arr[idx] = s
                                                    } else if idx == arr.count {
                                                        arr.append(s)
                                                    }
                                                    dbTablesStore.setWorkingSet(arr, for: sessions.current, template: selectedTemplate)
                                                    focusedDBTableRow = nil
                                                    suggestionIndexByRow[idx] = nil
                                                    LOG("DBTables suggest selected", ctx: ["row": "\(idx)", "value": s])
                                                } label: {
                                                    Text(s)
                                                        .font(.system(size: fontSize - 1))
                                                        .lineLimit(1)
                                                        .padding(.vertical, 4)
                                                        .padding(.horizontal, 8)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 4)
                                                                .fill(selectedIdx == sIndex ? Theme.purple.opacity(0.25) : Color.clear)
                                                        )
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Theme.grayBG.opacity(0.9))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Theme.purple.opacity(0.3), lineWidth: 1)
                                                )
                                        )
                                    }
                                }
                            }
                        }
                        
                        // Add row button
                        if !dbTablesLocked {
                            Button {
                                var current = dbTablesStore.workingSet(for: sessions.current, template: selectedTemplate)
                                current.append("")
                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: selectedTemplate)
                                LOG("DBTables row added", ctx: ["count": "\(current.count)"])
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add table")
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                        } else {
                            Text("Tables locked for copying - unlock to edit")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        if !dbTablesLocked {
                            Button("Save Tables") {
                                _ = dbTablesStore.saveSidecar(for: sessions.current, template: t)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.purple)
                            .disabled(!isDirty)
                            
                            Button("Revert to Saved") {
                                _ = dbTablesStore.loadSidecar(for: sessions.current, template: t)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.pink)
                            .disabled(!isDirty)
                        } else {
                            Text("Unlock to save changes")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                        }

                        Button("Copy Tables") {
                            copyTablesToClipboard()
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.aqua)
                        .help("Copy all DB table names for this session/template to clipboard")
                        
                        Spacer()
                    }
                    .padding(.top, 2)
                    
                } else {
                    Text("Load a template to manage its DB tables.")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.grayBG.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        // ✅ Copy db tables to clipboard:
        private func copyTablesToClipboard() {
            guard let t = selectedTemplate else { return }
            let tables = dbTablesStore.workingSet(for: sessions.current, template: t)
            let nonEmpty = tables.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonEmpty.isEmpty else { return }
            
            let joined = nonEmpty.joined(separator: "\n")
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(joined, forType: .string)
            
            LOG("Copied DB tables to clipboard", ctx: ["count": "\(nonEmpty.count)"])
            withAnimation { toastCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toastCopied = false }
            }
        }
        
        // MARK: — Alternate Fields pane (per-session)
        
        private var alternateFieldsPane: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Alternate Fields (per session)")
                        .font(.system(size: fontSize + 1, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    
                    Spacer()
                    
                    Toggle(isOn: $alternateFieldsLocked) {
                        HStack(spacing: 4) {
                            Image(systemName: alternateFieldsLocked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: fontSize - 2))
                            Text(alternateFieldsLocked ? "Locked" : "Unlocked")
                                .font(.system(size: fontSize - 2))
                        }
                    }
                    .toggleStyle(.checkbox)
                    .help(alternateFieldsLocked
                          ? "Alternate fields are locked for copying. Uncheck to edit."
                          : "Alternate fields are editable. Check to lock for easy copying.")
                }
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions.sessionAlternateFields[sessions.current] ?? [], id: \.id) { field in
                            AlternateFieldRow(session: sessions.current,
                                              field: field,
                                              locked: $alternateFieldsLocked,
                                              fontSize: fontSize,
                                              selectedTemplate: selectedTemplate,
                                              draftDynamicValues: $draftDynamicValues) // ✅ pass it in
                        }
                        
                        if !alternateFieldsLocked {
                            Button {
                                let newField = AlternateField(name: "", value: "")
                                if sessions.sessionAlternateFields[sessions.current] == nil {
                                    sessions.sessionAlternateFields[sessions.current] = []
                                }
                                sessions.sessionAlternateFields[sessions.current]?.append(newField)
                                LOG("Alternate field added", ctx: ["id": "\(newField.id)"])
                            } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                    Text("Add Alternate Field")
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlock to add or edit fields")
                                    .font(.system(size: fontSize - 3))
                                    .foregroundStyle(.secondary)
                                Text("💡 Double-click a value to use it in a dynamic field")
                                    .font(.system(size: fontSize - 3))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                }
                .frame(minHeight: 160, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.grayBG.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                        )
                )
                .frame(maxWidth: .infinity)
            }
        }
        
        // MARK: — Session & Template Tabbed Pane
        private var sessionAndTemplatePane: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Session & Template")
                    .font(.system(size: fontSize + 1, weight: .semibold))
                    .foregroundStyle(Theme.purple)

                Picker("Tab", selection: $selectedSessionTemplateTab) {
                    Text("Ses. Images").tag(SessionTemplateTab.sessionImages)
                    Text("Guide Images").tag(SessionTemplateTab.guideImages)
                    Text("Links").tag(SessionTemplateTab.templateLinks)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
                
                // Tab content - simple conditional view
                Group {
                    if selectedSessionTemplateTab == .sessionImages {
                        buildSessionImagesView()
                    } else if selectedSessionTemplateTab == .guideImages {
                        buildTemplateGuideImagesView()
                    } else {
                        buildTemplateLinksView()
                    }
                }
                .frame(minHeight: 200, maxHeight: 300)
            }
        }
        //    // MARK: — Alternate Fields pane (per-session)
        //    private var alternateFieldsPane: some View {
        //        VStack(alignment: .leading, spacing: 6) {
        //            HStack {
        //                Text("Alternate Fields (per session)")
        //                    .font(.system(size: fontSize + 1, weight: .semibold))
        //                    .foregroundStyle(Theme.purple)
        //
        //                Spacer()
        //
        //                Toggle(isOn: $alternateFieldsLocked) {
        //                    HStack(spacing: 4) {
        //                        Image(systemName: alternateFieldsLocked ? "lock.fill" : "lock.open.fill")
        //                            .font(.system(size: fontSize - 2))
        //                        Text(alternateFieldsLocked ? "Locked" : "Unlocked")
        //                            .font(.system(size: fontSize - 2))
        //                    }
        //                }
        //                .toggleStyle(.checkbox)
        //                .help(alternateFieldsLocked
        //                    ? "Alternate fields are locked for copying. Uncheck to edit."
        //                    : "Alternate fields are editable. Check to lock for easy copying.")
        //            }
        //
        //            ScrollView {
        //                VStack(alignment: .leading, spacing: 6) {
        //                    ForEach(sessions.sessionAlternateFields[sessions.current] ?? [], id: \.id) { field in
        //                        AlternateFieldRow(session: sessions.current,
        //                                          field: field,
        //                                          locked: $alternateFieldsLocked,
        //                                          fontSize: fontSize,
        //                                          selectedTemplate: selectedTemplate,
        //                                          draftDynamicValues: $draftDynamicValues)
        //                    }
        //
        //                    if !alternateFieldsLocked {
        //                        Button {
        //                            let newField = AlternateField(name: "", value: "")
        //                            if sessions.sessionAlternateFields[sessions.current] == nil {
        //                                sessions.sessionAlternateFields[sessions.current] = []
        //                            }
        //                            sessions.sessionAlternateFields[sessions.current]?.append(newField)
        //                            LOG("Alternate field added", ctx: ["id": "\(newField.id)"])
        //                        } label: {
        //                            HStack {
        //                                Image(systemName: "plus.circle")
        //                                Text("Add Alternate Field")
        //                            }
        //                        }
        //                        .buttonStyle(.plain)
        //                        .padding(.top, 4)
        //                    } else {
        //                        VStack(alignment: .leading, spacing: 2) {
        //                            Text("Unlock to add or edit fields")
        //                                .font(.system(size: fontSize - 3))
        //                                .foregroundStyle(.secondary)
        //                            Text("Double-click a value to use it in a dynamic field")
        //                                .font(.system(size: fontSize - 3))
        //                                .foregroundStyle(.secondary)
        //                        }
        //                        .padding(.top, 4)
        //                    }
        //                }
        //                .padding(6)
        //            }
        //            .frame(minHeight: 120, maxHeight: 180)
        //            .background(
        //                RoundedRectangle(cornerRadius: 8)
        //                    .fill(Theme.grayBG.opacity(0.25))
        //                    .overlay(
        //                        RoundedRectangle(cornerRadius: 8)
        //                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
        //                    )
        //            )
        //        }
        //    }
        
        // MARK: - Tab Content Builders
        private func buildSessionImagesView() -> some View {
            VStack(alignment: .leading, spacing: 8) {
                // Header with paste button
                HStack {
                    Text("Session \(sessions.current.rawValue) Images")
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(Theme.purple)
                    
                    Spacer()
                    
                    Button("Paste Screenshot") {
                        handleImagePaste()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.pink)
                    .font(.system(size: fontSize - 2))
                }
                
                // Images list
                let sessionImages = sessions.sessionImages[sessions.current] ?? []
                
                if sessionImages.isEmpty {
                    VStack {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("No images yet")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                        Text("Click 'Paste Screenshot' to add images")
                            .font(.system(size: fontSize - 3))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(sessionImages) { image in
                                SessionImageRow(
                                    image: image,
                                    fontSize: fontSize,
                                    onDelete: { imageToDelete in
                                        deleteSessionImage(imageToDelete)
                                    },
                                    onRename: { imageToRename in
                                        renameSessionImage(imageToRename)
                                    },
                                    onPreview: { imageToPreview in
                                        previewingSessionImage = imageToPreview
                                    }
                                )
                            }
                        }
                        .padding(4)
                    }
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.grayBG.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
            .sheet(item: $previewingSessionImage) { sessionImage in
                SessionImagePreviewSheet(sessionImage: sessionImage)
            }
        }
        
        private func buildTemplateGuideImagesView() -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let template = selectedTemplate {
                        Text("\(template.name) Guide Images")
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(Theme.purple)
                    } else {
                        Text("No Template Selected")
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Paste Guide Image") {
                        handleGuideImagePaste()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.purple)
                    .font(.system(size: fontSize - 2))
                    .disabled(selectedTemplate == nil)
                }

                if let template = selectedTemplate {
                    let guideImages = templateGuideStore.images(for: template)

                    if guideImages.isEmpty {
                        VStack {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("No guide images yet")
                                .font(.system(size: fontSize - 1))
                                .foregroundStyle(.secondary)
                            Text("Paste screenshots to document this template")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(guideImages) { image in
                                    TemplateGuideImageRow(
                                        image: image,
                                        fontSize: fontSize,
                                        onOpen: { openGuideImage(image) },
                                        onRename: { renameGuideImage(image) },
                                        onDelete: { deleteGuideImage(image) },
                                        onPreview: { previewingGuideImage = image }
                                    )
                                }
                            }
                            .padding(4)
                        }
                    }
                } else {
                    VStack {
                        Text("Select a template to manage guide images")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.grayBG.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
            .sheet(item: $previewingGuideImage) { guideImage in
                if let template = selectedTemplate {
                    TemplateGuideImagePreviewSheet(template: template, guideImage: guideImage)
                }
            }
        }
        
        private func buildTemplateLinksView() -> some View {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    if let template = selectedTemplate {
                        Text("\(template.name) Links")
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(Theme.purple)
                    } else {
                        Text("No Template Selected")
                            .font(.system(size: fontSize, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if selectedTemplate != nil {
                        Button("Add Link") {
                            addNewLink()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 2))
                    }
                }
                
                // Links list
                if let template = selectedTemplate {
                    let templateLinks = templateLinksStore.links(for: template)
                    
                    if templateLinks.isEmpty {
                        VStack {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("No links yet")
                                .font(.system(size: fontSize - 1))
                                .foregroundStyle(.secondary)
                            Text("Click 'Add Link' to associate URLs with this template")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(templateLinks) { link in
                                    TemplateLinkRow(
                                        link: link,
                                        fontSize: fontSize,
                                        onOpen: { openTemplateLink(link) },
                                        onEdit: { editTemplateLink(link) },
                                        onDelete: { deleteTemplateLink(link) },
                                        hoveredLinkID: $hoveredTemplateLinkID
                                    )
                                }
                            }
                            .padding(4)
                        }
                        
                        // Save/Revert buttons
                        let isDirty = templateLinksStore.isDirty(for: template)
                        if isDirty {
                            HStack {
                                Button("Save Links") {
                                    _ = templateLinksStore.saveSidecar(for: template)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.purple)
                                
                                Button("Revert") {
                                    _ = templateLinksStore.loadSidecar(for: template)
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.pink)
                                
                                Spacer()
                            }
                            .padding(.top, 4)
                        }
                    }
                } else {
                    VStack {
                        Text("Select a template to manage its links")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.grayBG.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        // Alternate Fields Row
        private struct AlternateFieldRow: View {
            @EnvironmentObject var sessions: SessionManager
            let session: TicketSession
            let field: AlternateField
            @Binding var locked: Bool
            let fontSize: CGFloat
            let selectedTemplate: TemplateItem?
            @Binding var draftDynamicValues: [TicketSession: [String: String]]
            
            @State private var editingName: String
            @State private var editingValue: String
            
            init(session: TicketSession,
                 field: AlternateField,
                 locked: Binding<Bool>,
                 fontSize: CGFloat,
                 selectedTemplate: TemplateItem?,
                 draftDynamicValues: Binding<[TicketSession: [String: String]]>) {
                self.session = session
                self.field = field
                self._locked = locked
                self.fontSize = fontSize
                self.selectedTemplate = selectedTemplate
                self._draftDynamicValues = draftDynamicValues
                _editingName = State(initialValue: field.name)
                _editingValue = State(initialValue: field.value)
            }
            
            var body: some View {
                if locked {
                    // 🔒 Locked mode: styled like dynamic fields (label above, value inside field look)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editingName.isEmpty ? "unnamed" : editingName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        
                        Text(editingValue.isEmpty ? "empty" : editingValue)
                            .font(.system(size: fontSize))
                            .foregroundStyle(editingValue.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                    )
                            )
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle()) // ✅ makes the whole row tappable
                    .onTapGesture(count: 2) {
                        promptReplaceDynamicField()
                    }
                } else {
                    // ✏️ Editable mode: name + value side by side
                    HStack(spacing: 6) {
                        TextField("Name", text: $editingName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitChanges() }
                            .onChange(of: editingName) { _, newVal in
                                commitChanges(newName: newVal, newValue: editingValue)
                            }
                        
                        TextField("Value", text: $editingValue)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitChanges() }
                            .onChange(of: editingValue) { _, newVal in
                                commitChanges(newName: editingName, newValue: newVal)
                            }
                        
                        Button {
                            if let idx = sessions.sessionAlternateFields[session]?.firstIndex(where: { $0.id == field.id }) {
                                sessions.sessionAlternateFields[session]?.remove(at: idx)
                                LOG("Alternate field removed", ctx: [
                                    "session": "\(session.rawValue)",
                                    "id": "\(field.id)"
                                ])
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            private func commitChanges(newName: String? = nil, newValue: String? = nil) {
                guard let idx = sessions.sessionAlternateFields[session]?.firstIndex(where: { $0.id == field.id }) else { return }
                sessions.sessionAlternateFields[session]?[idx].name = newName ?? editingName
                sessions.sessionAlternateFields[session]?[idx].value = newValue ?? editingValue
                LOG("Alternate field committed", ctx: [
                    "session": "\(session.rawValue)",
                    "id": "\(field.id)",
                    "name": sessions.sessionAlternateFields[session]?[idx].name ?? "",
                    "value": sessions.sessionAlternateFields[session]?[idx].value ?? ""
                ])
            }
            
            private func promptReplaceDynamicField() {
                let alert = NSAlert()
                alert.messageText = "Replace Dynamic Field"
                alert.informativeText = "Choose which dynamic field should be replaced by '\(editingValue)'."
                alert.alertStyle = .informational
                
                var availableDynamicFields: [String] = []
                
                if let template = selectedTemplate {
                    // Filter out static fields (case-insensitive comparison)
                    let staticFields = ["Org-ID", "Acct-ID", "mysqlDb"]
                    availableDynamicFields = template.placeholders.filter { ph in
                        !staticFields.contains { $0.caseInsensitiveCompare(ph) == .orderedSame }
                    }
                    
                    LOG("Dynamic placeholders available", ctx: ["placeholders": availableDynamicFields.joined(separator: ", ")])
                    
                    if availableDynamicFields.isEmpty {
                        alert.informativeText = "⚠️ No dynamic fields available to replace."
                    } else {
                        // Add a button for each dynamic field
                        for ph in availableDynamicFields {
                            alert.addButton(withTitle: ph)
                        }
                    }
                } else {
                    alert.informativeText = "⚠️ No template is currently loaded."
                }
                
                alert.addButton(withTitle: "Cancel")
                
                // Show the modal and get the result
                let result = alert.runModal()
                
                // Calculate which button was clicked based on the modal response
                let clickedIndex = Int(result.rawValue) - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                
                // Check if a valid dynamic field button was clicked (not Cancel)
                if clickedIndex >= 0 && clickedIndex < availableDynamicFields.count {
                    let chosen = availableDynamicFields[clickedIndex]
                    
                    // Apply the alternate field value to the chosen dynamic field
                    var bucket = draftDynamicValues[session] ?? [:]
                    bucket[chosen] = editingValue
                    draftDynamicValues[session] = bucket
                    
                    LOG("Alternate field applied to dynamic", ctx: [
                        "session": "\(session.rawValue)",
                        "dynamicField": chosen,
                        "value": editingValue
                    ])
                }
            }
        }
        
        // MARK: — Output area
        private var outputView: some View {
            let guideDirty = templateGuideStore.isNotesDirty(for: selectedTemplate)
            return VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(showTroubleshootingGuide ? "Troubleshooting Guide" : "Output SQL")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.aqua)

                    if showTroubleshootingGuide {
                        if guideDirty {
                            Button("Save Guide") {
                                guard let template = selectedTemplate else { return }
                                if templateGuideStore.saveNotes(for: template) {
                                    guideNotesDraft = templateGuideStore.currentNotes(for: template)
                                    touchTemplateActivity(for: template)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.purple)
                            .font(.system(size: fontSize - 1))

                            Button("Revert") {
                                guard let template = selectedTemplate else { return }
                                guideNotesDraft = templateGuideStore.revertNotes(for: template)
                            }
                            .buttonStyle(.bordered)
                            .tint(Theme.pink)
                            .font(.system(size: fontSize - 1))
                        }

                        MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !guidePreviewMode, controller: guideNotesEditor)
                        PreviewModeToggle(isPreview: $guidePreviewMode)
                    }

                    Spacer(minLength: 12)

                    Button {
                        withAnimation { showNotesSidebar.toggle() }
                    } label: {
                        Label(showNotesSidebar ? "Hide Notes" : "Show Notes", systemImage: "note.text")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.purple)
                    .font(.system(size: fontSize - 1))
                    .help("Toggle Session Notes sidebar")
                }

                let leftPane = Group {
                    if showTroubleshootingGuide {
                        if let template = selectedTemplate {
                            Group {
                                if guidePreviewMode {
                                    MarkdownPreviewView(text: guideNotesDraft, fontSize: fontSize)
                                } else {
                                    MarkdownEditor(
                                        text: $guideNotesDraft,
                                        fontSize: fontSize,
                                        controller: guideNotesEditor,
                                        onLinkRequested: handleTroubleshootingLink(selectedText:source:completion:)
                                    )
                                }
                            }
                            .frame(minHeight: 200)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.grayBG.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                                    )
                            )
                            .onChange(of: guideNotesDraft) { _, newVal in
                                if templateGuideStore.setNotes(newVal, for: template) {
                                    touchTemplateActivity(for: template)
                                }
                            }
                        } else {
                            VStack {
                                Text("Select a template to view its troubleshooting guide")
                                    .font(.system(size: fontSize - 1))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.grayBG.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                                    )
                            )
                            .frame(minHeight: 160)
                        }
                    } else {
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

                if showNotesSidebar {
                    HSplitView {
                        leftPane
                            .frame(minWidth: 900, idealWidth: 1100)

                        SessionNotesInline(
                            fontSize: fontSize,
                            session: sessions.current,
                            draft: Binding(
                                get: { sessionNotesDrafts[sessions.current] ?? "" },
                                set: { sessionNotesDrafts[sessions.current] = $0 }
                            ),
                            savedValue: sessions.sessionNotes[sessions.current] ?? "",
                            controller: sessionNotesEditor,
                            isPreview: $notesPreviewMode,
                            onSave: saveSessionNotes,
                            onRevert: revertSessionNotes,
                            onLinkRequested: handleSessionNotesLink(selectedText:source:completion:)
                        )
                        .frame(minWidth: 300, idealWidth: 360)
                        .layoutPriority(1)
                    }
                    .frame(minHeight: 160)
                } else {
                    leftPane
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
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                    .frame(minWidth: 70, alignment: .leading)
                    .layoutPriority(1)
                if let link = sessions.sessionLinks[sessions.current], !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        openCurrentSessionLink()
                    } label: {
                        Image(systemName: "link")
                            .font(.system(size: fontSize - 1, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.aqua)
                    .help("Open linked ticket: \(link)")
                }
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
                    .registerShortcut(name: "Switch to Session #\(s.rawValue)", keyLabel: "\(s.rawValue)", modifiers: [.command], scope: "Sessions")
                    .contextMenu {
                        Button("Rename…") { promptRename(for: s) }
                        Button("Link to Ticket…") { promptLink(for: s) }
                        if let existing = sessions.sessionLinks[s], !existing.isEmpty {
                            Button("Clear Link") { sessions.sessionLinks.removeValue(forKey: s) }
                        }
                        Divider()
                        if sessions.current == s {
                            Button("Clear This Session") {
                                promptClearCurrentSession()
                            }
                        } else {
                            Button("Switch to This Session") {
                                switchToSession(s)
                            }
                        }
                    }
                }
                // New: Copy Block Values and Copy All Individual buttons
                Button {
                    copyBlockValuesToClipboard()
                } label: {
                    Label("Copy Block Values", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .tint(Theme.aqua)
                .font(.system(size: fontSize - 1))
                .help("Copy Org-ID, Acct-ID, mysqlDb, and all template values as a single block to clipboard")
                Button {
                    copyIndividualValuesToClipboard()
                } label: {
                    Label("Copy All Individual", systemImage: "list.clipboard")
                }
                .buttonStyle(.bordered)
                .tint(Theme.aqua)
                .font(.system(size: fontSize - 1))
                .help("Copy Org-ID, Acct-ID, mysqlDb, and all template values as individual clipboard items")
                // Invisible bridge view to receive menu notifications and register KB shortcuts for Help sheet
                Color.clear.frame(width: 0, height: 0)
                    .background(TicketSessionNotificationBridge(
                        onSave: { saveTicketSessionFlow() },
                        onLoad: { loadTicketSessionFlow() },
                        onOpen: { openSessionsFolderFlow() }
                    ))
                    .background(
                        Group {
                            Color.clear
                                .registerShortcut(name: "Save Ticket Session…", keyLabel: "S", modifiers: [.command], scope: "Ticket Sessions")
                            Color.clear
                                .registerShortcut(name: "Load Ticket Session…", keyLabel: "L", modifiers: [.command], scope: "Ticket Sessions")
                        }
                    )
            }
        }
        
        // Helper to copy all static, template, and alternate field values as a single block to clipboard
        private func copyBlockValuesToClipboard() {
            var values: [String] = []
            values.append(orgId)
            values.append(acctId)
            values.append(mysqlDb)
            var blockLines: [String] = []
            let sessionName = sessions.sessionNames[sessions.current] ?? "Session #\(sessions.current.rawValue)"
            blockLines.append(sessionName)
            blockLines.append("Org-ID: \(orgId)")
            blockLines.append("Acct-ID: \(acctId)")
            blockLines.append("mysqlDb: \(mysqlDb)")
            if let t = selectedTemplate {
                let staticKeys = ["Org-ID", "Acct-ID", "mysqlDb"]
                for ph in t.placeholders where !staticKeys.contains(ph) {
                    let val = sessions.value(for: ph) ?? ""
                    values.append(val)
                    blockLines.append("\(ph): \(val)")
                }
            }
            // Also include alternate fields for this session
            if let alternates = sessions.sessionAlternateFields[sessions.current] {
                for alt in alternates {
                    values.append(alt.value)
                    blockLines.append("\(alt.name): \(alt.value)")
                }
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            // Add each value as a separate clipboard entry
            for v in values {
                pb.setString(v, forType: .string)
            }
            // Add the block string as a single clipboard entry
            let block = blockLines.joined(separator: "\n")
            pb.setString(block, forType: .string)
            LOG("Copied all values to clipboard", ctx: ["count": "\(values.count)"])
            withAnimation { toastCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toastCopied = false }
            }
        }
        
        private func copyIndividualValuesToClipboard() {
            var values: [String] = []
            
            // Always include static fields first (ensures orgId isn’t dropped)
            if !orgId.isEmpty { values.append(orgId) }
            if !acctId.isEmpty { values.append(acctId) }
            if !mysqlDb.isEmpty { values.append(mysqlDb) }
            
            if let t = selectedTemplate {
                let staticKeys = ["Org-ID", "Acct-ID", "mysqlDb"]
                for ph in t.placeholders {
                    if staticKeys.contains(where: { $0.caseInsensitiveCompare(ph) == .orderedSame }) {
                        continue // skip duplicates
                    }
                    let val = sessions.value(for: ph)
                    if !val.isEmpty {
                        values.append(val)
                    }
                }
            }
            // Include non-empty alternate field values for this session
            if let alternates = sessions.sessionAlternateFields[sessions.current] {
                for alt in alternates {
                    if !alt.value.isEmpty {
                        values.append(alt.value)
                    }
                }
            }
            
            let count = values.count
            let pb = NSPasteboard.general
            
            for (idx, v) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(idx * 800)) {
                    pb.clearContents()
                    pb.setString(v, forType: .string)
                    LOG("Copied value \(idx + 1)/\(count): \(v)")
                }
            }
            
            LOG("Scheduled copy of all values individually", ctx: ["count": "\(count)"])
            withAnimation { toastCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toastCopied = false }
            }
        }

        private func isSessionNotesDirty(session: TicketSession) -> Bool {
            (sessionNotesDrafts[session] ?? "") != (sessions.sessionNotes[session] ?? "")
        }

        private func saveSessionNotes() {
            let currentSession = sessions.current
            let draft = sessionNotesDrafts[currentSession] ?? ""
            sessions.sessionNotes[currentSession] = draft
            LOG("Session notes saved", ctx: ["session": "\(currentSession.rawValue)", "length": "\(draft.count)"])
        }

        private func revertSessionNotes() {
            let currentSession = sessions.current
            let saved = sessions.sessionNotes[currentSession] ?? ""
            sessionNotesDrafts[currentSession] = saved
            LOG("Session notes reverted", ctx: ["session": "\(currentSession.rawValue)"])
        }

        private func handleSessionNotesLink(selectedText: String,
                                             source _: MarkdownEditor.LinkRequestSource,
                                             completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Insert Link"
            alert.informativeText = "Add a title and URL to insert a Markdown link into the session notes."

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))

            let titleField = NSTextField(frame: NSRect(x: 0, y: 44, width: 320, height: 24))
            titleField.placeholderString = "Link text (optional)"
            titleField.stringValue = selectedText

            let urlField = NSTextField(frame: NSRect(x: 0, y: 12, width: 320, height: 24))
            urlField.placeholderString = "https://example.com/path"

            container.addSubview(titleField)
            container.addSubview(urlField)

            alert.accessoryView = container
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }

            let label = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else {
                completion(nil)
                return
            }

            let normalized = normalizeURL(rawURL)
            completion(MarkdownEditor.LinkInsertion(label: label.isEmpty ? normalized : label,
                                                    url: normalized,
                                                    saveToTemplateLinks: false))
            LOG("Session notes link inserted", ctx: ["url": normalized])
        }

        private func handleTroubleshootingLink(selectedText: String,
                                               source _: MarkdownEditor.LinkRequestSource,
                                               completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Insert Link"
            alert.informativeText = "Add a title and URL to insert a Markdown link into the troubleshooting guide."

            let containerHeight: CGFloat = selectedTemplate == nil ? 80 : 110
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: containerHeight))

            let titleField = NSTextField(frame: NSRect(x: 0, y: containerHeight - 36, width: 340, height: 24))
            titleField.placeholderString = "Link text (optional)"
            titleField.stringValue = selectedText

            let urlFieldY = selectedTemplate == nil ? 12 : 40
            let urlField = NSTextField(frame: NSRect(x: 0, y: CGFloat(urlFieldY), width: 340, height: 24))
            urlField.placeholderString = "https://example.com/path"

            var saveCheckbox: NSButton?
            if selectedTemplate != nil {
                let checkbox = NSButton(checkboxWithTitle: "Save this link to template links?", target: nil, action: nil)
                checkbox.frame = NSRect(x: 0, y: 8, width: 340, height: 24)
                checkbox.state = .off
                container.addSubview(checkbox)
                saveCheckbox = checkbox
            }

            container.addSubview(titleField)
            container.addSubview(urlField)

            alert.accessoryView = container
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }

            let label = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty else {
                completion(nil)
                return
            }

            let normalized = normalizeURL(rawURL)
            var shouldSaveLink = false
            if let checkbox = saveCheckbox, checkbox.state == .on, let template = selectedTemplate {
                templateLinksStore.addLink(title: label.isEmpty ? normalized : label, url: normalized, for: template)
                shouldSaveLink = true
                touchTemplateActivity(for: template)
            }

            completion(MarkdownEditor.LinkInsertion(label: label.isEmpty ? normalized : label,
                                                    url: normalized,
                                                    saveToTemplateLinks: shouldSaveLink))
            LOG("Troubleshooting link inserted", ctx: ["url": normalized, "savedToTemplate": shouldSaveLink ? "true" : "false"])
        }

        private func normalizeURL(_ raw: String) -> String {
            var text = raw
            if !text.contains("://") {
                text = "https://" + text
            }
            text = text.replacingOccurrences(of: " ", with: "%20")
            return text
        }

        // Helper to set selection and persist for current session (no draft commit here for responsiveness)
        private func selectTemplate(_ t: TemplateItem?) {
            selectedTemplate = t
            if let t = t {
                sessionSelectedTemplate[sessions.current] = t.id
                // Hydrate DB tables working set from sidecar
                _ = DBTablesStore.shared.loadSidecar(for: sessions.current, template: t)
                LOG("DBTables sidecar hydrated", ctx: ["template": t.name, "session": "\(sessions.current.rawValue)"])
                
                // Hydrate template links from sidecar
                _ = templateLinksStore.loadSidecar(for: t)
                LOG("Template links hydrated", ctx: ["template": t.name])
                templateGuideStore.prepare(for: t)
                guideNotesDraft = templateGuideStore.currentNotes(for: t)
            } else {
                showTroubleshootingGuide = false
                guideNotesDraft = ""
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
                // NEW: hydrate DB tables for this session/template
                _ = DBTablesStore.shared.loadSidecar(for: newSession, template: found)
                LOG("DBTables sidecar hydrated (session switch)", ctx: ["template": found.name, "session": "\(newSession.rawValue)"])
                templateGuideStore.prepare(for: found)
                guideNotesDraft = templateGuideStore.currentNotes(for: found)
            } else {
                selectedTemplate = nil
                showTroubleshootingGuide = false
                guideNotesDraft = ""
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
            // NEW: hydrate working set from sidecar for the current session
            _ = DBTablesStore.shared.loadSidecar(for: sessions.current, template: t)
            LOG("DBTables sidecar hydrated", ctx: ["template": t.name, "session": "\(sessions.current.rawValue)"])
            // Hydrate template links from sidecar
            _ = templateLinksStore.loadSidecar(for: t)
            LOG("Template links hydrated", ctx: ["template": t.name])
            templateGuideStore.prepare(for: t)
            guideNotesDraft = templateGuideStore.currentNotes(for: t)
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
                
                // 4) STREAMLINED WORKFLOW: Auto re-select the saved template and populate query
                DispatchQueue.main.async {
                    // Find the updated template in the reloaded list by matching URL
                    if let updatedTemplate = self.templates.templates.first(where: { $0.url == url }) {
                        // Re-select the template
                        self.selectTemplate(updatedTemplate)
                        self.loadTemplate(updatedTemplate)
                        
                        // Auto-populate the query for convenience
                        self.populateQuery()
                        UsedTemplatesStore.shared.touch(session: self.sessions.current, templateId: updatedTemplate.id)
                        
                        LOG("Template editing workflow completed", ctx: [
                            "template": updatedTemplate.name,
                            "auto_reselected": "true",
                            "auto_populated": "true"
                        ])
                    } else {
                        LOG("Could not find updated template after reload", ctx: ["originalName": template.name])
                    }
                }
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
            showTroubleshootingGuide = false
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
            UsedTemplatesStore.shared.touch(session: sessions.current, templateId: t.id)
            
            if let entry = mapping.lookup(orgId: orgId) {
                mysqlDb = entry.mysqlDb
                companyLabel = entry.companyName ?? ""
            }
        }
        
        @State private var isNotesSheetOpen: Bool = false
        @State private var showNotesSidebar: Bool = true
        
        
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
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            
            sessions.setCurrent(s)
            sessions.renameCurrent(to: newName)
            
            LOG("Session renamed manually", ctx: [
                "session": "\(s.rawValue)",
                "name": newName
            ])
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
        
        private func promptLink(for s: TicketSession) {
            let current = sessions.sessionLinks[s] ?? ""
            let alert = NSAlert()
            alert.messageText = "Link to Ticket"
            alert.informativeText = "Paste a URL to associate with Session #\(s.rawValue). Leave empty to clear."
            alert.alertStyle = .informational
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.placeholderString = "https://…"
            input.stringValue = current
            alert.accessoryView = input
            alert.addButton(withTitle: "Save Link")
            alert.addButton(withTitle: "Cancel")
            let result = alert.runModal()
            guard result == .alertFirstButtonReturn else { return }
            let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                sessions.sessionLinks.removeValue(forKey: s)
            } else if let _ = normalizedURL(from: value) {
                sessions.sessionLinks[s] = value
            } else {
                NSSound.beep()
                showAlert(title: "Invalid Link",
                          message: "Please enter a full web URL (e.g., https://example.com/ticket/123)")
            }
        }
        
        // Normalize raw user text into a browser-safe web URL (http/https only)
        private func normalizedURL(from raw: String) -> URL? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if !s.contains("://") {            // domain without scheme
                s = "https://" + s
            }
            s = s.replacingOccurrences(of: " ", with: "%20") // minimal encoding
            guard let url = URL(string: s) else { return nil }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url
            }
            return nil
        }
        
        private func openCurrentSessionLink() {
            guard let raw = sessions.sessionLinks[sessions.current]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return }
            
            if let url = normalizedURL(from: raw) {
                NSWorkspace.shared.open(url)
                LOG("Open session link", ctx: ["url": url.absoluteString])
            } else {
                NSSound.beep()
                showAlert(title: "Invalid Link",
                          message: "That doesn't look like a valid web URL.\nTry something like https://example.com/ticket/123.")
                LOG("Open session link failed: invalid URL", ctx: ["raw": raw])
            }
        }
        
        // MARK: – Ticket Session Save/Load/Open
        private struct SavedTicketSession: Codable {
            struct StaticFields: Codable {
                let orgId: String
                let acctId: String
                let mysqlDb: String
                let companyLabel: String
            }
            let version: Int
            let sessionName: String
            let sessionLink: String?
            let templateId: String?
            let templateName: String?
            let staticFields: StaticFields
            let placeholders: [String:String]
            let dbTables: [String]
            let notes: String
            let alternateFields: [String: String]
            let sessionImages: [SessionImage]
            
        }
        
        private func sanitizeFileName(_ name: String) -> String {
            let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            return name.components(separatedBy: invalid).joined(separator: "_")
        }
        
        private func saveTicketSessionFlow() {
            let fm = FileManager.default
            try? fm.createDirectory(at: AppPaths.sessions, withIntermediateDirectories: true)
            
            let defaultName = sessions.sessionNames[sessions.current]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggested = (defaultName?.isEmpty == false)
            ? defaultName!
            : "Session #\(sessions.current.rawValue)"
            guard let rawName = promptForString(
                title: "Save Ticket Session",
                message: "Type a name for this ticket session file (no extension needed)",
                defaultValue: suggested
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return }
            
            let base = sanitizeFileName(rawName)
            var url = AppPaths.sessions.appendingPathComponent(base, conformingTo: .json)
            if url.pathExtension.lowercased() != "json" {
                url = url.appendingPathExtension("json")
            }
            
            if fm.fileExists(atPath: url.path) {
                let overwrite = NSAlert()
                overwrite.messageText = "File Exists"
                overwrite.informativeText = "A file named ‘\(url.lastPathComponent)’ already exists. Overwrite it?"
                overwrite.alertStyle = .warning
                overwrite.addButton(withTitle: "Overwrite")
                overwrite.addButton(withTitle: "Cancel")
                guard overwrite.runModal() == .alertFirstButtonReturn else { return }
            }
            
            // Snapshot current UI/session state
            let staticData = sessionStaticFields[sessions.current] ?? (orgId, acctId, mysqlDb, companyLabel)
            let sFields = SavedTicketSession.StaticFields(
                orgId: staticData.orgId,
                acctId: staticData.acctId,
                mysqlDb: staticData.mysqlDb,
                companyLabel: staticData.company
            )
            
            var placeholders: [String:String] = [:]
            if let t = selectedTemplate {
                for ph in t.placeholders { placeholders[ph] = sessions.value(for: ph) }
            }
            
            let dbSet: [String] = {
                if let t = selectedTemplate { return dbTablesStore.workingSet(for: sessions.current, template: t) }
                return []
            }()
            
            let saved = SavedTicketSession(
                version: 1,
                sessionName: sessions.sessionNames[sessions.current] ?? "#\(sessions.current.rawValue)",
                sessionLink: sessions.sessionLinks[sessions.current],
                templateId: selectedTemplate.map { "\($0.id)" },
                templateName: selectedTemplate?.name,
                staticFields: sFields,
                placeholders: placeholders,
                dbTables: dbSet,
                notes: sessions.sessionNotes[sessions.current] ?? "",
                alternateFields: sessions.sessionAlternateFields[sessions.current]?
                    .reduce(into: [String:String]()) { dict, field in
                        dict[field.name] = field.value
                    } ?? [:],
                sessionImages: sessions.sessionImages[sessions.current] ?? []
            )
            
            do {
                let enc = JSONEncoder()
                if #available(macOS 10.13, *) { enc.outputFormatting = [.prettyPrinted, .sortedKeys] } else { enc.outputFormatting = [.prettyPrinted] }
                let data = try enc.encode(saved)
                try data.write(to: url, options: .atomic)
                LOG("Ticket session saved", ctx: ["file": url.lastPathComponent])
            } catch {
                NSSound.beep()
                showAlert(title: "Save Failed", message: error.localizedDescription)
                LOG("Ticket session save failed", ctx: ["error": error.localizedDescription])
            }
        }
        
    private func loadTicketSessionFlow() {
        // Confirm overwrite of current UI state
        let warn = NSAlert()
        warn.messageText = "Load Ticket Session?"
        warn.informativeText = "Loading will overwrite the current session’s values. Continue?"
        warn.alertStyle = .warning
        warn.addButton(withTitle: "Load")
        warn.addButton(withTitle: "Cancel")
        guard warn.runModal() == .alertFirstButtonReturn else { return }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.directoryURL = AppPaths.sessions
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            let loaded = try dec.decode(SavedTicketSession.self, from: data)
            
            // ⬅️ Key change: derive session name from file name
            let inferredName = url.deletingPathExtension().lastPathComponent
            sessions.renameCurrent(to: inferredName)
            
            // Restore optional link
            if let link = loaded.sessionLink, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sessions.sessionLinks[sessions.current] = link
            } else {
                sessions.sessionLinks.removeValue(forKey: sessions.current)
            }
            
            // Restore static fields
            orgId = loaded.staticFields.orgId
            acctId = loaded.staticFields.acctId
            mysqlDb = loaded.staticFields.mysqlDb
            companyLabel = loaded.staticFields.companyLabel
            sessionStaticFields[sessions.current] = (orgId, acctId, mysqlDb, companyLabel)
            
            // Restore placeholders
            for (k, v) in loaded.placeholders {
                sessions.setValue(v, for: k)
            }

            // Try to resolve template
            var matched: TemplateItem? = nil
            if let tid = loaded.templateId {
                matched = templates.templates.first(where: { "\($0.id)" == tid })
            }
            if matched == nil, let tname = loaded.templateName {
                matched = templates.templates.first(where: { $0.name == tname })
            }

            // Rehydrate template usage
            if let t = matched ?? selectedTemplate {
                let hasValues = loaded.placeholders.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if hasValues {
                    UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: t.id)
                    UsedTemplatesStore.shared.setAllValues(
                        loaded.placeholders,
                        session: sessions.current,
                        templateId: t.id
                    )
                    LOG("UsedTemplates rehydrated from loaded session",
                        ctx: ["template": t.name, "count": "\(loaded.placeholders.count)"])
                }
            }

            // Restore notes, alternates, images
            sessions.sessionNotes[sessions.current] = loaded.notes
            sessionNotesDrafts[sessions.current] = loaded.notes
            sessions.sessionAlternateFields[sessions.current] =
                loaded.alternateFields.map { AlternateField(name: $0.key, value: $0.value) }
            sessions.sessionImages[sessions.current] = loaded.sessionImages
            
            // Restore template if matched
            if let t = matched {
                loadTemplate(t)
                if !loaded.dbTables.isEmpty {
                    dbTablesStore.setWorkingSet(loaded.dbTables, for: sessions.current, template: t)
                }
            } else {
                LOG("Saved session template not found; restored values only", ctx: ["templateName": loaded.templateName ?? "?"])
            }
            
            // Refresh populated SQL
            populateQuery()
            LOG("Ticket session loaded", ctx: ["file": url.lastPathComponent])
        } catch {
            NSSound.beep()
            showAlert(title: "Load Failed", message: error.localizedDescription)
            LOG("Ticket session load failed", ctx: ["error": error.localizedDescription])
        }
    }
        
        private func openSessionsFolderFlow() {
            let fm = FileManager.default
            try? fm.createDirectory(at: AppPaths.sessions, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppPaths.sessions)
            LOG("Open sessions folder")
        }
        
        private func promptClearCurrentSession() {
            let hasNotes = !(sessions.sessionNotes[sessions.current] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let alert = NSAlert()
            alert.messageText = "Save this session before clearing?"
            alert.informativeText = "Session #\(sessions.current.rawValue) will be reset."
            alert.alertStyle = .informational
            if hasNotes {
                // Default = Yes (Save) when notes exist
                alert.addButton(withTitle: "Yes, Save")
                alert.addButton(withTitle: "No, Don’t Save")
                alert.addButton(withTitle: "Cancel")
            } else {
                // Default = No (Don’t Save) otherwise
                alert.addButton(withTitle: "No, Don’t Save")
                alert.addButton(withTitle: "Yes, Save")
                alert.addButton(withTitle: "Cancel")
            }
            let response = alert.runModal()
            if hasNotes {
                switch response {
                case .alertFirstButtonReturn: // Yes, Save
                    saveTicketSessionFlow()
                    fallthrough
                case .alertSecondButtonReturn: // No, Don’t Save
                    sessions.clearAllFieldsForCurrentSession()
                    sessions.sessionNotes[sessions.current] = ""
                    sessionNotesDrafts[sessions.current] = ""
                    sessionStaticFields[sessions.current] = ("", "", "", "")
                    LOG("Session cleared via prompt", ctx: ["session": "\(sessions.current.rawValue)"])
                default:
                    return
                }
            } else {
                switch response {
                case .alertFirstButtonReturn: // No, Don’t Save
                    sessions.clearAllFieldsForCurrentSession()
                    sessions.sessionNotes[sessions.current] = ""
                    sessionNotesDrafts[sessions.current] = ""
                    sessionStaticFields[sessions.current] = ("", "", "", "")
                    LOG("Session cleared via prompt", ctx: ["session": "\(sessions.current.rawValue)"])
                case .alertSecondButtonReturn: // Yes, Save
                    saveTicketSessionFlow()
                    sessions.clearAllFieldsForCurrentSession()
                    sessions.sessionNotes[sessions.current] = ""
                    sessionNotesDrafts[sessions.current] = ""
                    sessionStaticFields[sessions.current] = ("", "", "", "")
                    LOG("Session cleared after save via prompt", ctx: ["session": "\(sessions.current.rawValue)"])
                default:
                    return
                }
            }
        }
        
        // A tiny invisible view that listens for the menu notifications
        private struct TicketSessionNotificationBridge: View {
            var onSave: () -> Void
            var onLoad: () -> Void
            var onOpen: () -> Void
            var body: some View {
                Color.clear
                    .onReceive(NotificationCenter.default.publisher(for: .saveTicketSession)) { _ in onSave() }
                    .onReceive(NotificationCenter.default.publisher(for: .loadTicketSession)) { _ in onLoad() }
                    .onReceive(NotificationCenter.default.publisher(for: .openSessionsFolder)) { _ in onOpen() }
            }
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
            // 🔔 Warning before rename
            let alert = NSAlert()
            alert.messageText = "Renaming this template will reset its DB Tables."
            alert.informativeText = "You will need to manually copy the saved values from the old JSON into the new template if needed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            
            let choice = alert.runModal()
            if choice != .alertFirstButtonReturn {
                return // User cancelled
            }
            
            // Proceed with the rename
            guard let newName = promptForString(
                title: "Rename Template",
                message: "Enter a new name for '\(item.name)'",
                defaultValue: item.name
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
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
            
            // Show the "Opening in Querious..." toast
            withAnimation { toastOpenDB = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toastOpenDB = false }
            }
            
            // Small delay to let the UI update, then connect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                do {
                    try QueriousConnector.connect(
                        orgId: orgId,
                        mysqlDbKey: mysqlDb,
                        username: userConfig.config.mysql_username,
                        password: userConfig.config.mysql_password,
                        queriousPath: userConfig.config.querious_path
                    )
                    LOG("Database connection initiated successfully")
                } catch {
                    // Handle specific credential errors
                    if let derr = error as? DBConnectError, case .missingCredentials = derr {
                        NotificationCenter.default.post(name: .showDatabaseSettings, object: nil)
                    }
                    
                    // Show error to user
                    showAlert(title: "Connection Error", message: error.localizedDescription)
                    LOG("Connect to DB failed", ctx: ["error": error.localizedDescription])
                }
            }
        }
        /// Escape a Swift string for use inside AppleScript string literal.
        private func appleScriptStringEscape(_ s: String) -> String {
            // Escape backslashes and double-quotes for AppleScript literal
            var out = s.replacingOccurrences(of: "\\", with: "\\\\")
            out = out.replacingOccurrences(of: "\"", with: "\\\"")
            return out
        }
        
        // Inline Template Editor Sheet
        struct TemplateInlineEditorSheet: View {
            let template: TemplateItem
            @Binding var text: String
            var fontSize: CGFloat
            var onSave: (String) -> Void
            var onCancel: () -> Void
            @State private var localText: String = ""
            @ObservedObject private var placeholderStore = PlaceholderStore.shared
            @State private var isEditingPlaceholders: Bool = false
            @State private var isDeletingPlaceholders: Bool = false
            @State private var editingNames: [String] = []
            @State private var editError: String? = nil
            @State private var deleteSelection: Set<String> = []
            @State private var editListVersion: Int = 0
            @State private var detectedFromFile: [String] = []
            
            // Find the NSTextView that backs the SwiftUI TextEditor so we can insert at caret / replace selection.
            private func activeEditorTextView() -> NSTextView? {
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView {
                    return tv
                }
                guard let contentView = NSApp.keyWindow?.contentView else { return nil }
                return findTextView(in: contentView)
            }
            private func findTextView(in view: NSView) -> NSTextView? {
                if let tv = view as? NSTextView { return tv }
                for sub in view.subviews {
                    if let found = findTextView(in: sub) { return found }
                }
                return nil
            }
            
            // Insert {{placeholder}} at the current caret or replace the current selection.
            private func insertPlaceholder(_ name: String) {
                let token = "{{\(name)}}"
                let current = self.localText
                guard let tv = activeEditorTextView() else {
                    // Fallback: append to end if we can't resolve the text view yet.
                    self.localText.append(token)
                    self.text = self.localText
                    LOG("Inserted placeholder (no TV)", ctx: ["ph": name])
                    return
                }
                let ns = current as NSString
                var sel = tv.selectedRange()
                if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
                let safeLoc = max(0, min(sel.location, ns.length))
                let safeLen = max(0, min(sel.length, ns.length - safeLoc))
                let safeRange = NSRange(location: safeLoc, length: safeLen)
                let updated = ns.replacingCharacters(in: safeRange, with: token)
                self.localText = updated
                self.text = updated
                DispatchQueue.main.async {
                    tv.string = updated
                    let newCaret = NSRange(location: safeRange.location + (token as NSString).length, length: 0)
                    tv.setSelectedRange(newCaret)
                    tv.scrollRangeToVisible(newCaret)
                }
                LOG("Inserted placeholder", ctx: ["ph": name, "mode": safeLen > 0 ? "replace" : "insert"])
            }
            
            // Detects {{placeholder}} tokens in source, de-duplicated in order
            private func detectedPlaceholders(from source: String) -> [String] {
                do {
                    let regex = try NSRegularExpression(pattern: #"\{\{\s*([^}]+?)\s*\}\}"#, options: [])
                    let range = NSRange(source.startIndex..<source.endIndex, in: source)
                    var seen = Set<String>()
                    var results: [String] = []
                    regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
                        guard let m = match, m.numberOfRanges >= 2,
                              let r = Range(m.range(at: 1), in: source) else { return }
                        let name = source[r].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty, !seen.contains(name) {
                            seen.insert(name)
                            results.append(name)
                        }
                    }
                    return results
                } catch {
                    return []
                }
            }
            
            // Local prompt (editor scope)
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
                return alert.runModal() == .alertFirstButtonReturn
                ? input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            }
            
            private func sanitizeName(_ raw: String) -> String {
                raw.replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Add / Edit / Delete placeholder flows
            private func addPlaceholderFlow() {
                guard let raw = promptForString(
                    title: "Add Placeholder",
                    message: "Enter a placeholder name (do not include braces)."
                ) else { return }
                let cleaned = sanitizeName(raw)
                guard !cleaned.isEmpty else { return }
                if placeholderStore.names.contains(cleaned) {
                    let dup = NSAlert()
                    dup.messageText = "Already Exists"
                    dup.informativeText = "A placeholder named \"\(cleaned)\" already exists."
                    dup.alertStyle = .warning
                    dup.addButton(withTitle: "OK")
                    dup.runModal()
                    return
                }
                placeholderStore.add(cleaned)
                LOG("Placeholder added via editor", ctx: ["name": cleaned])
            }
            
            private func startEditPlaceholders() {
                editingNames = placeholderStore.names
                editError = nil
                // Bump version so the sheet rebuilds with fresh data
                editListVersion &+= 1
                // Present on next runloop so data is ready before the sheet builds
                DispatchQueue.main.async {
                    isEditingPlaceholders = true
                }
                LOG("Edit placeholders started", ctx: ["count": "\(editingNames.count)"])
            }
            private func cancelEditPlaceholders() {
                isEditingPlaceholders = false
                editError = nil
            }
            private func applyEditPlaceholders() {
                var seen = Set<String>()
                var cleaned: [String] = []
                for raw in editingNames {
                    let name = sanitizeName(raw)
                    if name.isEmpty {
                        editError = "Placeholder names cannot be empty."
                        return
                    }
                    if !seen.insert(name).inserted {
                        editError = "Duplicate name: \"\(name)\""
                        return
                    }
                    cleaned.append(name)
                }
                placeholderStore.reorder(cleaned) // Use reorder instead of set to preserve order
                LOG("Edit placeholders applied with order", ctx: ["count": "\(cleaned.count)"])
                isEditingPlaceholders = false
                editError = nil
                
                // Force UI update
                DispatchQueue.main.async {
                    // The @Published property should automatically trigger UI updates
                }
            }
            private func startDeletePlaceholders() {
                deleteSelection = []
                isDeletingPlaceholders = true
                LOG("Delete placeholders started", ctx: ["count": "\(placeholderStore.names.count)"])
            }
            private func cancelDeletePlaceholders() {
                isDeletingPlaceholders = false
                deleteSelection = []
                LOG("Delete placeholders cancelled")
            }
            private func applyDeletePlaceholders() {
                guard !deleteSelection.isEmpty else { return }
                let names = Array(deleteSelection).sorted()
                // Confirm destructive action
                let alert = NSAlert()
                alert.messageText = "Delete \(names.count) placeholder\(names.count == 1 ? "" : "s")?"
                let previewList = names.prefix(6).joined(separator: ", ")
                let more = names.count > 6 ? " …and \(names.count - 6) more." : ""
                alert.informativeText = "This will remove the selected placeholders from the global list:\n\(previewList)\(more)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    LOG("Delete placeholders aborted at confirm")
                    return
                }
                // Apply deletion atomically
                let remaining = placeholderStore.names.filter { !deleteSelection.contains($0) }
                placeholderStore.set(remaining)
                LOG("Delete placeholders applied", ctx: ["deleted": "\(names.count)", "remaining": "\(remaining.count)"])
                isDeletingPlaceholders = false
                deleteSelection = []
            }
            
            // Toggle SQL comments ("-- ") on the current line(s) in the editor.
            // If all non-empty selected lines are commented, it will UNcomment; otherwise it will comment them.
            private func toggleCommentOnSelection() {
                guard let tv = activeEditorTextView() else {
                    NSSound.beep()
                    return
                }
                let ns = self.localText as NSString
                var sel = tv.selectedRange()
                if sel.location == NSNotFound {
                    sel = NSRange(location: 0, length: 0)
                }
                // Expand to full line range covering selection (or caret line)
                let lineRange = ns.lineRange(for: sel)
                let segment = ns.substring(with: lineRange)
                
                // Track trailing newline so we preserve it after transformation
                let hasTrailingNewline = segment.hasSuffix("\n")
                var lines = segment.components(separatedBy: "\n")
                if hasTrailingNewline { lines.removeLast() } // last element is "" from trailing newline
                
                // Decide if we are commenting or uncommenting
                // "commented" means: optional leading spaces + "--" optionally followed by a space
                let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let allAlreadyCommented = nonEmpty.allSatisfy { line in
                    let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
                    return trimmedLeading.hasPrefix("--")
                }
                
                var changedCount = 0
                let transformed: [String] = lines.map { line in
                    let original = line
                    let trimmed = original.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        return original // keep blank lines untouched
                    }
                    // Split leading whitespace
                    let leadingWhitespace = original.prefix { $0 == " " || $0 == "\t" }
                    let remainder = original.dropFirst(leadingWhitespace.count)
                    
                    if allAlreadyCommented {
                        // UNcomment: remove leading "--" and an optional single space after
                        if remainder.hasPrefix("--") {
                            let afterDashes = remainder.dropFirst(2)
                            let afterSpace = afterDashes.first == " " ? afterDashes.dropFirst() : afterDashes
                            changedCount += 1
                            return String(leadingWhitespace) + String(afterSpace)
                        } else {
                            return original
                        }
                    } else {
                        // Comment: insert "-- " after any leading indentation
                        changedCount += 1
                        return String(leadingWhitespace) + "-- " + String(remainder)
                    }
                }
                
                let updatedSegment = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
                let newString = ns.replacingCharacters(in: lineRange, with: updatedSegment)
                
                // Update SwiftUI and the NSTextView
                self.localText = newString
                self.text = newString
                tv.string = newString
                
                // Keep selection over the transformed block
                let newRange = NSRange(location: lineRange.location, length: (updatedSegment as NSString).length)
                tv.setSelectedRange(newRange)
                tv.scrollRangeToVisible(newRange)
                
                LOG("Toggle comment", ctx: [
                    "action": allAlreadyCommented ? "uncomment" : "comment",
                    "lines": "\(lines.count)",
                    "changed": "\(changedCount)"
                ])
            }
            
            // Insert visual divider at cursor position
            private func insertVisualDivider() {
                let dividerText = "---|-----------------**- xxxxxxx -**------------------------------|"
                let current = self.localText
                guard let tv = activeEditorTextView() else {
                    // Fallback: append to end if we can't resolve the text view yet.
                    self.localText.append("\n" + dividerText + "\n")
                    self.text = self.localText
                    LOG("Inserted visual divider (no TV)")
                    return
                }
                let ns = current as NSString
                var sel = tv.selectedRange()
                if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
                let safeLoc = max(0, min(sel.location, ns.length))
                let safeLen = max(0, min(sel.length, ns.length - safeLoc))
                let safeRange = NSRange(location: safeLoc, length: safeLen)
                
                // Add newlines around the divider for better formatting
                let insertText = "\n" + dividerText + "\n"
                let updated = ns.replacingCharacters(in: safeRange, with: insertText)
                self.localText = updated
                self.text = updated
                DispatchQueue.main.async {
                    tv.string = updated
                    let newCaret = NSRange(location: safeRange.location + (insertText as NSString).length, length: 0)
                    tv.setSelectedRange(newCaret)
                    tv.scrollRangeToVisible(newCaret)
                }
                LOG("Inserted visual divider", ctx: ["mode": safeLen > 0 ? "replace" : "insert"])
            }
            
            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Editing Template:")
                            .font(.system(size: fontSize + 2, weight: .semibold))
                        Text(template.name)
                            .font(.system(size: fontSize + 2, weight: .medium))
                            .foregroundStyle(Theme.purple)
                        Spacer()
                        Button {
                            toggleCommentOnSelection()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.quote")
                                Text("Comment/Uncomment")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize - 1))
                        .keyboardShortcut("/", modifiers: [.command]) // ⌘/
                        .help("Toggle '--' comments on selected lines (⌘/)")
                        
                        Button {
                            insertVisualDivider()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "minus.rectangle")
                                Text("Insert Divider")
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 1))
                        .keyboardShortcut("d", modifiers: [.command]) // ⌘D
                        .help("Insert visual divider (⌘D)")
                        
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.bordered)
                        Button("Save") { onSave(localText) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.pink)
                            .keyboardShortcut("s", modifiers: [.command]) // ⌘S to save
                            .help("Save (⌘S)")
                    }
                    .padding()
                    Divider()
                    // Placeholder toolbar (buttons insert {{name}} at caret)
                    if !placeholderStore.names.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text("Placeholders:")
                                    .font(.system(size: fontSize - 2))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, 4)
                                ForEach(Array(placeholderStore.names.enumerated()), id: \.element) { index, ph in
                                    Button(ph) { insertPlaceholder(ph) }
                                        .buttonStyle(.bordered)
                                        .tint(Theme.pink)
                                        .font(.system(size: fontSize - 1, weight: .medium))
                                        .help("Insert {{\(ph)}} at cursor")
                                }
                                Divider()
                                    .frame(height: 18)
                                    .overlay(Color.secondary.opacity(0.2))
                                    .padding(.horizontal, 4)
                                Menu {
                                    Button("Add new placeholder…") { addPlaceholderFlow() }
                                    Divider()
                                    Button("Edit placeholders…") { startEditPlaceholders() }
                                    Button("Delete placeholders…") { startDeletePlaceholders() }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.system(size: fontSize + 2, weight: .medium))
                                        .foregroundStyle(Theme.purple)
                                        .help("Placeholder options")
                                }
                                .menuStyle(.borderlessButton)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.grayBG.opacity(0.6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                                    )
                            )
                            .padding(.trailing, 12)
                        }
                    }
                    Divider()
                    TextEditor(text: $localText)
                        .font(.system(size: fontSize, design: .monospaced))
                        .frame(minHeight: 340)
                        .padding()
                        .onAppear {
                            localText = text
                            let found = detectedPlaceholders(from: localText)
                            detectedFromFile = found
                            LOG("Detected placeholders in file", ctx: ["detected": "\(found.count)"])
                        }
                        .onChange(of: localText) { _, newVal in text = newVal }
                    HStack {
                        Spacer()
                        Text("Tip: ⌘S to save, ⎋ to cancel")
                            .font(.system(size: fontSize - 3))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .sheet(isPresented: $isEditingPlaceholders) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Edit Placeholders")
                            .font(.system(size: fontSize + 2, weight: .semibold))
                            .foregroundStyle(Theme.purple)
                            .padding(.bottom, 4)
                        
                        Text("Drag to reorder • Click to edit names")
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(.secondary)
                        
                        if let err = editError {
                            Text(err)
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.red)
                        }
                        
                        List {
                            ForEach(Array(editingNames.enumerated()), id: \.offset) { idx, name in
                                HStack(spacing: 8) {
                                    // Drag handle
                                    Image(systemName: "line.3.horizontal")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: fontSize - 1))
                                    
                                    Text("\(idx + 1).")
                                        .frame(width: 24, alignment: .trailing)
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: fontSize - 2))
                                    
                                    TextField("Placeholder name", text: Binding(
                                        get: { editingNames[idx] },
                                        set: { editingNames[idx] = $0 }
                                    ))
                                    .textFieldStyle(.plain)
                                    .font(.system(size: fontSize))
                                    .padding(.vertical, 2)
                                }
                                .padding(.vertical, 2)
                            }
                            .onMove(perform: { indices, newOffset in
                                editingNames.move(fromOffsets: indices, toOffset: newOffset)
                                LOG("Placeholders reordered in edit sheet", ctx: ["from": "\(indices)", "to": "\(newOffset)"])
                            })
                        }
                        .listStyle(.plain)
                        .frame(minHeight: 220)
                        
                        HStack {
                            Button("Cancel") { cancelEditPlaceholders() }
                                .font(.system(size: fontSize))
                            Spacer()
                            Button("Apply") { applyEditPlaceholders() }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.pink)
                                .font(.system(size: fontSize))
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 520, minHeight: 360)
                    .id(editListVersion)
                    .onAppear {
                        // Ensure list is populated and force a rebuild when the sheet appears
                        editingNames = placeholderStore.names
                        editListVersion &+= 1
                    }
                }
                .sheet(isPresented: $isDeletingPlaceholders) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Delete Placeholders")
                            .font(.system(size: fontSize + 2, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.bottom, 4)
                        HStack(spacing: 8) {
                            Button("Select All") {
                                deleteSelection = Set(placeholderStore.names)
                            }
                            .font(.system(size: fontSize - 1))
                            Button("Clear Selection") {
                                deleteSelection.removeAll()
                            }
                            .font(.system(size: fontSize - 1))
                            Spacer()
                            Text("\(deleteSelection.count) selected")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(placeholderStore.names, id: \.self) { name in
                                    Toggle(isOn: Binding<Bool>(
                                        get: { deleteSelection.contains(name) },
                                        set: { newVal in
                                            if newVal { deleteSelection.insert(name) }
                                            else { deleteSelection.remove(name) }
                                        }
                                    )) {
                                        Text(name)
                                            .font(.system(size: fontSize))
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(minHeight: 220)
                        HStack {
                            Button("Cancel") { cancelDeletePlaceholders() }
                                .font(.system(size: fontSize))
                            Spacer()
                            Button("Delete") { applyDeletePlaceholders() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .font(.system(size: fontSize))
                                .disabled(deleteSelection.isEmpty)
                        }
                    }
                    .padding(14)
                    .frame(minWidth: 520, minHeight: 360)
                }
                .frame(minWidth: 760, minHeight: 520)
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
        // MARK: - Session Image Row
        struct SessionImageRow: View {
            let image: SessionImage
            let fontSize: CGFloat
            let onDelete: (SessionImage) -> Void
            let onRename: (SessionImage) -> Void
            let onPreview: (SessionImage) -> Void

            var body: some View {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .foregroundStyle(Theme.aqua)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.displayName)
                                .font(.system(size: fontSize - 1, weight: .medium))

                            Text(formatDate(image.savedAt))
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .modifiers(.command)
                            .onEnded {
                                LOG("Session image preview", ctx: ["fileName": image.fileName])
                                onPreview(image)
                            }
                    )
                    .help("⌘-click to preview")
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Button("Open") {
                            openSessionImage(image)
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: fontSize - 3))
                        
                        Button("Rename") {
                            onRename(image)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.aqua)
                        .font(.system(size: fontSize - 3))
                        
                        Button("Delete") {
                            onDelete(image)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.system(size: fontSize - 3))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )
            }
            
            private func formatDate(_ date: Date) -> String {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }
            
            private func openSessionImage(_ image: SessionImage) {
                let imageURL = AppPaths.sessionImages.appendingPathComponent(image.fileName)
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    NSWorkspace.shared.open(imageURL)
                    LOG("Opened session image", ctx: ["fileName": image.fileName])
                } else {
                    LOG("Session image file not found", ctx: ["fileName": image.fileName])
                }
            }
        }

        struct TemplateGuideImageRow: View {
            let image: TemplateGuideImage
            let fontSize: CGFloat
            let onOpen: () -> Void
            let onRename: () -> Void
            let onDelete: () -> Void
            let onPreview: () -> Void

            var body: some View {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.fill")
                            .foregroundStyle(Theme.purple)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(image.displayName)
                                .font(.system(size: fontSize - 1, weight: .medium))

                            Text(formatDate(image.savedAt))
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        TapGesture()
                            .modifiers(.command)
                            .onEnded { onPreview() }
                    )
                    .help("⌘-click to preview")

                    Spacer()

                    HStack(spacing: 4) {
                        Button("Open") { onOpen() }
                            .buttonStyle(.bordered)
                            .font(.system(size: fontSize - 3))

                        Button("Rename") { onRename() }
                            .buttonStyle(.bordered)
                            .tint(Theme.purple)
                            .font(.system(size: fontSize - 3))

                        Button("Delete") { onDelete() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .font(.system(size: fontSize - 3))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                )
            }

            private func formatDate(_ date: Date) -> String {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }
        }

        private struct SessionImagePreviewSheet: View {
            let sessionImage: SessionImage

            private var imageURL: URL {
                AppPaths.sessionImages.appendingPathComponent(sessionImage.fileName)
            }

            private var imageExists: Bool {
                FileManager.default.fileExists(atPath: imageURL.path)
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    Text(sessionImage.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.purple)

                    ScrollView {
                        Group {
                            if let nsImage = NSImage(contentsOf: imageURL) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 640)
                                    .cornerRadius(10)
                                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.orange)
                                    Text("Unable to load image from disk")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(imageURL.path)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 8) {
                        Text(imageURL.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(imageURL)
                            LOG("Session image preview open", ctx: ["fileName": sessionImage.fileName])
                        }
                        .disabled(!imageExists)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                            LOG("Session image preview show in Finder", ctx: ["fileName": sessionImage.fileName])
                        }
                        .disabled(!imageExists)
                    }
                }
                .padding(20)
                .frame(minWidth: 420, minHeight: 360)
            }
        }

        private struct TemplateGuideImagePreviewSheet: View {
            let template: TemplateItem
            let guideImage: TemplateGuideImage

            private var imageURL: URL {
                TemplateGuideStore.shared.imageURL(for: guideImage, template: template)
            }

            private var imageExists: Bool {
                FileManager.default.fileExists(atPath: imageURL.path)
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    Text(guideImage.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.purple)

                    ScrollView {
                        Group {
                            if let nsImage = NSImage(contentsOf: imageURL) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 640)
                                    .cornerRadius(10)
                                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(.orange)
                                    Text("Unable to load image from disk")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(imageURL.path)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)

                    HStack(spacing: 8) {
                        Text(imageURL.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Open") {
                            NSWorkspace.shared.open(imageURL)
                        }
                        .disabled(!imageExists)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                        }
                        .disabled(!imageExists)
                    }
                }
                .padding(20)
                .frame(minWidth: 420, minHeight: 360)
            }
        }
        private func handleImagePaste() {
            let pasteboard = NSPasteboard.general
            
            guard pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue]) else {
                LOG("No PNG image found in clipboard")
                return
            }
            
            guard let imageData = pasteboard.data(forType: .png) else {
                LOG("Failed to get image data from clipboard")
                return
            }
            
            // Generate filename
            let sessionName = "Session\(sessions.current.rawValue)"
            let existingImages = sessions.sessionImages[sessions.current] ?? []
            let imageNumber = existingImages.count + 1
            let fileName = "\(sessionName)_\(String(format: "%03d", imageNumber)).png"
            
            do {
                // Save to session_images folder
                let imageURL = AppPaths.sessionImages.appendingPathComponent(fileName)
                try imageData.write(to: imageURL)
                
                // Create session image record
                let sessionImage = SessionImage(
                    fileName: fileName,
                    originalPath: nil,
                    savedAt: Date()
                )
                
                // Add to session manager
                sessions.addSessionImage(sessionImage, for: sessions.current)
                
                LOG("Image pasted and saved", ctx: [
                    "fileName": fileName,
                    "session": "\(sessions.current.rawValue)",
                    "size": "\(imageData.count)"
                ])
                
            } catch {
                LOG("Failed to save pasted image", ctx: ["error": error.localizedDescription])
            }
        }
    }
    
    
    // MARK: – Session Notes Sheet (Markdown editor + preview)
    struct SessionNotesSheet: View {
        var fontSize: CGFloat
        @Binding var text: String
        @Binding var isEditing: Bool
        @Binding var showToolbar: Bool
        
        @Environment(\.dismiss) private var dismiss
        @State private var localText: String = ""
        
        // Find the NSTextView backing the TextEditor so we can wrap selection.
        private func activeTextView() -> NSTextView? {
            if let tv = NSApp.keyWindow?.firstResponder as? NSTextView { return tv }
            guard let contentView = NSApp.keyWindow?.contentView else { return nil }
            func find(_ v: NSView) -> NSTextView? {
                if let tv = v as? NSTextView { return tv }
                for sub in v.subviews { if let f = find(sub) { return f } }
                return nil
            }
            return find(contentView)
        }
        
        private func wrapSelection(prefix: String, suffix: String? = nil) {
            guard let tv = activeTextView() else { return }
            var sel = tv.selectedRange()
            let ns = localText as NSString
            if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
            let safeLoc = max(0, min(sel.location, ns.length))
            let safeLen = max(0, min(sel.length, ns.length - safeLoc))
            let range = NSRange(location: safeLoc, length: safeLen)
            let suf = suffix ?? prefix
            let selected = ns.substring(with: range)
            let updated = ns.replacingCharacters(in: range, with: prefix + selected + suf)
            localText = updated
            text = updated
            DispatchQueue.main.async {
                tv.string = updated
                let newCaret = NSRange(location: range.location + (prefix as NSString).length + (selected as NSString).length + (suf as NSString).length, length: 0)
                tv.setSelectedRange(newCaret)
                tv.scrollRangeToVisible(newCaret)
            }
        }
        
        private func toggleInlineCode() { wrapSelection(prefix: "`") }
        private func toggleBold() { wrapSelection(prefix: "**") }
        private func toggleItalic() { wrapSelection(prefix: "*") }
        private func toggleUnderline() { wrapSelection(prefix: "<u>", suffix: "</u>") }
        private func toggleCodeBlock() { wrapSelection(prefix: "\n```\n", suffix: "\n```\n") }
        private func insertHR() { wrapSelection(prefix: "\n---\n", suffix: "") }
        
        private func applyHeading(_ level: Int) {
            guard let tv = activeTextView() else { return }
            var sel = tv.selectedRange()
            let ns = localText as NSString
            if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
            let lineRange = ns.lineRange(for: sel)
            let segment = ns.substring(with: lineRange)
            let prefix = String(repeating: "#", count: max(1, min(6, level))) + " "
            let updated = prefix + segment.trimmingCharacters(in: .whitespaces)
            let newString = ns.replacingCharacters(in: lineRange, with: updated)
            localText = newString
            text = newString
            tv.string = newString
        }
        
        private func applyList(prefix: String) {
            guard let tv = activeTextView() else { return }
            var sel = tv.selectedRange()
            let ns = localText as NSString
            if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
            let lineRange = ns.lineRange(for: sel)
            let segment = ns.substring(with: lineRange)
            let lines = segment.split(separator: "\n", omittingEmptySubsequences: false)
            let transformed = lines.map { l -> String in
                let s = String(l)
                if s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
                return prefix + s
            }.joined(separator: "\n")
            let newString = ns.replacingCharacters(in: lineRange, with: transformed)
            localText = newString
            text = newString
            tv.string = newString
        }
        
        private func insertLink() {
            guard let tv = activeTextView() else { return }
            var sel = tv.selectedRange()
            let ns = localText as NSString
            if sel.location == NSNotFound { sel = NSRange(location: ns.length, length: 0) }
            let selected = ns.substring(with: sel)
            let textLabel = selected.isEmpty ? "link" : selected
            
            let alert = NSAlert()
            alert.messageText = "Insert Link"
            alert.informativeText = "Enter a URL"
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "https://…"
            alert.accessoryView = input
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = "[\(textLabel)](\(url))"
            let updated = ns.replacingCharacters(in: sel, with: replacement)
            localText = updated
            text = updated
            tv.string = updated
        }
        
        private var previewView: some View {
            ScrollView {
                let rendered: Text = {
                    if let attr = try? AttributedString(markdown: localText) {
                        return Text(attr)
                    } else {
                        return Text(localText)
                    }
                }()
                rendered
                    .font(.system(size: fontSize))
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.grayBG.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        
        private var editorView: some View {
            VStack(spacing: 8) {
                if showToolbar {
                    HStack(spacing: 8) {
                        Button { toggleBold() } label: { Image(systemName: "bold") }.keyboardShortcut("b", modifiers: [.command])
                        Button { toggleItalic() } label: { Image(systemName: "italic") }.keyboardShortcut("i", modifiers: [.command])
                        Button { toggleUnderline() } label: { Image(systemName: "underline") }.keyboardShortcut("u", modifiers: [.command])
                        Button { insertLink() } label: { Image(systemName: "link") }.keyboardShortcut("k", modifiers: [.command])
                        Divider()
                        Button { toggleInlineCode() } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        Button { toggleCodeBlock() } label: { Image(systemName: "square.grid.3x3") }
                        Button { insertHR() } label: { Image(systemName: "scribble.variable") }
                        Divider()
                        Button { applyHeading(1) } label: { Text("H1") }
                        Button { applyHeading(2) } label: { Text("H2") }
                        Button { applyHeading(3) } label: { Text("H3") }
                        Divider()
                        Button { applyList(prefix: "- ") } label: { Image(systemName: "list.bullet") }
                        Button { applyList(prefix: "1. ") } label: { Image(systemName: "list.number") }
                    }
                    .font(.system(size: fontSize - 1))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.grayBG.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                            )
                    )
                }
                TextEditor(text: $localText)
                    .font(.system(size: fontSize))
                    .frame(minHeight: 360)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.aqua.opacity(0.25)))
            }
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Session Notes")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.aqua)
                    Spacer()
                    Picker("Mode", selection: $isEditing) {
                        Text("Preview").tag(false)
                        Text("Edit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $showToolbar) {
                        Image(systemName: "textformat")
                    }
                    .toggleStyle(.switch)
                    .help("Show/Hide formatting toolbar")
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
                
                if isEditing { editorView } else { previewView }
                
                HStack {
                    Spacer()
                    Text("Shortcuts: ⌘B Bold • ⌘I Italic • ⌘U Underline • ⌘K Link")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .onAppear {
                self.localText = text
            }
            .onChange(of: localText) { _, newVal in
                self.text = newVal
            }
        }
    }
    // MARK: – Session Notes Inline (sidebar)
    struct MarkdownToolbar: View {
        var iconSize: CGFloat
        var isEnabled: Bool = true
        @ObservedObject var controller: MarkdownEditorController

        var body: some View {
            let size = max(14, iconSize)
            HStack(spacing: 10) {
                Button(action: controller.bold) {
                    Image(systemName: "textformat.bold")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.italic) {
                    Image(systemName: "textformat.italic")
                        .font(.system(size: size, weight: .semibold))
                }
                Menu {
                    Button("Heading 1") { controller.heading(level: 1) }
                    Button("Heading 2") { controller.heading(level: 2) }
                    Button("Heading 3") { controller.heading(level: 3) }
                    Button("Heading 4") { controller.heading(level: 4) }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: size + 1, weight: .semibold))
                }
                Button(action: controller.inlineCode) {
                    Image(systemName: "chevron.left.slash.chevron.right")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.codeBlock) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.blockQuote) {
                    Image(systemName: "text.quote")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.bulletList) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.numberedList) {
                    Image(systemName: "list.number")
                        .font(.system(size: size, weight: .semibold))
                }
                Button(action: controller.horizontalRule) {
                    Image(systemName: "minus")
                        .font(.system(size: size - 1, weight: .semibold))
                }
                Button(action: controller.link) {
                    Image(systemName: "link")
                        .font(.system(size: size, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.grayBG.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .disabled(!isEnabled)
        }
    }

    struct PreviewModeToggle: View {
        @Binding var isPreview: Bool

        var body: some View {
            HStack(spacing: 6) {
                modeButton(title: "Edit", isActive: !isPreview) {
                    isPreview = false
                }

                modeButton(title: "Preview", isActive: isPreview) {
                    isPreview = true
                }
            }
        }

        @ViewBuilder
        private func modeButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
            Button(title, action: action)
                .font(.system(size: 12, weight: .semibold))
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(isActive ? Theme.purple : Theme.grayBG.opacity(0.4))
                .foregroundStyle(isActive ? Color.white : Theme.purple)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Theme.purple.opacity(isActive ? 1.0 : 0.6), lineWidth: 1)
                )
        }
    }

    struct SessionNotesInline: View {
        var fontSize: CGFloat
        var session: TicketSession
        @Binding var draft: String
        var savedValue: String
        @ObservedObject var controller: MarkdownEditorController
        @Binding var isPreview: Bool
        var onSave: () -> Void
        var onRevert: () -> Void
        var onLinkRequested: (_ selectedText: String, _ source: MarkdownEditor.LinkRequestSource, _ completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) -> Void

        private var isDirty: Bool { draft != savedValue }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Session Notes")
                        .font(.system(size: fontSize - 1, weight: .semibold))
                        .foregroundStyle(Theme.aqua)

                    MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !isPreview, controller: controller)
                    PreviewModeToggle(isPreview: $isPreview)

                    Spacer()

                    if isDirty {
                        Button("Save Notes") { onSave() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.purple)
                            .font(.system(size: fontSize - 2))

                        Button("Revert") { onRevert() }
                            .buttonStyle(.bordered)
                            .tint(Theme.pink)
                            .font(.system(size: fontSize - 2))
                    }
                }

                Group {
                    if isPreview {
                        MarkdownPreviewView(text: draft, fontSize: fontSize)
                    } else {
                        MarkdownEditor(
                            text: $draft,
                            fontSize: fontSize,
                            controller: controller,
                            onLinkRequested: onLinkRequested
                        )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.grayBG.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                        )
                )
            }
            .padding(6)
            .frame(maxWidth: .infinity)
        }
    }
    
    // MARK: - Template Link Row
    struct TemplateLinkRow: View {
        let link: TemplateLink
        let fontSize: CGFloat
        let onOpen: () -> Void
        let onEdit: () -> Void
        let onDelete: () -> Void
        @Binding var hoveredLinkID: UUID?

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(Theme.aqua)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .lineLimit(1)

                    Text(link.url)
                        .font(.system(size: fontSize - 3))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .onHover { hovering in
                    if hovering {
                        hoveredLinkID = link.id
                    } else if hoveredLinkID == link.id {
                        hoveredLinkID = nil
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Button("Open") { onOpen() }
                        .buttonStyle(.bordered)
                        .font(.system(size: fontSize - 3))
                    
                    Button("Edit") { onEdit() }
                        .buttonStyle(.bordered)
                        .font(.system(size: fontSize - 3))
                    
                    Button("Delete") { onDelete() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .font(.system(size: fontSize - 3))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(alignment: .topLeading) {
                if shouldShowTooltip, let tooltip = linkTooltip {
                    LinkTooltipBubble(text: tooltip)
                        .offset(x: 28, y: -6)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(100)
                        .compositingGroup()
                        .drawingGroup()
                }
            }
            .onDisappear {
                if hoveredLinkID == link.id {
                    hoveredLinkID = nil
                }
            }
            .animation(.easeInOut(duration: 0.12), value: shouldShowTooltip)
        }

        private var linkTooltip: String? {
            let name = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)

            var parts: [String] = []
            if !name.isEmpty { parts.append(name) }
            if !url.isEmpty { parts.append(url) }

            if parts.isEmpty {
                return nil
            }

            return parts.joined(separator: "\n")
        }

        private var shouldShowTooltip: Bool {
            hoveredLinkID == link.id && linkTooltip != nil
        }
    }

    private struct LinkTooltipBubble: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .compositingGroup()
                .drawingGroup()
        }
    }
