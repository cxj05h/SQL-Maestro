import SwiftUI
import MarkdownUI
import AppKit
import UniformTypeIdentifiers

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Workaround for macOS 26 (Tahoe) NSAlert button rendering bug
// where default buttons don't show blue highlight until window loses/regains focus
fileprivate func runAlertWithFix(_ alert: NSAlert) -> NSApplication.ModalResponse {
    // Use asyncAfter with minimal delay to ensure window is shown
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        // Style the default button (first button with return key equivalent)
        for button in alert.buttons {
            if button.keyEquivalent == "\r" {
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                button.layer?.cornerRadius = 6
                button.layer?.borderWidth = 0

                // Force white text color
                let title = button.title
                let attrTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: NSColor.white
                ])
                button.attributedTitle = attrTitle

                // Force redraw
                button.needsDisplay = true
                button.layer?.setNeedsDisplay()
                alert.window.displayIfNeeded()
                break
            }
        }
    }

    return alert.runModal()
}

private let markdownFileLinkRegex: NSRegularExpression = {
    let pattern = #"!?\[([^\]]*)\]\(([^)]+)\)"#
    return try! NSRegularExpression(pattern: pattern, options: [])
}()

private let orgIdRegex: NSRegularExpression = {
    let pattern = #"(?<!\d)(\d{12})(?!\d)"#
    return try! NSRegularExpression(pattern: pattern, options: [])
}()

private let accountIdRegex: NSRegularExpression = {
    let pattern = #"(?i)\b(act-[a-z0-9_-]+)\b"#
    return try! NSRegularExpression(pattern: pattern, options: [])
}()

@MainActor
final class SessionNotesAutosaveCoordinator: ObservableObject {
    private struct Entry {
        let workItem: DispatchWorkItem
        let action: () -> Void
    }

    private var entries: [TicketSession: Entry] = [:]

    func schedule(for session: TicketSession, delay: TimeInterval, action: @escaping () -> Void) {
        cancel(for: session)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  self.entries.removeValue(forKey: session) != nil else { return }
            action()
        }
        entries[session] = Entry(workItem: workItem, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush(for session: TicketSession) {
        guard let entry = entries.removeValue(forKey: session) else { return }
        entry.workItem.cancel()
        DispatchQueue.main.async(execute: entry.action)
    }

    func cancel(for session: TicketSession) {
        guard let entry = entries.removeValue(forKey: session) else { return }
        entry.workItem.cancel()
    }

    func cancelAll() {
        let toCancel = Array(entries.values)
        entries.removeAll(keepingCapacity: false)
        for entry in toCancel {
            entry.workItem.cancel()
        }
    }
}

@MainActor
final class GuideNotesAutosaveCoordinator: ObservableObject {
    private struct Entry {
        let workItem: DispatchWorkItem
        let action: () -> Void
    }

    private var entries: [UUID: Entry] = [:]

    func schedule(for templateId: UUID, delay: TimeInterval, action: @escaping () -> Void) {
        cancel(for: templateId)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.entries.removeValue(forKey: templateId) != nil else { return }
            action()
        }
        entries[templateId] = Entry(workItem: workItem, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush(for templateId: UUID) {
        guard let entry = entries.removeValue(forKey: templateId) else { return }
        entry.workItem.cancel()
        DispatchQueue.main.async(execute: entry.action)
    }

    func cancel(for templateId: UUID) {
        guard let entry = entries.removeValue(forKey: templateId) else { return }
        entry.workItem.cancel()
    }

    func cancelAll() {
        let existing = entries.values
        entries.removeAll(keepingCapacity: false)
        for entry in existing {
            entry.workItem.cancel()
        }
    }
}
@MainActor
final class SavedFileAutosaveCoordinator: ObservableObject {
    private struct Key: Hashable {
        var session: TicketSession
        var fileId: UUID
    }

    private struct Entry {
        let workItem: DispatchWorkItem
        let action: () -> Void
    }

    private var entries: [Key: Entry] = [:]

    func schedule(session: TicketSession, fileId: UUID, delay: TimeInterval, action: @escaping () -> Void) {
        let key = Key(session: session, fileId: fileId)
        cancel(session: session, fileId: fileId)
        let workItem = DispatchWorkItem { [weak self] in
            guard let entry = self?.entries.removeValue(forKey: key) else { return }
            entry.action()
        }
        entries[key] = Entry(workItem: workItem, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush(session: TicketSession, fileId: UUID) {
        let key = Key(session: session, fileId: fileId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.workItem.cancel()
        DispatchQueue.main.async(execute: entry.action)
    }

    func cancel(session: TicketSession, fileId: UUID) {
        let key = Key(session: session, fileId: fileId)
        if let entry = entries.removeValue(forKey: key) {
            entry.workItem.cancel()
        }
    }

    func cancelAll(for session: TicketSession) {
        let keys = entries.keys.filter { $0.session == session }
        for key in keys {
            entries.removeValue(forKey: key)?.workItem.cancel()
        }
    }

    func cancelAll() {
        entries.values.forEach { $0.workItem.cancel() }
        entries.removeAll()
    }
}

@MainActor
final class DBTablesAutosaveCoordinator: ObservableObject {
    private struct Key: Hashable {
        var session: TicketSession
        var templateId: UUID
    }

    private struct Entry {
        let workItem: DispatchWorkItem
        let action: () -> Void
    }

    private var entries: [Key: Entry] = [:]

    func schedule(session: TicketSession, templateId: UUID, delay: TimeInterval, action: @escaping () -> Void) {
        let key = Key(session: session, templateId: templateId)
        cancel(session: session, templateId: templateId)
        let workItem = DispatchWorkItem { [weak self] in
            guard let entry = self?.entries.removeValue(forKey: key) else { return }
            entry.action()
        }
        entries[key] = Entry(workItem: workItem, action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func flush(session: TicketSession, templateId: UUID) {
        let key = Key(session: session, templateId: templateId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.workItem.cancel()
        DispatchQueue.main.async(execute: entry.action)
    }

    func cancel(session: TicketSession, templateId: UUID) {
        let key = Key(session: session, templateId: templateId)
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.workItem.cancel()
    }

    func cancelAll(for session: TicketSession) {
        let matches = entries.filter { $0.key.session == session }
        for (key, entry) in matches {
            entry.workItem.cancel()
            entries.removeValue(forKey: key)
        }
    }

    func cancelAll() {
        entries.values.forEach { $0.workItem.cancel() }
        entries.removeAll()
    }
}

enum SessionTemplateTab {
    case sessionImages
    case guideImages
    case templateLinks
}

enum SessionNotesPaneMode: Hashable {
    case notes
    case savedFiles
}

enum BottomPaneContent: Hashable {
    case guideNotes
    case sessionNotes
    case savedFiles
}

enum PopoutPaneContext: Identifiable {
    case guide
    case session(TicketSession)
    case saved(TicketSession)
    case sessionTemplate(TicketSession)

    var id: String {
        switch self {
        case .guide:
            return "guide"
        case .session(let session):
            return "session-\(session.rawValue)"
        case .saved(let session):
            return "saved-\(session.rawValue)"
        case .sessionTemplate(let session):
            return "sessionTemplate-\(session.rawValue)"
        }
    }
}

enum JSONValidationState: Equatable {
    case valid
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

struct SavedFileTreePreviewContext: Identifiable {
    let id = UUID()
    let fileName: String
    let content: String
    let format: SavedFileFormat
}

struct GhostOverlayContext: Identifiable {
    let id = UUID()
    let session: TicketSession
    let availableFiles: [SessionSavedFile]
    var originalFile: SessionSavedFile?
    var ghostFile: SessionSavedFile?
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

// MARK: – Quick capture (Begin) workflow support types
private struct BeginCaptureEntry: Identifiable, Equatable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String = "") {
        self.id = id
        self.value = value
    }
}

private enum BeginFieldFocus: Hashable {
    case org
    case acct
    case extra(UUID)
}

private enum BeginButtonFocus: Hashable {
    case cancel
    case save
}

private struct BeginCaptureSheet: View {
    @Binding var orgValue: String
    @Binding var acctValue: String
    @Binding var extraValues: [BeginCaptureEntry]
    var onAutoPopulate: () -> Void
    var onSave: () -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var clipboardHistory: ClipboardHistory
    @State private var focusedField: BeginFieldFocus? = .org
    @FocusState private var focusedButton: BeginButtonFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Capture")
                .font(.system(size: 20, weight: .semibold))
            Text("Paste identifiers fast, use ⌘↩ to add rows, and press Return to Save.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                BeginCaptureField(text: $orgValue,
                                  placeholder: "Org ID",
                                  focus: .org,
                                  focusedField: $focusedField,
                                  onReturn: moveFocusAfterOrg,
                                  onTab: moveFocusAfterOrg,
                                  onCommandReturn: triggerCommandAddRow)

                BeginCaptureField(text: $acctValue,
                                  placeholder: "Account ID",
                                  focus: .acct,
                                  focusedField: $focusedField,
                                  onReturn: moveFocusAfterAcct,
                                  onTab: moveFocusAfterAcct,
                                  onCommandReturn: triggerCommandAddRow)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach($extraValues) { $entry in
                        BeginCaptureField(text: $entry.value,
                                          placeholder: "Additional value",
                                          focus: .extra(entry.id),
                                          focusedField: $focusedField,
                                          onReturn: { moveFocusAfterExtra(entry.id) },
                                          onTab: { handleTabFromExtra(entry.id) },
                                          onCommandReturn: triggerCommandAddRow)
                    }
                    if extraValues.isEmpty {
                        Text("Press Return to add more fields.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack {
                Button("Auto Populate") {
                    onAutoPopulate()
                }
                .buttonStyle(.bordered)
                .disabled(clipboardHistory.recentStrings.isEmpty)
                .help("Fill the fields using the last copied clipboard items captured while SQL Maestro is open.")

                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .focusable(true)
                .focused($focusedButton, equals: .cancel)

                Button("Save") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .focusable(true)
                .focused($focusedButton, equals: .save)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            ensureSeedEntry()
            focusedField = .org
        }
        .onChange(of: focusedField) { _, _ in
            focusedButton = nil
        }
        .overlay(
            Button(action: triggerCommandAddRow) {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0.0001)
            .allowsHitTesting(false)
        )
    }

    private func ensureSeedEntry() {
        if extraValues.isEmpty {
            extraValues = [BeginCaptureEntry()]
        }
    }

    private func cycleButtonFocus() {
        focusedField = nil
        switch focusedButton {
        case .cancel:
            focusedButton = .save
        case .save:
            focusedButton = .cancel
        default:
            focusedButton = .cancel
        }
        focusedField = nil
    }

    private func moveFocusAfterOrg() {
        focusedField = .acct
        focusedButton = nil
    }

    private func moveFocusAfterAcct() {
        ensureSeedEntry()
        focusedButton = nil
        if let first = extraValues.first {
            focusedField = .extra(first.id)
        }
    }

    private func moveFocusAfterExtra(_ id: UUID) {
        guard let idx = extraValues.firstIndex(where: { $0.id == id }) else { return }
        focusedButton = nil
        if idx == extraValues.indices.last {
            let newEntry = appendNewExtraRow()
            focusedField = .extra(newEntry.id)
        } else {
            let nextId = extraValues[extraValues.index(after: idx)].id
            focusedField = .extra(nextId)
        }
    }

    private func handleTabFromExtra(_: UUID) {
        focusedField = nil
        cycleButtonFocus()
    }

    @discardableResult
    private func appendNewExtraRow() -> BeginCaptureEntry {
        let entry = BeginCaptureEntry()
        extraValues.append(entry)
        return entry
    }

    private func triggerCommandAddRow() {
        ensureSeedEntry()
        focusedButton = nil
        let entry = appendNewExtraRow()
        focusedField = .extra(entry.id)
    }
}

private struct BeginCaptureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focus: BeginFieldFocus
    @Binding var focusedField: BeginFieldFocus?
    var onReturn: () -> Void
    var onTab: () -> Void
    var onCommandReturn: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> BeginTextField {
        let field = BeginTextField()
        field.isBordered = true
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.onReturn = {
            onReturn()
        }
        field.onTab = {
            onTab()
        }
        field.onCommandReturn = {
            onCommandReturn()
        }
        return field
    }

    func updateNSView(_ nsView: BeginTextField, context: Context) {
        nsView.placeholderString = placeholder
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onReturn = {
            onReturn()
        }
        nsView.onTab = {
            onTab()
        }
        nsView.onCommandReturn = {
            onCommandReturn()
        }
        if focusedField == focus {
            let currentEditor = nsView.currentEditor()
            if nsView.window?.firstResponder !== currentEditor {
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                    if let editor = nsView.currentEditor() {
                        let length = editor.string.count
                        editor.selectedRange = NSRange(location: length, length: 0)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BeginCaptureField

        init(_ parent: BeginCaptureField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                let cleaned = sanitized(field.stringValue, for: parent.focus)
                if cleaned != field.stringValue {
                    field.stringValue = cleaned
                }
                parent.text = cleaned
                if let editor = field.currentEditor() {
                    let length = editor.string.count
                    editor.selectedRange = NSRange(location: length, length: 0)
                }
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.focusedField = parent.focus
            if let field = obj.object as? NSTextField {
                let cleaned = sanitized(field.stringValue, for: parent.focus)
                if cleaned != field.stringValue {
                    field.stringValue = cleaned
                    parent.text = cleaned
                }
                DispatchQueue.main.async {
                    if let editor = field.currentEditor() {
                        let length = editor.string.count
                        editor.selectedRange = NSRange(location: length, length: 0)
                    }
                }
            }
        }

        private func sanitized(_ text: String, for focus: BeginFieldFocus) -> String {
            switch focus {
            case .org:
                return text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            case .acct:
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case .extra(_):
                return text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
        }
    }

    final class BeginTextField: NSTextField {
        var onReturn: (() -> Void)?
        var onTab: (() -> Void)?
        var onCommandReturn: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isEditable = true
            isSelectable = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36: // Return
                if event.modifierFlags.contains(.command) {
                    window?.makeFirstResponder(nil)
                    onCommandReturn?()
                    return
                }
                window?.makeFirstResponder(nil)
                onReturn?()
            case 48: // Tab
                window?.makeFirstResponder(nil)
                onTab?()
            default:
                super.keyDown(with: event)
            }
        }

        override func selectText(_ sender: Any?) {
            super.selectText(sender)
            guard sender is NSApplication else { return }
            DispatchQueue.main.async { [weak self] in
                if let editor = self?.currentEditor() {
                    let length = editor.string.count
                    editor.selectedRange = NSRange(location: length, length: 0)
                }
            }
        }

        override func textDidChange(_ notification: Notification) {
            super.textDidChange(notification)
            if let editor = currentEditor() {
                let length = editor.string.count
                editor.selectedRange = NSRange(location: length, length: 0)
            }
        }
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
    var onLinkOpen: ((URL, NSEvent.ModifierFlags) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            NonBubblingScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    previewMarkdown
                        .frame(width: geometry.size.width - 16, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, fontSize * 3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.clear)
            .environment(\.openURL, makeOpenURLAction())
        }
    }

    private var previewMarkdown: some View {
        Markdown(processedText)
            .markdownTheme(previewTheme)
            .markdownSoftBreakMode(.lineBreak)
            .markdownMargin(top: 0, bottom: 0)
            .padding(.vertical, 2)
            .textSelection(.enabled)
    }

    private var processedText: String {
        text.replacingOccurrences(of: "=>", with: "→")
    }

    private var previewTheme: MarkdownUI.Theme {
        let inlineFill: Color
        let textColor: Color

        if colorScheme == .dark {
            inlineFill = Color(nsColor: NSColor(calibratedWhite: 0.85, alpha: 1.0))
            textColor = .primary
        } else {
            inlineFill = Color(nsColor: NSColor(calibratedWhite: 0.9, alpha: 1.0))
            textColor = .white
        }

        return MarkdownUI.Theme.gitHub
            .text {
                FontSize(fontSize)
                ForegroundColor(textColor)
            }
            .code { InlineCodeTextStyle(fontSize: fontSize, fill: inlineFill, foreground: .black) }
            .strong {
                ForegroundColor(Theme.gold)
                FontWeight(.semibold)
            }
            .emphasis {
                ForegroundColor(Theme.pink)
                FontStyle(.italic)
            }
            .codeBlock { configuration in
                codeBlock(configuration, fill: inlineFill)
            }
    }

    @ViewBuilder
    private func codeBlock(_ configuration: CodeBlockConfiguration, fill: Color) -> some View {
        ScrollView(.horizontal) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(RelativeSize.em(0.225))
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(fontSize)
                    ForegroundColor(.black)
                }
                .padding(16)
        }
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(fill.opacity(0.35), lineWidth: 1)
        )
        .markdownMargin(top: 0, bottom: 16)
    }

    private func makeOpenURLAction() -> OpenURLAction {
        OpenURLAction { url in
#if canImport(AppKit)
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if let handler = onLinkOpen {
                handler(url, modifiers)
            } else {
                NSWorkspace.shared.open(url)
            }
            return .handled
#else
            return .systemAction
#endif
        }
    }
}

private struct MonospacedTextStyle: TextStyle {
    var size: CGFloat

    func _collectAttributes(in attributes: inout AttributeContainer) {
        FontFamilyVariant(.monospaced)._collectAttributes(in: &attributes)
        FontSize(size)._collectAttributes(in: &attributes)
    }
}

private struct InlineCodeTextStyle: TextStyle {
    var fontSize: CGFloat
    var fill: Color
    var foreground: Color

    func _collectAttributes(in attributes: inout AttributeContainer) {
        FontFamilyVariant(.monospaced)._collectAttributes(in: &attributes)
        FontSize(fontSize)._collectAttributes(in: &attributes)
        BackgroundColor(fill)._collectAttributes(in: &attributes)
        attributes.foregroundColor = foreground
    }
}

/// Scroll view used inside nested panes to swallow edge scroll events so the parent view doesn't move.
private struct NonBubblingScrollView<Content: View>: NSViewRepresentable {
    var showsIndicators: Bool
    var content: Content

    init(showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NonBubblingNSScrollView {
        let scrollView = NonBubblingNSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = showsIndicators
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = showsIndicators
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false

        // Enable layer-backing and clipping to prevent content overflow
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = true
        scrollView.documentView = hosting
        context.coordinator.hostingView = hosting

        if let clipView = scrollView.contentView as? NSClipView {
            // Enable clipping on the clip view itself
            clipView.wantsLayer = true
            clipView.layer?.masksToBounds = true

            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: clipView.topAnchor),
                hosting.widthAnchor.constraint(equalTo: clipView.widthAnchor)
            ])

            let bottom = hosting.bottomAnchor.constraint(greaterThanOrEqualTo: clipView.bottomAnchor)
            bottom.priority = .defaultLow
            bottom.isActive = true
        }

        return scrollView
    }

    func updateNSView(_ nsView: NonBubblingNSScrollView, context: Context) {
        if let hosting = context.coordinator.hostingView {
            hosting.rootView = content
        }
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

final class NonBubblingNSScrollView: NSScrollView {
    enum ScrollDecision {
        case passToParent
        case swallow
        case handle
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        contentView.copiesOnScroll = false
    }

    func scrollDecision(for event: NSEvent) -> ScrollDecision {
        guard let documentView = documentView else {
            return .handle
        }

        let docBounds = documentView.bounds
        let visibleRect = contentView.documentVisibleRect
        let maxOffsetY = max(docBounds.height - visibleRect.height, 0)
        let hasScrollableContent = maxOffsetY > 0.5

        let scrollingUp = event.scrollingDeltaY > 0
        let scrollingDown = event.scrollingDeltaY < 0
        let epsilon: CGFloat = 1.0
        let atTop = visibleRect.minY <= docBounds.minY + epsilon
        let atBottom = visibleRect.maxY >= docBounds.maxY - epsilon

        if !hasScrollableContent {
            return .passToParent
        }

        if (scrollingUp && atTop) || (scrollingDown && atBottom) {
            return .swallow
        }

        return .handle
    }

    override func scrollWheel(with event: NSEvent) {
        switch scrollDecision(for: event) {
        case .passToParent:
            nextResponder?.scrollWheel(with: event)
        case .swallow:
            return
        case .handle:
            let originalNextResponder = nextResponder
            nextResponder = nil
            super.scrollWheel(with: event)
            nextResponder = originalNextResponder
        }
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
    static let attemptAppExit = Notification.Name("AttemptAppExit")
    // `showDatabaseSettings` is declared elsewhere to avoid duplicate symbol errors.
    static let beginQuickCaptureRequested = Notification.Name("BeginQuickCaptureRequested")
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
    @Environment(\.tabID) var tabID
    @Environment(\.isActiveTab) var isActiveTab
    @Environment(\.tabContext) var tabContext
    @EnvironmentObject var templates: TemplateManager
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var exitCoordinator: AppExitCoordinator
    @EnvironmentObject var clipboardHistory: ClipboardHistory
    @StateObject private var mapping = MappingStore()
    @StateObject private var mysqlHosts = MysqlHostStore()
    @StateObject private var userConfig = UserConfigStore()
    @State private var selectedSessionTemplateTab: SessionTemplateTab = .templateLinks
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject private var dbTablesStore = DBTablesStore.shared
    @ObservedObject private var dbTablesCatalog = DBTablesCatalog.shared
    @ObservedObject private var templateLinksStore = TemplateLinksStore.shared
    @ObservedObject private var templateTagsStore = TemplateTagsStore.shared
    @ObservedObject private var templateGuideStore = TemplateGuideStore.shared
    @ObservedObject private var usedTemplates = UsedTemplatesStore.shared
    @State private var selectedTemplate: TemplateItem?
    @State private var currentSQL: String = ""
    @State private var populatedSQL: String = ""
    // Toasts
    @State private var toastCopied: Bool = false
    @State private var toastOpenDB: Bool = false
    @State private var toastTemplatesMessage: String? = nil
    @State private var imageAttachmentToast: String? = nil
    @State private var toastPreviewBehind: Bool = false

    // Copy Individual progress
    @State private var showCopyWarning: Bool = false
    @State private var copyProgressMessage: String = ""
    @State private var copySuccessMessage: String = ""

    @State private var alternateFieldsLocked: Bool = true
    @State private var alternateFieldsReorderMode: Bool = false
    @State private var draggedAlternateField: UUID?

    @State private var fontSize: CGFloat = 13
    @State private var hoverRecentKey: String? = nil
    @State private var previewingSessionImage: SessionImage? = nil
    @State private var previewingGuideImageContext: GuideImagePreviewContext? = nil
    @State private var activeBottomPane: BottomPaneContent? = nil
    @State private var isOutputVisible: Bool = false
    @State private var guideNotesDraft: String = ""
    @State private var hoveredTemplateLinkID: UUID? = nil
    @State private var tagEditorTemplate: TemplateItem?
    @State private var tagExplorerContext: TagExplorerContext?
    @State private var showTagSearchDialog: Bool = false
    @State private var showGuideNotesSearchDialog: Bool = false
    @State private var guideNotesSearchKeyword: String = ""
    @State private var guideNotesInPaneSearchQuery: String = ""
    @State private var guideNotesSearchMatches: [Range<String.Index>] = []
    @State private var guideNotesCurrentMatchIndex: Int = 0
    @State private var sessionNotesInPaneSearchQuery: String = ""
    @State private var sessionNotesSearchMatches: [Range<String.Index>] = []
    @State private var sessionNotesCurrentMatchIndex: Int = 0
    @State private var activePopoutPane: PopoutPaneContext? = nil
    @State private var isSidebarVisible: Bool = false
    struct TagExplorerContext: Identifiable {
        let tag: String
        var id: String { tag }
    }
    struct TagSearchResult: Identifiable, Equatable {
        let tag: String
        let templates: [TemplateItem]
        var id: String { tag }
        var count: Int { templates.count }

        static func == (lhs: TagSearchResult, rhs: TagSearchResult) -> Bool {
            lhs.tag == rhs.tag && lhs.templates.map { $0.id } == rhs.templates.map { $0.id }
        }
    }
    struct GuideImagePreviewContext: Identifiable {
        let template: TemplateItem
        let image: TemplateGuideImage
        var id: TemplateGuideImage.ID { image.id }
    }
    @State private var sessionNotesDrafts: [TicketSession: String] = [:]
    @State private var isLoadingTicketSession = false
    @State private var isSwitchingSession = false
    @StateObject private var sessionNotesEditor = MarkdownEditorController()
    @StateObject private var guideNotesEditor = MarkdownEditorController()
    @StateObject private var sessionNotesAutosave = SessionNotesAutosaveCoordinator()
    @StateObject private var guideNotesAutosave = GuideNotesAutosaveCoordinator()
    @StateObject private var savedFileAutosave = SavedFileAutosaveCoordinator()
    @StateObject private var dbTablesAutosave = DBTablesAutosaveCoordinator()
    @State private var isPreviewMode: Bool = true
    @State private var savedScrollPosition: CGFloat = 0.0
    @State private var sessionNotesMode: [TicketSession: SessionNotesPaneMode] = [
        .one: .notes,
        .two: .notes,
        .three: .notes
    ]
    @State private var savedFileDrafts: [TicketSession: [UUID: String]] = [:]
    @State private var selectedSavedFile: [TicketSession: UUID?] = [
        .one: nil,
        .two: nil,
        .three: nil
    ]
    @State private var savedFileValidation: [TicketSession: [UUID: JSONValidationState]] = [:]
    @State private var savedFileTreePreview: SavedFileTreePreviewContext?
    @State private var ghostOverlayContext: GhostOverlayContext?
    @State private var isSavedFileEditorFocused: Bool = false
    @State private var isGuideNotesEditorFocused: Bool = false
    @State private var isSessionNotesEditorFocused: Bool = false

    @State private var searchText: String = ""
    @State private var showShortcutsSheet: Bool = false
    @State private var showDatabaseSettings: Bool = false
    @State private var showTemplateEditor: Bool = false // (no longer controls presentation)
    @State private var editorTemplate: TemplateItem? = nil
    @State private var editorText: String = ""

    @State private var showBeginCaptureSheet: Bool = false
    @State private var beginOrgDraft: String = ""
    @State private var beginAcctDraft: String = ""
    @State private var beginExtraDrafts: [BeginCaptureEntry] = []

    private let hardStopRowHeight: CGFloat = 0
    private let paneRegionMinHeight: CGFloat = 420
    private let outputRegionHeight: CGFloat = 236
    private let bottomPaneEditorMinHeight: CGFloat = 236
    private let outputRegionSpacing: CGFloat = 12
    private let mainContentTopPadding: CGFloat = 0
    private let compactMainContentTopPadding: CGFloat = 0

    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    @FocusState private var focusedDBTableRow: Int?
    @FocusState private var isGuideNotesSearchFocused: Bool
    @FocusState private var isSessionNotesSearchFocused: Bool
    @FocusState private var isSavedFileSearchFocused: Bool
    @State private var dbTablesLocked: Bool = true
    @State private var suggestionIndexByRow: [Int: Int] = [:]
    @State private var selectedTagIndex: Int = 0
    @State private var keyEventMonitor: Any?
    @State private var scrollEventMonitor: Any?
    
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
    @State private var sessionSavedSnapshots: [TicketSession: SessionSnapshot] = [:]
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
    @State private var workspaceShortcutsRegistered = false
    
    
    
        var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            templatesPane
                .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 400)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onAppear {
            // Initialize session notes drafts from saved values on first load
            for session in [TicketSession.one, .two, .three] {
                if sessionNotesDrafts[session] == nil {
                    sessionNotesDrafts[session] = sessions.sessionNotes[session] ?? ""
                }
            }
            registerWorkspaceShortcutsIfNeeded()

            #if os(macOS)
            // Install keyboard event monitoring for DB table suggestions and word-wise navigation
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // First try DB suggestion handler (for arrow keys in suggestions)
                if let result = handleDBSuggestKeyEvent(event), result == nil {
                    return nil
                }

                // Then try word-wise selection handler (for Option+Arrow in text fields)
                if let result = handleWordwiseSelection(event), result == nil {
                    return nil
                }

                return event
            }
            updateScrollEventMonitor()
            #endif
        }
        .onDisappear {
            #if os(macOS)
            // Clean up keyboard event monitoring
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
            if let monitor = scrollEventMonitor {
                NSEvent.removeMonitor(monitor)
                scrollEventMonitor = nil
            }
            #endif
        }
        .onChange(of: isActiveTab) { newValue in
            LOG("Tab active state changed", ctx: ["tabId": tabID, "isActive": "\(newValue)"])
            guard newValue, let context = tabContext else { return }

            // Check if templates were reloaded while this tab was inactive
            if context.lastTemplateReload < tabManager.lastTemplateReload {
                LOG("Tab became active with stale templates, refreshing", ctx: [
                    "tabId": context.tabIdentifier,
                    "lastSeen": "\(context.lastTemplateReload)",
                    "lastReload": "\(tabManager.lastTemplateReload)"
                ])

                // Refresh selectedTemplate reference
                if let currentTemplate = selectedTemplate {
                    if let refreshed = templates.templates.first(where: { $0.id == currentTemplate.id }) {
                        selectedTemplate = refreshed
                        LOG("Template reference refreshed", ctx: ["template": refreshed.name])
                    }
                }

                // Mark this tab as having seen the latest reload
                context.markTemplateReloadSeen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
            handleFocusSearchShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGuideNotesRequested)) { _ in
            handleShowGuideNotesShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSessionNotesRequested)) { _ in
            handleShowSessionNotesShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSavedFilesRequested)) { _ in
            handleShowSavedFilesShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequested)) { _ in
            handleToggleSidebarShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchTagsRequested)) { _ in
            handleSearchTagsShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchGuideNotesRequested)) { _ in
            handleSearchGuideNotesShortcut()
        }
        .onChange(of: isGuideNotesEditorFocused) { _, newValue in
            #if os(macOS)
            updateScrollEventMonitor()
            #endif
            // When the guide notes editor gains focus, clear the search
            // This is the same as clicking the 'x' button in the search field
            if newValue {
                isGuideNotesSearchFocused = false
                guideNotesInPaneSearchQuery = ""
            }
        }
        .onChange(of: isSessionNotesEditorFocused) { _, newValue in
            #if os(macOS)
            updateScrollEventMonitor()
            #endif
            // When the session notes editor gains focus, clear the search
            // This is the same as clicking the 'x' button in the search field
            if newValue {
                isSessionNotesSearchFocused = false
                sessionNotesInPaneSearchQuery = ""
            }
        }
    }


    // MARK: - Detail Layout

    @ViewBuilder
    private var detailContent: some View {
        GeometryReader { geometry in
            ScrollView {
                mainDetailContent(topPadding: 0)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
            .safeAreaInset(edge: .top, spacing: 0) {
                sessionTemplateTitleBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(Theme.grayBG)
            }
        }
        .background(Theme.grayBG)
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .trailing) { commandSidebar }
        .overlay(alignment: .top) { toastOverlay }
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
            guard isActiveTab else { return }
            showShortcutsSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .importQueryTemplatesRequested)) { _ in
            guard isActiveTab else { return }
            importTemplatesFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreQueryTemplateRequested)) { _ in
            guard isActiveTab else { return }
            restoreTemplateFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .restoreQueryBackupsRequested)) { _ in
            guard isActiveTab else { return }
            restoreAllTemplatesFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .queriesBackedUp)) { _ in
            guard isActiveTab else { return }
            showTemplateToast("All queries backed up successfully")
        }
        .onReceive(NotificationCenter.default.publisher(for: .beginQuickCaptureRequested)) { _ in
            guard isActiveTab else { return }
            startBeginCapture()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDatabaseSettings)) { _ in
            guard isActiveTab else { return }
            showDatabaseSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePreviewShortcutRequested)) { _ in
            guard isActiveTab else { return }
            togglePreviewShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSessionRequested)) { _ in
            guard isActiveTab else { return }
            attemptClearCurrentSession()
        }
        .registerShortcut(name: "Clear Session", keyLabel: "K", modifiers: [.command, .shift], scope: "Session")
        .onReceive(NotificationCenter.default.publisher(for: .switchToSession1Requested)) { _ in
            guard isActiveTab else { return }
            switchToSession(.one)
        }
        .registerShortcut(name: "Switch to Session #1", keyLabel: "1", modifiers: [.control], scope: "Session")
        .onReceive(NotificationCenter.default.publisher(for: .switchToSession2Requested)) { _ in
            guard isActiveTab else { return }
            switchToSession(.two)
        }
        .registerShortcut(name: "Switch to Session #2", keyLabel: "2", modifiers: [.control], scope: "Session")
        .onReceive(NotificationCenter.default.publisher(for: .switchToSession3Requested)) { _ in
            guard isActiveTab else { return }
            switchToSession(.three)
        }
        .registerShortcut(name: "Switch to Session #3", keyLabel: "3", modifiers: [.control], scope: "Session")
        .sheet(isPresented: $showBeginCaptureSheet) {
            BeginCaptureSheet(orgValue: $beginOrgDraft,
                              acctValue: $beginAcctDraft,
                              extraValues: $beginExtraDrafts,
                              onAutoPopulate: {
                                  autoPopulateQuickCaptureFromClipboard()
                              },
                              onSave: {
                                  applyBeginCaptureValues()
                                  showBeginCaptureSheet = false
                              },
                              onCancel: {
                                  showBeginCaptureSheet = false
                              })
        }
        .sheet(isPresented: $showShortcutsSheet) {
            KeyboardShortcutsSheet(onClose: { showShortcutsSheet = false })
        }
        .sheet(isPresented: $showDatabaseSettings) {
            DatabaseSettingsSheet(userConfig: userConfig)
        }
        .sheet(item: $savedFileTreePreview) { preview in
            savedFileTreePreviewSheet(preview)
        }
        .sheet(item: $ghostOverlayContext) { context in
            ghostOverlaySheet(context)
        }
        .sheet(item: $previewingSessionImage) { sessionImage in
            SessionImagePreviewSheet(sessionImage: sessionImage)
        }
        .sheet(item: $previewingGuideImageContext) { context in
            TemplateGuideImagePreviewSheet(template: context.template, guideImage: context.image)
        }
        .sheet(item: $activePopoutPane) { pane in
            popoutSheet(for: pane)
        }
        .sheet(item: $editorTemplate) { template in
            TemplateInlineEditorSheet(
                template: template,
                text: $editorText,
                fontSize: fontSize,
                onSave: { newText in
                    saveTemplateEdits(template: template, newText: newText)
                    editorTemplate = nil
                },
                onCancel: {
                    editorTemplate = nil
                }
            )
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 760, height: 520),
                    preferredSize: CGSize(width: 820, height: 600),
                    sizeStorageKey: "TemplateInlineEditorSize"
                )
            )
        }
        .sheet(item: $tagEditorTemplate) { template in
            TagEditorSheetWrapper(
                template: template,
                existingTags: templateTagsStore.tags(for: template),
                onSave: { newTags in
                    persistTags(newTags, for: template)
                    tagEditorTemplate = nil
                },
                onCancel: {
                    tagEditorTemplate = nil
                }
            )
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 520, height: 360),
                    preferredSize: CGSize(width: 560, height: 400),
                    sizeStorageKey: "TemplateTagEditorSize"
                )
            )
        }
        .sheet(item: $tagExplorerContext) { context in
            TemplateTagExplorerSheet(
                tag: context.tag,
                templates: templates.templates,
                onSelect: { template in
                    selectTemplate(template)
                    tagExplorerContext = nil
                },
                onClose: {
                    tagExplorerContext = nil
                }
            )
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 420, height: 320),
                    preferredSize: CGSize(width: 460, height: 360),
                    sizeStorageKey: "TemplateTagExplorerSize"
                )
            )
        }
        .sheet(isPresented: $showTagSearchDialog) {
            TagSearchDialog(
                templates: templates.templates,
                onSelectTag: { tag in
                    showTemplates(for: tag)
                    showTagSearchDialog = false
                },
                onClose: {
                    showTagSearchDialog = false
                }
            )
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 500, height: 400),
                    preferredSize: CGSize(width: 540, height: 480),
                    sizeStorageKey: "TagSearchDialogSize"
                )
            )
        }
        .sheet(isPresented: $showGuideNotesSearchDialog) {
            GuideNotesSearchDialog(
                templates: templates.templates,
                onSelectTemplate: { template, keyword in
                    LOG("Guide notes search: selecting template", ctx: [
                        "template": template.name,
                        "keyword": keyword
                    ])
                    guideNotesSearchKeyword = keyword
                    showGuideNotesSearchDialog = false
                    selectTemplate(template)

                    // Wait for template to load, then show guide notes (simulating cmd+1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        LOG("Guide notes search: showing guide notes pane (cmd+1)")
                        handleShowGuideNotesShortcut()

                        // Then highlight the keyword after pane is visible
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            LOG("Guide notes search: highlighting keyword", ctx: ["keyword": keyword])
                            highlightKeywordInGuideNotes(keyword)
                        }
                    }
                },
                onClose: {
                    showGuideNotesSearchDialog = false
                }
            )
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 600, height: 450),
                    preferredSize: CGSize(width: 640, height: 520),
                    sizeStorageKey: "GuideNotesSearchDialogSize"
                )
            )
        }
    }

    @ViewBuilder
    private func savedFileTreePreviewSheet(_ preview: SavedFileTreePreviewContext) -> some View {
        JSONTreePreview(fileName: preview.fileName, content: preview.content, format: preview.format)
            .frame(minWidth: 720, minHeight: 540)
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 640, height: 500),
                    preferredSize: CGSize(width: 760, height: 560),
                    sizeStorageKey: "SavedFilesTreePreviewSize"
                )
            )
    }

    private func ghostOverlaySheet(_ context: GhostOverlayContext) -> some View {
        GhostOverlayView(
            availableFiles: context.availableFiles,
            originalFile: Binding(
                get: { context.originalFile },
                set: { newValue in
                    if let index = ghostOverlayContext != nil ? 0 : nil {
                        _ = index // suppress warning
                        ghostOverlayContext?.originalFile = newValue
                    }
                }
            ),
            ghostFile: Binding(
                get: { context.ghostFile },
                set: { newValue in
                    if let index = ghostOverlayContext != nil ? 0 : nil {
                        _ = index // suppress warning
                        ghostOverlayContext?.ghostFile = newValue
                    }
                }
            ),
            onClose: {
                ghostOverlayContext = nil
            },
            onJumpToLine: { file, lineNumber in
                // Select the ghost file in the editor
                setSavedFileSelection(file.id, for: context.session)
                // Close the overlay
                ghostOverlayContext = nil
                // TODO: Implement line jumping in JSONEditor
            }
        )
        .frame(minWidth: 800, minHeight: 600)
        .background(
            SheetWindowConfigurator(
                minSize: CGSize(width: 700, height: 500),
                preferredSize: CGSize(width: 1000, height: 700),
                sizeStorageKey: "GhostOverlaySize"
            )
        )
    }

    private func popoutSheet(for pane: PopoutPaneContext) -> some View {
        // Handle sessionTemplate separately with its own sheet
        if case .sessionTemplate(let session) = pane {
            return AnyView(SessionTemplatePopoutSheet(
                fontSize: fontSize,
                session: session,
                selectedTab: $selectedSessionTemplateTab,
                sessions: sessions,
                templateGuideStore: templateGuideStore,
                templateLinksStore: templateLinksStore,
                selectedTemplate: selectedTemplate,
                onClose: {
                    activePopoutPane = nil
                },
                onImagePreview: { image in
                    // Close popout before showing preview
                    activePopoutPane = nil
                    // Show image preview
                    if let sessionImg = image as? SessionImage {
                        previewingSessionImage = sessionImg
                    } else if let context = image as? GuideImagePreviewContext {
                        previewingGuideImageContext = context
                    }
                },
                onImagePreviewClose: {
                    // Reopen the popout after preview closes
                    if case .sessionTemplate = pane {
                        activePopoutPane = .sessionTemplate(session)
                    }
                },
                onSessionImageDelete: { image in
                    deleteSessionImage(image)
                },
                onSessionImageRename: { image in
                    renameSessionImage(image)
                },
                onSessionImagePaste: {
                    handleImagePaste()
                },
                onGuideImageDelete: { image in
                    deleteGuideImage(image)
                },
                onGuideImageRename: { image in
                    renameGuideImage(image)
                },
                onGuideImageOpen: { image in
                    openGuideImage(image)
                },
                onGuideImagePaste: {
                    handleGuideImagePaste()
                },
                onTemplateLinkHover: { linkId in
                    hoveredTemplateLinkID = linkId
                },
                onTemplateLinkOpen: { link in
                    openTemplateLink(link)
                }
            ))
        }

        let targetSession: TicketSession
        switch pane {
        case .guide:
            targetSession = sessions.current
        case .session(let session), .saved(let session):
            targetSession = session
        case .sessionTemplate(let session):
            targetSession = session
        }

        let sessionDraftBinding = Binding<String>(
            get: { sessionNotesDrafts[targetSession] ?? "" },
            set: { newValue in
                // Prevent updates when loading a ticket session
                if isLoadingTicketSession { return }
                // Prevent updates if this isn't the active session
                if targetSession != sessions.current { return }
                if sessionNotesDrafts[targetSession] == newValue { return }
                setSessionNotesDraft(newValue,
                                     for: targetSession,
                                     source: "session.popout")
            }
        )

        return AnyView(PanePopoutSheet(
            pane: pane,
            fontSize: fontSize,
            editorMinHeight: bottomPaneEditorMinHeight,
            selectedTemplate: selectedTemplate,
            guideText: $guideNotesDraft,
            guideDirty: templateGuideStore.isNotesDirty(for: selectedTemplate),
            guideController: guideNotesEditor,
            isPreview: $isPreviewMode,
            onGuideSave: {
                guard let template = selectedTemplate else { return }
                guideNotesAutosave.flush(for: template.id)
                if templateGuideStore.saveNotes(for: template) {
                    guideNotesDraft = templateGuideStore.currentNotes(for: template)
                    guideNotesAutosave.cancel(for: template.id)
                }
            },
            onGuideRevert: {
                guard let template = selectedTemplate else { return }
                guideNotesAutosave.cancel(for: template.id)
                guideNotesDraft = templateGuideStore.revertNotes(for: template)
            },
            onGuideTextChanged: { newValue in
                guard let template = selectedTemplate else { return }
                handleGuideNotesChange(newValue,
                                       for: template,
                                       source: "popout")
            },
            onGuideLinkRequested: handleTroubleshootingLink(selectedText:source:completion:),
            onGuideImageAttachment: { info in
                handleGuideEditorImageAttachment(info)
            },
            onGuideLinkOpen: { url, modifiers in
                openLink(url, modifiers: modifiers)
            },
            session: targetSession,
            sessionDraft: sessionDraftBinding,
            sessionSavedValue: sessions.sessionNotes[targetSession] ?? "",
            sessionController: sessionNotesEditor,
            savedFiles: savedFiles(for: targetSession),
            selectedSavedFileID: currentSavedFileSelection(for: targetSession),
            savedFileDraftProvider: { savedFileDraft(for: targetSession, fileId: $0) },
            savedFileValidationProvider: { validationState(for: targetSession, fileId: $0) },
            onSavedFileSelect: { setSavedFileSelection($0, for: targetSession) },
            onSavedFileAdd: { addSavedFile(for: targetSession) },
            onSavedFileDelete: { removeSavedFile($0, in: targetSession) },
            onSavedFileRename: { renameSavedFile($0, in: targetSession) },
            onSavedFileReorder: { sourceIndex, destinationIndex in
                sessions.reorderSavedFiles(from: sourceIndex, to: destinationIndex, in: targetSession)
            },
            onSavedFileContentChange: { fileId, newValue in
                setSavedFileDraft(newValue,
                                  for: fileId,
                                  session: targetSession,
                                  source: "savedFile.popout")
            },
            onSavedFileFocusChange: { focus in
                isSavedFileEditorFocused = focus
            },
            onSavedFileOpenTree: { fileId in
                presentTreeView(for: fileId, session: targetSession)
            },
            onSavedFileFormatTree: { fileId in
                formatSavedFileAsTree(for: fileId, session: targetSession)
            },
            onSavedFileFormatLine: { fileId in
                formatSavedFileAsLine(for: fileId, session: targetSession)
            },
            onSavedFilesModeExit: { commitSavedFileDrafts(for: targetSession) },
            onSessionSave: {
                saveSessionNotes(for: targetSession, reason: "popout-manual")
            },
            onSessionRevert: {
                let saved = sessions.sessionNotes[targetSession] ?? ""
                setSessionNotesDraft(saved,
                                     for: targetSession,
                                     source: "popout-revert")
            },
            onSessionLinkRequested: handleSessionNotesLink(selectedText:source:completion:),
            onSessionImageAttachment: { info in
                handleSessionEditorImageAttachment(info)
            },
            onSessionLinkOpen: { url, modifiers in
                openLink(url, modifiers: modifiers)
            },
            onClose: {
                if case .saved(let savedSession) = pane {
                    commitSavedFileDrafts(for: savedSession)
                }
                if case .guide = pane {
                    finalizeGuideNotesAutosave(for: selectedTemplate, reason: "guide-popout-close")
                }
                isSavedFileEditorFocused = false
                activePopoutPane = nil
            },
            onTogglePreview: togglePreviewShortcut,
            onImagePreview: {
                // Close popout before showing preview
                activePopoutPane = nil
            },
            onImagePreviewClose: {
                // Reopen the popout after preview closes
                activePopoutPane = pane
            }
        ))
    }

    private var hardStopTitleRow: some View {
        Color.clear
            .frame(height: hardStopRowHeight)
            .background(Theme.grayBG.opacity(0.98))
    }

    private var hardStopDivider: some View {
        Rectangle()
            .fill(Theme.purple.opacity(0.35))
            .frame(height: 1)
            .overlay(Rectangle().fill(Color.black.opacity(0.3)).frame(height: 0.5), alignment: .bottom)
    }

    private var toastOverlay: some View {
        VStack(spacing: 10) {
            // Red warning banner for copy in progress
            if showCopyWarning {
                Text("⚠️ Copying in progress - Do not use keyboard or mouse")
                    .font(.system(size: fontSize + 4, weight: .bold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.red).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }

            // Progress message
            if !copyProgressMessage.isEmpty {
                Text(copyProgressMessage)
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.aqua).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }

            // Success message
            if !copySuccessMessage.isEmpty {
                Text("✓ " + copySuccessMessage)
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Color.green).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }

            if toastCopied {
                Text("Copied to clipboard")
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.aqua).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
            if toastOpenDB {
                Text("Opening in Querious…")
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.aqua).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
            if let templateToast = toastTemplatesMessage {
                Text(templateToast)
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
            if toastPreviewBehind {
                Text("Close editor to view preview")
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.purple).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
            if let message = imageAttachmentToast {
                Text(message)
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(Theme.gold).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .zIndex(10000)
    }

    private func showTemplateToast(_ message: String) {
        withAnimation { toastTemplatesMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toastTemplatesMessage = nil }
        }
    }

    private func truncateSessionName(_ name: String) -> String {
        if name.count > 80 {
            return String(name.prefix(77)) + "..."
        }
        return name
    }

    private var sessionTemplateTitleBar: some View {
        ZStack {
            HStack {
                // Session name on the left
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(Theme.titleBarLabel)
                    Text(truncateSessionName(sessions.sessionNames[sessions.current] ?? "#\(sessions.current.rawValue)"))
                        .font(.system(size: fontSize + 3, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                }

                Spacer()

                // Active Template on the right
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Active Template")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(Theme.titleBarLabel)
                    if let template = selectedTemplate {
                        if let displayName = activeTemplateDisplayName(for: template) {
                            Text(displayName)
                                .font(.system(size: fontSize + 3, weight: .medium))
                                .foregroundStyle(Theme.gold)
                        }
                        activeTemplateTags(for: template)
                    } else {
                        Text("No template loaded")
                            .font(.system(size: fontSize + 3, weight: .medium))
                            .foregroundStyle(Theme.gold)
                    }
                }
            }

            // Company absolutely centered
            if !companyLabel.isEmpty {
                VStack(alignment: .center, spacing: 4) {
                    Text("Company")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(Theme.titleBarLabel)
                    Text(companyLabel)
                        .font(.system(size: fontSize + 3, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.titleBarBG)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.purple.opacity(0.2), lineWidth: 1)
                )
                .allowsHitTesting(false)
        )
    }

    private func mainDetailContent(topPadding: CGFloat) -> some View {
        VStack(spacing: 12) {
            staticFields
                .padding(.bottom, 8)
            Divider()

            HStack(alignment: .top, spacing: 20) {
                dynamicFields
                    .frame(maxWidth: 540, alignment: .leading)

                dbTablesPane
                    .frame(width: 360)

                sessionAndTemplatePane
                    .frame(width: 320)

                alternateFieldsPane
                    .frame(width: 440)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 42)

            sessionToolbar
                .padding(.top, 4)

            outputView

            EmptyView()
                .frame(width: 0, height: 0)
                .hidden()
        }
        .padding(EdgeInsets(top: topPadding, leading: 16, bottom: 16, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func resolvedMainContentTopPadding(for availableHeight: CGFloat) -> CGFloat {
        let upperThreshold: CGFloat = 900
        let lowerThreshold: CGFloat = 650

        guard availableHeight < upperThreshold else {
            return mainContentTopPadding
        }

        if availableHeight <= lowerThreshold {
            return compactMainContentTopPadding
        }

        let progress = (availableHeight - lowerThreshold) / (upperThreshold - lowerThreshold)
        return compactMainContentTopPadding + ((mainContentTopPadding - compactMainContentTopPadding) * progress)
    }

    private func activeTemplateDisplayName(for template: TemplateItem) -> String? {
        let trimmed = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased()
        if normalized == "sqlmaestro" { return nil }
        return trimmed
    }

    // MARK: – Templates Pane (split to help the type checker)
    @ViewBuilder
    private var templatesPane: some View {
        TemplatesSidebar {
            templatesHeader
        } search: {
            templatesSearch
        } list: {
            templatesList
        } footer: {
            templatesFooter
        }
        .padding(EdgeInsets(top: 5, leading: 16, bottom: 16, trailing: 16))
        .background(Theme.grayBG)
        .frame(minWidth: 300, idealWidth: 320)
        .toolbar {
            if isActiveTab {
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: {
                        toggleSidebar()
                    }) {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle Sidebar (⌘T)")
                }
            }
        }
    }

    @ViewBuilder
    private var templatesFooter: some View {
        if !trimmedSearchText.isEmpty {
            if isTagSearch {
                let count = tagSearchResults.count
                Text("\(count) matching tag\(count == 1 ? "" : "s")")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(filteredTemplates.count) of \(templates.templates.count) templates")
                    .font(.system(size: fontSize - 2))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var templatesHeader: some View {
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
            Button("Import") {
                importTemplatesFlow()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .font(.system(size: fontSize))
        }
    }

    private struct TemplateArchiveManifest: Codable {
        var version: Int
        var exportedAt: Date
        var templateName: String
        var originalTemplateId: String?
    }

    private func importTemplatesFlow() {
        let panel = NSOpenPanel()
        panel.title = "Import Query Templates"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["zip"]
        panel.allowedContentTypes = [UTType.zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK else {
            LOG("Template import cancelled", ctx: ["reason": "panel dismissed"])
            return
        }

        let archives = panel.urls
        guard !archives.isEmpty else { return }

        var importedDestinations: [URL] = []
        var failures: [String] = []

        for archive in archives {
            do {
                let destination = try importTemplateArchive(from: archive)
                importedDestinations.append(destination)
                LOG("Template archive imported", ctx: [
                    "archive": archive.lastPathComponent,
                    "template": destination.lastPathComponent
                ])
            } catch {
                let message = "\(archive.lastPathComponent): \(error.localizedDescription)"
                failures.append(message)
                WARN("Template archive import failed", ctx: [
                    "archive": archive.lastPathComponent,
                    "error": error.localizedDescription
                ])
            }
        }

        guard !importedDestinations.isEmpty else {
            if !failures.isEmpty {
                NSSound.beep()
                showAlert(title: "Import Failed", message: failures.joined(separator: "\n"))
            }
            return
        }

        templates.loadTemplates()

        let importedTemplates: [TemplateItem] = importedDestinations.compactMap { destination in
            templates.templates.first(where: { $0.url.standardizedFileURL == destination.standardizedFileURL })
        }

        for template in importedTemplates {
            _ = templateLinksStore.loadSidecar(for: template)
            templateTagsStore.ensureLoaded(template)
            templateGuideStore.prepare(for: template)
        }

        if let newlyImported = importedTemplates.last {
            selectTemplate(newlyImported)
        }

        let message = importedTemplates.count == 1
            ? "Imported 1 template"
            : "Imported \(importedTemplates.count) templates"
        showTemplateToast(message)

        if !failures.isEmpty {
            NSSound.beep()
            showAlert(title: "Some imports failed", message: failures.joined(separator: "\n"))
        }
    }

    private func restoreTemplateFlow() {
        let panel = NSOpenPanel()
        panel.title = "Restore Query Template"
        panel.prompt = "Restore"
        panel.message = "Select a template history backup to restore"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["zip"]
        panel.allowedContentTypes = [UTType.zip]
        panel.directoryURL = AppPaths.queryHistoryCheckpoints

        guard panel.runModal() == .OK, let archiveURL = panel.url else {
            LOG("Template restore cancelled", ctx: ["reason": "panel dismissed"])
            return
        }

        do {
            try templates.restoreTemplateFromHistory(archiveURL: archiveURL)
            showTemplateToast("Template restored successfully")
        } catch {
            NSSound.beep()
            showAlert(title: "Restore Failed", message: error.localizedDescription)
            WARN("Template restore failed", ctx: ["archive": archiveURL.lastPathComponent, "error": error.localizedDescription])
        }
    }

    private func restoreAllTemplatesFlow() {
        let panel = NSOpenPanel()
        panel.title = "Restore Query Backups"
        panel.prompt = "Restore"
        panel.message = "Select a full backup archive to restore"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["zip"]
        panel.allowedContentTypes = [UTType.zip]
        panel.directoryURL = AppPaths.queryTemplateBackups

        guard panel.runModal() == .OK, let archiveURL = panel.url else {
            LOG("Restore all templates cancelled", ctx: ["reason": "panel dismissed"])
            return
        }

        let alert = NSAlert()
        alert.messageText = "Restore All Query Templates?"
        alert.informativeText = "This will overwrite all existing query templates with the templates from the selected backup. This action cannot be undone.\n\nAre you sure you want to continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore All")
        alert.addButton(withTitle: "Cancel")

        guard runAlertWithFix(alert) == .alertFirstButtonReturn else {
            LOG("Restore all templates cancelled", ctx: ["reason": "user cancelled warning"])
            return
        }

        do {
            try templates.restoreAllTemplatesFromBackup(archiveURL: archiveURL)
            showTemplateToast("All templates restored successfully")
        } catch {
            NSSound.beep()
            showAlert(title: "Restore Failed", message: error.localizedDescription)
            WARN("Restore all templates failed", ctx: ["archive": archiveURL.lastPathComponent, "error": error.localizedDescription])
        }
    }

    private func exportTemplate(_ template: TemplateItem) {
        let fm = FileManager.default
        guard let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            WARN("Downloads directory unavailable", ctx: [:])
            showAlert(title: "Export Failed", message: "Could not locate the Downloads folder.")
            return
        }

        let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseCandidate = trimmedName.isEmpty ? "Template" : trimmedName
        let sanitizedBase = sanitizeFileName(baseCandidate)
        var finalBase = sanitizedBase.isEmpty ? "Template" : sanitizedBase

        var destination = downloads.appendingPathComponent("\(finalBase).zip")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent("\(finalBase)-\(suffix).zip")
            suffix += 1
        }

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroTemplateExport-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempRoot) }

            try exportTemplateAssets(template, to: tempRoot)

            let manifest = TemplateArchiveManifest(
                version: 1,
                exportedAt: Date(),
                templateName: template.name,
                originalTemplateId: template.id.uuidString
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let manifestURL = tempRoot.appendingPathComponent("metadata.json")
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: manifestURL, options: .atomic)

            try zipFolder(at: tempRoot, to: destination)
            LOG("Template archive exported", ctx: [
                "template": template.name,
                "zip": destination.lastPathComponent
            ])
            showTemplateToast("Exported \(template.name)")
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSSound.beep()
            showAlert(title: "Export Failed", message: error.localizedDescription)
            WARN("Template archive export failed", ctx: [
                "template": template.name,
                "error": error.localizedDescription
            ])
        }
    }

    private func importTemplateArchive(from archiveURL: URL) throws -> URL {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroTemplateImport-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        try unzipArchive(archiveURL, to: tempRoot)

        let payloadRoot = try resolveTemplateArchiveRoot(at: tempRoot)
        let manifest = decodeTemplateArchiveManifest(at: payloadRoot)
        let sqlURL = try resolveTemplateSQL(in: payloadRoot)
        let sqlContent = try String(contentsOf: sqlURL, encoding: .utf8)

        let manifestName = manifest?.templateName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileName = sqlURL.deletingPathExtension().lastPathComponent
        let archiveName = archiveURL.deletingPathExtension().lastPathComponent

        let prioritizedNames = [manifestName, fileName, archiveName]
        let chosenName = prioritizedNames.first(where: { !$0.isEmpty && $0.lowercased() != "template" }) ?? "Imported Template"
        let sanitizedBase = sanitizeFileName(chosenName).isEmpty ? "Imported Template" : sanitizeFileName(chosenName)

        var finalBase = sanitizedBase
        var destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            finalBase = "\(sanitizedBase) \(suffix)"
            destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
            suffix += 1
        }

        try sqlContent.write(to: destination, atomically: true, encoding: .utf8)
        let templateId = TemplateIdentityStore.shared.id(for: destination)

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Links sidecar
        let linksSource = payloadRoot.appendingPathComponent("links.json")
        if fm.fileExists(atPath: linksSource.path) {
            do {
                let data = try Data(contentsOf: linksSource)
                if let payload = try? decoder.decode(TemplateLinks.self, from: data) {
                    let model = TemplateLinks(templateId: templateId, links: payload.links)
                    let dest = destination.deletingPathExtension().appendingPathExtension("links.json")
                    let encoded = try encoder.encode(model)
                    try encoded.write(to: dest, options: .atomic)
                    LOG("Template links imported", ctx: ["file": dest.lastPathComponent])
                }
            } catch {
                WARN("Template links import failed", ctx: ["error": error.localizedDescription])
            }
        }

        // Tables sidecar
        let tablesSource = payloadRoot.appendingPathComponent("tables.json")
        if fm.fileExists(atPath: tablesSource.path) {
            do {
                let data = try Data(contentsOf: tablesSource)
                if let payload = try? decoder.decode(TemplateTables.self, from: data) {
                    let model = TemplateTables(templateId: templateId, tables: payload.tables)
                    let dest = destination.deletingPathExtension().appendingPathExtension("tables.json")
                    let encoded = try encoder.encode(model)
                    try encoded.write(to: dest, options: .atomic)
                    LOG("Template tables imported", ctx: ["file": dest.lastPathComponent, "count": "\(payload.tables.count)"])
                }
            } catch {
                WARN("Template tables import failed", ctx: ["error": error.localizedDescription])
            }
        }

        // Tags sidecar
        let tagsSource = payloadRoot.appendingPathComponent("tags.json")
        if fm.fileExists(atPath: tagsSource.path) {
            do {
                let data = try Data(contentsOf: tagsSource)
                if let payload = try? decoder.decode(TemplateTags.self, from: data) {
                    let model = TemplateTags(templateId: templateId, tags: payload.tags)
                    let dest = destination.deletingPathExtension().appendingPathExtension("tags.json")
                    let encoded = try encoder.encode(model)
                    try encoded.write(to: dest, options: .atomic)
                    LOG("Template tags imported", ctx: ["file": dest.lastPathComponent, "count": "\(payload.tags.count)"])
                }
            } catch {
                WARN("Template tags import failed", ctx: ["error": error.localizedDescription])
            }
        }

        // Guide assets
        let guideSource = payloadRoot.appendingPathComponent("guide", isDirectory: true)
        if fm.fileExists(atPath: guideSource.path) {
            let guideDestination = AppPaths.templateGuides.appendingPathComponent(finalBase, isDirectory: true)
            if fm.fileExists(atPath: guideDestination.path) {
                try? fm.removeItem(at: guideDestination)
            }
            do {
                try fm.createDirectory(at: guideDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: guideSource, to: guideDestination)
                rewriteGuideManifest(at: guideDestination.appendingPathComponent("guide.json"), templateId: templateId)
                rewriteGuideImagesManifest(at: guideDestination.appendingPathComponent("images.json"), templateId: templateId)
                LOG("Template guide imported", ctx: ["folder": guideDestination.lastPathComponent])
            } catch {
                WARN("Template guide import failed", ctx: ["error": error.localizedDescription])
            }
        }

        return destination.standardizedFileURL
    }

    private func resolveTemplateArchiveRoot(at directory: URL) throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: directory,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
        if contents.count == 1,
           let first = contents.first,
           (try first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false) {
            return first
        }
        return directory
    }

    private func resolveTemplateSQL(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let preferred = folder.appendingPathComponent("template.sql")
        if fm.fileExists(atPath: preferred.path) {
            return preferred
        }

        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw templateArchiveError("Unable to inspect template archive")
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "sql" {
                return fileURL
            }
        }
        throw templateArchiveError("Archive missing SQL template file")
    }

    private func decodeTemplateArchiveManifest(at folder: URL) -> TemplateArchiveManifest? {
        let manifestURL = folder.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TemplateArchiveManifest.self, from: data)
        } catch {
            WARN("Template archive manifest decode failed", ctx: [
                "file": manifestURL.lastPathComponent,
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    private func templateArchiveError(_ message: String) -> NSError {
        NSError(domain: "TemplateArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @ViewBuilder
    private func activeTemplateTags(for template: TemplateItem) -> some View {
        let tags = templateTagsStore.tags(for: template)
        if !tags.isEmpty {
            HStack(spacing: 8) {
                Text("Tags:")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(Theme.titleBarLabel)
                ForEach(tags, id: \.self) { tag in
                    Button {
                        showTemplates(for: tag)
                    } label: {
                        Text("#\(tag)")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(Theme.pink)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Show templates tagged #\(tag)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var templatesSearch: some View {
    HStack {
    Image(systemName: "magnifyingglass")
    .foregroundStyle(.secondary)
    .font(.system(size: fontSize))
    TextField("Search templates...", text: $searchText)
    .textFieldStyle(.roundedBorder)
    .font(.system(size: fontSize))
    .focused($isSearchFocused)
    .onSubmit { _ = focusTemplates(direction: 1) }
    .onKeyPress(.downArrow) {
        _ = focusTemplates(direction: 1)
        return .handled
    }
    .onKeyPress(.upArrow) {
        _ = focusTemplates(direction: -1)
        return .handled
    }
    .onKeyPress(.escape) {
        isSearchFocused = false
        searchText = ""
        return .handled
    }
    if !searchText.isEmpty {
    Button("Clear") {
    searchText = ""
    selectedTemplate = nil
    isSearchFocused = true
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
    Button(role: .destructive, action: { deleteTemplateFlow(sel) }) {
    Text("Delete Selected Template…")
    }
    } else {
    Text("No template selected").foregroundStyle(.secondary)
    }
    }
    }

    @ViewBuilder
    private var templatesList: some View {
        if isTagSearch {
            tagSearchList
        } else {
            templateSearchList
        }
    }

    private var templateSearchList: some View {
        List(filteredTemplates, id: \.id, selection: Binding(
            get: { selectedTemplate?.id },
            set: { newValue in
                if let id = newValue,
                   let found = templates.templates.first(where: { $0.id == id }) {
                    selectTemplate(found)
                } else {
                    selectTemplate(nil)
                }
            }
        )) { template in
            templateRow(template)
        }
        .animation(nil, value: selectedTemplate?.id)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onKeyPress(.return) {
            guard !filteredTemplates.isEmpty else { return .ignored }
            if selectedTemplate == nil { selectTemplate(filteredTemplates.first) }
            guard let selected = selectedTemplate else { return .handled }

            if let event = NSApp.currentEvent, event.modifierFlags.contains(.command) {
                loadTemplate(selected)
            } else {
                editTemplateInline(selected)
            }

            return .handled
        }
        .onKeyPress(.upArrow) { navigateTemplate(direction: -1); return .handled }
        .onKeyPress(.downArrow) { navigateTemplate(direction: 1); return .handled }
        .focused($isListFocused)
    }

    private var tagSearchList: some View {
        List(Array(tagSearchResults.enumerated()), id: \.element.id) { index, result in
            let isSelected = index == selectedTagIndex
            Button {
                showTemplates(for: result.tag)
            } label: {
                HStack(spacing: 10) {
                    Text("#\(result.tag)")
                        .font(.system(size: fontSize))
                        .foregroundStyle(Theme.pink)
                    Spacer()
                    Text("\(result.count)")
                        .font(.system(size: fontSize - 3, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .onKeyPress(.upArrow) {
            navigateTagSearch(direction: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigateTagSearch(direction: 1)
            return .handled
        }
        .onKeyPress(.return) {
            selectCurrentTag()
            return .handled
        }
        .onChange(of: tagSearchResults) { _, _ in
            // Reset selection when search results change
            selectedTagIndex = 0
        }
        .focused($isListFocused)
    }

    @ViewBuilder
    private func templateRow(_ template: TemplateItem) -> some View {
    let isUsed = UsedTemplatesStore.shared.isTemplateUsed(in: sessions.current, templateId: template.id)
    let isSelected = selectedTemplate?.id == template.id

    HStack(spacing: 8) {
    Image(systemName: "doc.text.fill")
    .foregroundStyle(
    isSelected ? (isUsed ? Theme.pink : .white)
    : (isUsed ? Theme.pink.opacity(0.8) : Theme.gold.opacity(0.6))
    )
    .font(.system(size: fontSize + 1))

        Text(template.name)
          .font(.system(size: fontSize))
          .foregroundStyle(isSelected ? .white : .primary)

        Spacer()

        if !template.placeholders.isEmpty {
          Text("\(template.placeholders.count)")
            .font(.system(size: fontSize - 3))
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              isSelected ? (isUsed ? Theme.pink.opacity(0.3) : .white.opacity(0.3))
                         : (isUsed ? Theme.pink.opacity(0.15) : Theme.gold.opacity(0.15))
            )
            .foregroundStyle(isSelected ? (isUsed ? Theme.pink : .white)
                                       : (isUsed ? Theme.pink : Theme.gold))
            .clipShape(Capsule())
        }

    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(
    RoundedRectangle(cornerRadius: 8)
    .fill(isSelected ? Theme.purple.opacity(0.1) : Color.clear)
    .overlay(
    RoundedRectangle(cornerRadius: 8)
    .stroke(isSelected ? Theme.purple.opacity(0.3) : Color.clear, lineWidth: 1.5)
    )
    )
    .contentShape(Rectangle())
    .contextMenu {
    Button("Edit") { editTemplateInline(template) }
    Button("Open in VS Code") { openInVSCode(template.url) }
    Button("Add Tags") { startAddTags(for: template) }
    Button("Show in Finder") { revealTemplateInFinder(template) }
    Divider()
    Button("Export Template…") { exportTemplate(template) }
    if isUsed {
        Divider()
        Button("Remove from Recents") { removeTemplateFromRecents(template) }
    }
    Divider()
    Button("Rename…") { renameTemplateFlow(template) }
    Divider()
    Button(role: .destructive, action: { deleteTemplateFlow(template) }) { Text("Delete Template…") }
    }
    .highPriorityGesture(TapGesture(count: 2).onEnded { editTemplateInline(template) })
    .onTapGesture { selectTemplate(template) }
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

            if runAlertWithFix(alert) == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !newName.isEmpty {
                    sessions.renameSessionImage(imageId: image.id, newName: newName, for: sessions.current)
                    if let updated = sessions.sessionImages[sessions.current]?.first(where: { $0.id == image.id }) {
                        updateSessionNoteLinks(for: sessions.current, fileName: image.fileName, newLabel: updated.displayName)
                    }
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

            if runAlertWithFix(alert) == .alertFirstButtonReturn {
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

            if runAlertWithFix(alert) == .alertFirstButtonReturn {
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
                runAlertWithFix(alert)
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
                runAlertWithFix(alert)
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

            removeSessionNoteLinks(referencing: imageURL)
            if let template = selectedTemplate {
                if removeGuideNoteLinks(for: template, fileURL: imageURL) {
                    touchTemplateActivity(for: template)
                }
            }
            
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

        private func handleImageAttachmentToast(_ message: String) {
            imageAttachmentToast = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if imageAttachmentToast == message {
                    imageAttachmentToast = nil
                }
            }
        }

        private func notifyPreviewBehindIfNeeded() {
            guard case .guide? = activePopoutPane else { return }
            withAnimation { toastPreviewBehind = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation { toastPreviewBehind = false }
            }
        }

        private func handleGuideEditorImageAttachment(_ info: MarkdownEditor.ImageDropInfo) -> MarkdownEditor.ImageInsertion? {
            guard let template = selectedTemplate else {
#if canImport(AppKit)
                NSSound.beep()
#endif
                return nil
            }
            guard let image = templateGuideStore.addImage(data: info.data, suggestedName: info.filename, for: template) else {
                return nil
            }
            touchTemplateActivity(for: template)
            let url = templateGuideStore.imageURL(for: image, template: template)
            handleImageAttachmentToast("Saved to Guide Images")
            LOG("Guide image added via editor", ctx: ["template": template.name, "fileName": image.fileName])
            let markdown = "[\(image.displayName)](\(url.absoluteString))"
            return MarkdownEditor.ImageInsertion(markdown: markdown)
        }

        private func handleSessionEditorImageAttachment(_ info: MarkdownEditor.ImageDropInfo) -> MarkdownEditor.ImageInsertion? {
            guard let result = saveSessionImageAttachment(data: info.data, originalName: info.filename) else {
                return nil
            }
            handleImageAttachmentToast("Saved to Session Images")
            LOG("Session image added via editor", ctx: ["session": "\(sessions.current.rawValue)", "fileName": result.image.fileName])
            let markdown = "[\(result.image.displayName)](\(result.url.absoluteString))"
            return MarkdownEditor.ImageInsertion(markdown: markdown)
        }

        private func saveSessionImageAttachment(data: Data, originalName: String?) -> (image: SessionImage, url: URL)? {
            let fm = FileManager.default
            try? fm.createDirectory(at: AppPaths.sessionImages, withIntermediateDirectories: true)
            let tabPrefix = tabID.isEmpty ? "" : "Tab\(tabID)_"
            let sessionIdentifier = "Session\(sessions.current.rawValue)"
            let existingImages = sessions.sessionImages[sessions.current] ?? []
            let sequence = existingImages.count + 1
            let fileName = "\(tabPrefix)\(sessionIdentifier)_\(String(format: "%03d", sequence)).png"
            let destination = AppPaths.sessionImages.appendingPathComponent(fileName)

            do {
                try data.write(to: destination, options: .atomic)
                let image = SessionImage(fileName: fileName, originalPath: originalName, savedAt: Date())
                sessions.addSessionImage(image, for: sessions.current)
                return (image, destination)
            } catch {
                LOG("Failed to save session image", ctx: ["error": error.localizedDescription])
                return nil
            }
        }

        private func openLink(_ url: URL, modifiers: NSEvent.ModifierFlags) {
#if canImport(AppKit)
            let wantsPreview = modifiers.contains(.command)
            if url.isFileURL {
                if wantsPreview {
                    if let sessionImage = sessionImage(forFileURL: url) {
                        previewingSessionImage = sessionImage
                        notifyPreviewBehindIfNeeded()
                        return
                    }
                    if let template = selectedTemplate,
                       let guideImage = guideImage(forFileURL: url, template: template) {
                        previewingGuideImageContext = GuideImagePreviewContext(template: template, image: guideImage)
                        notifyPreviewBehindIfNeeded()
                        return
                    }
                }
                NSWorkspace.shared.open(url)
                return
            }
            NSWorkspace.shared.open(url)
#endif
        }

        private func replaceLinkLabels(in text: String, fileURL: URL, newLabel: String) -> String {
            let urlString = fileURL.absoluteString
            let escapedURL = NSRegularExpression.escapedPattern(for: urlString)
            let pattern = "\\[[^\\]]*\\]\\(\(escapedURL)\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let replacement = "[\(NSRegularExpression.escapedTemplate(for: newLabel))](\(urlString))"
            return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
        }

        private func removingImageLinks(from text: String, fileURL: URL) -> String {
            let urlString = fileURL.absoluteString
            let escapedURL = NSRegularExpression.escapedPattern(for: urlString)
            let fullLinePattern = "(?m)^[ \\t]*!?\\[[^\\]]*\\]\\(" + escapedURL + "\\)[ \\t]*\\r?\\n?"
            let inlinePattern = "!?\\[[^\\]]*\\]\\(" + escapedURL + "\\)"
            var updated = text
            if let lineRegex = try? NSRegularExpression(pattern: fullLinePattern) {
                let range = NSRange(updated.startIndex..<updated.endIndex, in: updated)
                updated = lineRegex.stringByReplacingMatches(in: updated, options: [], range: range, withTemplate: "")
            }
            if let inlineRegex = try? NSRegularExpression(pattern: inlinePattern) {
                let range = NSRange(updated.startIndex..<updated.endIndex, in: updated)
                updated = inlineRegex.stringByReplacingMatches(in: updated, options: [], range: range, withTemplate: "")
            }
            if let collapseRegex = try? NSRegularExpression(pattern: "\\n{3,}") {
                let range = NSRange(updated.startIndex..<updated.endIndex, in: updated)
                updated = collapseRegex.stringByReplacingMatches(in: updated, options: [], range: range, withTemplate: "\n\n")
            }
            return updated
        }

        private func updateSessionNoteLinks(for session: TicketSession, fileName: String, newLabel: String) {
            let fileURL = AppPaths.sessionImages.appendingPathComponent(fileName)
            if var draft = sessionNotesDrafts[session] {
                let updated = replaceLinkLabels(in: draft, fileURL: fileURL, newLabel: newLabel)
                if updated != draft {
                    setSessionNotesDraft(updated, for: session, source: "updateLinks")
                }
            }
            let currentSaved = sessions.sessionNotes[session] ?? ""
            let updatedSaved = replaceLinkLabels(in: currentSaved, fileURL: fileURL, newLabel: newLabel)
            if updatedSaved != currentSaved {
                sessions.sessionNotes[session] = updatedSaved
                syncSessionImageNames(with: updatedSaved, for: session)
            }
        }

        private func removeSessionNoteLinks(referencing fileURL: URL) {
            for session in TicketSession.allCases {
                if let draft = sessionNotesDrafts[session] {
                    let cleanedDraft = removingImageLinks(from: draft, fileURL: fileURL)
                    if cleanedDraft != draft {
                        setSessionNotesDraft(cleanedDraft, for: session, source: "removeLinks")
                    }
                }
                let currentSaved = sessions.sessionNotes[session] ?? ""
                let cleanedSaved = removingImageLinks(from: currentSaved, fileURL: fileURL)
                if cleanedSaved != currentSaved {
                    sessions.sessionNotes[session] = cleanedSaved
                }
            }
        }

        private func updateGuideNoteLinks(for template: TemplateItem, fileName: String, newLabel: String) {
            let tempImage = TemplateGuideImage(fileName: fileName)
            let fileURL = TemplateGuideStore.shared.imageURL(for: tempImage, template: template)
            let updatedDraft = replaceLinkLabels(in: guideNotesDraft, fileURL: fileURL, newLabel: newLabel)
            if updatedDraft != guideNotesDraft {
                guideNotesDraft = updatedDraft
            }
            let existingStore = templateGuideStore.currentNotes(for: template)
            let updatedStore = replaceLinkLabels(in: existingStore, fileURL: fileURL, newLabel: newLabel)
            if updatedStore != existingStore {
                _ = templateGuideStore.setNotes(updatedStore, for: template)
                syncGuideImageNames(with: updatedStore, for: template)
            }
        }

        @discardableResult
        private func removeGuideNoteLinks(for template: TemplateItem, fileURL: URL) -> Bool {
            var changed = false
            let cleanedDraft = removingImageLinks(from: guideNotesDraft, fileURL: fileURL)
            if cleanedDraft != guideNotesDraft {
                guideNotesDraft = cleanedDraft
                changed = true
            }
            let existingStore = templateGuideStore.currentNotes(for: template)
            let cleanedStore = removingImageLinks(from: existingStore, fileURL: fileURL)
            if cleanedStore != existingStore {
                _ = templateGuideStore.setNotes(cleanedStore, for: template)
                syncGuideImageNames(with: cleanedStore, for: template)
                changed = true
            }
            return changed
        }

        private func sessionImage(forFileURL url: URL) -> SessionImage? {
            guard url.path.hasPrefix(AppPaths.sessionImages.path) else { return nil }
            let fileName = url.lastPathComponent
            for session in TicketSession.allCases {
                if let image = sessions.sessionImages[session]?.first(where: { $0.fileName == fileName }) {
                    return image
                }
            }
            return nil
        }

        private func guideImage(forFileURL url: URL, template: TemplateItem) -> TemplateGuideImage? {
            let images = templateGuideStore.images(for: template)
            return images.first { image in
                templateGuideStore.imageURL(for: image, template: template).path == url.path
            }
        }

        private func deleteGuideImage(_ image: TemplateGuideImage) {
            guard let template = selectedTemplate else { return }
            let fileURL = templateGuideStore.imageURL(for: image, template: template)
            if templateGuideStore.deleteImage(image, for: template) {
                removeGuideNoteLinks(for: template, fileURL: fileURL)
                removeSessionNoteLinks(referencing: fileURL)
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
            if runAlertWithFix(alert) == .alertFirstButtonReturn {
                let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newName.isEmpty else { return }
                if templateGuideStore.renameImage(image, to: newName, for: template) {
                    touchTemplateActivity(for: template)
                    LOG("Guide image renamed", ctx: ["template": template.name, "fileName": image.fileName, "newName": newName])
                    if let updated = templateGuideStore.images(for: template).first(where: { $0.id == image.id }) {
                        updateGuideNoteLinks(for: template, fileName: image.fileName, newLabel: updated.displayName)
                    }
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

        private func scheduleDBTablesAutosave(for session: TicketSession, template: TemplateItem, force: Bool = false) {
            let tables = dbTablesStore.workingSet(for: session, template: template)
            if !force {
                let hasContent = tables.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !hasContent {
                    return
                }
            }

            dbTablesAutosave.schedule(session: session, templateId: template.id, delay: 1.0) { [self] in
                let latest = dbTablesStore.workingSet(for: session, template: template)
                if !force {
                    let hasContent = latest.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if !hasContent && !latest.isEmpty {
                        scheduleDBTablesAutosave(for: session, template: template, force: force)
                        return
                    }
                }
                if dbTablesStore.saveSidecar(for: session, template: template) {
                    touchTemplateActivity(for: template)
                }
            }
        }

        private func flushDBTablesAutosave(for session: TicketSession, template: TemplateItem?) {
            guard let template else { return }
            dbTablesAutosave.flush(session: session, templateId: template.id)
        }

        private func cancelDBTablesAutosave(for session: TicketSession, template: TemplateItem?) {
            guard let template else { return }
            dbTablesAutosave.cancel(session: session, templateId: template.id)
        }
        
        private func trimTrailingWhitespace(_ string: String) -> String {
            string.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        
        private var trimmedSearchText: String {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var isTagSearch: Bool {
            trimmedSearchText.hasPrefix("#")
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
            let initialDraft = sessionNotesDrafts[cur] ?? ""
            let savedValue = sessions.sessionNotes[cur] ?? ""
            LOG("Commit drafts begin", ctx: [
                "session": "\(cur.rawValue)",
                "notesChars": "\(initialDraft.count)",
                "savedChars": "\(savedValue.count)",
                "notesDirty": initialDraft == savedValue ? "clean" : "dirty",
                "sample": String(initialDraft.prefix(80)).replacingOccurrences(of: "\n", with: "⏎")
            ])
            let bucket = draftDynamicValues[cur] ?? [:]
            for (ph, val) in bucket {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                sessions.setValue(trimmed, for: ph)
                LOG("Draft committed", ctx: ["session": "\(cur.rawValue)", "ph": ph, "value": trimmed])
            }

            // Only trust the editor if it's showing the current session
            // This prevents empty drafts from being written during session switches
            if let liveNotes = sessionNotesEditor.currentText(), !isLoadingTicketSession, !isSwitchingSession {
                // Keep the in-memory draft in sync with what the editor currently shows.
                if sessionNotesDrafts[cur] != liveNotes {
                    setSessionNotesDraft(liveNotes, for: cur, source: "commitDrafts")
                } else {
                    LOG("Session notes draft unchanged", ctx: [
                        "session": "\(cur.rawValue)",
                        "chars": "\(liveNotes.count)",
                        "source": "commitDrafts"
                    ])
                }
            } else {
                LOG("Session notes editor unavailable", ctx: [
                    "session": "\(cur.rawValue)",
                    "source": "commitDrafts"
                ])
            }

            let finalDraft = sessionNotesDrafts[cur] ?? ""
            LOG("Commit drafts end", ctx: [
                "session": "\(cur.rawValue)",
                "notesChars": "\(finalDraft.count)",
                "savedChars": "\(savedValue.count)",
                "notesDirty": finalDraft == savedValue ? "clean" : "dirty",
                "sample": String(finalDraft.prefix(80)).replacingOccurrences(of: "\n", with: "⏎")
            ])

            saveSessionNotes(for: cur, reason: "commitDrafts")
            commitSavedFileDrafts(for: cur)
        }

        private func setSessionNotesDraft(_ value: String,
                                          for session: TicketSession,
                                          source: String,
                                          logChange: Bool = true) {
            let previous = sessionNotesDrafts[session] ?? ""
            sessionNotesDrafts[session] = value

            if value != previous {
                syncSessionImageNames(with: value, for: session)
                syncSessionImagesWithNotes(notes: value, for: session)
                scheduleSessionNotesAutosave(for: session)
            }
            guard logChange else { return }

            let saved = sessions.sessionNotes[session] ?? ""
            let sample = String(value.prefix(80)).replacingOccurrences(of: "\n", with: "⏎")
            LOG("Session notes draft updated", ctx: [
                "session": "\(session.rawValue)",
                "chars": "\(value.count)",
                "delta": "\(value.count - previous.count)",
                "savedChars": "\(saved.count)",
                "dirty": value == saved ? "clean" : "dirty",
                "sample": String(sample),
                "source": source
            ])
        }

        private func extractFileLinkLabels(from text: String) -> [String: String] {
            guard !text.isEmpty else { return [:] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            var results: [String: String] = [:]

            markdownFileLinkRegex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match,
                      match.numberOfRanges >= 3,
                      let labelRange = Range(match.range(at: 1), in: text),
                      let urlRange = Range(match.range(at: 2), in: text) else { return }

                let label = String(text[labelRange])
                var target = String(text[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)

                if target.hasPrefix("<"), target.hasSuffix(">"), target.count >= 2 {
                    target = String(target.dropFirst().dropLast())
                }

                var resolvedURL: URL?
                if let direct = URL(string: target), direct.isFileURL {
                    resolvedURL = direct
                } else if target.hasPrefix("file://") {
                    let prefixCount = "file://".count
                    var path = String(target.dropFirst(prefixCount))
                    if let decoded = path.removingPercentEncoding {
                        path = decoded
                    }
                    if !path.hasPrefix("/") {
                        path = "/" + path
                    }
                    resolvedURL = URL(fileURLWithPath: path)
                }

                guard let url = resolvedURL else { return }
                let fileName = url.lastPathComponent
                results[fileName] = label
            }

            return results
        }

        private func syncSessionImageNames(with notes: String, for session: TicketSession) {
            let labels = extractFileLinkLabels(from: notes)
            guard !labels.isEmpty else { return }

            for (fileName, label) in labels {
                sessions.setSessionImageName(fileName: fileName, to: label, for: session)
            }
        }

        private func syncSessionImagesWithNotes(notes: String, for session: TicketSession) {
            // Extract all file names referenced in the notes
            let referencedFileNames = Set(extractFileLinkLabels(from: notes).keys)

            // Get current images from session
            let currentImages = sessions.sessionImages[session] ?? []

            // Find images that are no longer referenced in the notes
            let orphanedImages = currentImages.filter { image in
                !referencedFileNames.contains(image.fileName)
            }

            // Remove orphaned images
            for orphanedImage in orphanedImages {
                let imageURL = AppPaths.sessionImages.appendingPathComponent(orphanedImage.fileName)
                try? FileManager.default.removeItem(at: imageURL)

                var images = sessions.sessionImages[session] ?? []
                images.removeAll { $0.id == orphanedImage.id }
                sessions.sessionImages[session] = images

                LOG("Session image removed (orphaned from notes)", ctx: [
                    "session": "\(session.rawValue)",
                    "fileName": orphanedImage.fileName,
                    "displayName": orphanedImage.displayName
                ])
            }
        }

        private func syncGuideImageNames(with notes: String, for template: TemplateItem) {
            let labels = extractFileLinkLabels(from: notes)
            guard !labels.isEmpty else { return }

            for (fileName, label) in labels {
                templateGuideStore.setImageCustomName(fileName: fileName, to: label, for: template)
            }
        }

        private func syncGuideImagesWithNotes(notes: String, for template: TemplateItem) {
            // Extract all file names referenced in the notes
            let referencedFileNames = Set(extractFileLinkLabels(from: notes).keys)

            // Get current images from store
            let currentImages = templateGuideStore.images(for: template)

            // Find images that are no longer referenced in the notes
            let orphanedImages = currentImages.filter { image in
                !referencedFileNames.contains(image.fileName)
            }

            // Remove orphaned images
            for orphanedImage in orphanedImages {
                if templateGuideStore.deleteImage(orphanedImage, for: template) {
                    LOG("Guide image removed (orphaned from notes)", ctx: [
                        "template": template.name,
                        "fileName": orphanedImage.fileName,
                        "displayName": orphanedImage.displayName
                    ])
                }
            }
        }

        private func scheduleGuideNotesAutosave(for template: TemplateItem, lastKnownText: String) {
            guideNotesAutosave.schedule(for: template.id, delay: 1.0) {
                if templateGuideStore.saveNotes(for: template) {
                    touchTemplateActivity(for: template)
                    let savedText = templateGuideStore.currentNotes(for: template)
                    LOG("Guide notes autosaved", ctx: [
                        "template": template.name,
                        "reason": "autosave",
                        "chars": "\(savedText.count)",
                        "delta": "\(savedText.count - lastKnownText.count)"
                    ])
                }
            }
        }

        private func handleGuideNotesChange(_ value: String,
                                            for template: TemplateItem,
                                            source: String,
                                            logChange: Bool = true) {
            let previous = templateGuideStore.currentNotes(for: template)
            let changed = templateGuideStore.setNotes(value, for: template)
            guard changed else { return }

            syncGuideImageNames(with: value, for: template)
            syncGuideImagesWithNotes(notes: value, for: template)
            scheduleGuideNotesAutosave(for: template, lastKnownText: previous)

            guard logChange else { return }
            LOG("Guide notes draft updated", ctx: [
                "template": template.name,
                "chars": "\(value.count)",
                "delta": "\(value.count - previous.count)",
                "dirty": templateGuideStore.isNotesDirty(for: template) ? "dirty" : "clean",
                "source": source
            ])
        }

        private func finalizeGuideNotesAutosave(for template: TemplateItem?, reason: String) {
            guard let template else { return }

            guideNotesAutosave.flush(for: template.id)
            if templateGuideStore.isNotesDirty(for: template) {
                if templateGuideStore.saveNotes(for: template) {
                    touchTemplateActivity(for: template)
                    LOG("Guide notes saved", ctx: [
                        "template": template.name,
                        "reason": reason,
                        "chars": "\(templateGuideStore.currentNotes(for: template).count)"
                    ])
                }
            }
        }

        // MARK: - Guide Notes Search

        private func stripMarkdownForSearch(_ text: String) -> String {
            var result = text

            // Strip image links: ![alt](url)
            result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            // Strip links: [text](url)
            result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
            // Strip bold: **text** or __text__
            result = result.replacingOccurrences(of: "\\*\\*([^\\*]+)\\*\\*", with: "$1", options: .regularExpression)
            result = result.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
            // Strip italic: *text* or _text_
            result = result.replacingOccurrences(of: "\\*([^\\*]+)\\*", with: "$1", options: .regularExpression)
            result = result.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
            // Strip inline code: `code`
            result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
            // Strip headings: # text
            result = result.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            // Strip bullet lists: - text or * text or + text
            result = result.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: .regularExpression)
            // Strip numbered lists: 1. text
            result = result.replacingOccurrences(of: "^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)

            return result
        }

        private func updateGuideNotesSearchMatches() {
            let query = guideNotesInPaneSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !query.isEmpty else {
                guideNotesSearchMatches = []
                guideNotesCurrentMatchIndex = 0
                return
            }

            // Search in the raw markdown text (case-insensitive)
            let text = guideNotesDraft.lowercased()
            let searchText = query.lowercased()
            var matches: [Range<String.Index>] = []
            var searchStartIndex = text.startIndex

            while searchStartIndex < text.endIndex,
                  let range = text.range(of: searchText, range: searchStartIndex..<text.endIndex) {
                matches.append(range)
                searchStartIndex = range.upperBound
            }

            guideNotesSearchMatches = matches
            guideNotesCurrentMatchIndex = matches.isEmpty ? 0 : 0

            LOG("Guide notes search: updated matches", ctx: [
                "query": query,
                "matchCount": "\(matches.count)"
            ])

            if !matches.isEmpty {
                scrollToGuideNotesMatch(at: 0)
            }
        }

        private func navigateToGuideNotesPreviousMatch() {
            guard !guideNotesSearchMatches.isEmpty else {
                LOG("Guide notes search: no matches to navigate")
                return
            }

            let oldIndex = guideNotesCurrentMatchIndex
            guideNotesCurrentMatchIndex = (guideNotesCurrentMatchIndex - 1 + guideNotesSearchMatches.count) % guideNotesSearchMatches.count

            LOG("Guide notes search: navigate previous", ctx: [
                "oldIndex": "\(oldIndex)",
                "newIndex": "\(guideNotesCurrentMatchIndex)",
                "total": "\(guideNotesSearchMatches.count)"
            ])

            scrollToGuideNotesMatch(at: guideNotesCurrentMatchIndex)
        }

        private func navigateToGuideNotesNextMatch() {
            guard !guideNotesSearchMatches.isEmpty else {
                LOG("Guide notes search: no matches to navigate")
                return
            }

            let oldIndex = guideNotesCurrentMatchIndex
            guideNotesCurrentMatchIndex = (guideNotesCurrentMatchIndex + 1) % guideNotesSearchMatches.count

            LOG("Guide notes search: navigate next", ctx: [
                "oldIndex": "\(oldIndex)",
                "newIndex": "\(guideNotesCurrentMatchIndex)",
                "total": "\(guideNotesSearchMatches.count)"
            ])

            scrollToGuideNotesMatch(at: guideNotesCurrentMatchIndex)
        }

        private func scrollToGuideNotesMatch(at index: Int) {
            guard index >= 0 && index < guideNotesSearchMatches.count else {
                LOG("Guide notes search: invalid index", ctx: ["index": "\(index)", "total": "\(guideNotesSearchMatches.count)"])
                return
            }
            guard !guideNotesInPaneSearchQuery.isEmpty else {
                LOG("Guide notes search: empty query")
                return
            }

            // Get the specific match range
            let matchRange = guideNotesSearchMatches[index]

            // Convert String.Index to Int offset for NSRange
            let offset = guideNotesDraft.distance(from: guideNotesDraft.startIndex, to: matchRange.lowerBound)
            let length = guideNotesDraft.distance(from: matchRange.lowerBound, to: matchRange.upperBound)

            LOG("Guide notes search: scrolling to match", ctx: [
                "index": "\(index + 1)",
                "total": "\(guideNotesSearchMatches.count)",
                "offset": "\(offset)",
                "length": "\(length)",
                "query": guideNotesInPaneSearchQuery
            ])

            // Manually select and scroll to the specific range in the editor
            DispatchQueue.main.async { [self] in
                guideNotesEditor.selectAndScrollToRange(offset: offset, length: length)
            }
        }

        private func handleGuideNotesSearchEnter() {
            guard !guideNotesInPaneSearchQuery.isEmpty else { return }

            // If in preview mode, switch to edit mode first
            if isPreviewMode {
                setPreviewMode(false)
                LOG("Guide notes search: switched to edit mode on Enter")
            }

            // Navigate to next match (or first match if just switched modes)
            if !guideNotesSearchMatches.isEmpty {
                navigateToGuideNotesNextMatch()
            }
        }

        // MARK: - Session Notes Search

        private func updateSessionNotesSearchMatches() {
            let query = sessionNotesInPaneSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !query.isEmpty else {
                sessionNotesSearchMatches = []
                sessionNotesCurrentMatchIndex = 0
                return
            }

            // Get the current session notes text
            let text = (sessionNotesDrafts[sessions.current] ?? "").lowercased()
            let searchText = query.lowercased()
            var matches: [Range<String.Index>] = []
            var searchStartIndex = text.startIndex

            while searchStartIndex < text.endIndex,
                  let range = text.range(of: searchText, range: searchStartIndex..<text.endIndex) {
                matches.append(range)
                searchStartIndex = range.upperBound
            }

            sessionNotesSearchMatches = matches
            sessionNotesCurrentMatchIndex = matches.isEmpty ? 0 : 0

            LOG("Session notes search: updated matches", ctx: [
                "query": query,
                "matchCount": "\(matches.count)"
            ])

            if !matches.isEmpty {
                scrollToSessionNotesMatch(at: 0)
            }
        }

        private func navigateToSessionNotesPreviousMatch() {
            guard !sessionNotesSearchMatches.isEmpty else {
                LOG("Session notes search: no matches to navigate")
                return
            }

            let oldIndex = sessionNotesCurrentMatchIndex
            sessionNotesCurrentMatchIndex = (sessionNotesCurrentMatchIndex - 1 + sessionNotesSearchMatches.count) % sessionNotesSearchMatches.count

            LOG("Session notes search: navigate previous", ctx: [
                "oldIndex": "\(oldIndex)",
                "newIndex": "\(sessionNotesCurrentMatchIndex)",
                "total": "\(sessionNotesSearchMatches.count)"
            ])

            scrollToSessionNotesMatch(at: sessionNotesCurrentMatchIndex)
        }

        private func navigateToSessionNotesNextMatch() {
            guard !sessionNotesSearchMatches.isEmpty else {
                LOG("Session notes search: no matches to navigate")
                return
            }

            let oldIndex = sessionNotesCurrentMatchIndex
            sessionNotesCurrentMatchIndex = (sessionNotesCurrentMatchIndex + 1) % sessionNotesSearchMatches.count

            LOG("Session notes search: navigate next", ctx: [
                "oldIndex": "\(oldIndex)",
                "newIndex": "\(sessionNotesCurrentMatchIndex)",
                "total": "\(sessionNotesSearchMatches.count)"
            ])

            scrollToSessionNotesMatch(at: sessionNotesCurrentMatchIndex)
        }

        private func scrollToSessionNotesMatch(at index: Int) {
            guard index >= 0 && index < sessionNotesSearchMatches.count else {
                LOG("Session notes search: invalid index", ctx: ["index": "\(index)", "total": "\(sessionNotesSearchMatches.count)"])
                return
            }
            guard !sessionNotesInPaneSearchQuery.isEmpty else {
                LOG("Session notes search: empty query")
                return
            }

            let sessionNotesDraft = sessionNotesDrafts[sessions.current] ?? ""

            // Get the specific match range
            let matchRange = sessionNotesSearchMatches[index]

            // Convert String.Index to Int offset for NSRange
            let offset = sessionNotesDraft.distance(from: sessionNotesDraft.startIndex, to: matchRange.lowerBound)
            let length = sessionNotesDraft.distance(from: matchRange.lowerBound, to: matchRange.upperBound)

            LOG("Session notes search: scrolling to match", ctx: [
                "index": "\(index + 1)",
                "total": "\(sessionNotesSearchMatches.count)",
                "offset": "\(offset)",
                "length": "\(length)",
                "query": sessionNotesInPaneSearchQuery
            ])

            // Manually select and scroll to the specific range in the editor
            DispatchQueue.main.async { [self] in
                sessionNotesEditor.selectAndScrollToRange(offset: offset, length: length)
            }
        }

        private func handleSessionNotesSearchEnter() {
            guard !sessionNotesInPaneSearchQuery.isEmpty else { return }

            // If in preview mode, switch to edit mode first
            if isPreviewMode {
                setPreviewMode(false)
            }

            // Navigate to next match (or first match if just switched modes)
            if !sessionNotesSearchMatches.isEmpty {
                navigateToSessionNotesNextMatch()
            }
        }

        private func scheduleSessionNotesAutosave(for session: TicketSession) {
            sessionNotesAutosave.schedule(for: session, delay: 1.0) { [self] in
                saveSessionNotes(for: session, reason: "autosave")
            }
        }

        // MARK: – Saved Files

        private func savedFiles(for session: TicketSession) -> [SessionSavedFile] {
            sessions.sessionSavedFiles[session] ?? []
        }

        private func currentSavedFileSelection(for session: TicketSession) -> UUID? {
            if let stored = selectedSavedFile[session] {
                return stored
            }
            return nil
        }

        private func setSavedFileSelection(_ id: UUID?, for session: TicketSession) {
            let previous = currentSavedFileSelection(for: session)
            if let previous, previous != id {
                savedFileAutosave.flush(session: session, fileId: previous)
                saveSavedFile(for: session, fileId: previous, reason: "selection-change")
            }
            selectedSavedFile[session] = id
            LOG("Saved file selection", ctx: [
                "session": "\(session.rawValue)",
                "previous": previous?.uuidString ?? "nil",
                "current": id?.uuidString ?? "nil"
            ])
        }

        private func savedFileDraft(for session: TicketSession, fileId: UUID) -> String {
            if let text = savedFileDrafts[session]?[fileId] {
                return text
            }
            return savedFiles(for: session).first(where: { $0.id == fileId })?.content ?? ""
        }

        private func validationState(for session: TicketSession, fileId: UUID) -> JSONValidationState {
            if let value = savedFileValidation[session]?[fileId] {
                return value
            }
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }) else {
                return .invalid("File not found")
            }
            let draft = savedFileDraft(for: session, fileId: fileId)
            let validation = validateSavedFile(draft, format: file.format)
            var validations = savedFileValidation[session] ?? [:]
            validations[fileId] = validation
            savedFileValidation[session] = validations
            return validation
        }

        private func ensureSavedFileState(for session: TicketSession) {
            let files = savedFiles(for: session)
            guard !files.isEmpty else {
                savedFileDrafts[session] = [:]
                savedFileValidation[session] = [:]
                sessionNotesMode[session] = .notes
                if currentSavedFileSelection(for: session) != nil {
                    setSavedFileSelection(nil, for: session)
                }
                LOG("Saved file state reset", ctx: [
                    "session": "\(session.rawValue)"
                ])
                return
            }

            var drafts = savedFileDrafts[session] ?? [:]
            var validations = savedFileValidation[session] ?? [:]
            let identifiers = Set(files.map { $0.id })

            var hydratedCount = 0
            for file in files {
                if drafts[file.id] == nil {
                    drafts[file.id] = file.content
                    hydratedCount += 1
                }
                let current = drafts[file.id] ?? file.content
                validations[file.id] = validateSavedFile(current, format: file.format)
            }

            var removedCount = 0
            for key in drafts.keys where !identifiers.contains(key) {
                drafts.removeValue(forKey: key)
                validations.removeValue(forKey: key)
                savedFileAutosave.cancel(session: session, fileId: key)
                removedCount += 1
            }

            savedFileDrafts[session] = drafts
            savedFileValidation[session] = validations

            LOG("Saved file state ensured", ctx: [
                "session": "\(session.rawValue)",
                "files": "\(files.count)",
                "drafts": "\(drafts.count)",
                "hydrated": "\(hydratedCount)",
                "removed": "\(removedCount)"
            ])

            if let selected = currentSavedFileSelection(for: session), !identifiers.contains(selected) {
                setSavedFileSelection(files.first?.id, for: session)
            } else if currentSavedFileSelection(for: session) == nil {
                setSavedFileSelection(files.first?.id, for: session)
            }
        }

        private func addSavedFile(for session: TicketSession) {
            ensureSavedFileState(for: session)

            // First, prompt for format selection
            let formatAlert = NSAlert()
            formatAlert.messageText = "Choose File Format"
            formatAlert.informativeText = "Select the format for your new saved file:"
            formatAlert.alertStyle = .informational
            formatAlert.addButton(withTitle: "JSON")
            formatAlert.addButton(withTitle: "YAML")
            formatAlert.addButton(withTitle: "Cancel")

            let formatResult = runAlertWithFix(formatAlert)
            guard formatResult != .alertThirdButtonReturn else {
                LOG("Saved file creation cancelled at format selection", ctx: ["session": "\(session.rawValue)"])
                return
            }

            let selectedFormat: SavedFileFormat = formatResult == .alertFirstButtonReturn ? .json : .yaml

            // Then, prompt for filename
            let defaultName = sessions.generateDefaultFileName(for: session)
            let extensionText = selectedFormat == .json ? ".json" : ".yaml"
            let message = "Enter a name for the new \(selectedFormat.rawValue.uppercased()) file. '\(extensionText)' will be added automatically."
            guard let rawInput = promptForString(
                title: "New Saved File",
                message: message,
                defaultValue: defaultName
            ) else {
                LOG("Saved file creation cancelled at name entry", ctx: ["session": "\(session.rawValue)"])
                return
            }

            let provided = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = provided.isEmpty ? defaultName : provided
            let file = sessions.addSavedFile(name: finalName, format: selectedFormat, for: session)
            ensureSavedFileState(for: session)
            setSavedFileSelection(file.id, for: session)
            sessionNotesMode[session] = .savedFiles
            LOG("Saved file added", ctx: ["session": "\(session.rawValue)", "file": file.displayName, "format": selectedFormat.rawValue])
        }

        private func removeSavedFile(_ fileId: UUID, in session: TicketSession) {
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }) else { return }
#if canImport(AppKit)
            let alert = NSAlert()
            alert.messageText = "Delete Saved File?"
            alert.informativeText = "This will remove '\(file.displayName)' from Session #\(session.rawValue)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard runAlertWithFix(alert) == .alertFirstButtonReturn else { return }
#endif
            savedFileAutosave.cancel(session: session, fileId: fileId)
            sessions.removeSavedFile(id: fileId, from: session)
            savedFileDrafts[session]?.removeValue(forKey: fileId)
            savedFileValidation[session]?.removeValue(forKey: fileId)
            if currentSavedFileSelection(for: session) == fileId {
                let remaining = savedFiles(for: session)
                setSavedFileSelection(remaining.first?.id, for: session)
            }
            ensureSavedFileState(for: session)
            LOG("Saved file removed", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
        }

        private func renameSavedFile(_ fileId: UUID, in session: TicketSession) {
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }) else { return }
            let prompt = "Update the display name for this JSON file."
            guard let newName = promptForString(title: "Rename Saved File",
                                               message: prompt,
                                               defaultValue: file.name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !newName.isEmpty else { return }
            sessions.renameSavedFile(id: fileId, to: newName, in: session)
            ensureSavedFileState(for: session)
        }

        private func presentTreeView(for fileId: UUID, session: TicketSession) {
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }) else { return }
            let content = savedFileDraft(for: session, fileId: fileId)
            savedFileTreePreview = SavedFileTreePreviewContext(fileName: file.displayName, content: content, format: file.format)
            LOG("Saved file tree preview", ctx: ["session": "\(session.rawValue)", "file": file.displayName, "format": file.format.rawValue])
        }

        private func presentGhostOverlay(for session: TicketSession, ghostFileId: UUID? = nil) {
            let files = savedFiles(for: session)
            let currentFile = currentSavedFileSelection(for: session).flatMap { id in
                files.first(where: { $0.id == id })
            }
            let ghostFile = ghostFileId.flatMap { id in
                files.first(where: { $0.id == id })
            }
            ghostOverlayContext = GhostOverlayContext(
                session: session,
                availableFiles: files,
                originalFile: currentFile,
                ghostFile: ghostFile
            )
            LOG("Ghost overlay presented", ctx: ["session": "\(session.rawValue)", "filesCount": "\(files.count)", "ghostPreselected": "\(ghostFile != nil)"])
        }

        private func formatJSONPreservingOrder(_ jsonString: String, indent: String = "  ") -> String? {
            var result = ""
            var indentLevel = 0
            var inString = false
            var escaped = false
            var i = jsonString.startIndex

            while i < jsonString.endIndex {
                let char = jsonString[i]

                if escaped {
                    result.append(char)
                    escaped = false
                    i = jsonString.index(after: i)
                    continue
                }

                if char == "\\" && inString {
                    result.append(char)
                    escaped = true
                    i = jsonString.index(after: i)
                    continue
                }

                if char == "\"" {
                    inString.toggle()
                    result.append(char)
                    i = jsonString.index(after: i)
                    continue
                }

                if inString {
                    result.append(char)
                    i = jsonString.index(after: i)
                    continue
                }

                switch char {
                case "{", "[":
                    result.append(char)
                    // Check if next char (after whitespace) is closing bracket
                    var nextIndex = jsonString.index(after: i)
                    while nextIndex < jsonString.endIndex && jsonString[nextIndex].isWhitespace {
                        nextIndex = jsonString.index(after: nextIndex)
                    }
                    if nextIndex < jsonString.endIndex && (jsonString[nextIndex] == "}" || jsonString[nextIndex] == "]") {
                        // Empty object/array, don't add newline
                        i = jsonString.index(after: i)
                        continue
                    }
                    indentLevel += 1
                    result.append("\n")
                    result.append(String(repeating: indent, count: indentLevel))

                case "}", "]":
                    indentLevel -= 1
                    result.append("\n")
                    result.append(String(repeating: indent, count: indentLevel))
                    result.append(char)

                case ",":
                    result.append(char)
                    result.append("\n")
                    result.append(String(repeating: indent, count: indentLevel))

                case ":":
                    result.append(": ")

                default:
                    if !char.isWhitespace {
                        result.append(char)
                    }
                }

                i = jsonString.index(after: i)
            }

            return result
        }

        private func formatSavedFileAsTree(for fileId: UUID, session: TicketSession) {
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }),
                  file.format == .json else { return }

            let content = savedFileDraft(for: session, fileId: fileId)

            // Validate JSON first
            guard let jsonData = content.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: jsonData)) != nil else {
                NSSound.beep()
                LOG("Failed to format JSON as tree - invalid JSON", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
                return
            }

            // Format while preserving key order
            guard let prettyString = formatJSONPreservingOrder(content) else {
                NSSound.beep()
                LOG("Failed to format JSON as tree", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
                return
            }

            setSavedFileDraft(prettyString, for: fileId, session: session, source: "format.tree")
            LOG("Formatted JSON as tree", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
        }

        private func minifyJSONPreservingOrder(_ jsonString: String) -> String? {
            var result = ""
            var inString = false
            var escaped = false

            for char in jsonString {
                if escaped {
                    result.append(char)
                    escaped = false
                    continue
                }

                if char == "\\" && inString {
                    result.append(char)
                    escaped = true
                    continue
                }

                if char == "\"" {
                    inString.toggle()
                    result.append(char)
                    continue
                }

                if inString {
                    result.append(char)
                    continue
                }

                // Outside strings: remove all whitespace
                if !char.isWhitespace {
                    result.append(char)
                }
            }

            return result
        }

        private func formatSavedFileAsLine(for fileId: UUID, session: TicketSession) {
            guard let file = savedFiles(for: session).first(where: { $0.id == fileId }),
                  file.format == .json else { return }

            let content = savedFileDraft(for: session, fileId: fileId)

            // Validate JSON first
            guard let jsonData = content.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: jsonData)) != nil else {
                NSSound.beep()
                LOG("Failed to minify JSON as line - invalid JSON", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
                return
            }

            // Minify while preserving key order
            guard let minifiedString = minifyJSONPreservingOrder(content) else {
                NSSound.beep()
                LOG("Failed to minify JSON as line", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
                return
            }

            setSavedFileDraft(minifiedString, for: fileId, session: session, source: "format.line")
            LOG("Formatted JSON as line", ctx: ["session": "\(session.rawValue)", "file": file.displayName])
        }

        private func setSavedFileDraft(_ value: String,
                                       for fileId: UUID,
                                       session: TicketSession,
                                       source: String) {
            let currentSelection = currentSavedFileSelection(for: session)
            var targetId = fileId
            var rerouted = false
            let shouldReroute = source == "savedFile.inline" || source == "savedFile.popout"
            if shouldReroute,
               let selected = currentSelection,
               selected != fileId {
                targetId = selected
                rerouted = true
                WARN("Saved file draft rerouted", ctx: [
                    "session": "\(session.rawValue)",
                    "incoming": fileId.uuidString,
                    "selected": selected.uuidString
                ])
            }

            var drafts = savedFileDrafts[session] ?? [:]
            let previous = drafts[targetId] ?? savedFiles(for: session).first(where: { $0.id == targetId })?.content ?? ""
            guard let file = savedFiles(for: session).first(where: { $0.id == targetId }) else { return }
            if previous == value {
                var validations = savedFileValidation[session] ?? [:]
                validations[targetId] = validateSavedFile(value, format: file.format)
                savedFileValidation[session] = validations
                return
            }
            drafts[targetId] = value
            savedFileDrafts[session] = drafts

            var validations = savedFileValidation[session] ?? [:]
            let validation = validateSavedFile(value, format: file.format)
            validations[targetId] = validation
            savedFileValidation[session] = validations

            let synced = sessions.syncSavedFileDraft(value, for: targetId, in: session)
            let delta = value.count - previous.count
            LOG("Saved file draft updated", ctx: [
                "session": "\(session.rawValue)",
                "fileId": fileId.uuidString,
                "targetId": targetId.uuidString,
                "chars": "\(value.count)",
                "delta": "\(delta)",
                "drafts": "\(drafts.count)",
                "valid": validation.isValid ? "true" : "false",
                "selected": currentSelection?.uuidString ?? "nil",
                "rerouted": rerouted ? "true" : "false",
                "synced": synced ? "true" : "false",
                "source": source
            ])

            if rerouted {
                savedFileAutosave.cancel(session: session, fileId: fileId)
            }
            scheduleSavedFileAutosave(for: session, fileId: targetId)
        }

        private func scheduleSavedFileAutosave(for session: TicketSession, fileId: UUID) {
            savedFileAutosave.schedule(session: session, fileId: fileId, delay: 0.8) { [self] in
                saveSavedFile(for: session, fileId: fileId, reason: "autosave")
            }
        }

        private func saveSavedFile(for session: TicketSession, fileId: UUID, reason: String) {
            savedFileAutosave.cancel(session: session, fileId: fileId)
            guard let draft = savedFileDrafts[session]?[fileId] else { return }
            guard let current = savedFiles(for: session).first(where: { $0.id == fileId }) else { return }
            if current.content == draft { return }
            sessions.updateSavedFileContent(draft, for: fileId, in: session)
            LOG("Saved file committed", ctx: [
                "session": "\(session.rawValue)",
                "file": current.displayName,
                "chars": "\(draft.count)",
                "fileId": fileId.uuidString,
                "reason": reason
            ])
        }

        private func commitSavedFileDrafts(for session: TicketSession) {
            guard let drafts = savedFileDrafts[session] else { return }
            for fileId in drafts.keys {
                savedFileAutosave.flush(session: session, fileId: fileId)
                saveSavedFile(for: session, fileId: fileId, reason: "commit")
            }
        }

        private func validateJSON(_ text: String) -> JSONValidationState {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .invalid("JSON content is empty") }
            guard let data = text.data(using: .utf8) else {
                return .invalid("Unable to encode text as UTF-8")
            }
            do {
                _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                return .valid
            } catch {
                return .invalid(error.localizedDescription)
            }
        }

        private func validateSavedFile(_ text: String, format: SavedFileFormat) -> JSONValidationState {
            let result = SavedFileParser.validate(text, as: format)
            switch result {
            case .valid:
                return .valid
            case .invalid(let message):
                return .invalid(message)
            }
        }

        private var filteredTemplates: [TemplateItem] {
            let baseList: [TemplateItem]
            let trimmedSearch = trimmedSearchText
            if trimmedSearch.isEmpty || isTagSearch {
                baseList = templates.templates
            } else {
                let query = normalizedSearchText(trimmedSearch)
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

        private var tagSearchResults: [TagSearchResult] {
            guard isTagSearch else { return [] }
            let rawQuery = String(trimmedSearchText.dropFirst())
            let normalized = TemplateTagsStore.sanitize(rawQuery)
            let fallback = rawQuery.lowercased().replacingOccurrences(of: " ", with: "-")

            var buckets: [String: [TemplateItem]] = [:]
            for template in templates.templates {
                let tags = templateTagsStore.tags(for: template)
                for tag in tags {
                    let matches: Bool
                    if let normalized = normalized, !normalized.isEmpty {
                        matches = tag.contains(normalized)
                    } else if !fallback.isEmpty {
                        matches = tag.contains(fallback)
                    } else {
                        matches = true
                    }
                    if matches {
                        buckets[tag, default: []].append(template)
                    }
                }
            }

            return buckets
                .map { TagSearchResult(tag: $0.key, templates: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count {
                        return lhs.count > rhs.count
                    }
                    return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
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
                HStack {
                    Text("Static Info")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    Spacer()
                    Button {
                        startBeginCapture()
                    } label: {
                        Text("Begin")
                            .font(.system(size: fontSize + 4, weight: .bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.pink)
                    .controlSize(.large)
                    .keyboardShortcut("b", modifiers: [.control, .shift])
                    .registerShortcut(name: "Begin Capture", keyLabel: "B", modifiers: [.control, .shift], scope: "Global")
                }

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
                            Button(action: { connectToQuerious() }) {
                                Text("Connect to Database")
                                    .foregroundColor(Color(hex: "#2A2A35"))
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
                        NonBubblingScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(dynamicPlaceholders, id: \.self) { ph in
                                    if ph.lowercased() == "date" {
                                        dateFieldRow("Date")
                                    } else {
                                        dynamicFieldRow(ph)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 260)
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
                    .padding(.trailing, 20)
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

        private func startBeginCapture() {
            beginOrgDraft = orgId
            beginAcctDraft = acctId
            beginExtraDrafts = [BeginCaptureEntry()]
            clipboardHistory.refresh()
            showBeginCaptureSheet = true
            LOG("Quick capture opened", ctx: ["session": "\(sessions.current.rawValue)"])
        }

        private func applyBeginCaptureValues() {
            let trimmedOrg = beginOrgDraft.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            let trimmedAcct = beginAcctDraft.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedOrg != beginOrgDraft { beginOrgDraft = trimmedOrg }
            orgId = trimmedOrg
            sessions.setValue(trimmedOrg, for: "Org-ID")

            if let match = mapping.lookup(orgId: trimmedOrg) {
                mysqlDb = match.mysqlDb
                companyLabel = match.companyName ?? ""
            } else {
                companyLabel = ""
            }

            acctId = trimmedAcct
            sessions.setValue(trimmedAcct, for: "Acct-ID")

            sessionStaticFields[sessions.current] = (trimmedOrg, trimmedAcct, mysqlDb, companyLabel)

            let extraValues = beginExtraDrafts
                .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !extraValues.isEmpty {
                var existing = sessions.sessionAlternateFields[sessions.current] ?? []
                for value in extraValues {
                    let newField = AlternateField(name: "", value: value)
                    existing.append(newField)
                    LOG("Quick capture alternate", ctx: [
                        "session": "\(sessions.current.rawValue)",
                        "value": value
                    ])
                }
                sessions.sessionAlternateFields[sessions.current] = existing
            }

            LOG("Quick capture saved", ctx: [
                "session": "\(sessions.current.rawValue)",
                "org": trimmedOrg,
                "acct": trimmedAcct,
                "extras": "\(extraValues.count)"
            ])

            beginExtraDrafts = [BeginCaptureEntry()]
        }

        private func autoPopulateQuickCaptureFromClipboard() {
            clipboardHistory.refresh()
            let entries = clipboardHistory.recentStrings
            guard !entries.isEmpty else { return }

            var remaining: [String] = []
            var matchedOrg: String?
            var matchedAcct: String?

            for entry in entries {
                let trimmedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedEntry.isEmpty else { continue }

                var consumed = false
                if matchedOrg == nil, let detectedOrg = firstMatch(in: trimmedEntry, using: orgIdRegex) {
                    matchedOrg = detectedOrg
                    consumed = true
                }

                if matchedAcct == nil, let detectedAcct = firstMatch(in: trimmedEntry, using: accountIdRegex) {
                    matchedAcct = detectedAcct
                    consumed = true
                }

                if !consumed {
                    remaining.append(trimmedEntry)
                }
            }

            if let org = matchedOrg {
                beginOrgDraft = org
            }
            if let acct = matchedAcct {
                beginAcctDraft = acct
            }

            let extras = remaining.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                   .filter { !$0.isEmpty }

            if extras.isEmpty {
                beginExtraDrafts = [BeginCaptureEntry()]
            } else {
                beginExtraDrafts = extras.map { BeginCaptureEntry(value: $0) }
            }

            LOG("Quick capture auto populated", ctx: [
                "session": "\(sessions.current.rawValue)",
                "orgMatched": "\(matchedOrg != nil)",
                "acctMatched": "\(matchedAcct != nil)",
                "extraCount": "\(extras.count)"
            ])
        }

        private func firstMatch(in text: String, using regex: NSRegularExpression) -> String? {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

            let targetRange: NSRange
            if match.numberOfRanges > 1 {
                targetRange = match.range(at: 1)
            } else {
                targetRange = match.range
            }

            guard let swiftRange = Range(targetRange, in: text) else { return nil }
            return String(text[swiftRange])
        }
        
        // Suggest tables using the global catalog (substring/fuzzy provided by the catalog)
        private func suggestTables(_ query: String, limit: Int = 15) -> [String] {
            DBTablesCatalog.shared.suggest(query, limit: limit)
        }
        
#if os(macOS)
        /// Routes Option(/Shift)+Arrow to the active text responder so word-wise moves always work.
        private func handleWordwiseSelection(_ event: NSEvent) -> NSEvent? {
            guard event.type == .keyDown else { return event }

            // Filter to Option+Left/Right (with optional Shift); avoid mixing with Command/Control combos.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains(.option), !modifiers.contains(.command), !modifiers.contains(.control) else { return event }

            let usesShift = modifiers.contains(.shift)
            let selector: Selector?

            switch event.keyCode {
            case 123: // Left arrow
                selector = usesShift ? #selector(NSResponder.moveWordLeftAndModifySelection(_:))
                                      : #selector(NSResponder.moveWordLeft(_:))
            case 124: // Right arrow
                selector = usesShift ? #selector(NSResponder.moveWordRightAndModifySelection(_:))
                                      : #selector(NSResponder.moveWordRight(_:))
            case 125: // Down arrow
                selector = usesShift ? Selector(("moveParagraphForwardAndModifySelection:"))
                                      : Selector(("moveParagraphForward:"))
            case 126: // Up arrow
                selector = usesShift ? Selector(("moveParagraphBackwardAndModifySelection:"))
                                      : Selector(("moveParagraphBackward:"))
            default:
                selector = nil
            }

            guard let command = selector else { return event }

            // Try the current first responder first.
            if let responder = NSApp.keyWindow?.firstResponder, responder.tryToPerform(command, with: nil) {
                return nil
            }

            // Fallback to the window's field editor (used by NSTextField instances).
            if let window = NSApp.keyWindow,
               let fieldEditor = window.fieldEditor(false, for: nil),
               fieldEditor.tryToPerform(command, with: nil) {
                return nil
            }

            return event
        }

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
                    if let template = selectedTemplate {
                        scheduleDBTablesAutosave(for: sessions.current, template: template)
                    }
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

        private func updateScrollEventMonitor() {
            let needsMonitor = isGuideNotesEditorFocused || isSessionNotesEditorFocused
            if needsMonitor {
                if scrollEventMonitor == nil {
                    scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        return shouldSwallowMarkdownScroll(event: event) ? nil : event
                    }
                }
            } else if let monitor = scrollEventMonitor {
                NSEvent.removeMonitor(monitor)
                scrollEventMonitor = nil
            }
        }

        private func shouldSwallowMarkdownScroll(event: NSEvent) -> Bool {
            guard isGuideNotesEditorFocused || isSessionNotesEditorFocused else { return false }
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            guard let textView = currentMarkdownTextView(from: responder) else { return false }
            guard let scrollView = textView.enclosingScrollView as? NonBubblingNSScrollView else { return false }

            let decision = scrollView.scrollDecision(for: event)
            if case .swallow = decision {
                return true
            }
            return false
        }

        private func currentMarkdownTextView(from responder: NSResponder?) -> MarkdownTextView? {
            if let textView = responder as? MarkdownTextView {
                return textView
            }
            if let view = responder as? NSView {
                var current: NSView? = view
                while let candidate = current {
                    if let textView = candidate as? MarkdownTextView {
                        return textView
                    }
                    current = candidate.superview
                }
            }
            return nil
        }
	#endif


        private func startAddTags(for template: TemplateItem) {
            templateTagsStore.ensureLoaded(template)
            tagEditorTemplate = template
        }

        private func persistTags(_ tags: [String], for template: TemplateItem) {
            templateTagsStore.setTags(tags, for: template)
            templateTagsStore.saveSidecar(for: template)
        }

        private func showTemplates(for tag: String) {
            tagExplorerContext = TagExplorerContext(tag: tag)
        }

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

            if runAlertWithFix(alert) == .alertFirstButtonReturn {
                do {
                    // Delete the file from disk
                    try FileManager.default.removeItem(at: item.url)
                    LOG("Template file removed", ctx: ["file": item.url.path])
                    TemplateTagsStore.shared.removeSidecar(for: item)
                    
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
            guard !isTagSearch else { return }
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

        private func navigateTagSearch(direction: Int) {
            guard !tagSearchResults.isEmpty else { return }
            let newIndex = selectedTagIndex + direction
            if newIndex >= 0 && newIndex < tagSearchResults.count {
                selectedTagIndex = newIndex
                LOG("Tag search navigation", ctx: ["direction": "\(direction)", "tag": tagSearchResults[newIndex].tag])
            }
        }

        private func selectCurrentTag() {
            guard !tagSearchResults.isEmpty else { return }
            guard selectedTagIndex >= 0 && selectedTagIndex < tagSearchResults.count else { return }
            let tag = tagSearchResults[selectedTagIndex].tag
            showTemplates(for: tag)
            LOG("Tag selected via keyboard", ctx: ["tag": tag])
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
                    
                    Toggle(isOn: Binding(
                        get: { dbTablesLocked },
                        set: { newValue in setPaneLockState(newValue, source: "dbToggle") }
                    )) {
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
                                                let current = dbTablesStore.workingSet(for: sessions.current, template: t)
                                                return idx < current.count ? current[idx] : ""
                                            },
                                            set: { newVal in
                                                var current = dbTablesStore.workingSet(for: sessions.current, template: t)
                                                if idx < current.count {
                                                    current[idx] = newVal
                                                } else if idx == current.count {
                                                    current.append(newVal)
                                                }
                                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: t)
                                                // Reset keyboard highlight for this row on text change
                                                suggestionIndexByRow[idx] = nil
                                                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                                if !trimmed.isEmpty {
                                                    scheduleDBTablesAutosave(for: sessions.current, template: t)
                                                }
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
                                            var current = dbTablesStore.workingSet(for: sessions.current, template: t)
                                            if idx < current.count {
                                                current.remove(at: idx)
                                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: t)
                                                scheduleDBTablesAutosave(for: sessions.current, template: t, force: true)
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
                                let current = dbTablesStore.workingSet(for: sessions.current, template: t)
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
                                                    dbTablesStore.setWorkingSet(arr, for: sessions.current, template: t)
                                                    scheduleDBTablesAutosave(for: sessions.current, template: t)
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
                                var current = dbTablesStore.workingSet(for: sessions.current, template: t)
                                current.append("")
                                dbTablesStore.setWorkingSet(current, for: sessions.current, template: t)
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
                        if dbTablesLocked {
                            Text("Unlock to edit tables")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Changes are saved automatically")
                                .font(.system(size: fontSize - 3))
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
                    
                    Toggle(isOn: Binding(
                        get: { alternateFieldsLocked },
                        set: { newValue in setPaneLockState(newValue, source: "altToggle") }
                    )) {
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

                // Reorder mode banner
                if alternateFieldsReorderMode {
                    HStack {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(.blue)
                        Text("Reorder Mode: Drag rows to reorder")
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .foregroundStyle(.blue)
                        Spacer()
                        Button("Done") {
                            withAnimation {
                                alternateFieldsReorderMode = false
                            }
                            LOG("Reorder mode deactivated via Done button", ctx: ["session": "\(sessions.current.rawValue)"])
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .font(.system(size: fontSize - 2))
                    }
                    .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 14))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.blue.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                let minPaneHeight = max(160, fontSize * 8)
                let maxPaneHeight = max(220, fontSize * 11)

                NonBubblingScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessions.sessionAlternateFields[sessions.current] ?? [], id: \.id) { field in
                            AlternateFieldRow(session: sessions.current,
                                              field: field,
                                              locked: $alternateFieldsLocked,
                                              reorderMode: $alternateFieldsReorderMode,
                                              draggedField: $draggedAlternateField,
                                              fontSize: fontSize,
                                              selectedTemplate: selectedTemplate,
                                              draftDynamicValues: $draftDynamicValues)
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
                            .font(.system(size: fontSize - 1, weight: .medium))
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
                    .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 14))
                    .frame(maxWidth: .infinity, minHeight: minPaneHeight, alignment: .topLeading)
                }
                .frame(minHeight: minPaneHeight, maxHeight: maxPaneHeight)
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
            let minPaneHeight = max(160, fontSize * 8)
            let maxPaneHeight = max(220, fontSize * 11)

            return VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Session & Template")
                        .font(.system(size: fontSize + 1, weight: .semibold))
                        .foregroundStyle(Theme.purple)

                    Button("Pop Out") {
                        triggerSessionTemplatePopOut()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .font(.system(size: fontSize - 1))

                    Spacer()
                }

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
                .frame(minHeight: minPaneHeight, maxHeight: maxPaneHeight, alignment: .top)
            }
        }
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
                    NonBubblingScrollView {
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
                                        notifyPreviewBehindIfNeeded()
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
                        NonBubblingScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(guideImages) { image in
                                    TemplateGuideImageRow(
                                        template: template,
                                        image: image,
                                        fontSize: fontSize,
                                        onOpen: { openGuideImage(image) },
                                        onRename: { renameGuideImage(image) },
                                        onDelete: { deleteGuideImage(image) },
                                        onPreview: {
                                            previewingGuideImageContext = GuideImagePreviewContext(template: template, image: image)
                                            notifyPreviewBehindIfNeeded()
                                        }
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
                        NonBubblingScrollView {
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

                        Text("Changes are saved automatically")
                            .font(.system(size: fontSize - 3))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
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
            @Binding var reorderMode: Bool
            @Binding var draggedField: UUID?
            let fontSize: CGFloat
            let selectedTemplate: TemplateItem?
            @Binding var draftDynamicValues: [TicketSession: [String: String]]

            @State private var editingName: String
            @State private var editingValue: String
            @State private var longPressTimer: Timer?
            @State private var gestureStartLocation: CGPoint?
            @State private var hasMovedDuringGesture: Bool = false

            init(session: TicketSession,
                 field: AlternateField,
                 locked: Binding<Bool>,
                 reorderMode: Binding<Bool>,
                 draggedField: Binding<UUID?>,
                 fontSize: CGFloat,
                 selectedTemplate: TemplateItem?,
                 draftDynamicValues: Binding<[TicketSession: [String: String]]>) {
                self.session = session
                self.field = field
                self._locked = locked
                self._reorderMode = reorderMode
                self._draggedField = draggedField
                self.fontSize = fontSize
                self.selectedTemplate = selectedTemplate
                self._draftDynamicValues = draftDynamicValues
                _editingName = State(initialValue: field.name)
                _editingValue = State(initialValue: field.value)
            }
            
            var body: some View {
                if locked {
                    // 🔒 Locked mode: styled like dynamic fields (label above, value inside field look)
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(editingName.isEmpty ? "unnamed" : editingName)
                                .font(.system(size: max(fontSize - 4, 11)))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled) // ✅ Enable text selection for name

                            Text(editingValue.isEmpty ? "empty" : editingValue)
                                .font(.system(size: fontSize))
                                .foregroundStyle(editingValue.isEmpty ? .secondary : .primary)
                                .lineLimit(nil) // Allow multiple lines
                                .fixedSize(horizontal: false, vertical: true) // Auto-expand vertically
                                .textSelection(.enabled) // ✅ Enable text selection for value
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
                        .contentShape(Rectangle()) // ✅ makes the whole row tappable
                        .onTapGesture(count: 2) {
                            promptReplaceDynamicField()
                        }

                        // Reorder icon in locked mode
                        Image(systemName: reorderMode ? "line.3.horizontal" : "line.3.horizontal")
                            .font(.system(size: max(fontSize - 4, 14)))
                            .foregroundStyle(reorderMode ? .blue : .secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 0.5) {
                                // Activate reorder mode after 0.5s hold
                                withAnimation {
                                    reorderMode = true
                                }
                                LOG("Reorder mode activated", ctx: ["session": "\(session.rawValue)"])
                            }
                            .onTapGesture {
                                // Quick click in reorder mode - exit reorder mode
                                if reorderMode {
                                    withAnimation {
                                        reorderMode = false
                                    }
                                    LOG("Reorder mode deactivated", ctx: ["session": "\(session.rawValue)"])
                                }
                            }
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 20)
                    .opacity(draggedField == field.id && reorderMode ? 0.5 : 1.0)
                    .onDrag {
                        // Enable dragging when in reorder mode
                        if reorderMode {
                            draggedField = field.id
                            return NSItemProvider(object: field.id.uuidString as NSString)
                        }
                        return NSItemProvider()
                    }
                    .onDrop(of: [.text], delegate: AlternateFieldDropDelegate(
                        item: field,
                        session: session,
                        sessions: sessions,
                        draggedField: $draggedField,
                        reorderMode: reorderMode
                    ))
                } else {
                    // ✏️ Editable mode: name + value side by side
                    HStack(spacing: 6) {
                        TextField("Name", text: $editingName)
                            .font(.system(size: fontSize - 1))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                commitChanges()
                                addNewAlternateField()
                            }
                            .onChange(of: editingName) { _, newVal in
                                commitChanges(newName: newVal, newValue: editingValue)
                            }

                        TextField("Value", text: $editingValue)
                            .font(.system(size: fontSize))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                commitChanges()
                                addNewAlternateField()
                            }
                            .onChange(of: editingValue) { _, newVal in
                                commitChanges(newName: editingName, newValue: newVal)
                            }

                        // Delete/Reorder button
                        Image(systemName: reorderMode ? "line.3.horizontal" : "minus.circle")
                            .font(.system(size: max(fontSize - 4, 12)))
                            .foregroundStyle(reorderMode ? .blue : .red)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        // Track if mouse has moved during gesture
                                        if gestureStartLocation == nil {
                                            // First onChanged call - record start location
                                            gestureStartLocation = value.startLocation
                                            hasMovedDuringGesture = false

                                            // Start long press timer on mouse down
                                            longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                                                // Activate reorder mode after 0.5s hold
                                                withAnimation {
                                                    reorderMode = true
                                                }
                                                LOG("Reorder mode activated", ctx: ["session": "\(session.rawValue)"])
                                            }
                                        } else {
                                            // Check if mouse has moved significantly (more than 5 points)
                                            let distance = sqrt(
                                                pow(value.location.x - value.startLocation.x, 2) +
                                                pow(value.location.y - value.startLocation.y, 2)
                                            )
                                            if distance > 5 {
                                                hasMovedDuringGesture = true
                                            }
                                        }
                                    }
                                    .onEnded { _ in
                                        // Clean up timer
                                        if let timer = longPressTimer, timer.isValid {
                                            timer.invalidate()
                                            longPressTimer = nil

                                            // Only delete if: not in reorder mode, quick click, and hasn't moved
                                            if !reorderMode && !hasMovedDuringGesture {
                                                if let idx = sessions.sessionAlternateFields[session]?.firstIndex(where: { $0.id == field.id }) {
                                                    sessions.sessionAlternateFields[session]?.remove(at: idx)
                                                    LOG("Alternate field removed", ctx: [
                                                        "session": "\(session.rawValue)",
                                                        "id": "\(field.id)"
                                                    ])
                                                }
                                            } else if reorderMode && !hasMovedDuringGesture {
                                                // Quick click in reorder mode - exit reorder mode
                                                withAnimation {
                                                    reorderMode = false
                                                }
                                                LOG("Reorder mode deactivated", ctx: ["session": "\(session.rawValue)"])
                                            }
                                        } else {
                                            // Long press completed - timer already fired
                                            longPressTimer = nil
                                        }

                                        // Reset gesture tracking
                                        gestureStartLocation = nil
                                        hasMovedDuringGesture = false
                                    }
                            )
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 20)
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

            private func addNewAlternateField() {
                // Create a new blank alternate field
                let newField = AlternateField(name: "", value: "")

                // Add it to the session's alternate fields
                if sessions.sessionAlternateFields[session] == nil {
                    sessions.sessionAlternateFields[session] = []
                }
                sessions.sessionAlternateFields[session]?.append(newField)

                LOG("New alternate field added via Cmd+Enter", ctx: [
                    "session": "\(session.rawValue)",
                    "id": "\(newField.id)"
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
                let result = runAlertWithFix(alert)

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

        // MARK: — Alternate Field Drop Delegate
        private struct AlternateFieldDropDelegate: DropDelegate {
            let item: AlternateField
            let session: TicketSession
            let sessions: SessionManager
            @Binding var draggedField: UUID?
            let reorderMode: Bool

            func performDrop(info: DropInfo) -> Bool {
                draggedField = nil
                return true
            }

            func dropEntered(info: DropInfo) {
                guard reorderMode else { return }
                guard let draggedID = draggedField else { return }
                guard let items = sessions.sessionAlternateFields[session] else { return }
                guard let fromIndex = items.firstIndex(where: { $0.id == draggedID }) else { return }
                guard let toIndex = items.firstIndex(where: { $0.id == item.id }) else { return }

                if fromIndex != toIndex {
                    withAnimation {
                        var updatedItems = items
                        let movedItem = updatedItems.remove(at: fromIndex)
                        updatedItems.insert(movedItem, at: toIndex)
                        sessions.sessionAlternateFields[session] = updatedItems
                        LOG("Alternate field reordered", ctx: [
                            "session": "\(session.rawValue)",
                            "from": "\(fromIndex)",
                            "to": "\(toIndex)"
                        ])
                    }
                }
            }
        }

        // MARK: — Output area

        private func setActivePane(_ pane: BottomPaneContent?) {
            // Don't toggle - if pane is already active, keep it active
            let normalized = pane

            // Backup template when switching panes
            if let template = selectedTemplate, normalized != activeBottomPane {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "pane_switch")
            }

            if activeBottomPane == .savedFiles && normalized != .savedFiles {
                commitSavedFileDrafts(for: sessions.current)
            }
            if activeBottomPane == .guideNotes && normalized != .guideNotes {
                finalizeGuideNotesAutosave(for: selectedTemplate, reason: "pane-switch")
            }
            if let pane = normalized {
                switch pane {
                case .guideNotes:
                    guard let template = selectedTemplate else { return }
                    templateGuideStore.prepare(for: template)
                    guideNotesDraft = templateGuideStore.currentNotes(for: template)
                    sessionNotesMode[sessions.current] = .notes
                case .sessionNotes:
                    sessionNotesMode[sessions.current] = .notes
                case .savedFiles:
                    sessionNotesMode[sessions.current] = .savedFiles
                }
                isOutputVisible = false
            }

            activeBottomPane = normalized
        }


        private var outputView: some View {
            let guideDirty = templateGuideStore.isNotesDirty(for: selectedTemplate)
            let activeSession = sessions.current
            let totalHeight = paneRegionMinHeight + outputRegionHeight + outputRegionSpacing

            return ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: totalHeight)

                if isOutputVisible {
                    outputSQLSection
                        .frame(maxWidth: .infinity, minHeight: outputRegionHeight, alignment: .top)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(spacing: 0) {
                    if isOutputVisible {
                        Spacer().frame(height: outputRegionHeight + outputRegionSpacing)
                    }
                    if let pane = activeBottomPane {
                        bottomPaneContainer(pane: pane, guideDirty: guideDirty, activeSession: activeSession)
                            .frame(minHeight: paneRegionMinHeight, alignment: .top)
                    } else {
                        Color.clear
                            .frame(minHeight: paneRegionMinHeight, alignment: .top)
                    }
                }
                .padding(.bottom, 30)
            }
            .animation(.easeInOut(duration: 0.22), value: isOutputVisible)
        }


        private var outputSQLSection: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Output SQL")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.paneLabelColor)
                    Spacer(minLength: 16)

                    Button("Hide Output") {
                        withAnimation { isOutputVisible = false }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: fontSize - 2, weight: .semibold))
                    .foregroundStyle(.secondary)
                }

                TextEditor(text: $populatedSQL)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .frame(minHeight: bottomPaneEditorMinHeight)
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
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.grayBG.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.purple.opacity(0.18), lineWidth: 1)
                    )
            )
            .padding(.bottom, 52)
        }

        private func bottomPaneContainer(pane: BottomPaneContent, guideDirty: Bool, activeSession: TicketSession) -> some View {
            VStack(spacing: 0) {
                bottomPaneHeader(for: pane, guideDirty: guideDirty, activeSession: activeSession)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                Divider().opacity(0.15)

                bottomPaneContent(for: pane, activeSession: activeSession)
                    .padding(.top, pane == .savedFiles ? 28 : 16)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 52)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Theme.grayBG.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Theme.purple.opacity(0.22), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 4)
            .frame(minHeight: paneRegionMinHeight, alignment: .top)
        }

        private func bottomPaneHeader(for pane: BottomPaneContent, guideDirty: Bool, activeSession: TicketSession) -> some View {
            HStack(alignment: .center, spacing: 12) {
                paneTitle(for: pane)

                Button("Pop Out") {
                    triggerPopOut(for: activeSession)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .font(.system(size: fontSize - 1))
                .disabled(pane == .guideNotes && selectedTemplate == nil)

                switch pane {
                case .guideNotes:
                    MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !isPreviewMode, controller: guideNotesEditor)
                    PreviewModeToggle(isPreview: Binding(
                        get: { isPreviewMode },
                        set: { setPreviewMode($0) }
                    ))

                    InPaneSearchBar(
                        searchQuery: $guideNotesInPaneSearchQuery,
                        matchCount: guideNotesSearchMatches.count,
                        currentMatchIndex: guideNotesCurrentMatchIndex,
                        onPrevious: { navigateToGuideNotesPreviousMatch() },
                        onNext: { navigateToGuideNotesNextMatch() },
                        onEnter: { handleGuideNotesSearchEnter() },
                        onCancel: {
                            isGuideNotesSearchFocused = false
                            guideNotesInPaneSearchQuery = ""
                        },
                        fontSize: fontSize,
                        isSearchFocused: $isGuideNotesSearchFocused
                    )

                    Spacer(minLength: 12)

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
                case .sessionNotes:
                    MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !isPreviewMode, controller: sessionNotesEditor)
                    PreviewModeToggle(isPreview: Binding(
                        get: { isPreviewMode },
                        set: { setPreviewMode($0) }
                    ))

                    InPaneSearchBar(
                        searchQuery: $sessionNotesInPaneSearchQuery,
                        matchCount: sessionNotesSearchMatches.count,
                        currentMatchIndex: sessionNotesCurrentMatchIndex,
                        onPrevious: { navigateToSessionNotesPreviousMatch() },
                        onNext: { navigateToSessionNotesNextMatch() },
                        onEnter: { handleSessionNotesSearchEnter() },
                        onCancel: {
                            isSessionNotesSearchFocused = false
                            sessionNotesInPaneSearchQuery = ""
                        },
                        fontSize: fontSize,
                        isSearchFocused: $isSessionNotesSearchFocused
                    )

                    Spacer(minLength: 12)
                    if (sessionNotesDrafts[activeSession] ?? "") != (sessions.sessionNotes[activeSession] ?? "") {
                        Button("Save Notes") {
                            saveSessionNotes()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize - 1))

                        Button("Revert") {
                            revertSessionNotes()
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 1))
                    }
                case .savedFiles:
                    SessionNotesInline.SavedFilesWorkspace.Toolbar(
                        fontSize: fontSize,
                        files: savedFiles(for: activeSession),
                        selectedID: currentSavedFileSelection(for: activeSession),
                        onAdd: { addSavedFile(for: activeSession) },
                        onSelect: { setSavedFileSelection($0, for: activeSession) },
                        onOpenTree: { presentTreeView(for: $0, session: activeSession) },
                        onRename: { renameSavedFile($0, in: activeSession) },
                        onDelete: { removeSavedFile($0, in: activeSession) },
                        onReorder: { sourceIndex, destinationIndex in
                            sessions.reorderSavedFiles(from: sourceIndex, to: destinationIndex, in: activeSession)
                        },
                        onPopOut: nil,
                        onFormatTree: { formatSavedFileAsTree(for: $0, session: activeSession) },
                        onFormatLine: { formatSavedFileAsLine(for: $0, session: activeSession) },
                        onCompare: { presentGhostOverlay(for: activeSession) },
                        onCompareWith: { ghostFileId in
                            presentGhostOverlay(for: activeSession, ghostFileId: ghostFileId)
                        }
                    )
                }
            }
        }

        private func paneTitle(for pane: BottomPaneContent) -> some View {
            switch pane {
            case .guideNotes:
                return Label("Guide Notes", systemImage: "text.book.closed")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: fontSize + 2, weight: .semibold))
                    .foregroundStyle(Theme.paneLabelColor)
            case .sessionNotes:
                return Label("Session Notes", systemImage: "pencil.and.list.clipboard")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: fontSize + 2, weight: .semibold))
                    .foregroundStyle(Theme.paneLabelColor)
            case .savedFiles:
                return Label("Saved Files", systemImage: "doc.richtext")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: fontSize + 2, weight: .semibold))
                    .foregroundStyle(Theme.paneLabelColor)
            }
        }

        private var commandSidebar: some View {
            ZStack(alignment: .trailing) {
                if isSidebarVisible {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { toggleSidebar(false) }
                        .transition(.opacity)
                }

                commandSidebarContent
                    .offset(x: isSidebarVisible ? 0 : 280)
                    .padding(.top, 30)
                    .shadow(color: Color.black.opacity(0.18), radius: 18, x: -6, y: 0)
                    .allowsHitTesting(isActiveTab) // Sidebar content only interactable on active tab
            }
            .animation(.easeInOut(duration: 0.26), value: isSidebarVisible)
            .allowsHitTesting(isSidebarVisible) // Entire ZStack (including dismiss overlay) interactable when visible
        }

        private var commandSidebarContent: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    Label("Quick Controls", systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: fontSize + 2, weight: .semibold))
                        .foregroundStyle(Theme.aqua)
                    Spacer()
                    Button(action: { toggleSidebar(false) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: fontSize + 2, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Sessions")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(TicketSession.allCases, id: \.self) { session in
                        sidebarSessionButton(session)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Panes")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach([BottomPaneContent.guideNotes, .sessionNotes, .savedFiles], id: \.self) { pane in
                        sidebarPaneButton(pane)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Clipboard")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button(action: copyBlockValuesToClipboard) {
                        Label("Copy Block Values", systemImage: "doc.on.clipboard")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Theme.grayBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

                    Button(action: copyIndividualValuesToClipboard) {
                        Label("Copy All Individual", systemImage: "list.clipboard")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Theme.grayBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Sharing")
                        .font(.system(size: fontSize - 2, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Button(action: shareTicketSessionFlow) {
                        Label("Share Session", systemImage: "square.and.arrow.up")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Theme.grayBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

                    Button(action: importSharedSessionFlow) {
                        Label("Import Session", systemImage: "tray.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Theme.grayBG.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                }

                Spacer(minLength: 12)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 18)
            .frame(width: 260)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Theme.purple.opacity(0.15), lineWidth: 1)
                    )
            )
            .padding(.trailing, 12)
            .padding(.top, 48)
            .background(
                Color.clear
                    .registerShortcut(name: "Toggle Sidebar", keyLabel: "T", modifiers: [.command], scope: "Layout")
            )
        }

        private func toggleSidebar(_ desiredState: Bool? = nil) {
            withAnimation(.easeInOut(duration: 0.26)) {
                if let desiredState {
                    isSidebarVisible = desiredState
                } else {
                    isSidebarVisible.toggle()
                }
            }
        }

        private func registerWorkspaceShortcutsIfNeeded() {
            guard !workspaceShortcutsRegistered else { return }
            let registry = ShortcutRegistry.shared
            registry.register(name: "Search Queries", keyLabel: "F", modifiers: [.command], scope: "Global")
            registry.register(name: "Search Tags", keyLabel: "T", modifiers: [.command, .shift], scope: "Search")
            registry.register(name: "Search Guide Notes", keyLabel: "F", modifiers: [.command, .shift], scope: "Search")
            registry.register(name: "Show Guide Notes", keyLabel: "1", modifiers: [.command], scope: "Panes")
            registry.register(name: "Show Session Notes", keyLabel: "2", modifiers: [.command], scope: "Panes")
            registry.register(name: "Show Saved Files", keyLabel: "3", modifiers: [.command], scope: "Panes")
            registry.register(name: "Toggle Sidebar", keyLabel: "T", modifiers: [.command], scope: "Layout")
            workspaceShortcutsRegistered = true
        }

        private func handleFocusSearchShortcut() {
            guard isActiveTab else {
                LOG("Search shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }

            // Log current state
            LOG("=== Cmd+F pressed ===", ctx: [
                "isSearchFocused": "\(isSearchFocused)",
                "isGuideNotesSearchFocused": "\(isGuideNotesSearchFocused)",
                "isSessionNotesSearchFocused": "\(isSessionNotesSearchFocused)",
                "isSavedFileSearchFocused": "\(isSavedFileSearchFocused)",
                "isGuideNotesEditorFocused": "\(isGuideNotesEditorFocused)",
                "isSessionNotesEditorFocused": "\(isSessionNotesEditorFocused)",
                "isSavedFileEditorFocused": "\(isSavedFileEditorFocused)",
                "activeBottomPane": "\(String(describing: activeBottomPane))"
            ])

            // Toggle between pane search and query template search
            // Priority: if a pane search is focused, switch to query template search
            // If query template search is focused, switch to the active pane's search
            // Otherwise, focus the appropriate search based on what's focused

            // If query template search is focused, switch to active pane's search
            if isSearchFocused {
                isSearchFocused = false
                // Switch to the search of the currently active pane
                if let pane = activeBottomPane {
                    switch pane {
                    case .guideNotes:
                        isGuideNotesSearchFocused = true
                        LOG("Toggled from query template search to guide notes search", ctx: ["tabId": tabID])
                    case .sessionNotes:
                        isSessionNotesSearchFocused = true
                        LOG("Toggled from query template search to session notes search", ctx: ["tabId": tabID])
                    case .savedFiles:
                        isSavedFileSearchFocused = true
                        LOG("Toggled from query template search to saved files search", ctx: ["tabId": tabID])
                    }
                } else {
                    // No pane is active, just refocus query template search
                    isSearchFocused = true
                    LOG("Query template search refocused (no active pane)", ctx: ["tabId": tabID])
                }
                return
            }

            if isGuideNotesSearchFocused {
                // Switch from guide notes search to query template search
                isGuideNotesSearchFocused = false
                isSearchFocused = true
                LOG("Toggled from guide notes search to query template search", ctx: ["tabId": tabID])
                return
            }

            if isSessionNotesSearchFocused {
                // Switch from session notes search to query template search
                isSessionNotesSearchFocused = false
                isSearchFocused = true
                LOG("Toggled from session notes search to query template search", ctx: ["tabId": tabID])
                return
            }

            if isSavedFileSearchFocused {
                // Switch from saved file search to query template search
                isSavedFileSearchFocused = false
                isSearchFocused = true
                LOG("Toggled from saved file search to query template search", ctx: ["tabId": tabID])
                return
            }

            // If guide notes editor is actively focused, focus the guide notes search bar
            if isGuideNotesEditorFocused {
                isGuideNotesSearchFocused = true
                LOG("Guide notes search focused via keyboard shortcut", ctx: ["tabId": tabID])
                return
            }

            // If session notes editor is actively focused, focus the session notes search bar
            if isSessionNotesEditorFocused {
                isSessionNotesSearchFocused = true
                LOG("Session notes search focused via keyboard shortcut", ctx: ["tabId": tabID])
                return
            }

            // If saved file editor is actively focused, focus the saved file search bar
            if isSavedFileEditorFocused {
                isSavedFileSearchFocused = true
                LOG("Saved file search focused via keyboard shortcut", ctx: ["tabId": tabID])
                return
            }

            // Otherwise, focus the main query template search
            isSearchFocused = true
            LOG("Query template search focused via keyboard shortcut", ctx: ["tabId": tabID])
        }

        private func handleShowGuideNotesShortcut() {
            guard isActiveTab else {
                LOG("Guide notes shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            guard selectedTemplate != nil else {
                LOG("Guide notes shortcut ignored without selected template", ctx: ["tabId": tabID])
                return
            }
            // Clear all search focus states AND editor focus states when switching panes
            isGuideNotesSearchFocused = false
            isSessionNotesSearchFocused = false
            isSavedFileSearchFocused = false
            isSearchFocused = false
            isGuideNotesEditorFocused = false
            isSessionNotesEditorFocused = false
            isSavedFileEditorFocused = false
            setActivePane(.guideNotes)
            LOG("Guide notes shortcut handled", ctx: ["tabId": tabID])
        }

        private func handleShowSessionNotesShortcut() {
            guard isActiveTab else {
                LOG("Session notes shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            LOG("=== Cmd+2 pressed (before) ===", ctx: [
                "activeBottomPane": "\(String(describing: activeBottomPane))",
                "isGuideNotesSearchFocused": "\(isGuideNotesSearchFocused)",
                "isSessionNotesSearchFocused": "\(isSessionNotesSearchFocused)",
                "isGuideNotesEditorFocused": "\(isGuideNotesEditorFocused)",
                "isSessionNotesEditorFocused": "\(isSessionNotesEditorFocused)"
            ])
            // Clear all search focus states AND editor focus states when switching panes
            isGuideNotesSearchFocused = false
            isSessionNotesSearchFocused = false
            isSavedFileSearchFocused = false
            isSearchFocused = false
            isGuideNotesEditorFocused = false
            isSessionNotesEditorFocused = false
            isSavedFileEditorFocused = false
            setActivePane(.sessionNotes)
            LOG("=== Cmd+2 pressed (after) ===", ctx: [
                "activeBottomPane": "\(String(describing: activeBottomPane))",
                "isGuideNotesSearchFocused": "\(isGuideNotesSearchFocused)",
                "isSessionNotesSearchFocused": "\(isSessionNotesSearchFocused)",
                "isGuideNotesEditorFocused": "\(isGuideNotesEditorFocused)",
                "isSessionNotesEditorFocused": "\(isSessionNotesEditorFocused)"
            ])
        }

        private func handleShowSavedFilesShortcut() {
            guard isActiveTab else {
                LOG("Saved files shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            // Clear all search focus states AND editor focus states when switching panes
            isGuideNotesSearchFocused = false
            isSessionNotesSearchFocused = false
            isSavedFileSearchFocused = false
            isSearchFocused = false
            isGuideNotesEditorFocused = false
            isSessionNotesEditorFocused = false
            isSavedFileEditorFocused = false
            setActivePane(.savedFiles)
            LOG("Saved files shortcut handled", ctx: ["tabId": tabID])
        }

        private func handleToggleSidebarShortcut() {
            guard isActiveTab else {
                LOG("Sidebar shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            toggleSidebar()
            LOG("Sidebar shortcut handled", ctx: ["tabId": tabID])
        }

        private func handleSearchTagsShortcut() {
            guard isActiveTab else {
                LOG("Search tags shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            showTagSearchDialog = true
            LOG("Tag search dialog opened via keyboard shortcut", ctx: ["tabId": tabID])
        }

        private func handleSearchGuideNotesShortcut() {
            guard isActiveTab else {
                LOG("Search guide notes shortcut ignored for inactive tab", ctx: ["tabId": tabID])
                return
            }
            showGuideNotesSearchDialog = true
            LOG("Guide notes search dialog opened via keyboard shortcut", ctx: [
                "tabId": tabID,
                "availableTemplates": "\(templates.templates.count)"
            ])
        }

        private func showGuideNotesPane() {
            LOG("showGuideNotesPane called, current pane: \(String(describing: activeBottomPane))")
            setActivePane(.guideNotes)
            LOG("showGuideNotesPane completed, new pane: \(String(describing: activeBottomPane))")
        }

        private func highlightKeywordInGuideNotes(_ keyword: String) {
            guideNotesEditor.find(keyword)
        }

        private func sidebarSessionButton(_ session: TicketSession) -> some View {
            let isActive = sessions.current == session
            return Button(action: { switchToSession(session) }) {
                HStack {
                    Text(truncateSessionName(sessions.sessionNames[session] ?? "Session #\(session.rawValue)"))
                        .font(.system(size: fontSize - 1, weight: isActive ? .semibold : .regular))
                    Spacer()
                    Text("⌃\(session.rawValue)")
                        .font(.system(size: fontSize - 4, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Theme.purple.opacity(0.18) : Theme.grayBG.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
        }

        private func sidebarPaneButton(_ pane: BottomPaneContent) -> some View {
            let info = paneInfo(for: pane)
            let isActive = activeBottomPane == pane
            let isEnabled = pane != .guideNotes || selectedTemplate != nil
            return Button(action: { setActivePane(pane) }) {
                HStack {
                    Label(info.title, systemImage: info.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: fontSize - 1, weight: isActive ? .semibold : .regular))
                    Spacer()
                    Text("⌘\(info.shortcut)")
                        .font(.system(size: fontSize - 4, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Theme.purple.opacity(0.18) : Theme.grayBG.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
        }

        private func paneInfo(for pane: BottomPaneContent) -> (title: String, systemImage: String, shortcut: String) {
            switch pane {
            case .guideNotes:
                return ("Guide Notes", "text.book.closed", "1")
            case .sessionNotes:
                return ("Session Notes", "pencil.and.list.clipboard", "2")
            case .savedFiles:
                return ("Saved Files", "doc.richtext", "3")
            }
        }

        private func bottomPaneContent(for pane: BottomPaneContent, activeSession: TicketSession) -> some View {
            Group {
                switch pane {
                case .guideNotes:
                    guideNotesPane
                case .sessionNotes:
                    sessionNotesPane(for: activeSession)
                        .id("session-notes-\(activeSession.rawValue)")
                case .savedFiles:
                    savedFilesPane(for: activeSession)
                        .id("saved-files-\(activeSession.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }

        @ViewBuilder
        private var guideNotesPane: some View {
            guideNotesContent
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(minHeight: bottomPaneEditorMinHeight, alignment: .top)
                .onChange(of: guideNotesInPaneSearchQuery) { _, _ in
                    updateGuideNotesSearchMatches()
                }
                .onChange(of: guideNotesDraft) { _, _ in
                    if !guideNotesInPaneSearchQuery.isEmpty {
                        updateGuideNotesSearchMatches()
                    }
                }
                .onChange(of: selectedTemplate?.id) { _, _ in
                    // Clear search when switching templates
                    guideNotesInPaneSearchQuery = ""
                    guideNotesSearchMatches = []
                    guideNotesCurrentMatchIndex = 0
                }
        }

        @ViewBuilder
        private var guideNotesContent: some View {
            if selectedTemplate != nil {
                guideNotesEditorContent
            } else {
                guideNotesPlaceholder
            }
        }

        private var guideNotesEditorContent: some View {
            Group {
                if isPreviewMode {
                    MarkdownPreviewView(
                        text: guideNotesDraft,
                        fontSize: fontSize * 1.5,
                        onLinkOpen: { url, modifiers in
                            openLink(url, modifiers: modifiers)
                        }
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    MarkdownEditor(
                        text: Binding(
                            get: { guideNotesDraft },
                            set: { newValue in
                                guideNotesDraft = newValue
                                guard let template = selectedTemplate else { return }
                                handleGuideNotesChange(newValue,
                                                       for: template,
                                                       source: "inline-editor")
                            }
                        ),
                        fontSize: fontSize * 1.5,
                        controller: guideNotesEditor,
                        onLinkRequested: handleTroubleshootingLink(selectedText:source:completion:),
                        onImageAttachment: { info in
                            handleGuideEditorImageAttachment(info)
                        },
                        onFocusChange: { focused in
                            isGuideNotesEditorFocused = focused
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: bottomPaneEditorMinHeight, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .layoutPriority(1)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "#2A2A35"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.purple.opacity(0.18), lineWidth: 1)
                    )
            )
        }

        private var guideNotesPlaceholder: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Select a template to view its troubleshooting guide")
                    .font(.system(size: fontSize - 1))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: bottomPaneEditorMinHeight, alignment: .top)
            .layoutPriority(1)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "#2A2A35"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.purple.opacity(0.15), lineWidth: 1)
                    )
            )
        }

        private func sessionNotesPane(for activeSession: TicketSession) -> some View {
            SessionNotesInline(
                fontSize: fontSize,
                editorMinHeight: bottomPaneEditorMinHeight,
                session: activeSession,
                draft: Binding(
                    get: { sessionNotesDrafts[activeSession] ?? "" },
                    set: { newValue in
                        let session = activeSession
                        // Prevent updates when loading a ticket session
                        if isLoadingTicketSession { return }
                        // Prevent updates if this isn't the active session
                        if session != sessions.current { return }
                        if sessionNotesDrafts[session] == newValue { return }
                        LOG("Session notes binding set", ctx: [
                            "session": "\(session.rawValue)",
                            "chars": "\(newValue.count)",
                            "sample": String(newValue.prefix(80)).replacingOccurrences(of: "\n", with: "⏎"),
                            "source": "editor-inline"
                        ])
                        setSessionNotesDraft(newValue,
                                            for: session,
                                            source: "editor-inline")
                    }
                ),
                savedValue: sessions.sessionNotes[activeSession] ?? "",
                controller: sessionNotesEditor,
                isPreview: Binding(
                    get: { isPreviewMode },
                    set: { setPreviewMode($0) }
                ),
                mode: .constant(.notes),
                savedFiles: savedFiles(for: activeSession),
                selectedSavedFileID: currentSavedFileSelection(for: activeSession),
                savedFileDraft: { savedFileDraft(for: activeSession, fileId: $0) },
                savedFileValidation: { validationState(for: activeSession, fileId: $0) },
                onSavedFileSelect: { setSavedFileSelection($0, for: activeSession) },
                onSavedFileAdd: { addSavedFile(for: activeSession) },
                onSavedFileDelete: { removeSavedFile($0, in: activeSession) },
                onSavedFileRename: { renameSavedFile($0, in: activeSession) },
                onSavedFileReorder: { sourceIndex, destinationIndex in
                    sessions.reorderSavedFiles(from: sourceIndex, to: destinationIndex, in: activeSession)
                },
                onSavedFileContentChange: { fileId, newValue in
                    setSavedFileDraft(newValue,
                                     for: fileId,
                                     session: activeSession,
                                     source: "savedFile.inline")
                },
                onSavedFileFocusChanged: { focused in
                    isSavedFileEditorFocused = focused
                },
                onSavedFileOpenTree: { presentTreeView(for: $0, session: activeSession) },
                onSavedFileFormatTree: { formatSavedFileAsTree(for: $0, session: activeSession) },
                onSavedFileFormatLine: { formatSavedFileAsLine(for: $0, session: activeSession) },
                onSavedFileSearchCancel: {
                    isSavedFileSearchFocused = false
                },
                savedFileSearchFocused: $isSavedFileSearchFocused,
                onSavedFilesModeExit: { commitSavedFileDrafts(for: activeSession) },
                onSavedFilesPopout: nil,
                onSessionNotesFocusChanged: { focused in
                    isSessionNotesEditorFocused = focused
                },
                onSave: { saveSessionNotes() },
                onRevert: revertSessionNotes,
                onLinkRequested: handleSessionNotesLink(selectedText:source:completion:),
                onLinkOpen: { url, modifiers in
                    openLink(url, modifiers: modifiers)
                },
                onImageAttachment: { info in
                    handleSessionEditorImageAttachment(info)
                },
                showsModePicker: false,
                showsModeToolbar: false,
                showsOuterBackground: false,
                showsContentBackground: true
            )
            .onChange(of: sessionNotesInPaneSearchQuery) { _, _ in
                updateSessionNotesSearchMatches()
            }
            .onChange(of: sessionNotesDrafts[activeSession]) { _, _ in
                if !sessionNotesInPaneSearchQuery.isEmpty {
                    updateSessionNotesSearchMatches()
                }
            }
            .onChange(of: activeSession) { _, _ in
                // Clear search when switching sessions
                sessionNotesInPaneSearchQuery = ""
                sessionNotesSearchMatches = []
                sessionNotesCurrentMatchIndex = 0
            }
        }

        private func savedFilesPane(for activeSession: TicketSession) -> some View {
            SessionNotesInline(
                fontSize: fontSize,
                editorMinHeight: bottomPaneEditorMinHeight,
                session: activeSession,
                draft: Binding(
                    get: { sessionNotesDrafts[activeSession] ?? "" },
                    set: { newValue in
                        let session = activeSession
                        // Prevent updates when loading a ticket session
                        if isLoadingTicketSession { return }
                        // Prevent updates if this isn't the active session
                        if session != sessions.current { return }
                        if sessionNotesDrafts[session] == newValue { return }
                        setSessionNotesDraft(newValue,
                                            for: session,
                                            source: "editor-inline")
                    }
                ),
                savedValue: sessions.sessionNotes[activeSession] ?? "",
                controller: sessionNotesEditor,
                isPreview: Binding(
                    get: { isPreviewMode },
                    set: { setPreviewMode($0) }
                ),
                mode: .constant(.savedFiles),
                savedFiles: savedFiles(for: activeSession),
                selectedSavedFileID: currentSavedFileSelection(for: activeSession),
                savedFileDraft: { savedFileDraft(for: activeSession, fileId: $0) },
                savedFileValidation: { validationState(for: activeSession, fileId: $0) },
                onSavedFileSelect: { setSavedFileSelection($0, for: activeSession) },
                onSavedFileAdd: { addSavedFile(for: activeSession) },
                onSavedFileDelete: { removeSavedFile($0, in: activeSession) },
                onSavedFileRename: { renameSavedFile($0, in: activeSession) },
                onSavedFileReorder: { sourceIndex, destinationIndex in
                    sessions.reorderSavedFiles(from: sourceIndex, to: destinationIndex, in: activeSession)
                },
                onSavedFileContentChange: { fileId, newValue in
                    setSavedFileDraft(newValue,
                                     for: fileId,
                                     session: activeSession,
                                     source: "savedFile.inline")
                },
                onSavedFileFocusChanged: { focused in
                    isSavedFileEditorFocused = focused
                },
                onSavedFileOpenTree: { presentTreeView(for: $0, session: activeSession) },
                onSavedFileFormatTree: { formatSavedFileAsTree(for: $0, session: activeSession) },
                onSavedFileFormatLine: { formatSavedFileAsLine(for: $0, session: activeSession) },
                onSavedFileSearchCancel: {
                    isSavedFileSearchFocused = false
                },
                savedFileSearchFocused: $isSavedFileSearchFocused,
                onSavedFilesModeExit: { commitSavedFileDrafts(for: activeSession) },
                onSavedFilesPopout: nil,
                onSave: { saveSessionNotes() },
                onRevert: revertSessionNotes,
                onLinkRequested: handleSessionNotesLink(selectedText:source:completion:),
                onLinkOpen: { url, modifiers in
                    openLink(url, modifiers: modifiers)
                },
                onImageAttachment: { info in
                    handleSessionEditorImageAttachment(info)
                },
                showsModePicker: false,
                showsModeToolbar: false,
                showsOuterBackground: false,
                showsContentBackground: false
            )
        }

        private func triggerPopOut(for activeSession: TicketSession) {
            guard let pane = activeBottomPane else { return }
            switch pane {
            case .guideNotes:
                guard selectedTemplate != nil else { return }
                if let template = selectedTemplate {
                    templateGuideStore.prepare(for: template)
                    guideNotesDraft = templateGuideStore.currentNotes(for: template)
                }
                activePopoutPane = .guide
            case .sessionNotes:
                activePopoutPane = .session(activeSession)
            case .savedFiles:
                sessionNotesMode[activeSession] = .savedFiles
                activePopoutPane = .saved(activeSession)
            }
        }

        private func triggerSessionTemplatePopOut() {
            activePopoutPane = .sessionTemplate(sessions.current)
        }

        @ViewBuilder
        private var sessionToolbar: some View {
            Group {
                if #available(macOS 13.0, *) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 16) {
                            sessionActionButtons
                            Spacer(minLength: 12)
                            sessionButtons
                            Spacer(minLength: 12)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            sessionActionButtons
                            sessionButtons
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        sessionActionButtons
                        sessionButtons
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }

        private var sessionActionButtons: some View {
            HStack(spacing: 12) {
                Button("Populate Query") { populateQuery() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.pink)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .font(.system(size: fontSize))
                    .registerShortcut(name: "Populate Query", key: .return, modifiers: [.command], scope: "Global")

                Button(action: { attemptClearCurrentSession() }) {
                    Text("Clear Session #\(sessions.current.rawValue)")
                        .foregroundColor(Theme.clearSessionText)
                }
                .buttonStyle(.bordered)
                .tint(Theme.clearSessionTint)
                .font(.system(size: fontSize))
            }
        }

        // Session buttons with proper functionality
        private var sessionButtons: some View {
            HStack(spacing: 12) {
                // Tab buttons (only show for active tab to avoid duplicates)
                if isActiveTab && tabManager.tabs.count > 1 {
                    tabSwitcherButtons
                }

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
                        Text(truncateSessionName(sessions.sessionNames[s] ?? "#\(s.rawValue)"))
                            .font(.system(size: fontSize - 1, weight: sessions.current == s ? .semibold : .regular))
                            .frame(minWidth: 60)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(sessions.current == s ? Theme.purple : Theme.purple.opacity(0.3))
                    .contextMenu {
                        Button("Rename…") { promptRename(for: s) }
                        Button("Link to Ticket…") { promptLink(for: s) }
                        if let existing = sessions.sessionLinks[s], !existing.isEmpty {
                            Button("Clear Link") { sessions.sessionLinks.removeValue(forKey: s) }
                        }
                        Divider()
                        if sessions.current == s {
                            Button("Clear This Session") {
                                attemptClearCurrentSession()
                            }
                        } else {
                            Button("Switch to This Session") {
                                switchToSession(s)
                            }
                        }
                    }
                }
                // Invisible bridge view to receive menu notifications and register KB shortcuts for Help sheet
                Color.clear.frame(width: 0, height: 0)
                    .background(TicketSessionNotificationBridge(
                        onSave: { handleTicketSessionSaveShortcut() },
                        onLoad: { loadTicketSessionFlow() },
                        onOpen: { openSessionsFolderFlow() }
                    ))
                    .onAppear {
                        registerExitWorkflowProvider()
                    }
                    .onDisappear {
                        unregisterExitWorkflowProvider()
                    }
            }
        }

        private var tabSwitcherButtons: some View {
            HStack(spacing: 8) {
                ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, _ in
                    let baseColor = tabManager.color(for: index)
                    let isActive = tabManager.activeTabIndex == index
                    let activeTint = baseColor.opacity(0.85)
                    let inactiveTint = baseColor.opacity(0.3)
                    let borderColor = baseColor.opacity(isActive ? 0.9 : 0.45)
                    Button(action: {
                        tabManager.switchToTab(at: index)
                        LOG("Tab switch via button", ctx: ["targetIndex": "\(index)", "tabId": tabID])
                    }) {
                        Text("\(index + 1)")
                            .font(.system(size: fontSize - 2, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(.white)
                            .padding(.vertical, 6)
                            .padding(.leading, 22)
                            .padding(.trailing, 16)
                            .frame(minWidth: 48, alignment: .center)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isActive ? activeTint : inactiveTint)
                    .help("Switch to Tab \(index + 1)")
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(borderColor, lineWidth: 1.4)
                    )
                    .overlay(alignment: .trailing) {
                        Button(action: {
                            tabManager.closeTab(at: index)
                            LOG("Tab close via button", ctx: ["index": "\(index)", "tabId": tabID])
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: fontSize - 3))
                                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.75))
                                .padding(.vertical, 4)
                                .padding(.trailing, 4)
                        }
                        .buttonStyle(.plain)
                        .help("Close Tab \(index + 1)")
                    }
                }
            }
        }

        
        // Helper to copy all static, template, and alternate field values as a single block to clipboard
        private func copyBlockValuesToClipboard() {
            // Backup template before copying values
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "copy_block_values")
            }

            let export = buildCopyBlock()
            let pb = NSPasteboard.general
            pb.clearContents()
            // Add each raw value as a separate clipboard entry
            for v in export.values {
                pb.setString(v, forType: .string)
            }
            // Add the formatted block as a single clipboard entry
            pb.setString(export.block, forType: .string)
            LOG("Copied all values to clipboard", ctx: ["count": "\(export.values.count)"])
            withAnimation { toastCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation { toastCopied = false }
            }
        }

        private struct CopyBlockExport {
            let values: [String]
            let block: String
            let header: String
        }

        private func buildCopyBlock(templateOverride: TemplateItem? = nil,
                                    allowSelectedTemplateFallback: Bool = true) -> CopyBlockExport {
            var values: [String] = []
            values.append(orgId)
            values.append(acctId)
            values.append(mysqlDb)

            let sessionName = sessions.sessionNames[sessions.current] ?? "Session #\(sessions.current.rawValue)"
            let formattedSessionName = sessionName.isEmpty ? sessionName : "## \(sessionName)"

            var blockLines: [String] = []
            blockLines.append(formattedSessionName)
            if !orgId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockLines.append("**Org-ID:** `\(orgId)`")
            }
            if !acctId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockLines.append("**Acct-ID:** `\(acctId)`")
            }
            if !mysqlDb.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blockLines.append("**mysqlDb:** `\(mysqlDb)`")
            }

            let templateForBlock: TemplateItem? = {
                if let override = templateOverride {
                    return override
                }
                return allowSelectedTemplateFallback ? selectedTemplate : nil
            }()
            if let t = templateForBlock {
                let staticKeys = ["Org-ID", "Acct-ID", "mysqlDb"]
                for ph in t.placeholders where !staticKeys.contains(ph) {
                    let val = sessions.value(for: ph)
                    if !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        values.append(val)
                        blockLines.append("**\(ph):** `\(val)`")
                    }
                }
            }

            if let alternates = sessions.sessionAlternateFields[sessions.current] {
                for alt in alternates {
                    // Skip if name or value is empty
                    if alt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                       alt.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continue
                    }
                    values.append(alt.value)
                    let formattedName: String
                    if let separatorRange = alt.name.range(of: " • ") {
                        let templateName = alt.name[..<separatorRange.lowerBound]
                        let fieldName = alt.name[separatorRange.upperBound...]
                        formattedName = "*\(templateName)* • **\(fieldName):**"
                    } else {
                        formattedName = "**\(alt.name):**"
                    }
                    blockLines.append("\(formattedName) `\(alt.value)`")
                }
            }

            return CopyBlockExport(
                values: values,
                block: blockLines.joined(separator: "\n"),
                header: formattedSessionName
            )
        }

        private func shouldAutoPrependCopyBlock(for source: String) -> Bool {
            source == "loadTicketSession" || source == "importSharedSession"
        }

        private func notesWithCopyBlockPrependedIfNeeded(_ original: String,
                                                         export: CopyBlockExport,
                                                         source: String) -> String {
            guard shouldAutoPrependCopyBlock(for: source) else { return original }
            let header = export.header.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !header.isEmpty else { return original }

            let firstLine = original
                .components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Check for header 2 format (## SessionName)
            if firstLine == header {
                return original
            }

            let remainder = String(original.drop(while: { ch in
                ch == "\n" || ch == "\r" || ch == "\t" || ch == " "
            }))
            if remainder.isEmpty {
                return export.block
            }
            return export.block + "\n\n" + remainder
        }

        private func copyIndividualValuesToClipboard() {
            // Backup template before copying values
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "copy_individual_values")
            }

            var values: [String] = []

            // Always include static fields first (ensures orgId isn't dropped)
            if !orgId.isEmpty {
                values.append(orgId)
                LOG("CI: Added orgId: \(orgId)")
            }
            if !acctId.isEmpty {
                values.append(acctId)
                LOG("CI: Added acctId: \(acctId)")
            }
            if !mysqlDb.isEmpty {
                values.append(mysqlDb)
                LOG("CI: Added mysqlDb: \(mysqlDb)")
            }

            if let t = selectedTemplate {
                let staticKeys = ["Org-ID", "Acct-ID", "mysqlDb"]
                for ph in t.placeholders {
                    if staticKeys.contains(where: { $0.caseInsensitiveCompare(ph) == .orderedSame }) {
                        continue // skip duplicates
                    }
                    let val = sessions.value(for: ph)
                    if !val.isEmpty {
                        values.append(val)
                        LOG("CI: Added dynamic field '\(ph)': \(val)")
                    }
                }
            }
            // Include non-empty alternate field values for this session
            if let alternates = sessions.sessionAlternateFields[sessions.current] {
                for alt in alternates {
                    if !alt.value.isEmpty {
                        values.append(alt.value)
                        LOG("CI: Added alternate field '\(alt.name)': \(alt.value)")
                    }
                }
            }

            LOG("CI: Total values to copy: \(values.count)")

            let count = values.count
            let pb = NSPasteboard.general

            // Show warning banner
            withAnimation { showCopyWarning = true }

            for (idx, v) in values.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(idx * 800)) {
                    pb.clearContents()
                    pb.setString(v, forType: .string)
                    LOG("Copied value \(idx + 1)/\(count): \(v)")

                    // Update progress message
                    withAnimation {
                        copyProgressMessage = "Copied to clipboard: \(idx + 1) of \(count)"
                    }
                }
            }

            // Show final success message after all values are copied
            let totalDuration = count * 800
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(totalDuration + 200)) {
                withAnimation {
                    showCopyWarning = false
                    copyProgressMessage = ""
                    copySuccessMessage = "All \(count) values copied successfully"
                }

                // Clear success message after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation {
                        copySuccessMessage = ""
                    }
                }
            }

            LOG("Scheduled copy of all values individually", ctx: ["count": "\(count)"])
        }

    private struct UnsavedFlags {
        let guide: Bool
        let notes: Bool
        let sessionData: Bool
        let links: Bool
        let tables: Bool

        var session: Bool { notes || sessionData }
        var any: Bool { guide || session || links || tables }
    }

    private struct SessionSnapshot: Equatable {
        struct StaticFields: Equatable {
            var orgId: String
            var acctId: String
            var mysqlDb: String
            var company: String

            var hasContent: Bool {
                [orgId, acctId, mysqlDb, company].contains { !$0.isEmpty }
            }
        }

        struct AlternateFieldSnapshot: Equatable {
            var name: String
            var value: String

            var hasContent: Bool {
                !name.isEmpty || !value.isEmpty
            }
        }

        struct ImageSnapshot: Equatable {
            var id: UUID
            var fileName: String
        }

        struct SavedFileSnapshot: Equatable {
            var name: String
            var content: String

            var hasContent: Bool {
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }

        var staticFields: StaticFields
        var sessionName: String
        var sessionLink: String
        var alternateFields: [AlternateFieldSnapshot]
        var storedValues: [String: String]
        var dbTables: [String]
        var images: [ImageSnapshot]
        var savedFiles: [SavedFileSnapshot]

        var hasAnyContent: Bool {
            staticFields.hasContent ||
            !sessionName.isEmpty ||
            !sessionLink.isEmpty ||
            alternateFields.contains { $0.hasContent } ||
            storedValues.values.contains { !$0.isEmpty } ||
            dbTables.contains { !$0.isEmpty } ||
            !images.isEmpty ||
            savedFiles.contains { $0.hasContent }
        }
    }

    private func captureSnapshot(for session: TicketSession) -> SessionSnapshot {
        let staticTuple = sessionStaticFields[session]
            ?? (session == sessions.current ? (orgId, acctId, mysqlDb, companyLabel) : ("", "", "", ""))

        let staticFields = SessionSnapshot.StaticFields(
            orgId: staticTuple.orgId.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression),
            acctId: staticTuple.acctId.trimmingCharacters(in: .whitespacesAndNewlines),
            mysqlDb: staticTuple.mysqlDb.trimmingCharacters(in: .whitespacesAndNewlines),
            company: staticTuple.company.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let defaultName = "#\(session.rawValue)"
        let name = (sessions.sessionNames[session] ?? defaultName).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = (name == defaultName) ? "" : name
        let link = (sessions.sessionLinks[session] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let alternates = (sessions.sessionAlternateFields[session] ?? []).map { field in
            SessionSnapshot.AlternateFieldSnapshot(
                name: field.name.trimmingCharacters(in: .whitespacesAndNewlines),
                value: field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let stored = sessions.sessionValues[session]?.reduce(into: [String: String]()) { dict, entry in
            let trimmedValue = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                dict[entry.key] = trimmedValue
            }
        } ?? [:]

        let dbTables: [String]
        if session == sessions.current, let template = selectedTemplate {
            dbTables = dbTablesStore.workingSet(for: session, template: template)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            dbTables = []
        }

        let images = (sessions.sessionImages[session] ?? []).map {
            SessionSnapshot.ImageSnapshot(id: $0.id, fileName: $0.fileName)
        }

        let savedFiles = (sessions.sessionSavedFiles[session] ?? []).map { file in
            SessionSnapshot.SavedFileSnapshot(
                name: file.name,
                content: file.content
            )
        }

        return SessionSnapshot(
            staticFields: staticFields,
            sessionName: normalizedName,
            sessionLink: link,
            alternateFields: alternates,
            storedValues: stored,
            dbTables: dbTables,
            images: images,
            savedFiles: savedFiles
        )
    }

    private func updateSavedSnapshot(for session: TicketSession) {
        sessionSavedSnapshots[session] = captureSnapshot(for: session)
    }

    private func isSessionNotesDirty(session: TicketSession) -> Bool {
        (sessionNotesDrafts[session] ?? "") != (sessions.sessionNotes[session] ?? "")
    }

    private func hasSessionFieldData(for session: TicketSession) -> Bool {
        let currentSnapshot = captureSnapshot(for: session)

        if let baseline = sessionSavedSnapshots[session] {
            if currentSnapshot != baseline {
                return true
            }
        } else if currentSnapshot.hasAnyContent {
            return true
        }

        if let draftValues = draftDynamicValues[session],
           draftValues.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return true
        }

        return false
    }

        private func saveSessionNotes(reason: String = "manual") {
            saveSessionNotes(for: sessions.current, reason: reason)
        }

        private func saveSessionNotes(for session: TicketSession, reason: String) {
            sessionNotesAutosave.cancel(for: session)
            let draft = sessionNotesDrafts[session] ?? ""
            let previous = sessions.sessionNotes[session] ?? ""
            if previous == draft {
                LOG("Session notes save skipped", ctx: [
                    "session": "\(session.rawValue)",
                    "length": "\(draft.count)",
                    "reason": reason,
                    "status": "unchanged"
                ])
                return
            }
            sessions.sessionNotes[session] = draft
            let delta = draft.count - previous.count
            LOG("Session notes saved", ctx: [
                "session": "\(session.rawValue)",
                "length": "\(draft.count)",
                "delta": "\(delta)",
                "reason": reason
            ])
        }

        private func revertSessionNotes() {
            let currentSession = sessions.current
            let saved = sessions.sessionNotes[currentSession] ?? ""
            setSessionNotesDraft(saved, for: currentSession, source: "revertSessionNotes")
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

            let response = runAlertWithFix(alert)
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

            let response = runAlertWithFix(alert)
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
            if let previous = selectedTemplate, previous.id != t?.id {
                finalizeGuideNotesAutosave(for: previous, reason: "template-selection")
                flushDBTablesAutosave(for: sessions.current, template: previous)
            }

            selectedTemplate = t
            if let t = t {
                setPreviewMode(true)
                sessionSelectedTemplate[sessions.current] = t.id
                // Hydrate DB tables working set from sidecar
                _ = DBTablesStore.shared.loadSidecar(for: sessions.current, template: t)
                LOG("DBTables sidecar hydrated", ctx: ["template": t.name, "session": "\(sessions.current.rawValue)"])
                
                // Hydrate template links from sidecar
                _ = templateLinksStore.loadSidecar(for: t)
                LOG("Template links hydrated", ctx: ["template": t.name])
                templateTagsStore.ensureLoaded(t)
                templateGuideStore.prepare(for: t)
                guideNotesDraft = templateGuideStore.currentNotes(for: t)
            } else {
                if activeBottomPane == .guideNotes {
                    setActivePane(nil)
                }
                guideNotesDraft = ""
            }
        }
        
        // MARK: – Actions
        // Function to handle session switching
        private func switchToSession(_ newSession: TicketSession) {
            guard newSession != sessions.current else { return }
            finalizeGuideNotesAutosave(for: selectedTemplate, reason: "session-switch")
            let previousSession = sessions.current
            let previousDraft = sessionNotesDrafts[previousSession] ?? ""
            let previousSaved = sessions.sessionNotes[previousSession] ?? ""
            LOG("Session switch requested", ctx: [
                "from": "\(previousSession.rawValue)",
                "to": "\(newSession.rawValue)",
                "fromNotesChars": "\(previousDraft.count)",
                "fromNotesDirty": previousDraft == previousSaved ? "clean" : "dirty",
                "sample": String(previousDraft.prefix(80)).replacingOccurrences(of: "\n", with: "⏎")
            ])

            // Set flag BEFORE commitDrafts to prevent editor reads during transition
            isSwitchingSession = true

            commitDraftsForCurrentSession()

            // Save current session's static fields
            sessionStaticFields[sessions.current] = (orgId, acctId, mysqlDb, companyLabel)

            // Backup template before switching sessions
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "session_switch")
            }

            // Switch to new session
            sessions.setCurrent(newSession)

            // Initialize draft from saved value if draft doesn't exist
            let incomingSaved = sessions.sessionNotes[newSession] ?? ""
            if sessionNotesDrafts[newSession] == nil {
                sessionNotesDrafts[newSession] = incomingSaved
            }
            let incomingDraft = sessionNotesDrafts[newSession] ?? ""

            LOG("Session switch applied", ctx: [
                "from": "\(previousSession.rawValue)",
                "to": "\(newSession.rawValue)",
                "toNotesChars": "\(incomingDraft.count)",
                "toNotesDirty": incomingDraft == incomingSaved ? "clean" : "dirty",
                "sample": String(incomingDraft.prefix(80)).replacingOccurrences(of: "\n", with: "⏎")
            ])
            ensureSavedFileState(for: newSession)

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
                templateTagsStore.ensureLoaded(found)
                templateGuideStore.prepare(for: found)
                guideNotesDraft = templateGuideStore.currentNotes(for: found)
            } else {
                selectedTemplate = nil
                if activeBottomPane == .guideNotes {
                    setActivePane(nil)
                }
                guideNotesDraft = ""
            }
            
            setPaneLockState(true, source: "sessionSwitch")
            LOG("Session switched", ctx: ["from": "\(previousSession.rawValue)", "to": "\(newSession.rawValue)"])

            if activeBottomPane == .savedFiles {
                sessionNotesMode[newSession] = .savedFiles
            } else {
                sessionNotesMode[newSession] = .notes
            }

            // Clear flag after SwiftUI updates complete
            // Use asyncAfter to ensure views have fully rendered
            // 250ms delay ensures view hierarchy is fully rebuilt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.isSwitchingSession = false
            }
        }

        private func togglePreviewShortcut() {
            setPreviewMode(!isPreviewMode)
            setPaneLockState(!dbTablesLocked, source: "cmd+e")
            LOG("Cmd+E toggled preview + locks", ctx: [
                "preview": isPreviewMode ? "preview" : "edit",
                "locked": dbTablesLocked ? "1" : "0"
            ])
        }

        private func loadTemplate(_ t: TemplateItem) {
            commitDraftsForCurrentSession()
            if let previous = selectedTemplate, previous.id != t.id {
                finalizeGuideNotesAutosave(for: previous, reason: "template-load")

                // Backup previous template when switching to a new one
                flushDBTablesAutosave(for: sessions.current, template: previous)
                templates.backupTemplateIfNeeded(previous, reason: "template_switch")
            }
            selectedTemplate = t
            currentSQL = t.rawSQL
            setPreviewMode(true)
            // Remember the template per session
            sessionSelectedTemplate[sessions.current] = t.id
            LOG("Template loaded", ctx: ["template": t.name, "phCount":"\(t.placeholders.count)"])
            // NEW: hydrate working set from sidecar for the current session
            _ = DBTablesStore.shared.loadSidecar(for: sessions.current, template: t)
            LOG("DBTables sidecar hydrated", ctx: ["template": t.name, "session": "\(sessions.current.rawValue)"])
            // Hydrate template links from sidecar
            _ = templateLinksStore.loadSidecar(for: t)
            LOG("Template links hydrated", ctx: ["template": t.name])
            templateTagsStore.ensureLoaded(t)
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
            let url = template.url
            do {
                // Save new contents
                try newText.data(using: .utf8)?.write(to: url, options: .atomic)
                LOG("Template saved", ctx: ["template": template.name, "bytes": "\(newText.utf8.count)"])

                // Reload templates so UI reflects latest
                templates.loadTemplates()

                // Notify tab manager that templates were reloaded
                tabManager.notifyTemplateReload()
                if let context = tabContext {
                    context.markTemplateReloadSeen()
                }

                // STREAMLINED WORKFLOW: Auto re-select the saved template and populate query
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

        private func setPreviewMode(_ preview: Bool) {
            // Save scroll position when leaving edit mode
            if isPreviewMode != preview && isPreviewMode == false {
                if activeBottomPane == .guideNotes {
                    savedScrollPosition = guideNotesEditor.getScrollPosition()
                } else {
                    savedScrollPosition = sessionNotesEditor.getScrollPosition()
                }
            }

            isPreviewMode = preview

            // Restore scroll position when entering edit mode
            if !preview {
                if activeBottomPane == .guideNotes {
                    DispatchQueue.main.async {
                        guideNotesEditor.focus()
                        guideNotesEditor.setScrollPosition(savedScrollPosition)
                    }
                } else {
                    DispatchQueue.main.async {
                        sessionNotesEditor.focus()
                        sessionNotesEditor.setScrollPosition(savedScrollPosition)
                    }
                }
            }
        }

        private func setPaneLockState(_ locked: Bool, source: String = "manual") {
            dbTablesLocked = locked
            alternateFieldsLocked = locked
            LOG("Pane lock state updated", ctx: [
                "state": locked ? "locked" : "unlocked",
                "source": source
            ])
        }

#if canImport(AppKit)
        private func configureTooltipDelay(_ delay: TimeInterval) {
            let manager = NSHelpManager.shared
            if manager.responds(to: NSSelectorFromString("setToolTipDelay:")) {
                manager.setValue(delay, forKey: "toolTipDelay")
            }
        }
#endif
        
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

            // Backup template before populating query
            flushDBTablesAutosave(for: sessions.current, template: t)
            templates.backupTemplateIfNeeded(t, reason: "populate_query")

            setActivePane(nil)
            isOutputVisible = true
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

        if runAlertWithFix(alert) == .alertFirstButtonReturn {
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
            let result = runAlertWithFix(alert)
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
            let result = runAlertWithFix(alert)
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
            struct SavedFile: Codable {
                let id: UUID
                let name: String
                let content: String
                let format: SavedFileFormat
                let createdAt: Date?
                let updatedAt: Date?

                init(id: UUID = UUID(), name: String, content: String, format: SavedFileFormat = .json, createdAt: Date? = nil, updatedAt: Date? = nil) {
                    self.id = id
                    self.name = name
                    self.content = content
                    self.format = format
                    self.createdAt = createdAt
                    self.updatedAt = updatedAt
                }

                private enum CodingKeys: String, CodingKey {
                    case id
                    case name
                    case content
                    case format
                    case createdAt
                    case updatedAt
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
                    self.name = try container.decode(String.self, forKey: .name)
                    self.content = try container.decode(String.self, forKey: .content)
                    // Default to .json for backward compatibility with old saved sessions
                    self.format = try container.decodeIfPresent(SavedFileFormat.self, forKey: .format) ?? .json
                    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
                    self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
                }
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
            let alternateFields: [SavedAlternateField]
            let sessionImages: [SessionImage]
            let savedFiles: [SavedFile]
            let usedTemplates: [UsedTemplate]

            private enum CodingKeys: String, CodingKey {
                case version
                case sessionName
                case sessionLink
                case templateId
                case templateName
                case staticFields
                case placeholders
                case dbTables
                case notes
                case alternateFields
                case sessionImages
                case savedFiles
                case usedTemplates
            }

            init(version: Int,
                 sessionName: String,
                 sessionLink: String?,
                 templateId: String?,
                 templateName: String?,
                 staticFields: StaticFields,
                 placeholders: [String : String],
                 dbTables: [String],
                 notes: String,
                 alternateFields: [SavedAlternateField],
                 sessionImages: [SessionImage],
                 savedFiles: [SavedFile],
                 usedTemplates: [UsedTemplate]) {
                self.version = version
                self.sessionName = sessionName
                self.sessionLink = sessionLink
                self.templateId = templateId
                self.templateName = templateName
                self.staticFields = staticFields
                self.placeholders = placeholders
                self.dbTables = dbTables
                self.notes = notes
                self.alternateFields = alternateFields
                self.sessionImages = sessionImages
                self.savedFiles = savedFiles
                self.usedTemplates = usedTemplates
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
                self.sessionName = try container.decode(String.self, forKey: .sessionName)
                self.sessionLink = try container.decodeIfPresent(String.self, forKey: .sessionLink)
                self.templateId = try container.decodeIfPresent(String.self, forKey: .templateId)
                self.templateName = try container.decodeIfPresent(String.self, forKey: .templateName)
                self.staticFields = try container.decode(StaticFields.self, forKey: .staticFields)
                self.placeholders = try container.decode([String:String].self, forKey: .placeholders)
                self.dbTables = try container.decode([String].self, forKey: .dbTables)
                self.notes = try container.decode(String.self, forKey: .notes)
                if let arrayFields = try? container.decode([SavedAlternateField].self, forKey: .alternateFields) {
                    self.alternateFields = arrayFields
                } else if let dictFields = try? container.decode([String:String].self, forKey: .alternateFields) {
                    self.alternateFields = dictFields
                        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                        .map { key, value in
                            SavedAlternateField(id: UUID(), name: key, value: value)
                        }
                } else {
                    self.alternateFields = []
                }
                self.sessionImages = try container.decodeIfPresent([SessionImage].self, forKey: .sessionImages) ?? []
                self.savedFiles = try container.decodeIfPresent([SavedFile].self, forKey: .savedFiles) ?? []
                self.usedTemplates = try container.decodeIfPresent([UsedTemplate].self, forKey: .usedTemplates) ?? []
            }

            struct UsedTemplate: Codable {
                let templateId: String
                let templateName: String?
                let placeholders: [String:String]
                let lastUpdated: Date?
                let alternateFields: [SavedAlternateField]

                init(templateId: String,
                     templateName: String?,
                     placeholders: [String:String],
                     lastUpdated: Date?,
                     alternateFields: [SavedAlternateField]) {
                    self.templateId = templateId
                    self.templateName = templateName
                    self.placeholders = placeholders
                    self.lastUpdated = lastUpdated
                    self.alternateFields = alternateFields
                }

                private enum CodingKeys: String, CodingKey {
                    case templateId
                    case templateName
                    case placeholders
                    case lastUpdated
                    case alternateFields
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    self.templateId = try container.decode(String.self, forKey: .templateId)
                    self.templateName = try container.decodeIfPresent(String.self, forKey: .templateName)
                    self.placeholders = try container.decodeIfPresent([String:String].self, forKey: .placeholders) ?? [:]
                    self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
                    self.alternateFields = try container.decodeIfPresent([SavedAlternateField].self, forKey: .alternateFields) ?? []
                }

                func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    try container.encode(templateId, forKey: .templateId)
                    try container.encodeIfPresent(templateName, forKey: .templateName)
                    try container.encode(placeholders, forKey: .placeholders)
                    try container.encodeIfPresent(lastUpdated, forKey: .lastUpdated)
                    if !alternateFields.isEmpty {
                        try container.encode(alternateFields, forKey: .alternateFields)
                    }
                }
            }

            struct SavedAlternateField: Codable {
                let id: UUID
                let name: String
                let value: String
            }
        }

        private struct SessionShareManifest: Codable {
            struct TemplateDescriptor: Codable {
                let order: Int
                let originalId: String
                let name: String
                let folder: String
            }

            let version: Int
            let exportedAt: Date
            let sessionName: String
            let templateIncluded: Bool
            let templateFileName: String?
            let templateDisplayName: String?
            let templateId: String?
            let templates: [TemplateDescriptor]

            init(version: Int = 1,
                 exportedAt: Date = Date(),
                 sessionName: String,
                 templateIncluded: Bool,
                 templateFileName: String?,
                 templateDisplayName: String?,
                 templateId: String?,
                 templates: [TemplateDescriptor]) {
                self.version = version
                self.exportedAt = exportedAt
                self.sessionName = sessionName
                self.templateIncluded = templateIncluded
                self.templateFileName = templateFileName
                self.templateDisplayName = templateDisplayName
                self.templateId = templateId
                self.templates = templates
            }

            private enum CodingKeys: String, CodingKey {
                case version
                case exportedAt
                case sessionName
                case templateIncluded
                case templateFileName
                case templateDisplayName
                case templateId
                case templates
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
                self.exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
                self.sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? "Shared Session"
                self.templateIncluded = try container.decodeIfPresent(Bool.self, forKey: .templateIncluded) ?? false
                self.templateFileName = try container.decodeIfPresent(String.self, forKey: .templateFileName)
                self.templateDisplayName = try container.decodeIfPresent(String.self, forKey: .templateDisplayName)
                self.templateId = try container.decodeIfPresent(String.self, forKey: .templateId)
                self.templates = try container.decodeIfPresent([TemplateDescriptor].self, forKey: .templates) ?? []
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(version, forKey: .version)
                try container.encode(exportedAt, forKey: .exportedAt)
                try container.encode(sessionName, forKey: .sessionName)
                try container.encode(templateIncluded, forKey: .templateIncluded)
                try container.encodeIfPresent(templateFileName, forKey: .templateFileName)
                try container.encodeIfPresent(templateDisplayName, forKey: .templateDisplayName)
                try container.encodeIfPresent(templateId, forKey: .templateId)
                if !templates.isEmpty {
                    try container.encode(templates, forKey: .templates)
                }
            }
        }

        private func buildSessionSnapshot(for session: TicketSession,
                                          template: TemplateItem?) -> SavedTicketSession {
            let staticData = sessionStaticFields[session] ?? (orgId, acctId, mysqlDb, companyLabel)
            let sFields = SavedTicketSession.StaticFields(
                orgId: staticData.orgId,
                acctId: staticData.acctId,
                mysqlDb: staticData.mysqlDb,
                companyLabel: staticData.company
            )

            var placeholders: [String:String] = [:]
            if let template {
                for placeholder in template.placeholders {
                    placeholders[placeholder] = sessions.value(for: placeholder)
                }
            }

            let dbTablesSnapshot: [String] = {
                if let template {
                    return dbTablesStore.workingSet(for: session, template: template)
                }
                return []
            }()

            let savedFilesSnapshot = (sessions.sessionSavedFiles[session] ?? []).map { file in
                SavedTicketSession.SavedFile(
                    id: file.id,
                    name: file.name,
                    content: file.content,
                    format: file.format,
                    createdAt: file.createdAt,
                    updatedAt: file.updatedAt
                )
            }

            let usedRecords = UsedTemplatesStore.shared.records(for: session)
            let usedTemplateSnapshots = usedRecords.map { record in
                let name = templates.templates.first(where: { $0.id == record.templateId })?.name
                let alternateFields = record.values.compactMap { key, value -> SavedTicketSession.SavedAlternateField? in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    let templateLabel = name ?? "Template"
                    return SavedTicketSession.SavedAlternateField(
                        id: UUID(),
                        name: "\(templateLabel) • \(key)",
                        value: trimmed
                    )
                }
                return SavedTicketSession.UsedTemplate(
                    templateId: record.templateId.uuidString,
                    templateName: name,
                    placeholders: record.values,
                    lastUpdated: record.lastUpdated,
                    alternateFields: alternateFields
                )
            }

            let combinedAlternateFields = buildCombinedAlternateFields(
                base: sessions.sessionAlternateFields[session] ?? [],
                usedTemplates: usedTemplateSnapshots
            )
            let limitedCombinedFields = Array(combinedAlternateFields.prefix(200))
            let limitedSavedAlternateFields = limitedCombinedFields.map { field in
                SavedTicketSession.SavedAlternateField(id: field.id, name: field.name, value: field.value)
            }

            return SavedTicketSession(
                version: 3,
                sessionName: sessions.sessionNames[session] ?? "#\(session.rawValue)",
                sessionLink: sessions.sessionLinks[session],
                templateId: template.map { "\($0.id)" },
                templateName: template?.name,
                staticFields: sFields,
                placeholders: placeholders,
                dbTables: dbTablesSnapshot,
                notes: sessions.sessionNotes[session] ?? "",
                alternateFields: limitedSavedAlternateFields,
                sessionImages: sessions.sessionImages[session] ?? [],
                savedFiles: savedFilesSnapshot,
                usedTemplates: usedTemplateSnapshots
            )
        }

        private func persistSnapshot(_ snapshot: SavedTicketSession, to url: URL) throws {
            let encoder = JSONEncoder()
            if #available(macOS 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        }

        private func applySessionSnapshot(_ snapshot: SavedTicketSession,
                                          inferredName: String,
                                          matchedTemplate: TemplateItem?,
                                          source: String) {
            sessions.renameCurrent(to: inferredName)

            if let link = snapshot.sessionLink?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
                sessions.sessionLinks[sessions.current] = link
            } else {
                sessions.sessionLinks.removeValue(forKey: sessions.current)
            }

            orgId = snapshot.staticFields.orgId
            acctId = snapshot.staticFields.acctId
            mysqlDb = snapshot.staticFields.mysqlDb
            companyLabel = snapshot.staticFields.companyLabel
            sessionStaticFields[sessions.current] = (orgId, acctId, mysqlDb, companyLabel)

            for (placeholder, value) in snapshot.placeholders {
                sessions.setValue(value, for: placeholder)
            }
            draftDynamicValues[sessions.current] = [:]

            UsedTemplatesStore.shared.clearSession(sessions.current)

            var resolvedTemplate: TemplateItem? = matchedTemplate
            if resolvedTemplate == nil, let templateId = snapshot.templateId {
                resolvedTemplate = templates.templates.first(where: { "\($0.id)" == templateId })
            }
            if resolvedTemplate == nil, let name = snapshot.templateName {
                resolvedTemplate = templates.templates.first(where: { $0.name == name })
            }

            func locateTemplate(idString: String?, name: String?) -> TemplateItem? {
                if let idString,
                   let uuid = UUID(uuidString: idString),
                   let match = templates.templates.first(where: { $0.id == uuid }) {
                    return match
                }
                if let name,
                   let match = templates.templates.first(where: { $0.name == name }) {
                    return match
                }
                return nil
            }

            if !snapshot.usedTemplates.isEmpty {
                for entry in snapshot.usedTemplates {
                    let template = locateTemplate(idString: entry.templateId, name: entry.templateName)
                        ?? resolvedTemplate
                    guard let template else { continue }
                    UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: template.id)
                    if !entry.placeholders.isEmpty {
                        UsedTemplatesStore.shared.setAllValues(
                            entry.placeholders,
                            session: sessions.current,
                            templateId: template.id
                        )
                    }
                    LOG("Used template restored", ctx: [
                        "template": template.name,
                        "placeholders": "\(entry.placeholders.count)"
                    ])
                }
            }

            if let template = resolvedTemplate,
               !UsedTemplatesStore.shared.isTemplateUsed(in: sessions.current, templateId: template.id) {
                let hasValues = snapshot.placeholders.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if hasValues {
                    UsedTemplatesStore.shared.markTemplateUsed(session: sessions.current, templateId: template.id)
                    UsedTemplatesStore.shared.setAllValues(
                        snapshot.placeholders,
                        session: sessions.current,
                        templateId: template.id
                    )
                    LOG("UsedTemplates rehydrated from snapshot",
                        ctx: ["template": template.name, "count": "\(snapshot.placeholders.count)"])
                }
            }

            isLoadingTicketSession = true

            let baseAlternateFields = snapshot.alternateFields.map { savedField -> AlternateField in
                var field = AlternateField(name: savedField.name, value: savedField.value)
                field.id = savedField.id
                return field
            }
            let combinedAlternateFields = buildCombinedAlternateFields(
                base: baseAlternateFields,
                usedTemplates: snapshot.usedTemplates
            )
            sessions.sessionAlternateFields[sessions.current] = Array(combinedAlternateFields.prefix(200))

            let copyBlockExport = buildCopyBlock(templateOverride: resolvedTemplate,
                                                 allowSelectedTemplateFallback: false)
            let preparedNotes = notesWithCopyBlockPrependedIfNeeded(snapshot.notes,
                                                                    export: copyBlockExport,
                                                                    source: source)
            sessions.sessionNotes[sessions.current] = preparedNotes
            setSessionNotesDraft(preparedNotes,
                                 for: sessions.current,
                                 source: source)

            sessions.sessionImages[sessions.current] = snapshot.sessionImages

            let restoredFiles = snapshot.savedFiles.map { item in
                SessionSavedFile(
                    id: item.id,
                    name: item.name,
                    content: item.content,
                    format: item.format,
                    createdAt: item.createdAt ?? Date(),
                    updatedAt: item.updatedAt ?? Date()
                )
            }
            sessions.setSavedFiles(restoredFiles, for: sessions.current)
            ensureSavedFileState(for: sessions.current)

            if let template = resolvedTemplate {
                loadTemplate(template)
                if !snapshot.dbTables.isEmpty {
                    dbTablesStore.setWorkingSet(snapshot.dbTables,
                                                for: sessions.current,
                                                template: template,
                                                markDirty: false)
                }
            } else {
                LOG("Session template not found; restored values only",
                    ctx: ["templateName": snapshot.templateName ?? "?" ])
            }

            populateQuery()
            updateSavedSnapshot(for: sessions.current)
            isLoadingTicketSession = false
        }

        private func exportSavedFiles(from snapshot: SavedTicketSession, to directory: URL) throws {
            guard !snapshot.savedFiles.isEmpty else { return }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in snapshot.savedFiles {
                let base = sanitizeFileName(file.name)
                var target = directory.appendingPathComponent(base)
                let expectedExtension = file.format.fileExtension
                if target.pathExtension.lowercased() != expectedExtension {
                    target = target.appendingPathExtension(expectedExtension)
                }
                try file.content.write(to: target, atomically: true, encoding: .utf8)
            }
        }

        private func exportSessionImages(from snapshot: SavedTicketSession, to directory: URL) throws {
            guard !snapshot.sessionImages.isEmpty else { return }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for image in snapshot.sessionImages {
                let source = AppPaths.sessionImages.appendingPathComponent(image.fileName)
                guard fm.fileExists(atPath: source.path) else {
                    LOG("Share session missing image file", ctx: ["file": image.fileName])
                    continue
                }
                let destination = directory.appendingPathComponent(image.fileName)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
            }
        }

        private func exportTemplateAssets(_ template: TemplateItem, to folder: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)

            TemplateGuideStore.shared.prepare(for: template)
            _ = TemplateLinksStore.shared.saveSidecar(for: template)
            _ = TemplateTagsStore.shared.saveSidecar(for: template)
            if TemplateGuideStore.shared.isNotesDirty(for: template) {
                _ = TemplateGuideStore.shared.saveNotes(for: template)
            }

            let sqlDestination = folder.appendingPathComponent("template.sql")
            try template.rawSQL.write(to: sqlDestination, atomically: true, encoding: .utf8)

            let sidecarPairs: [(URL, String, String)] = [
                (template.url.templateLinksSidecarURL(), "links", "links.json"),
                (template.url.templateTablesSidecarURL(), "tables", "tables.json"),
                (template.url.templateTagsSidecarURL(), "tags", "tags.json")
            ]
            for (source, kind, targetName) in sidecarPairs {
                guard fm.fileExists(atPath: source.path) else { continue }
                let data = try Data(contentsOf: source)
                try data.write(to: folder.appendingPathComponent(targetName), options: .atomic)
                LOG("Template sidecar bundled", ctx: ["file": targetName, "kind": kind])
            }

            let templateBase = template.url.deletingPathExtension().lastPathComponent
            let guideSource = AppPaths.templateGuides.appendingPathComponent(templateBase, isDirectory: true)
            if fm.fileExists(atPath: guideSource.path) {
                let guideDestination = folder.appendingPathComponent("guide", isDirectory: true)
                if fm.fileExists(atPath: guideDestination.path) {
                    try fm.removeItem(at: guideDestination)
                }
                try fm.copyItem(at: guideSource, to: guideDestination)
                LOG("Template guide bundled", ctx: ["template": template.name])
            }
        }

        private func templatesForSharing(snapshot: SavedTicketSession,
                                          primaryTemplate: TemplateItem?) -> [TemplateItem] {
            var ordered: [TemplateItem] = []
            var seen: Set<UUID> = []

            func append(_ template: TemplateItem) {
                if seen.insert(template.id).inserted {
                    ordered.append(template)
                }
            }

            if let primaryTemplate {
                append(primaryTemplate)
            }

            if let templateId = snapshot.templateId,
               let uuid = UUID(uuidString: templateId),
               let template = templates.templates.first(where: { $0.id == uuid }) {
                append(template)
            }

            let records = UsedTemplatesStore.shared
                .records(for: sessions.current)
                .sorted(by: { $0.lastUpdated < $1.lastUpdated })

            for record in records {
                if let template = templates.templates.first(where: { $0.id == record.templateId }) {
                    append(template)
                }
            }

            if ordered.isEmpty,
               let templateId = snapshot.templateId,
               let uuid = UUID(uuidString: templateId),
               let template = templates.templates.first(where: { $0.id == uuid }) {
                append(template)
            }

            return ordered
        }

        private struct SharedGuideNotesModel: Codable {
            var templateId: UUID?
            var text: String
            var updatedAt: String?
        }

        private struct SharedGuideImagesManifest: Codable {
            var templateId: UUID?
            var images: [TemplateGuideImage]
            var updatedAt: String?
        }

        private struct SharedGuideImagePayload {
            let url: URL
            let meta: TemplateGuideImage
        }

        private struct SharedTemplatePayload {
            let descriptor: SessionShareManifest.TemplateDescriptor
            let sql: String
            let guideNotes: String
            let links: [TemplateLink]
            let tags: [String]
            let tables: [String]
            let guideImages: [SharedGuideImagePayload]
        }

        private func writeShareManifest(_ manifest: SessionShareManifest, to url: URL) throws {
            let encoder = JSONEncoder()
            if #available(macOS 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        }

        private func zipFolder(at source: URL, to destination: URL) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["zip", "-r", destination.path, "."]
            process.currentDirectoryURL = source
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "zip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "zip failed with status \(process.terminationStatus)"])
            }
        }

        private func unzipArchive(_ archive: URL, to destination: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["unzip", "-q", archive.path, "-d", destination.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw NSError(domain: "unzip", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "unzip failed with status \(process.terminationStatus)"])
            }
        }

        private func iso8601String(_ date: Date = Date()) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        private func rewriteLinksSidecar(from source: URL, to destination: URL, templateId: UUID) throws {
            let decoder = JSONDecoder()
            var model = try decoder.decode(TemplateLinks.self, from: Data(contentsOf: source))
            model.templateId = templateId
            model.updatedAt = iso8601String()
            let encoder = JSONEncoder()
            if #available(macOS 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
            let data = try encoder.encode(model)
            try data.write(to: destination, options: .atomic)
        }

        private func rewriteTablesSidecar(from source: URL, to destination: URL, templateId: UUID) throws {
            let decoder = JSONDecoder()
            var model = try decoder.decode(TemplateTables.self, from: Data(contentsOf: source))
            model.templateId = templateId
            model.updatedAt = iso8601String()
            let encoder = JSONEncoder()
            if #available(macOS 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
            let data = try encoder.encode(model)
            try data.write(to: destination, options: .atomic)
        }

        private func rewriteTagsSidecar(from source: URL, to destination: URL, templateId: UUID) throws {
            let decoder = JSONDecoder()
            var model = try decoder.decode(TemplateTags.self, from: Data(contentsOf: source))
            model.templateId = templateId
            model.updatedAt = iso8601String()
            let encoder = JSONEncoder()
            if #available(macOS 10.13, *) {
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            } else {
                encoder.outputFormatting = [.prettyPrinted]
            }
            let data = try encoder.encode(model)
            try data.write(to: destination, options: .atomic)
        }

        private func rewriteGuideManifest(at url: URL, templateId: UUID) {
            guard let data = try? Data(contentsOf: url),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            object["templateId"] = templateId.uuidString
            object["updatedAt"] = iso8601String()
            if let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                try? rewritten.write(to: url, options: .atomic)
            }
        }

        private func rewriteGuideImagesManifest(at url: URL, templateId: UUID) {
            guard let data = try? Data(contentsOf: url),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            object["templateId"] = templateId.uuidString
            object["updatedAt"] = iso8601String()
            if var images = object["images"] as? [[String: Any]] {
                for idx in images.indices {
                    images[idx]["id"] = UUID().uuidString
                }
                object["images"] = images
            }
            if let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                try? rewritten.write(to: url, options: .atomic)
            }
        }

        private func importSessionImage(from source: URL,
                                         original: SessionImage,
                                         nextIndex: inout Int) throws -> SessionImage {
            let fm = FileManager.default
            try fm.createDirectory(at: AppPaths.sessionImages, withIntermediateDirectories: true)
            let prefix = "Session\(sessions.current.rawValue)"
            while true {
                nextIndex += 1
                let candidate = String(format: "%@_%03d.png", prefix, nextIndex)
                let destination = AppPaths.sessionImages.appendingPathComponent(candidate)
                if fm.fileExists(atPath: destination.path) {
                    continue
                }
                try fm.copyItem(at: source, to: destination)
                return SessionImage(
                    fileName: candidate,
                    originalPath: original.originalPath,
                    savedAt: original.savedAt,
                    customName: original.customName
                )
            }
        }

        private func sanitizeFileName(_ name: String) -> String {
            let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            return name.components(separatedBy: invalid).joined(separator: "_")
        }
        
        @discardableResult
        private func saveTicketSessionFlow() -> Bool {
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
            )?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { return false }
            
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
                guard overwrite.runModal() == .alertFirstButtonReturn else { return false }
            }
            
            let previousName = sessions.sessionNames[sessions.current]
            sessions.renameCurrent(to: rawName)

            let snapshot = buildSessionSnapshot(for: sessions.current, template: selectedTemplate)

            do {
                try persistSnapshot(snapshot, to: url)
                LOG("Ticket session saved", ctx: ["file": url.lastPathComponent])
                updateSavedSnapshot(for: sessions.current)
                return true
            } catch {
                if let previousName {
                    sessions.renameCurrent(to: previousName)
                } else {
                    sessions.renameCurrent(to: "#\(sessions.current.rawValue)")
                }
                NSSound.beep()
                showAlert(title: "Save Failed", message: error.localizedDescription)
                LOG("Ticket session save failed", ctx: ["error": error.localizedDescription])
                return false
            }
        }

        private func shareTicketSessionFlow() {
            let snapshot = buildSessionSnapshot(for: sessions.current, template: selectedTemplate)

            let templateCandidate: TemplateItem? = {
                if let current = selectedTemplate {
                    return current
                }
                if let templateId = snapshot.templateId,
                   let match = templates.templates.first(where: { "\($0.id)" == templateId }) {
                    return match
                }
                if let name = snapshot.templateName,
                   let match = templates.templates.first(where: { $0.name == name }) {
                    return match
                }
                return nil
            }()

            let sanitizedName = sanitizeFileName(snapshot.sessionName.isEmpty ? "Session-\(sessions.current.rawValue)" : snapshot.sessionName)

            let panel = NSSavePanel()
            panel.title = "Share Ticket Session"
            panel.prompt = "Save"
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "SharedSession-\(sanitizedName.isEmpty ? "Ticket" : sanitizedName).zip"
            panel.allowedContentTypes = [UTType.zip]
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

            guard panel.runModal() == .OK, let destination = panel.url else { return }

            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroShare-\(UUID().uuidString)", isDirectory: true)

            do {
                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempRoot) }

                try persistSnapshot(snapshot, to: tempRoot.appendingPathComponent("session.json"))

                let templatesToShare = templatesForSharing(snapshot: snapshot,
                                                            primaryTemplate: templateCandidate)
                var templateDescriptors: [SessionShareManifest.TemplateDescriptor] = []
                if !templatesToShare.isEmpty {
                    let templatesRoot = tempRoot.appendingPathComponent("templates", isDirectory: true)
                    try fm.createDirectory(at: templatesRoot, withIntermediateDirectories: true)
                    for (index, template) in templatesToShare.enumerated() {
                        let folderName = String(format: "template_%03d", index + 1)
                        let folderURL = templatesRoot.appendingPathComponent(folderName, isDirectory: true)
                        try exportTemplateAssets(template, to: folderURL)
                        templateDescriptors.append(
                            SessionShareManifest.TemplateDescriptor(
                                order: index,
                                originalId: template.id.uuidString,
                                name: template.name,
                                folder: "templates/\(folderName)"
                            )
                        )
                    }
                }

                let manifest = SessionShareManifest(
                    sessionName: snapshot.sessionName,
                    templateIncluded: !templatesToShare.isEmpty,
                    templateFileName: templateCandidate?.url.lastPathComponent,
                    templateDisplayName: templateCandidate?.name,
                    templateId: templateCandidate.map { "\($0.id)" },
                    templates: templateDescriptors
                )
                try writeShareManifest(manifest, to: tempRoot.appendingPathComponent("metadata.json"))

                try exportSavedFiles(from: snapshot, to: tempRoot.appendingPathComponent("saved-files", isDirectory: true))
                try exportSessionImages(from: snapshot, to: tempRoot.appendingPathComponent("session-images", isDirectory: true))

                try zipFolder(at: tempRoot, to: destination)
                LOG("Ticket session share archive created", ctx: ["zip": destination.lastPathComponent])
            } catch {
                NSSound.beep()
                showAlert(title: "Share Failed", message: error.localizedDescription)
                LOG("Ticket session share failed", ctx: ["error": error.localizedDescription])
            }
        }

        private func importTemplateAssets(from extractionRoot: URL,
                                           manifest: SessionShareManifest) throws -> TemplateItem? {
            if !manifest.templates.isEmpty {
                let payloads = try loadSharedTemplatePayloads(from: manifest.templates,
                                                              extractionRoot: extractionRoot)
                return try importCombinedTemplates(from: payloads, manifest: manifest)
            }

            if manifest.templateIncluded {
                return try importLegacyTemplate(from: extractionRoot, manifest: manifest)
            }

            return nil
        }

        private func loadSharedTemplatePayloads(from descriptors: [SessionShareManifest.TemplateDescriptor],
                                                extractionRoot: URL) throws -> [SharedTemplatePayload] {
            let sorted = descriptors.sorted { $0.order < $1.order }
            var payloads: [SharedTemplatePayload] = []
            for descriptor in sorted {
                let folderURL = extractionRoot.appendingPathComponent(descriptor.folder, isDirectory: true)
                guard FileManager.default.fileExists(atPath: folderURL.path) else {
                    throw NSError(domain: "import", code: 40, userInfo: [NSLocalizedDescriptionKey: "Shared archive missing folder for template ‘\(descriptor.name)’"])
                }
                payloads.append(try loadSharedTemplatePayload(from: folderURL, descriptor: descriptor))
            }
            return payloads
        }

        private func loadSharedTemplatePayload(from folder: URL,
                                               descriptor: SessionShareManifest.TemplateDescriptor) throws -> SharedTemplatePayload {
            let fm = FileManager.default
            let sqlURL = folder.appendingPathComponent("template.sql")
            guard fm.fileExists(atPath: sqlURL.path) else {
                throw NSError(domain: "import", code: 41, userInfo: [NSLocalizedDescriptionKey: "Shared archive missing SQL for template ‘\(descriptor.name)’"])
            }
            let sql = try String(contentsOf: sqlURL, encoding: .utf8)

            let guideFolder = folder.appendingPathComponent("guide", isDirectory: true)
            let guideNotesURL = guideFolder.appendingPathComponent("guide.json")
            var guideNotes = ""
            if fm.fileExists(atPath: guideNotesURL.path) {
                let data = try Data(contentsOf: guideNotesURL)
                if let model = try? JSONDecoder().decode(SharedGuideNotesModel.self, from: data) {
                    guideNotes = model.text
                }
            }

            var links: [TemplateLink] = []
            let linksURL = folder.appendingPathComponent("links.json")
            if fm.fileExists(atPath: linksURL.path) {
                let data = try Data(contentsOf: linksURL)
                if let payload = try? JSONDecoder().decode(TemplateLinks.self, from: data) {
                    links = payload.links
                }
            }

            var tags: [String] = []
            let tagsURL = folder.appendingPathComponent("tags.json")
            if fm.fileExists(atPath: tagsURL.path) {
                let data = try Data(contentsOf: tagsURL)
                if let payload = try? JSONDecoder().decode(TemplateTags.self, from: data) {
                    tags = payload.tags
                }
            }

            var tables: [String] = []
            let tablesURL = folder.appendingPathComponent("tables.json")
            if fm.fileExists(atPath: tablesURL.path) {
                let data = try Data(contentsOf: tablesURL)
                if let payload = try? JSONDecoder().decode(TemplateTables.self, from: data) {
                    tables = payload.tables
                }
            }

            var guideImages: [SharedGuideImagePayload] = []
            let guideImagesURL = guideFolder.appendingPathComponent("images.json")
            if fm.fileExists(atPath: guideImagesURL.path) {
                let data = try Data(contentsOf: guideImagesURL)
                if let manifest = try? JSONDecoder().decode(SharedGuideImagesManifest.self, from: data) {
                    for image in manifest.images {
                        let source = guideFolder.appendingPathComponent("images", isDirectory: true).appendingPathComponent(image.fileName)
                        if fm.fileExists(atPath: source.path) {
                            guideImages.append(SharedGuideImagePayload(url: source, meta: image))
                        }
                    }
                }
            }

            return SharedTemplatePayload(
                descriptor: descriptor,
                sql: sql,
                guideNotes: guideNotes,
                links: links,
                tags: tags,
                tables: tables,
                guideImages: guideImages
            )
        }

        private func importCombinedTemplates(from payloads: [SharedTemplatePayload],
                                              manifest: SessionShareManifest) throws -> TemplateItem? {
            let fm = FileManager.default
            let sessionComponent = sanitizeFileName(manifest.sessionName.trimmingCharacters(in: .whitespacesAndNewlines))
            let preferredName = !sessionComponent.isEmpty
                ? sessionComponent
                : (manifest.templateDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? payloads.first?.descriptor.name
                    ?? "Template")
            var candidateBase = "(shared) \(preferredName)".trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateBase.isEmpty {
                candidateBase = "(shared) Template"
            }

            var finalBase = candidateBase
            var destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
            var suffix = 2
            while fm.fileExists(atPath: destination.path) {
                finalBase = "\(candidateBase) \(suffix)"
                destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
                suffix += 1
            }

            let combinedSQL = payloads.map { payload -> String in
                let name = payload.descriptor.name.isEmpty ? "Unnamed Template" : payload.descriptor.name
                let header = "-- ---\n-- Template: \(name)\n-- ---\n\n"
                let body = payload.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                return header + body + "\n"
            }.joined(separator: "\n")

            try combinedSQL.write(to: destination, atomically: true, encoding: .utf8)
            let newTemplateId = TemplateIdentityStore.shared.id(for: destination)
            LOG("Shared combined template created", ctx: ["file": destination.lastPathComponent, "fragments": "\(payloads.count)"])

            templates.loadTemplates()
            guard let imported = templates.templates.first(where: { $0.url == destination }) else {
                throw NSError(domain: "import", code: 52, userInfo: [NSLocalizedDescriptionKey: "Failed to register combined shared template"])
            }

            // Links
            var combinedLinks: [TemplateLink] = []
            var seenLinkKeys: Set<String> = []
            for payload in payloads {
                let name = payload.descriptor.name.isEmpty ? "Unnamed Template" : payload.descriptor.name
                for link in payload.links {
                    let title = name.isEmpty ? link.title : "[\(name)] \(link.title)"
                    let key = "\(title)::\(link.url)"
                    if seenLinkKeys.insert(key).inserted {
                        combinedLinks.append(TemplateLink(title: title, url: link.url))
                    }
                }
            }
            if !combinedLinks.isEmpty {
                TemplateLinksStore.shared.setLinks(combinedLinks, for: imported)
                _ = TemplateLinksStore.shared.saveSidecar(for: imported)
            }

            // Tags
            let combinedTags = Array(Set(payloads.flatMap { $0.tags })).sorted()
            if !combinedTags.isEmpty {
                TemplateTagsStore.shared.setTags(combinedTags, for: imported)
                _ = TemplateTagsStore.shared.saveSidecar(for: imported)
            }

            // Tables
            let combinedTables = Array(Set(payloads.flatMap { $0.tables })).sorted()
            if !combinedTables.isEmpty {
                let model = TemplateTables(templateId: newTemplateId, tables: combinedTables, updatedAt: Date())
                let encoder = JSONEncoder()
                if #available(macOS 10.13, *) {
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                } else {
                    encoder.outputFormatting = [.prettyPrinted]
                }
                let data = try encoder.encode(model)
                try data.write(to: imported.url.templateTablesSidecarURL(), options: .atomic)
                LOG("Combined template tables saved", ctx: ["template": imported.name, "count": "\(combinedTables.count)"])
            }

            // Guide notes and images
            TemplateGuideStore.shared.prepare(for: imported)
            let combinedNotes = buildCombinedGuideNotes(from: payloads)
            TemplateGuideStore.shared.setNotes(combinedNotes, for: imported)
            _ = TemplateGuideStore.shared.saveNotes(for: imported)

            for payload in payloads {
                for image in payload.guideImages {
                    if let data = try? Data(contentsOf: image.url) {
                        _ = TemplateGuideStore.shared.addImage(data: data,
                                                               suggestedName: image.meta.customName,
                                                               for: imported)
                    }
                }
            }

            return imported
        }

        private func buildCombinedAlternateFields(base: [AlternateField],
                                                  usedTemplates: [SavedTicketSession.UsedTemplate]) -> [AlternateField] {
            var result: [AlternateField] = []
            var seenValues: Set<String> = []

            func addField(name rawName: String, value rawValue: String) {
                let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else { return }
                guard seenValues.insert(trimmedValue).inserted else { return }
                let baseName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedBase = baseName.isEmpty ? "Field" : baseName
                if result.contains(where: { $0.name == normalizedBase && $0.value == trimmedValue }) { return }
                var candidate = normalizedBase
                var suffix = 1
                while result.contains(where: { $0.name == candidate }) {
                    if result.contains(where: { $0.name == candidate && $0.value == trimmedValue }) {
                        return
                    }
                    suffix += 1
                    candidate = "\(normalizedBase) (\(suffix))"
                }
                result.append(AlternateField(name: candidate, value: trimmedValue))
            }

            for field in base {
                addField(name: field.name, value: field.value)
            }

            for entry in usedTemplates {
                if entry.alternateFields.isEmpty {
                    let templateLabel = (entry.templateName?.isEmpty == false) ? entry.templateName! : "Template"
                    for (key, value) in entry.placeholders {
                        addField(name: "\(templateLabel) • \(key)", value: value)
                    }
                } else {
                    for alt in entry.alternateFields {
                        addField(name: alt.name, value: alt.value)
                    }
                }
            }

            return result
        }

        private func buildCombinedGuideNotes(from payloads: [SharedTemplatePayload]) -> String {
            var sections: [String] = []
            for (index, payload) in payloads.enumerated() {
                let name = payload.descriptor.name.isEmpty ? "Unnamed Template" : payload.descriptor.name
                let trimmed = payload.guideNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = trimmed.isEmpty ? "_No guide notes provided._" : trimmed
                let heading = "# Guide notes from \(name)"
                if index == 0 {
                    sections.append("\(heading)\n\n\(content)")
                } else {
                    let separator = "---\n\(name) - Guide Notes\n---"
                    sections.append("\(separator)\n\n\(heading)\n\n\(content)")
                }
            }
            return sections.joined(separator: "\n\n")
        }

        private func importLegacyTemplate(from extractionRoot: URL,
                                           manifest: SessionShareManifest) throws -> TemplateItem? {
            guard manifest.templateIncluded else { return nil }

            let fm = FileManager.default
            let templateFolder = extractionRoot.appendingPathComponent("template", isDirectory: true)
            guard fm.fileExists(atPath: templateFolder.path) else {
                throw NSError(domain: "import", code: 20, userInfo: [NSLocalizedDescriptionKey: "Shared archive missing template folder"])
            }

            let sqlFiles = try fm.contentsOfDirectory(at: templateFolder,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "sql" }
            guard let sqlSource = sqlFiles.first else {
                throw NSError(domain: "import", code: 21, userInfo: [NSLocalizedDescriptionKey: "Shared archive missing template SQL file"])
            }

            let providedName = manifest.templateDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalBase = sqlSource.deletingPathExtension().lastPathComponent
            let baseName = (providedName?.isEmpty == false ? providedName! : originalBase)
            var candidateBase = "(shared) \(baseName)".trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateBase.isEmpty {
                candidateBase = "(shared) Template"
            }

            var finalBase = candidateBase
            var destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
            var suffix = 2
            while fm.fileExists(atPath: destination.path) {
                finalBase = "\(candidateBase) \(suffix)"
                destination = AppPaths.templates.appendingPathComponent("\(finalBase).sql")
                suffix += 1
            }

            try fm.copyItem(at: sqlSource, to: destination)
            let newTemplateId = TemplateIdentityStore.shared.id(for: destination)
            LOG("Shared template SQL imported", ctx: ["file": destination.lastPathComponent])

            let originalSidecarBase = originalBase
            typealias SidecarTransform = (_ source: URL, _ destination: URL, _ templateId: UUID) throws -> Void
            let sidecarPairs: [(source: URL, name: String, apply: SidecarTransform)] = [
                (
                    templateFolder.appendingPathComponent("\(originalSidecarBase).links.json"),
                    "links",
                    { source, destination, templateId in
                        try self.rewriteLinksSidecar(from: source, to: destination, templateId: templateId)
                    }
                ),
                (
                    templateFolder.appendingPathComponent("\(originalSidecarBase).tables.json"),
                    "tables",
                    { source, destination, templateId in
                        try self.rewriteTablesSidecar(from: source, to: destination, templateId: templateId)
                    }
                ),
                (
                    templateFolder.appendingPathComponent("\(originalSidecarBase).tags.json"),
                    "tags",
                    { source, destination, templateId in
                        try self.rewriteTagsSidecar(from: source, to: destination, templateId: templateId)
                    }
                )
            ]

            for pair in sidecarPairs {
                guard fm.fileExists(atPath: pair.source.path) else { continue }
                let destinationURL = AppPaths.templates.appendingPathComponent(pair.source.lastPathComponent.replacingOccurrences(of: originalSidecarBase, with: finalBase))
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try pair.apply(pair.source, destinationURL, newTemplateId)
                LOG("Shared template sidecar imported", ctx: ["file": destinationURL.lastPathComponent, "kind": pair.name])
            }

            let guideSource = extractionRoot.appendingPathComponent("template-guide", isDirectory: true)
            if fm.fileExists(atPath: guideSource.path) {
                let guideDestination = AppPaths.templateGuides.appendingPathComponent(finalBase, isDirectory: true)
                if fm.fileExists(atPath: guideDestination.path) {
                    try fm.removeItem(at: guideDestination)
                }
                try fm.copyItem(at: guideSource, to: guideDestination)
                rewriteGuideManifest(at: guideDestination.appendingPathComponent("guide.json"), templateId: newTemplateId)
                rewriteGuideImagesManifest(at: guideDestination.appendingPathComponent("images.json"), templateId: newTemplateId)
                LOG("Shared template guide imported", ctx: ["template": finalBase])
            }

            templates.loadTemplates()
            guard let imported = templates.templates.first(where: { $0.url == destination }) else {
                throw NSError(domain: "import", code: 22, userInfo: [NSLocalizedDescriptionKey: "Failed to register shared template"])
            }

            TemplateLinksStore.shared.loadSidecar(for: imported)
            TemplateTagsStore.shared.ensureLoaded(imported)
            TemplateGuideStore.shared.prepare(for: imported)

            return imported
        }

        private func snapshotForImportedSession(original: SavedTicketSession,
                                                 manifest: SessionShareManifest,
                                                 extractionRoot: URL,
                                                 importedTemplate: TemplateItem?) throws -> SavedTicketSession {
            let fm = FileManager.default

            let imagesFolder = extractionRoot.appendingPathComponent("session-images", isDirectory: true)
            var nextImageIndex = sessions.sessionImages[sessions.current]?.count ?? 0
            var remappedImages: [SessionImage] = []
            if fm.fileExists(atPath: imagesFolder.path) {
                for image in original.sessionImages {
                    let source = imagesFolder.appendingPathComponent(image.fileName)
                    guard fm.fileExists(atPath: source.path) else {
                        LOG("Shared session missing referenced image", ctx: ["file": image.fileName])
                        continue
                    }
                    let copied = try importSessionImage(from: source,
                                                        original: image,
                                                        nextIndex: &nextImageIndex)
                    remappedImages.append(copied)
                }
            }

            let remappedSavedFiles = original.savedFiles.map { file in
                SavedTicketSession.SavedFile(
                    id: UUID(),
                    name: file.name,
                    content: file.content,
                    format: file.format,
                    createdAt: file.createdAt,
                    updatedAt: file.updatedAt
                )
            }

            let nameCandidate = manifest.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let sessionName = nameCandidate.isEmpty ? original.sessionName : nameCandidate

            let adjustedUsedTemplates: [SavedTicketSession.UsedTemplate] = {
                guard let importedTemplate else { return original.usedTemplates }
                if manifest.templates.isEmpty {
                    return original.usedTemplates.map { entry in
                        let resolvedTemplate: TemplateItem = {
                            if let uuid = UUID(uuidString: entry.templateId),
                               let match = templates.templates.first(where: { $0.id == uuid }) {
                                return match
                            }
                            if let name = entry.templateName,
                               let match = templates.templates.first(where: { $0.name == name }) {
                                return match
                            }
                            if entry.templateName == importedTemplate.name {
                                return importedTemplate
                            }
                            return importedTemplate
                        }()
                        let altFields = entry.alternateFields.isEmpty ? buildAlternateFields(from: entry.placeholders,
                                                                                               templateName: resolvedTemplate.name) : entry.alternateFields
                        return SavedTicketSession.UsedTemplate(
                            templateId: resolvedTemplate.id.uuidString,
                            templateName: resolvedTemplate.name,
                            placeholders: entry.placeholders,
                            lastUpdated: entry.lastUpdated,
                            alternateFields: altFields
                        )
                    }
                } else {
                    var merged: [String:String] = [:]
                    for entry in original.usedTemplates {
                        for (key, value) in entry.placeholders {
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty { continue }
                            if merged[key] == nil { merged[key] = value }
                        }
                    }
                    return [
                        SavedTicketSession.UsedTemplate(
                            templateId: importedTemplate.id.uuidString,
                            templateName: importedTemplate.name,
                            placeholders: merged,
                            lastUpdated: original.usedTemplates.first?.lastUpdated,
                            alternateFields: buildAlternateFields(from: merged, templateName: importedTemplate.name)
                        )
                    ]
                }
            }()

            let baseAlternateFields = original.alternateFields.map { savedField -> AlternateField in
                var field = AlternateField(name: savedField.name, value: savedField.value)
                field.id = savedField.id
                return field
            }
            let combinedAlternateFields = buildCombinedAlternateFields(
                base: baseAlternateFields,
                usedTemplates: adjustedUsedTemplates
            )
            let limitedAlternateFields = Array(combinedAlternateFields.prefix(200))
            let alternateFieldsList = limitedAlternateFields.map {
                SavedTicketSession.SavedAlternateField(id: $0.id, name: $0.name, value: $0.value)
            }

            return SavedTicketSession(
                version: max(original.version, 3),
                sessionName: sessionName,
                sessionLink: original.sessionLink,
                templateId: importedTemplate.map { "\($0.id)" } ?? original.templateId,
                templateName: importedTemplate?.name ?? original.templateName,
                staticFields: original.staticFields,
                placeholders: original.placeholders,
                dbTables: original.dbTables,
                notes: original.notes,
                alternateFields: alternateFieldsList,
                sessionImages: remappedImages.isEmpty ? original.sessionImages : remappedImages,
                savedFiles: remappedSavedFiles,
                usedTemplates: adjustedUsedTemplates
            )
        }

        private func buildAlternateFields(from placeholders: [String:String], templateName: String?) -> [SavedTicketSession.SavedAlternateField] {
            placeholders.compactMap { key, value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let templateLabel = (templateName?.isEmpty == false) ? templateName! : "Template"
                return SavedTicketSession.SavedAlternateField(
                    id: UUID(),
                    name: "\(templateLabel) • \(key)",
                    value: trimmed
                )
            }
        }

        private func removeTemplateFromRecents(_ template: TemplateItem) {
            UsedTemplatesStore.shared.clearTemplate(session: sessions.current, templateId: template.id)
            if var fields = sessions.sessionAlternateFields[sessions.current] {
                fields.removeAll { field in
                    field.name.hasPrefix("\(template.name) • ")
                }
                sessions.sessionAlternateFields[sessions.current] = fields
            }
            LOG("Template removed from recents", ctx: ["template": template.name, "session": "\(sessions.current.rawValue)"])
        }

        private func importSharedSessionFlow() {
            let panel = NSOpenPanel()
            panel.title = "Import Shared Session"
            panel.prompt = "Import"
            panel.allowedContentTypes = [UTType.zip]
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

            guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("SQLMaestroImport-\(UUID().uuidString)", isDirectory: true)

            do {
                try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempRoot) }

                try unzipArchive(archiveURL, to: tempRoot)

                let metadataURL = tempRoot.appendingPathComponent("metadata.json")
                let sessionURL = tempRoot.appendingPathComponent("session.json")
                guard fm.fileExists(atPath: metadataURL.path), fm.fileExists(atPath: sessionURL.path) else {
                    throw NSError(domain: "import", code: 30, userInfo: [NSLocalizedDescriptionKey: "Archive missing metadata.json or session.json"])
                }

                let decoder = JSONDecoder()
                let manifest = try decoder.decode(SessionShareManifest.self, from: Data(contentsOf: metadataURL))
                let originalSnapshot = try decoder.decode(SavedTicketSession.self, from: Data(contentsOf: sessionURL))

                let importedTemplate = try importTemplateAssets(from: tempRoot, manifest: manifest)
                let preparedSnapshot = try snapshotForImportedSession(original: originalSnapshot,
                                                                      manifest: manifest,
                                                                      extractionRoot: tempRoot,
                                                                      importedTemplate: importedTemplate)

                let rename = preparedSnapshot.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                cancelDBTablesAutosave(for: sessions.current, template: selectedTemplate)
                applySessionSnapshot(preparedSnapshot,
                                     inferredName: rename.isEmpty ? "Shared Session" : rename,
                                     matchedTemplate: importedTemplate ?? selectedTemplate,
                                     source: "importSharedSession")

                var baseName = sanitizeFileName(preparedSnapshot.sessionName)
                if baseName.isEmpty {
                    baseName = "SharedSession"
                }
                var finalURL = AppPaths.sessions.appendingPathComponent(baseName, conformingTo: .json)
                if finalURL.pathExtension.lowercased() != "json" {
                    finalURL = finalURL.appendingPathExtension("json")
                }
                var suffix = 2
                while fm.fileExists(atPath: finalURL.path) {
                    var candidate = baseName
                    if candidate.lowercased().hasSuffix(".json") {
                        candidate = String(candidate.dropLast(5))
                    }
                    candidate = "\(candidate)-\(suffix)"
                    finalURL = AppPaths.sessions.appendingPathComponent(candidate, conformingTo: .json)
                    if finalURL.pathExtension.lowercased() != "json" {
                        finalURL = finalURL.appendingPathExtension("json")
                    }
                    suffix += 1
                }

                try persistSnapshot(preparedSnapshot, to: finalURL)
                updateSavedSnapshot(for: sessions.current)
                LOG("Shared session imported", ctx: ["file": finalURL.lastPathComponent])

                let templateCount = !manifest.templates.isEmpty ? manifest.templates.count : (importedTemplate == nil ? 0 : 1)
                if let template = importedTemplate {
                    if templateCount > 1 {
                        showAlert(title: "Session Imported",
                                  message: "Loaded session ‘\(preparedSnapshot.sessionName)’ with \(templateCount) shared templates merged into ‘\(template.name)’.\nSaved as \(finalURL.lastPathComponent)")
                    } else {
                        showAlert(title: "Session Imported",
                                  message: "Loaded session ‘\(preparedSnapshot.sessionName)’ with template ‘\(template.name)’.\nSaved as \(finalURL.lastPathComponent)")
                    }
                } else {
                    showAlert(title: "Session Imported",
                              message: "Loaded session ‘\(preparedSnapshot.sessionName)’.\nSaved as \(finalURL.lastPathComponent)")
                }
            } catch {
                NSSound.beep()
                showAlert(title: "Import Failed", message: error.localizedDescription)
                LOG("Shared session import failed", ctx: ["error": error.localizedDescription])
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
        
        cancelDBTablesAutosave(for: sessions.current, template: selectedTemplate)
        
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
            draftDynamicValues[sessions.current] = [:]

            let matched = templates.templates.first(where: { "\($0.id)" == loaded.templateId ?? "" })
                ?? templates.templates.first(where: { $0.name == loaded.templateName ?? "" })
            applySessionSnapshot(loaded,
                                 inferredName: inferredName,
                                 matchedTemplate: matched ?? selectedTemplate,
                                 source: "loadTicketSession")

            LOG("Ticket session loaded", ctx: ["file": url.lastPathComponent])
        } catch {
            // Clear flag even on error
            isLoadingTicketSession = false
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

        private func attemptClearCurrentSession() {
            let flags = currentUnsavedFlags()
            let snapshot = captureSnapshot(for: sessions.current)

            guard flags.any else {
                // If there are no unsaved changes, check if session matches saved state
                if let savedSnapshot = sessionSavedSnapshots[sessions.current] {
                    // Session was saved - if current state matches saved state, clear without prompt
                    if snapshot == savedSnapshot {
                        clearCurrentSessionState()
                        return
                    }
                } else if !snapshot.hasAnyContent {
                    // No saved snapshot and no content - safe to clear without prompt
                    clearCurrentSessionState()
                    return
                }

                // Session has content but doesn't match saved state (or no saved state exists with content)
                let alert = NSAlert()
                alert.messageText = "Clear Session #\(sessions.current.rawValue)?"
                alert.informativeText = "Clearing will remove the current session's data. Save before clearing or cancel to keep working."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")

                let response = runAlertWithFix(alert)
                switch response {
                case .alertFirstButtonReturn:
                    _ = handleSessionSaveOnly()
                case .alertSecondButtonReturn:
                    clearCurrentSessionState()
                default:
                    return
                }
                return
            }
            let guideDirty = flags.guide
            let notesDirty = flags.notes
            let sessionFieldDirty = flags.sessionData
            let sessionDirty = flags.session
            let linksDirty = flags.links
            let dbTablesDirty = flags.tables

            var detailLines: [String] = []
            if guideDirty { detailLines.append("• Troubleshooting guide changes") }
            if notesDirty { detailLines.append("• Session notes changes") }
            if sessionFieldDirty { detailLines.append("• Session data changes") }
            if linksDirty { detailLines.append("• Template links updates") }
            if dbTablesDirty { detailLines.append("• DB tables updates") }

            let alert = NSAlert()
            alert.messageText = "Unsaved changes detected"
            alert.informativeText = ([
                "Session #\(sessions.current.rawValue) has pending edits:",
                detailLines.joined(separator: "\n"),
                "Choose how to proceed before clearing."
            ].filter { !$0.isEmpty }).joined(separator: "\n")
            alert.alertStyle = .warning

            enum PendingAction {
                case clear
                case saveAll
                case saveGuide
                case saveSession
                case saveLinks
                case saveTables
                case cancel
            }

            var actions: [PendingAction] = []

            alert.addButton(withTitle: "Clear Session")
            actions.append(.clear)

            alert.addButton(withTitle: "Save All")
            actions.append(.saveAll)

            if guideDirty {
                alert.addButton(withTitle: "Save Guide")
                actions.append(.saveGuide)
            }

            if sessionDirty {
                alert.addButton(withTitle: "Save Session")
                actions.append(.saveSession)
            }

            if linksDirty {
                alert.addButton(withTitle: "Save Links")
                actions.append(.saveLinks)
            }

            if dbTablesDirty {
                alert.addButton(withTitle: "Save DB Tables")
                actions.append(.saveTables)
            }

            alert.addButton(withTitle: "Cancel")
            actions.append(.cancel)

            let response = runAlertWithFix(alert)
            let index = Int(response.rawValue) - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0 && index < actions.count else { return }

            switch actions[index] {
            case .clear:
                clearCurrentSessionState()
            case .saveAll:
                performSaveAll(
                    guideDirty: guideDirty,
                    sessionDirty: sessionDirty,
                    linksDirty: linksDirty,
                    dbTablesDirty: dbTablesDirty
                ) {
                    clearCurrentSessionState()
                }
            case .saveGuide:
                handleGuideSaveOnly()
            case .saveSession:
                handleSessionSaveOnly()
            case .saveLinks:
                handleLinksSaveOnly()
            case .saveTables:
                handleTablesSaveOnly()
            case .cancel:
                return
            }
        }

        private func exitWorkflowPreflight() {
#if canImport(AppKit)
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "app_quit")
            }
#endif
        }

        private func exitUnsavedComponents(for session: TicketSession) -> AppExitCoordinator.Components {
            var components: AppExitCoordinator.Components = []
            if hasSessionFieldData(for: session) {
                components.insert(.session)
            }

            if let template = templateForSession(session) {
                if templateLinksStore.isDirty(for: template) {
                    components.insert(.links)
                }
                if dbTablesStore.isDirty(for: session, template: template) {
                    components.insert(.tables)
                }
            }

            return components
        }

        private func exitUnsavedSessions() -> [AppExitCoordinator.SessionEntry] {
            TicketSession.allCases.compactMap { session in
                let components = exitUnsavedComponents(for: session)
                guard !components.isEmpty else { return nil }

                let rawName = (sessions.sessionNames[session] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let display = rawName.isEmpty ? "Session #\(session.rawValue)" : rawName

                return AppExitCoordinator.SessionEntry(
                    session: session,
                    sessionDisplayName: display,
                    components: components
                )
            }
        }

        private func focusForExitWorkflow(on session: TicketSession) {
            if sessions.current != session {
                switchToSession(session)
            }
#if canImport(AppKit)
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "app_quit")
            }
#endif
        }

        private func saveForExitWorkflow(session: TicketSession,
                                         components: AppExitCoordinator.Components) -> Bool {
            if sessions.current != session {
                switchToSession(session)
            }

            var succeeded = true

            if components.contains(.session) {
                succeeded = handleSessionSaveOnly()
            }

            if succeeded, components.contains(.links) {
                succeeded = handleLinksSaveOnly()
            }

            if succeeded, components.contains(.tables) {
                succeeded = handleTablesSaveOnly()
            }

            return succeeded
        }

        private func templateForSession(_ session: TicketSession) -> TemplateItem? {
            if session == sessions.current, let template = selectedTemplate {
                return template
            }

            if let templateID = sessionSelectedTemplate[session],
               let match = templates.templates.first(where: { $0.id == templateID }) {
                return match
            }

            return nil
        }

        private func registerExitWorkflowProvider() {
            guard let tabContext else { return }
            let provider = AppExitCoordinator.Provider(
                tabContextID: tabContext.id,
                preflight: { exitWorkflowPreflight() },
                fetchSessions: { exitUnsavedSessions() },
                focusSession: { session in
                    focusForExitWorkflow(on: session)
                },
                performSave: { session, components in
                    saveForExitWorkflow(session: session, components: components)
                }
            )
            exitCoordinator.register(tabID: tabContext.id, provider: provider)
        }

        private func unregisterExitWorkflowProvider() {
            guard let tabContext else { return }
            exitCoordinator.unregister(tabID: tabContext.id)
        }

        private func currentUnsavedFlags() -> UnsavedFlags {
            UnsavedFlags(
                guide: templateGuideStore.isNotesDirty(for: selectedTemplate),
                notes: isSessionNotesDirty(session: sessions.current),
                sessionData: hasSessionFieldData(for: sessions.current),
                links: templateLinksStore.isDirty(for: selectedTemplate),
                tables: dbTablesStore.isDirty(for: sessions.current, template: selectedTemplate)
            )
        }

        private func clearCurrentSessionState() {
            commitDraftsForCurrentSession()

            // Backup template before clearing session
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "clear_session")
            }

            sessions.clearAllFieldsForCurrentSession()
            orgId = ""
            acctId = ""
            mysqlDb = ""
            companyLabel = ""
            draftDynamicValues[sessions.current] = [:]
            sessionStaticFields[sessions.current] = ("", "", "", "")
            savedFileAutosave.cancelAll(for: sessions.current)
            dbTablesAutosave.cancelAll(for: sessions.current)
            savedFileDrafts[sessions.current] = [:]
            savedFileValidation[sessions.current] = [:]
            setSavedFileSelection(nil, for: sessions.current)
            sessionNotesMode[sessions.current] = .notes
            setSessionNotesDraft("",
                                 for: sessions.current,
                                 source: "clearSession")
            UsedTemplatesStore.shared.clearSession(sessions.current)
            sessionSavedSnapshots.removeValue(forKey: sessions.current)
            setPaneLockState(true, source: "clearSession")
            LOG("Session cleared", ctx: ["session": "\(sessions.current.rawValue)"])
        }

        private func performSaveAll(guideDirty: Bool,
                                    sessionDirty: Bool,
                                    linksDirty: Bool,
                                    dbTablesDirty: Bool,
                                    onSuccess: () -> Void) {
            var succeeded = true

            if guideDirty { succeeded = handleGuideSaveOnly() }
            if succeeded && sessionDirty { succeeded = handleSessionSaveOnly() }
            if succeeded && linksDirty { succeeded = handleLinksSaveOnly() }
            if succeeded && dbTablesDirty { succeeded = handleTablesSaveOnly() }

            if succeeded {
                onSuccess()
            }
        }

        private func handleTicketSessionSaveShortcut() {
            let sessionResult = handleSessionSaveOnly()
            if sessionResult {
                _ = handleLinksSaveOnly()
            }
        }

        @discardableResult
        private func handleGuideSaveOnly() -> Bool {
            guard let template = selectedTemplate else { return true }
            guard templateGuideStore.isNotesDirty(for: template) else { return true }
            if templateGuideStore.saveNotes(for: template) {
                guideNotesDraft = templateGuideStore.currentNotes(for: template)
                touchTemplateActivity(for: template)
                return true
            }
#if canImport(AppKit)
            NSSound.beep()
#endif
            showAlert(title: "Save Failed", message: "Could not save troubleshooting guide changes.")
            return false
        }

        @discardableResult
        private func handleSessionSaveOnly() -> Bool {
            let session = sessions.current
            let previousSaved = sessions.sessionNotes[session] ?? ""
            let draft = sessionNotesDrafts[session] ?? ""
            if draft != previousSaved {
                saveSessionNotes()
            }
            commitDraftsForCurrentSession()
            if saveTicketSessionFlow() {
                return true
            } else {
                sessions.sessionNotes[session] = previousSaved
                setSessionNotesDraft(draft,
                                     for: session,
                                     source: "handleSessionSaveOnly.rollback")
                return false
            }
        }

        @discardableResult
        private func handleLinksSaveOnly() -> Bool {
            guard let template = selectedTemplate else { return true }
            guard templateLinksStore.isDirty(for: template) else { return true }
            if templateLinksStore.saveSidecar(for: template) {
                return true
            }
#if canImport(AppKit)
            NSSound.beep()
#endif
            showAlert(title: "Save Failed", message: "Could not save template links.")
            return false
        }

        @discardableResult
        private func handleTablesSaveOnly() -> Bool {
            guard let template = selectedTemplate else { return true }
            flushDBTablesAutosave(for: sessions.current, template: template)
            guard dbTablesStore.isDirty(for: sessions.current, template: template) else { return true }
            if dbTablesStore.saveSidecar(for: sessions.current, template: template) {
                return true
            }
#if canImport(AppKit)
            NSSound.beep()
#endif
            showAlert(title: "Save Failed", message: "Could not save DB tables.")
            return false
        }
        
        // A tiny invisible view that listens for the menu notifications
        private struct TicketSessionNotificationBridge: View {
            @Environment(\.isActiveTab) var isActiveTab
            @Environment(\.tabID) var tabID
            var onSave: () -> Void
            var onLoad: () -> Void
            var onOpen: () -> Void
            var body: some View {
                Color.clear
                    .onReceive(NotificationCenter.default.publisher(for: .saveTicketSession)) { _ in
                        guard isActiveTab else {
                            LOG("Save session notification ignored", ctx: ["tabId": tabID])
                            return
                        }
                        onSave()
                        LOG("Save session notification handled", ctx: ["tabId": tabID])
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .loadTicketSession)) { _ in
                        guard isActiveTab else {
                            LOG("Load session notification ignored", ctx: ["tabId": tabID])
                            return
                        }
                        onLoad()
                        LOG("Load session notification handled", ctx: ["tabId": tabID])
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .openSessionsFolder)) { _ in
                        guard isActiveTab else {
                            LOG("Open sessions folder notification ignored", ctx: ["tabId": tabID])
                            return
                        }
                        onOpen()
                        LOG("Open sessions folder notification handled", ctx: ["tabId": tabID])
                    }
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
            guard let newName = promptForString(
                title: "Rename Template",
                message: "Enter a new name for '\(item.name)'",
                defaultValue: item.name
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newName.isEmpty else { return }
            
            do {
                let originalURL = item.url
                let renamed = try templates.renameTemplate(item, to: newName)
                rewriteSessionNotesForTemplateRename(from: originalURL, to: renamed.url)
                if selectedTemplate?.id == item.id {
                    selectTemplate(renamed)
                }
            } catch {
                NSSound.beep()
            }
        }

        private func rewriteSessionNotesForTemplateRename(from oldURL: URL, to newURL: URL) {
            let oldFolder = AppPaths.templateGuides.appendingPathComponent(oldURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            let newFolder = AppPaths.templateGuides.appendingPathComponent(newURL.deletingPathExtension().lastPathComponent, isDirectory: true)
            guard oldFolder != newFolder else { return }

            for session in TicketSession.allCases {
                let current = sessions.sessionNotes[session] ?? ""
                if let updated = TemplateGuideStore.rewriteGuideTextPrefix(in: current,
                                                                          from: oldFolder,
                                                                          to: newFolder) {
                    sessions.sessionNotes[session] = updated
                }
            }

            for session in TicketSession.allCases {
                if let draft = sessionNotesDrafts[session],
                   let updated = TemplateGuideStore.rewriteGuideTextPrefix(in: draft,
                                                                          from: oldFolder,
                                                                          to: newFolder) {
                    setSessionNotesDraft(updated, for: session, source: "template-rename", logChange: false)
                }
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
                let response = runAlertWithFix(alert)
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
            runAlertWithFix(alert)
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

            // Backup template before connecting to database
            if let template = selectedTemplate {
                flushDBTablesAutosave(for: sessions.current, template: template)
                templates.backupTemplateIfNeeded(template, reason: "connect_database")
            }

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

        // Wrapper that intercepts Cmd+S for the tag editor
        struct TagEditorSheetWrapper: View {
            let template: TemplateItem
            let existingTags: [String]
            let onSave: ([String]) -> Void
            let onCancel: () -> Void

            @State private var shouldSave: Bool = false

            var body: some View {
                TemplateTagEditorSheet(
                    template: template,
                    existingTags: existingTags,
                    onSave: onSave,
                    onCancel: onCancel,
                    externalSaveTrigger: $shouldSave
                )
                .background(
                    Button("") {
                        shouldSave.toggle()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    .hidden()
                )
            }
        }

        // Inline Template Editor Sheet
        struct TemplateTagEditorSheet: View {
            let template: TemplateItem
            let onSave: ([String]) -> Void
            let onCancel: () -> Void
            @Binding var externalSaveTrigger: Bool

            @EnvironmentObject private var templatesManager: TemplateManager
            @ObservedObject private var tagsStore = TemplateTagsStore.shared
            @State private var inputText: String = ""
            @State private var draftTags: [String]
            @State private var availableTags: [String] = []
            @State private var highlightedSuggestionIndex: Int? = nil
            @State private var errorMessage: String? = nil
            @FocusState private var isFieldFocused: Bool

            init(template: TemplateItem,
                 existingTags: [String],
                 onSave: @escaping ([String]) -> Void,
                 onCancel: @escaping () -> Void,
                 externalSaveTrigger: Binding<Bool>) {
                self.template = template
                self.onSave = onSave
                self.onCancel = onCancel
                self._externalSaveTrigger = externalSaveTrigger
                _draftTags = State(initialValue: existingTags)
            }

            private var tagFieldBinding: Binding<String> {
                Binding(
                    get: { inputText },
                    set: { newValue in
                        updateBuffer(newValue)
                    }
                )
            }

            private var trimmedInput: String {
                inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            private var matchingTags: [String] {
                let query = trimmedInput
                guard !query.isEmpty else { return [] }
                return availableTags.filter { tag in
                    tag.range(of: query, options: .caseInsensitive) != nil
                }
            }

            private var highlightedSuggestionTag: String? {
                guard let index = highlightedSuggestionIndex,
                      index >= 0,
                      index < matchingTags.count else { return nil }
                return matchingTags[index]
            }

            private var suggestionsListHeight: CGFloat {
                let visible = min(matchingTags.count, 8)
                guard visible > 0 else { return 0 }
                let rowHeight: CGFloat = 32
                let spacing: CGFloat = 6
                let padding: CGFloat = 8 // LazyVStack vertical padding (4 top + 4 bottom)
                let rowsHeight = CGFloat(visible) * rowHeight
                let spacingHeight = CGFloat(max(visible - 1, 0)) * spacing
                return rowsHeight + spacingHeight + padding
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Tags")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Separate tags with commas. We'll add the '#' prefix automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("test-tag, another-tag", text: tagFieldBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                            .focused($isFieldFocused)
                            .onSubmit(commitCurrentEntry)
                            .onKeyPress(.downArrow) { moveHighlight(1) }
                            .onKeyPress(.upArrow) { moveHighlight(-1) }
                            .onKeyPress(.space) { handleSpaceKey() }
                            .onChange(of: inputText) { _ in
                                updateHighlightForCurrentMatches(resetToFirst: true)
                            }
                            .overlay(alignment: .trailing) {
                                if !inputText.isEmpty {
                                    Button(action: { inputText = "" }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                    .padding(.trailing, 8)
                                }
                            }
                            .tint(Theme.pink)
                            .onChange(of: availableTags) { _ in
                                updateHighlightForCurrentMatches(resetToFirst: false)
                            }

                        if let message = errorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(Color.red)
                        }

                        suggestionsSection
                        selectedTagsSection
                    }

                    Spacer(minLength: 8)

                    HStack {
                        Button("Cancel") {
                            onCancel()
                        }
                        .keyboardShortcut(.cancelAction)

                        Spacer()

                        Button("Save") {
                            commitCurrentEntry()
                            onSave(draftTags)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(minWidth: 480, minHeight: 320)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isFieldFocused = true
                    }
                    refreshAvailableTags()
                }
                .onChange(of: templatesManager.templates) { _ in
                    refreshAvailableTags()
                }
                .onChange(of: externalSaveTrigger) { _ in
                    commitCurrentEntry()
                    onSave(draftTags)
                }
            }

            private func updateBuffer(_ newValue: String) {
                guard newValue.contains(",") else {
                    inputText = newValue
                    return
                }

                var parts = newValue.components(separatedBy: ",")
                let trailing = parts.removeLast()
                for part in parts {
                    addTag(part)
                }
                inputText = trailing
            }

            private func commitCurrentEntry() {
                guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                addTag(inputText)
                inputText = ""
            }

            private func addTag(_ raw: String) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                guard let normalized = TemplateTagsStore.sanitize(trimmed) else {
                    errorMessage = "Tags must include letters or numbers."
                    return
                }
                errorMessage = nil
                if !draftTags.contains(normalized) {
                    draftTags.append(normalized)
                    includeInAvailable(normalized)
                }
            }

            private func removeTag(_ tag: String) {
                draftTags.removeAll { $0 == tag }
            }

            private func includeInAvailable(_ tag: String) {
                if !availableTags.contains(tag) {
                    availableTags.append(tag)
                    availableTags.sort { lhs, rhs in
                        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                    }
                    updateHighlightForCurrentMatches(resetToFirst: false)
                }
            }

            @discardableResult
            private func moveHighlight(_ delta: Int) -> KeyPress.Result {
                let count = matchingTags.count
                guard count > 0 else { return .ignored }
                let startingIndex: Int
                if let current = highlightedSuggestionIndex {
                    startingIndex = current
                } else {
                    startingIndex = delta > 0 ? -1 : count
                }
                var next = startingIndex + delta
                if next < 0 { next = count - 1 }
                if next >= count { next = 0 }
                highlightedSuggestionIndex = next
                return .handled
            }

            private func handleSpaceKey() -> KeyPress.Result {
                guard let tag = highlightedSuggestionTag else { return .ignored }
                acceptSuggestion(tag)
                return .handled
            }

            private func acceptSuggestion(_ tag: String) {
                guard !draftTags.contains(tag) else { return }
                addTag(tag)
                highlightedSuggestionIndex = nil
                inputText = ""
                DispatchQueue.main.async {
                    isFieldFocused = true
                }
            }

            private func updateHighlightForCurrentMatches(resetToFirst: Bool) {
                let count = matchingTags.count
                guard count > 0 else {
                    highlightedSuggestionIndex = nil
                    return
                }
                if resetToFirst || highlightedSuggestionIndex == nil || highlightedSuggestionIndex! >= count {
                    highlightedSuggestionIndex = 0
                }
            }

            @ViewBuilder
            private var selectedTagsSection: some View {
                if draftTags.isEmpty {
                    if matchingTags.isEmpty {
                        Text("No tags yet. Type a name and hit comma or return to confirm the tag.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(Theme.pink.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    ScrollView {
                        TagWrap(draftTags, spacing: 8) { tag in
                            HStack(spacing: 6) {
                                Text("#\(tag)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.pink)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Button {
                                    removeTag(tag)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove tag #\(tag)")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.pink.opacity(0.15))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Theme.pink.opacity(0.25), lineWidth: 1)
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(minHeight: 80, maxHeight: 200)
                }
            }

            @ViewBuilder
            private var suggestionsSection: some View {
                if !matchingTags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Matching tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let height = max(suggestionsListHeight, 44)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(matchingTags.enumerated()), id: \.element) { index, tag in
                                    let isHighlighted = highlightedSuggestionIndex == index
                                    Button {
                                        acceptSuggestion(tag)
                                    } label: {
                                        HStack {
                                            Text("#\(tag)")
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            if draftTags.contains(tag) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundStyle(Theme.pink)
                                                    Text("Added")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            } else {
                                                Image(systemName: "plus.circle")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(Theme.pink)
                                            }
                                        }
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(isHighlighted ? Theme.pink.opacity(0.2) : Theme.pink.opacity(0.08))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isHighlighted ? Theme.pink.opacity(0.5) : Theme.pink.opacity(0.25), lineWidth: isHighlighted ? 1.5 : 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(draftTags.contains(tag))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: height)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.pink.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.pink.opacity(0.2), lineWidth: 1)
                    )
                } else if !trimmedInput.isEmpty {
                    Text("No matching existing tags.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.pink.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.pink.opacity(0.2), lineWidth: 1)
                        )
                }
            }

            private func refreshAvailableTags() {
                var set = Set<String>()
                for template in templatesManager.templates {
                    tagsStore.ensureLoaded(template)
                    for tag in tagsStore.tags(for: template) {
                        set.insert(tag)
                    }
                }
                for tag in draftTags {
                    set.insert(tag)
                }
                availableTags = set.sorted { lhs, rhs in
                    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                updateHighlightForCurrentMatches(resetToFirst: true)
            }
        }

        private struct TagWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
            private let items: [Data.Element]
            private let spacing: CGFloat
            private let content: (Data.Element) -> Content

            init(_ data: Data, spacing: CGFloat = 8, @ViewBuilder content: @escaping (Data.Element) -> Content) {
                self.items = Array(data)
                self.spacing = spacing
                self.content = content
            }

            var body: some View {
                FlowLayout(spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        content(item)
                    }
                }
            }
        }

        private struct FlowLayout: Layout {
            var spacing: CGFloat = 8

            func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
                let rows = computeRows(proposal: proposal, subviews: subviews)
                let width = proposal.replacingUnspecifiedDimensions().width
                let height = rows.last?.maxY ?? 0
                return CGSize(width: width, height: height)
            }

            func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
                let rows = computeRows(proposal: proposal, subviews: subviews)
                for (index, subview) in subviews.enumerated() {
                    if let position = rows.flatMap({ $0.positions }).first(where: { $0.index == index }) {
                        subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                     proposal: .unspecified)
                    }
                }
            }

            private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
                let containerWidth = proposal.replacingUnspecifiedDimensions().width
                var rows: [Row] = []
                var currentRow = Row(positions: [], maxY: 0)
                var x: CGFloat = 0
                var y: CGFloat = 0

                for (index, subview) in subviews.enumerated() {
                    let size = subview.sizeThatFits(.unspecified)

                    if x + size.width > containerWidth && !currentRow.positions.isEmpty {
                        y = currentRow.maxY + spacing
                        rows.append(currentRow)
                        currentRow = Row(positions: [], maxY: 0)
                        x = 0
                    }

                    currentRow.positions.append(Position(index: index, x: x, y: y))
                    currentRow.maxY = max(currentRow.maxY, y + size.height)
                    x += size.width + spacing
                }

                if !currentRow.positions.isEmpty {
                    rows.append(currentRow)
                }

                return rows
            }

            private struct Row {
                var positions: [Position]
                var maxY: CGFloat
            }

            private struct Position {
                let index: Int
                let x: CGFloat
                let y: CGFloat
            }
        }

        struct TagSearchDialog: View {
            let templates: [TemplateItem]
            let onSelectTag: (String) -> Void
            let onClose: () -> Void

            @State private var searchQuery: String = ""
            @State private var selectedIndex: Int = 0
            @ObservedObject private var tagsStore = TemplateTagsStore.shared
            @FocusState private var isSearchFocused: Bool

            private var allTags: [TagResult] {
                var tagCounts: [String: Int] = [:]
                for template in templates {
                    let tags = tagsStore.tags(for: template)
                    for tag in tags {
                        tagCounts[tag, default: 0] += 1
                    }
                }
                return tagCounts.map { TagResult(tag: $0.key, count: $0.value) }
                    .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
            }

            private var filteredTags: [TagResult] {
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return allTags
                }
                let normalized = TemplateTagsStore.sanitize(trimmed)
                let fallback = trimmed.lowercased().replacingOccurrences(of: " ", with: "-")
                return allTags.filter { result in
                    if let normalized = normalized, !normalized.isEmpty {
                        return result.tag.contains(normalized)
                    } else if !fallback.isEmpty {
                        return result.tag.contains(fallback)
                    }
                    return true
                }
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search Tags")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Select a tag to view its templates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Type to filter tags...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isSearchFocused = true
                            }
                        }
                        .onChange(of: searchQuery) { _, _ in
                            selectedIndex = 0
                        }
                        .onKeyPress(.upArrow) {
                            if selectedIndex > 0 {
                                selectedIndex -= 1
                            }
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if selectedIndex < filteredTags.count - 1 {
                                selectedIndex += 1
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            guard !filteredTags.isEmpty else { return .handled }
                            guard selectedIndex >= 0 && selectedIndex < filteredTags.count else { return .handled }
                            onSelectTag(filteredTags[selectedIndex].tag)
                            return .handled
                        }

                    if filteredTags.isEmpty {
                        Text("No matching tags found.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        List(Array(filteredTags.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            Button {
                                onSelectTag(result.tag)
                            } label: {
                                HStack(spacing: 10) {
                                    Text("#\(result.tag)")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.pink)
                                    Spacer()
                                    Text("\(result.count)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                        }
                        .frame(minHeight: 280, maxHeight: 340)
                        .listStyle(.inset)
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            onClose()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                .frame(minWidth: 500, minHeight: 400)
            }

            struct TagResult: Identifiable {
                let tag: String
                let count: Int
                var id: String { tag }
            }
        }

        struct GuideNotesSearchDialog: View {
            let templates: [TemplateItem]
            let onSelectTemplate: (TemplateItem, String) -> Void
            let onClose: () -> Void

            @State private var searchQuery: String = ""
            @State private var selectedIndex: Int = 0
            @FocusState private var isSearchFocused: Bool
            @ObservedObject private var guideStore = TemplateGuideStore.shared

            private struct SearchMatch: Identifiable {
                let id = UUID()
                let template: TemplateItem
                let previews: [MatchPreview]
            }

            private struct MatchPreview {
                let keyword: String
                let contextBefore: String
                let matchedLine: String
                let contextAfter: String
                let lineNumber: Int
            }

            private enum SearchLogic {
                case and
                case or
            }

            private var searchResults: [SearchMatch] {
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    LOG("Guide notes search: empty query")
                    return []
                }

                let (keywords, logic) = parseSearchQuery(trimmed)
                guard !keywords.isEmpty else {
                    LOG("Guide notes search: no keywords parsed", ctx: ["query": trimmed])
                    return []
                }

                LOG("Guide notes search started", ctx: [
                    "keywords": keywords.joined(separator: ", "),
                    "logic": logic == .and ? "AND" : "OR",
                    "templateCount": "\(templates.count)"
                ])

                var matches: [SearchMatch] = []
                var templatesWithNotes = 0
                var totalNotesLength = 0

                for template in templates {
                    // IMPORTANT: Load notes from disk first - they may not be in cache
                    guideStore.prepare(for: template)
                    let notes = guideStore.currentNotes(for: template)
                    if !notes.isEmpty {
                        templatesWithNotes += 1
                        totalNotesLength += notes.count
                    }
                    let strippedNotes = stripMarkdown(notes)

                    if let previews = findMatches(in: strippedNotes, rawNotes: notes, keywords: keywords, logic: logic), !previews.isEmpty {
                        LOG("Guide notes search: match found", ctx: [
                            "template": template.name,
                            "matchCount": "\(previews.count)"
                        ])
                        matches.append(SearchMatch(template: template, previews: previews))
                    }
                }

                LOG("Guide notes search completed", ctx: [
                    "resultsFound": "\(matches.count)",
                    "templatesWithNotes": "\(templatesWithNotes)",
                    "totalNotesLength": "\(totalNotesLength)"
                ])

                return matches.sorted { $0.template.name.localizedCaseInsensitiveCompare($1.template.name) == .orderedAscending }
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search Guide Notes")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Space-separated words search with AND logic. Use or for OR logic. Partial words match.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Examples: \"vcpu\" • \"ocean characteristics\" • \"cpu or memory\" • \"saving\"")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.8))
                    }

                    TextField("Type keywords...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused($isSearchFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isSearchFocused = true
                            }
                        }
                        .onChange(of: searchQuery) { _, _ in
                            selectedIndex = 0
                        }
                        .onKeyPress(.upArrow) {
                            if selectedIndex > 0 {
                                selectedIndex -= 1
                            }
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if selectedIndex < searchResults.count - 1 {
                                selectedIndex += 1
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            guard !searchResults.isEmpty else { return .handled }
                            guard selectedIndex >= 0 && selectedIndex < searchResults.count else { return .handled }
                            let match = searchResults[selectedIndex]
                            let firstKeyword = match.previews.first?.keyword ?? searchQuery
                            onSelectTemplate(match.template, firstKeyword)
                            return .handled
                        }

                    if searchResults.isEmpty && !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No matches found.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else if searchResults.isEmpty {
                        Text("Enter keywords to search across all guide notes.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, match in
                                        let isSelected = index == selectedIndex

                                        VStack(alignment: .leading, spacing: 8) {
                                            Button {
                                                let firstKeyword = match.previews.first?.keyword ?? searchQuery
                                                onSelectTemplate(match.template, firstKeyword)
                                            } label: {
                                                HStack {
                                                    Text(match.template.name)
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundStyle(Theme.pink)
                                                    Spacer()
                                                    Text("\(match.previews.count) match\(match.previews.count == 1 ? "" : "es")")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(.secondary)
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                                                .cornerRadius(6)
                                            }
                                            .buttonStyle(.plain)
                                            .id(index)

                                            if isSelected {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    ForEach(Array(match.previews.enumerated()), id: \.offset) { _, preview in
                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text("Match: \"\(preview.keyword)\"")
                                                                .font(.system(size: 10, weight: .medium))
                                                                .foregroundStyle(.secondary)

                                                            VStack(alignment: .leading, spacing: 1) {
                                                                if !preview.contextBefore.isEmpty {
                                                                    Text(preview.contextBefore)
                                                                        .font(.system(size: 11))
                                                                        .foregroundStyle(.secondary)
                                                                }

                                                                Text(preview.matchedLine)
                                                                    .font(.system(size: 11, weight: .medium))
                                                                    .foregroundStyle(.primary)

                                                                if !preview.contextAfter.isEmpty {
                                                                    Text(preview.contextAfter)
                                                                        .font(.system(size: 11))
                                                                        .foregroundStyle(.secondary)
                                                                }
                                                            }
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 6)
                                                            .background(Color.primary.opacity(0.05))
                                                            .cornerRadius(4)
                                                        }
                                                    }
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.bottom, 8)
                                            }
                                        }
                                        .background(Color.clear)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                            .frame(minHeight: 280, maxHeight: 400)
                            .onChange(of: selectedIndex) { _, newIndex in
                                withAnimation {
                                    proxy.scrollTo(newIndex, anchor: .center)
                                }
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            onClose()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                .frame(minWidth: 600, minHeight: 450)
            }

            private func parseSearchQuery(_ query: String) -> (keywords: [String], logic: SearchLogic) {
                // Remove quotes from the query first - they're not part of the search terms
                let cleanedQuery = query.replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let lowercased = cleanedQuery.lowercased()
                var logic: SearchLogic = .and
                var parts: [String] = []

                // Split on AND/OR using lowercased version (case-insensitive matching)
                if lowercased.contains(" and ") {
                    logic = .and
                    parts = lowercased.components(separatedBy: " and ")
                } else if lowercased.contains(" or ") {
                    logic = .or
                    parts = lowercased.components(separatedBy: " or ")
                } else {
                    // Default: treat spaces as separators, each word is a keyword with AND logic
                    parts = lowercased.components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
                    logic = .and
                }

                let keywords = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                LOG("Guide notes search: query parsed", ctx: [
                    "originalQuery": query,
                    "cleanedQuery": cleanedQuery,
                    "keywords": keywords.joined(separator: ", "),
                    "logic": logic == .and ? "AND" : "OR"
                ])

                return (keywords, logic)
            }

            private func stripMarkdown(_ text: String) -> String {
                var result = text

                result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "\\*\\*([^\\*]+)\\*\\*", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "\\*([^\\*]+)\\*", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
                result = result.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
                result = result.replacingOccurrences(of: "^\\s*[-*+]\\s+", with: "", options: .regularExpression)
                result = result.replacingOccurrences(of: "^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)

                return result
            }

            private func findMatches(in strippedText: String, rawNotes: String, keywords: [String], logic: SearchLogic) -> [MatchPreview]? {
                let lines = strippedText.components(separatedBy: .newlines)
                var allPreviews: [MatchPreview] = []

                LOG("Guide notes search: findMatches called", ctx: [
                    "lineCount": "\(lines.count)",
                    "textLength": "\(strippedText.count)",
                    "keywords": keywords.joined(separator: ", ")
                ])

                for keyword in keywords {
                    let lowercasedKeyword = keyword.lowercased()
                    var matchesForKeyword = 0

                    for (index, line) in lines.enumerated() {
                        let lowercasedLine = line.lowercased()

                        if lowercasedLine.contains(lowercasedKeyword) {
                            matchesForKeyword += 1
                            let contextBefore = index > 0 ? lines[index - 1] : ""
                            let contextAfter = index < lines.count - 1 ? lines[index + 1] : ""

                            let preview = MatchPreview(
                                keyword: keyword,
                                contextBefore: contextBefore,
                                matchedLine: line,
                                contextAfter: contextAfter,
                                lineNumber: index
                            )
                            allPreviews.append(preview)
                        }
                    }

                    if matchesForKeyword > 0 {
                        LOG("Guide notes search: keyword found", ctx: [
                            "keyword": keyword,
                            "matchCount": "\(matchesForKeyword)"
                        ])
                    }
                }

                if logic == .and && keywords.count > 1 {
                    let foundKeywords = Set(allPreviews.map { $0.keyword.lowercased() })
                    let requiredKeywords = Set(keywords.map { $0.lowercased() })

                    if foundKeywords != requiredKeywords {
                        LOG("Guide notes search: AND logic failed", ctx: [
                            "required": requiredKeywords.joined(separator: ", "),
                            "found": foundKeywords.joined(separator: ", ")
                        ])
                        return nil
                    }
                }

                LOG("Guide notes search: findMatches result", ctx: [
                    "totalPreviews": "\(allPreviews.count)"
                ])

                return allPreviews.isEmpty ? nil : allPreviews
            }
        }

        struct TemplateTagExplorerSheet: View {
            let tag: String
            let templates: [TemplateItem]
            let onSelect: (TemplateItem) -> Void
            let onClose: () -> Void

            @State private var selectedIndex: Int = 0
            @ObservedObject private var tagsStore = TemplateTagsStore.shared

            private var matchingTemplates: [TemplateItem] {
                templates
                    .filter { tagsStore.tags(for: $0).contains(tag) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Templates tagged #\(tag)")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("\(matchingTemplates.count) template\(matchingTemplates.count == 1 ? "" : "s") found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if matchingTemplates.isEmpty {
                        Text("No templates currently use this tag.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        List(Array(matchingTemplates.enumerated()), id: \.element.id) { index, template in
                            let isSelected = index == selectedIndex
                            Button {
                                onSelect(template)
                            } label: {
                                HStack {
                                    Text(template.name)
                                        .font(.system(size: 14))
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(Theme.pink)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                        }
                        .frame(minHeight: 220, maxHeight: 260)
                        .listStyle(.inset)
                        .onKeyPress(.upArrow) {
                            if selectedIndex > 0 {
                                selectedIndex -= 1
                            }
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if selectedIndex < matchingTemplates.count - 1 {
                                selectedIndex += 1
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            guard !matchingTemplates.isEmpty else { return .handled }
                            guard selectedIndex >= 0 && selectedIndex < matchingTemplates.count else { return .handled }
                            onSelect(matchingTemplates[selectedIndex])
                            return .handled
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Close") {
                            onClose()
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24)
                .frame(minWidth: 420, minHeight: 320)
            }
        }

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
            @StateObject private var sqlEditorController = SQLEditorController()
            
            // Find the NSTextView that backs the SwiftUI TextEditor so we can insert at caret / replace selection.
            private func activeEditorTextView() -> NSTextView? {
                sqlEditorController.attachedTextView()
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
                let insertionLength = (token as NSString).length
                let newCaret = NSRange(location: safeRange.location + insertionLength, length: 0)
                applyTextChange(textView: tv,
                                 range: safeRange,
                                 replacement: token,
                                 newSelection: newCaret,
                                 actionName: "Insert Placeholder")
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
                return runAlertWithFix(alert) == .alertFirstButtonReturn
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
                guard runAlertWithFix(alert) == .alertFirstButtonReturn else {
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
                // "commented" means: optional leading spaces + either "#" or "--" (legacy) optionally followed by a space
                let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let allAlreadyCommented = nonEmpty.allSatisfy { line in
                    let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
                    return trimmedLeading.hasPrefix("#") || trimmedLeading.hasPrefix("--")
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
                        // UNcomment: remove the recognized comment marker and optional following space
                        let removePrefix: (Substring, Int) -> String = { segment, toDrop in
                            let afterPrefix = segment.dropFirst(toDrop)
                            let afterSpace = afterPrefix.first == " " ? afterPrefix.dropFirst() : afterPrefix
                            changedCount += 1
                            return String(leadingWhitespace) + String(afterSpace)
                        }
                        if remainder.hasPrefix("#") {
                            return removePrefix(remainder, 1)
                        }
                        if remainder.hasPrefix("--") {
                            return removePrefix(remainder, 2)
                        }
                        return original
                    } else {
                        // Comment: insert "# " after any leading indentation
                        if remainder.hasPrefix("#") {
                            return original
                        }
                        changedCount += 1
                        return String(leadingWhitespace) + "# " + String(remainder)
                    }
                }
                
                let updatedSegment = transformed.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
                let newString = ns.replacingCharacters(in: lineRange, with: updatedSegment)
                
                // Update SwiftUI and the NSTextView
                let newRange = NSRange(location: lineRange.location, length: (updatedSegment as NSString).length)
                applyTextChange(textView: tv,
                                 range: lineRange,
                                 replacement: updatedSegment,
                                 newSelection: newRange,
                                 actionName: allAlreadyCommented ? "Uncomment" : "Comment")

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
                let newCaret = NSRange(location: safeRange.location + (insertText as NSString).length, length: 0)
                applyTextChange(textView: tv,
                                 range: safeRange,
                                 replacement: insertText,
                                 newSelection: newCaret,
                                 actionName: "Insert Divider")
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
                        .help("Toggle '# ' comments on selected lines (⌘/)")
                        
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
                    SQLEditor(text: $localText,
                              fontSize: fontSize,
                              controller: sqlEditorController,
                              onTextChange: { newVal in
                                  self.text = newVal
                              })
                        .frame(minHeight: 340)
                        .padding()
                        .background(Color.clear)
                        .onAppear {
                            localText = text
                            let found = detectedPlaceholders(from: localText)
                            detectedFromFile = found
                            LOG("Detected placeholders in file", ctx: ["detected": "\(found.count)"])
                        }
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
                .onAppear {
                    let sizeString: String
                    if let window = NSApp.keyWindow {
                        let size = window.contentView?.bounds.size ?? .zero
                        sizeString = String(format: "%.0fx%.0f", size.width, size.height)
                    } else {
                        sizeString = "unknown"
                    }
                    LOG("Inline editor appeared", ctx: [
                        "template": template.name,
                        "window": sizeString
                    ])
                }
            }

            private func applyTextChange(textView: NSTextView,
                                         range: NSRange,
                                         replacement: String,
                                         newSelection: NSRange,
                                         actionName: String) {
                let undoManager = textView.undoManager
                undoManager?.beginUndoGrouping()
                defer { undoManager?.endUndoGrouping() }

                guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
                textView.didChangeText()
                textView.setSelectedRange(newSelection)
                textView.scrollRangeToVisible(newSelection)
                undoManager?.setActionName(actionName)

                let updated = textView.string
                self.localText = updated
                self.text = updated
                LOG("SQL editor text change applied", ctx: [
                    "action": actionName,
                    "length": "\(replacement.count)"
                ])
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
                .contextMenu {
                    Button("Show in Finder") {
                        showInFinder(image)
                    }
                    Button("Open") {
                        openSessionImage(image)
                    }
                    Button("Copy File Path") {
                        copyFilePath(image)
                    }
                    Divider()
                    Button("Rename") {
                        onRename(image)
                    }
                    Button("Delete", role: .destructive) {
                        onDelete(image)
                    }
                }
            }

            private func showInFinder(_ image: SessionImage) {
                let imageURL = AppPaths.sessionImages.appendingPathComponent(image.fileName)
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                    LOG("Showed session image in Finder", ctx: ["fileName": image.fileName])
                } else {
                    LOG("Session image file not found", ctx: ["fileName": image.fileName])
                }
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

            private func copyFilePath(_ image: SessionImage) {
                let imageURL = AppPaths.sessionImages.appendingPathComponent(image.fileName)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(imageURL.path, forType: .string)
                LOG("Session image file path copied to clipboard", ctx: ["fileName": image.fileName, "path": imageURL.path])
            }
        }

        struct TemplateGuideImageRow: View {
            let template: TemplateItem
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
                .contextMenu {
                    Button("Show in Finder") {
                        showInFinder()
                    }
                    Button("Open") {
                        onOpen()
                    }
                    Button("Copy File Path") {
                        copyFilePath()
                    }
                    Divider()
                    Button("Rename") {
                        onRename()
                    }
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
            }

            private func showInFinder() {
                let imageURL = TemplateGuideStore.shared.imageURL(for: image, template: template)
                if FileManager.default.fileExists(atPath: imageURL.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                    LOG("Showed guide image in Finder", ctx: ["fileName": image.fileName])
                } else {
                    LOG("Guide image file not found", ctx: ["fileName": image.fileName])
                }
            }

            private func formatDate(_ date: Date) -> String {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }

            private func copyFilePath() {
                let imageURL = TemplateGuideStore.shared.imageURL(for: image, template: template)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(imageURL.path, forType: .string)
                LOG("Guide image file path copied to clipboard", ctx: ["fileName": image.fileName, "path": imageURL.path])
            }
        }

        private struct SessionImagePreviewSheet: View {
            let sessionImage: SessionImage
            private let displayedImage: NSImage?
            @State private var sliderValue: Double
            @Environment(\.dismiss) private var dismiss

            init(sessionImage: SessionImage) {
                self.sessionImage = sessionImage
                let url = AppPaths.sessionImages.appendingPathComponent(sessionImage.fileName)
                self.displayedImage = NSImage(contentsOf: url)
                self._sliderValue = State(initialValue: 0.35)
            }

            private var imageURL: URL {
                AppPaths.sessionImages.appendingPathComponent(sessionImage.fileName)
            }

            private var imageExists: Bool {
                FileManager.default.fileExists(atPath: imageURL.path)
            }

            var body: some View {
                let baseWidth: CGFloat = 480
                let baseHeight: CGFloat = 360

                // Get the screen size and calculate max width based on available space
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let screenSize = screenFrame.size
                let screenPadding: CGFloat = 100 // padding from screen edges
                let maxWidth = max(screenSize.width - screenPadding, baseWidth)
                let widthRange: CGFloat = maxWidth - baseWidth

                let chromeHeight: CGFloat = 220

                let resolvedWidth = baseWidth + CGFloat(sliderValue) * widthRange
                let aspectRatio = (displayedImage?.size.width ?? 0) > 0 ? (displayedImage!.size.height / displayedImage!.size.width) : 0.75
                let imageHeightForWidth = resolvedWidth * aspectRatio
                let resolvedHeight = max(baseHeight, imageHeightForWidth + chromeHeight)

                let verticalPadding: CGFloat = 80
                let maxWindowHeight = max(screenSize.height - verticalPadding, baseHeight)

                let finalWidth = min(resolvedWidth, maxWidth)
                let finalHeight = min(resolvedHeight, maxWindowHeight)

                return VStack(alignment: .leading, spacing: 16) {
                    Text(sessionImage.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.purple)

                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        VStack(spacing: 0) {
                            if let nsImage = displayedImage {
                                let imageView = Image(nsImage: nsImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: resolvedWidth)
                                    .cornerRadius(10)
                                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)

                                if resolvedWidth <= finalWidth {
                                    HStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        imageView
                                        Spacer(minLength: 0)
                                    }
                                } else {
                                    imageView
                                }
                            } else {
                                let placeholder = VStack(spacing: 8) {
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
                                .padding(.vertical, 40)
                                .frame(width: max(resolvedWidth, finalWidth))

                                if resolvedWidth <= finalWidth {
                                    HStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        placeholder
                                        Spacer(minLength: 0)
                                    }
                                } else {
                                    placeholder
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Window Size")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Slider(value: $sliderValue, in: 0.0...1.0)
                                .help("Adjust preview size")
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(imageURL.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 12))

                        Button("Open") {
                            NSWorkspace.shared.open(imageURL)
                            LOG("Session image preview open", ctx: ["fileName": sessionImage.fileName])
                            dismiss()
                        }
                        .disabled(!imageExists)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                            LOG("Session image preview show in Finder", ctx: ["fileName": sessionImage.fileName])
                        }
                        .disabled(!imageExists)

                        Button("Copy File Path") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(imageURL.path, forType: .string)
                            LOG("Session image file path copied to clipboard", ctx: ["fileName": sessionImage.fileName, "path": imageURL.path])
                        }
                        .disabled(!imageExists)

                        Button("Copy") {
                            if let image = displayedImage {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.writeObjects([image])
                                LOG("Session image copied to clipboard", ctx: ["fileName": sessionImage.fileName])
                            }
                        }
                        .disabled(!imageExists)
                    }
                }
                .padding(20)
                .frame(width: finalWidth,
                       height: finalHeight,
                       alignment: .topLeading)
#if canImport(AppKit)
                .background(WindowSizeUpdater(size: CGSize(width: finalWidth,
                                                          height: finalHeight)))
                .background(FloatingWindowConfigurator(level: .floating))
#endif
            }
        }

        private struct TemplateGuideImagePreviewSheet: View {
            let template: TemplateItem
            let guideImage: TemplateGuideImage

            private let displayedImage: NSImage?
            @State private var sliderValue: Double
            @Environment(\.dismiss) private var dismiss

            init(template: TemplateItem, guideImage: TemplateGuideImage) {
                self.template = template
                self.guideImage = guideImage
                let url = TemplateGuideStore.shared.imageURL(for: guideImage, template: template)
                self.displayedImage = NSImage(contentsOf: url)
                self._sliderValue = State(initialValue: 0.35)
            }

            private var imageURL: URL {
                TemplateGuideStore.shared.imageURL(for: guideImage, template: template)
            }

            private var imageExists: Bool {
                FileManager.default.fileExists(atPath: imageURL.path)
            }

            var body: some View {
                let baseWidth: CGFloat = 480
                let baseHeight: CGFloat = 360

                // Get the screen size and calculate max width based on available space
                let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
                let screenSize = screenFrame.size
                let screenPadding: CGFloat = 100 // padding from screen edges
                let maxWidth = max(screenSize.width - screenPadding, baseWidth)
                let widthRange: CGFloat = maxWidth - baseWidth

                let chromeHeight: CGFloat = 220

                let resolvedWidth = baseWidth + CGFloat(sliderValue) * widthRange
                let aspectRatio = (displayedImage?.size.width ?? 0) > 0 ? (displayedImage!.size.height / displayedImage!.size.width) : 0.75
                let imageHeightForWidth = resolvedWidth * aspectRatio
                let resolvedHeight = max(baseHeight, imageHeightForWidth + chromeHeight)

                let verticalPadding: CGFloat = 80
                let maxWindowHeight = max(screenSize.height - verticalPadding, baseHeight)

                let finalWidth = min(resolvedWidth, maxWidth)
                let finalHeight = min(resolvedHeight, maxWindowHeight)

                return VStack(alignment: .leading, spacing: 16) {
                    Text(guideImage.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.purple)

                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        VStack(spacing: 0) {
                            if let nsImage = displayedImage {
                                let imageView = Image(nsImage: nsImage)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: resolvedWidth)
                                    .cornerRadius(10)
                                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)

                                if resolvedWidth <= finalWidth {
                                    HStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        imageView
                                        Spacer(minLength: 0)
                                    }
                                } else {
                                    imageView
                                }
                            } else {
                                let placeholder = VStack(spacing: 8) {
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
                                .padding(.vertical, 40)
                                .frame(width: max(resolvedWidth, finalWidth))

                                if resolvedWidth <= finalWidth {
                                    HStack(spacing: 0) {
                                        Spacer(minLength: 0)
                                        placeholder
                                        Spacer(minLength: 0)
                                    }
                                } else {
                                    placeholder
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Window Size")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Slider(value: $sliderValue, in: 0.0...1.0)
                                .help("Adjust preview size")
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(imageURL.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Close") {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .font(.system(size: 12))

                        Button("Open") {
                            NSWorkspace.shared.open(imageURL)
                            dismiss()
                        }
                        .disabled(!imageExists)

                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([imageURL])
                        }
                        .disabled(!imageExists)

                        Button("Copy File Path") {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(imageURL.path, forType: .string)
                            LOG("Guide image file path copied to clipboard", ctx: ["fileName": guideImage.fileName, "path": imageURL.path])
                        }
                        .disabled(!imageExists)

                        Button("Copy") {
                            if let image = displayedImage {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.writeObjects([image])
                                LOG("Guide image copied to clipboard", ctx: ["fileName": guideImage.fileName])
                            }
                        }
                        .disabled(!imageExists)
                    }
                }
                .padding(20)
                .frame(width: finalWidth,
                       height: finalHeight,
                       alignment: .topLeading)
#if canImport(AppKit)
                .background(WindowSizeUpdater(size: CGSize(width: finalWidth,
                                                          height: finalHeight)))
                .background(FloatingWindowConfigurator(level: .floating))
#endif
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
        
        private func toggleInlineCode() { wrapSelection(prefix: "`", suffix: "`") }
        private func toggleBold() { wrapSelection(prefix: "**") }
        private func toggleItalic() { wrapSelection(prefix: "*") }
        private func toggleUnderline() { wrapSelection(prefix: "<u>", suffix: "</u>") }
        private func toggleCodeBlock() { wrapSelection(prefix: "\n```\n", suffix: "\n```\n") }
        
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
            guard runAlertWithFix(alert) == .alertFirstButtonReturn else { return }
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
                        Button(action: { toggleBold() }) { Image(systemName: "bold") }
                            .keyboardShortcut("b", modifiers: [.command])
                            .help("Bold (⌘B)")
                        Button(action: { toggleItalic() }) { Image(systemName: "italic") }
                            .keyboardShortcut("i", modifiers: [.command])
                            .help("Italic (⌘I)")
                        Button(action: { toggleUnderline() }) { Image(systemName: "underline") }
                            .keyboardShortcut("u", modifiers: [.command])
                            .help("Underline (⌘U)")
                        Button(action: { insertLink() }) { Image(systemName: "link") }
                            .keyboardShortcut("k", modifiers: [.command])
                            .help("Insert link (⌘K)")
                            .registerShortcut(name: "Insert Link", keyLabel: "K", modifiers: [.command], scope: "Markdown")
                        Divider()
                        Button(action: { toggleInlineCode() }) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                            .help("Inline code")
                        Button(action: { toggleCodeBlock() }) { Image(systemName: "square.grid.3x3") }
                            .help("Code block")
                        Divider()
                        Button(action: { applyHeading(1) }) { Text("H1") }
                            .help("Heading 1")
                        Button(action: { applyHeading(2) }) { Text("H2") }
                            .help("Heading 2")
                        Button(action: { applyHeading(3) }) { Text("H3") }
                            .help("Heading 3")
                        Divider()
                        Button(action: { applyList(prefix: "- ") }) { Image(systemName: "list.bullet") }
                            .help("Bulleted list")
                        Button(action: { applyList(prefix: "1. ") }) { Image(systemName: "list.number") }
                            .help("Numbered list")
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
                        .foregroundStyle(Theme.paneLabelColor)
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
    private struct TemplatesSidebar<Header: View, Search: View, List: View, Footer: View>: View {
        private let header: Header
        private let search: Search
        private let list: List
        private let footer: Footer

        init(@ViewBuilder header: () -> Header,
             @ViewBuilder search: () -> Search,
             @ViewBuilder list: () -> List,
             @ViewBuilder footer: () -> Footer) {
            self.header = header()
            self.search = search()
            self.list = list()
            self.footer = footer()
        }

        var body: some View {
            VStack(spacing: 8) {
                header
                search
                list
                footer
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
                .help("Bold (⌘B)")
                Button(action: controller.italic) {
                    Image(systemName: "textformat.italic")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Italic (⌘I)")
                Menu {
                    Button("Heading 1") { controller.heading(level: 1) }
                    Button("Heading 2") { controller.heading(level: 2) }
                    Button("Heading 3") { controller.heading(level: 3) }
                    Button("Heading 4") { controller.heading(level: 4) }
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: size + 1, weight: .semibold))
                }
                .help("Headings")
                Button(action: controller.inlineCode) {
                    Image(systemName: "chevron.left.slash.chevron.right")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Inline code (⌘`)")
                Button(action: controller.codeBlock) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Code block")
                Button(action: controller.bulletList) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Bulleted list")
                Button(action: controller.numberedList) {
                    Image(systemName: "list.number")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Numbered list")
                Button(action: controller.link) {
                    Image(systemName: "link")
                        .font(.system(size: size, weight: .semibold))
                }
                .help("Insert link (⌘K)")
                .registerShortcut(name: "Insert Link", keyLabel: "K", modifiers: [.command], scope: "Markdown")
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

    struct InPaneSearchBar: View {
        @Binding var searchQuery: String
        var matchCount: Int
        var currentMatchIndex: Int
        var onPrevious: () -> Void
        var onNext: () -> Void
        var onEnter: () -> Void
        var onCancel: () -> Void
        var fontSize: CGFloat
        var isSearchFocused: FocusState<Bool>.Binding

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: fontSize - 1, weight: .medium))
                    .foregroundStyle(Theme.purple.opacity(0.7))

                TextField("Search...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize - 2))
                    .frame(width: 120)
                    .submitLabel(.search)
                    .focused(isSearchFocused)
                    .onSubmit {
                        onEnter()
                        // Refocus the search field after Enter is pressed
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isSearchFocused.wrappedValue = true
                        }
                    }
                    .onKeyPress(.escape) {
                        onCancel()
                        return .handled
                    }

                if !searchQuery.isEmpty {
                    if matchCount > 0 {
                        Text("\(currentMatchIndex + 1) of \(matchCount)")
                            .font(.system(size: fontSize - 3, weight: .medium))
                            .foregroundStyle(.secondary)

                        Button(action: onPrevious) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: fontSize - 3, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(matchCount == 0)

                        Button(action: onNext) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: fontSize - 3, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(matchCount == 0)
                    } else {
                        Text("No matches")
                            .font(.system(size: fontSize - 3, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: fontSize - 2))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.grayBG.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                    )
            )
        }
    }

    private struct EditorSectionBadge: View {
        var title: String

        var body: some View {
            HStack {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.aqua)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.pink.opacity(0.85), lineWidth: 1)
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .accessibilityLabel(title)
                Spacer(minLength: 0)
            }
        }
    }

    struct SessionNotesInline: View {
        var fontSize: CGFloat
        var editorMinHeight: CGFloat
        var session: TicketSession
        @Binding var draft: String
        var savedValue: String
        @ObservedObject var controller: MarkdownEditorController
        @Binding var isPreview: Bool
        @Binding var mode: SessionNotesPaneMode
        var savedFiles: [SessionSavedFile]
        var selectedSavedFileID: UUID?
        var savedFileDraft: (UUID) -> String
        var savedFileValidation: (UUID) -> JSONValidationState
        var onSavedFileSelect: (UUID?) -> Void
        var onSavedFileAdd: () -> Void
        var onSavedFileDelete: (UUID) -> Void
        var onSavedFileRename: (UUID) -> Void
        var onSavedFileReorder: (Int, Int) -> Void
        var onSavedFileContentChange: (UUID, String) -> Void
        var onSavedFileFocusChanged: (Bool) -> Void
        var onSavedFileOpenTree: (UUID) -> Void
        var onSavedFileFormatTree: ((UUID) -> Void)? = nil
        var onSavedFileFormatLine: ((UUID) -> Void)? = nil
        var onSavedFileSearchCancel: () -> Void
        var savedFileSearchFocused: FocusState<Bool>.Binding
        var onSavedFilesModeExit: () -> Void
        var onSavedFilesPopout: (() -> Void)? = nil
        var onSessionNotesFocusChanged: ((Bool) -> Void)? = nil
        var onSave: () -> Void
        var onRevert: () -> Void
        var onLinkRequested: (_ selectedText: String, _ source: MarkdownEditor.LinkRequestSource, _ completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) -> Void
        var onLinkOpen: (URL, NSEvent.ModifierFlags) -> Void
        var onImageAttachment: (MarkdownEditor.ImageDropInfo) -> MarkdownEditor.ImageInsertion?
        var showsModePicker: Bool = true
        var showsModeToolbar: Bool = true
        var showsOuterBackground: Bool = true
        var showsContentBackground: Bool = true

        private var isDirty: Bool { draft != savedValue }

        @State private var showingGhostOverlay = false
        @State private var ghostOverlayOriginal: SessionSavedFile?
        @State private var ghostOverlayGhost: SessionSavedFile?

        var body: some View {
            Group {
                if showsOuterBackground {
                    contentStack
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(hex: "#2A2A35").opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Theme.purple.opacity(0.2), lineWidth: 1)
                                )
                            )
                } else {
                    contentStack
                        .padding(.vertical, 0)
                }
            }
            .sheet(isPresented: $showingGhostOverlay) {
                GhostOverlayView(
                    availableFiles: savedFiles,
                    originalFile: $ghostOverlayOriginal,
                    ghostFile: $ghostOverlayGhost,
                    onClose: { showingGhostOverlay = false },
                    onJumpToLine: { file, lineNumber in
                        // Select the ghost file in the editor
                        onSavedFileSelect(file.id)
                        // TODO: Jump to specific line number in JSONEditor
                        // This will require extending JSONEditor with a jump-to-line capability
                    }
                )
            }
        }

        private var contentStack: some View {
            VStack(alignment: .leading, spacing: 8) {
                if showsModePicker {
                    Picker("Notes Mode", selection: $mode) {
                        Text("Session Notes").tag(SessionNotesPaneMode.notes)
                        Text("Saved Files").tag(SessionNotesPaneMode.savedFiles)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if showsModeToolbar {
                    modeToolbar
                }

                contentBody
            }
            .onChange(of: mode) { previous, newValue in
                if newValue != .savedFiles {
                    onSavedFileFocusChanged(false)
                    onSavedFilesModeExit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .layoutPriority(1)
        }

        @ViewBuilder
        private var contentBody: some View {
            if mode == .notes {
                let topPadding = showsContentBackground ? 0.0 : 12.0
                notesPane
                    .padding(.top, topPadding)
                    .frame(minHeight: editorMinHeight, alignment: .top)
            } else {
                let topPadding: CGFloat = 0.0
                SavedFilesWorkspace(
                    fontSize: fontSize,
                    files: savedFiles,
                    selectedID: selectedSavedFileID,
                    draftProvider: savedFileDraft,
                    validationProvider: savedFileValidation,
                    onAdd: onSavedFileAdd,
                    onSelect: onSavedFileSelect,
                    onDelete: onSavedFileDelete,
                    onRename: onSavedFileRename,
                    onContentChange: onSavedFileContentChange,
                    onFocusChange: onSavedFileFocusChanged,
                    onOpenTree: onSavedFileOpenTree,
                    onFormatTree: onSavedFileFormatTree,
                    onFormatLine: onSavedFileFormatLine,
                    onSearchCancel: onSavedFileSearchCancel,
                    isSearchFieldFocused: savedFileSearchFocused,
                    editorMinHeight: editorMinHeight
                )
                .padding(.top, topPadding)
                .frame(minHeight: editorMinHeight, alignment: .top)
            }
        }

        private var modeToolbar: some View {
            ZStack(alignment: .topLeading) {
                notesToolbar
                    .opacity(mode == .notes ? 1 : 0)
                    .allowsHitTesting(mode == .notes)
                savedFilesToolbar
                    .opacity(mode == .savedFiles ? 1 : 0)
                    .allowsHitTesting(mode == .savedFiles)
            }
            .frame(minHeight: 60, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.18), value: mode)
        }

        private var notesToolbar: some View {
            HStack(spacing: 12) {
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
        }

        private var savedFilesToolbar: some View {
            SavedFilesWorkspace.Toolbar(
                fontSize: fontSize,
                files: savedFiles,
                selectedID: selectedSavedFileID,
                onAdd: onSavedFileAdd,
                onSelect: onSavedFileSelect,
                onOpenTree: onSavedFileOpenTree,
                onRename: onSavedFileRename,
                onDelete: onSavedFileDelete,
                onReorder: onSavedFileReorder,
                onPopOut: onSavedFilesPopout,
                onFormatTree: onSavedFileFormatTree,
                onFormatLine: onSavedFileFormatLine,
                onCompare: {
                    // Pre-select currently active file as original
                    if let currentFile = savedFiles.first(where: { $0.id == selectedSavedFileID }) {
                        ghostOverlayOriginal = currentFile
                    }
                    ghostOverlayGhost = nil
                    showingGhostOverlay = true
                },
                onCompareWith: { ghostFileId in
                    // The currently selected file is the original
                    // The file from context menu is the ghost
                    if let currentFile = savedFiles.first(where: { $0.id == selectedSavedFileID }) {
                        ghostOverlayOriginal = currentFile
                        LOG("Ghost overlay - context menu - Original set", ctx: ["file": currentFile.displayName])
                    } else {
                        LOG("Ghost overlay - context menu - No current file selected", ctx: [:])
                    }
                    if let ghostFile = savedFiles.first(where: { $0.id == ghostFileId }) {
                        ghostOverlayGhost = ghostFile
                        LOG("Ghost overlay - context menu - Ghost set", ctx: ["file": ghostFile.displayName])
                    } else {
                        LOG("Ghost overlay - context menu - Ghost file not found", ctx: ["id": "\(ghostFileId)"])
                    }
                    showingGhostOverlay = true
                    LOG("Ghost overlay - context menu - Sheet shown", ctx: ["original": ghostOverlayOriginal?.displayName ?? "nil", "ghost": ghostOverlayGhost?.displayName ?? "nil"])
                }
            )
        }

        @ViewBuilder
        private var notesPane: some View {
            let base = Group {
                if isPreview {
                    MarkdownPreviewView(
                        text: draft,
                        fontSize: fontSize * 1.5,
                        onLinkOpen: onLinkOpen
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    MarkdownEditor(
                        text: $draft,
                        fontSize: fontSize * 1.5,
                        controller: controller,
                        onLinkRequested: onLinkRequested,
                        onImageAttachment: { info in
                            onImageAttachment(info)
                        },
                        onFocusChange: { focused in
                            onSessionNotesFocusChanged?(focused)
                        }
                    )
                    .frame(maxWidth: .infinity, minHeight: editorMinHeight, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .layoutPriority(1)

            if showsContentBackground {
                base
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(hex: "#2A2A35"))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .frame(minHeight: editorMinHeight, alignment: .top)
            } else {
                base
                    .background(Color(hex: "#2A2A35"))
                    .frame(minHeight: editorMinHeight, alignment: .top)
            }
        }

        struct SavedFilesWorkspace: View {
            enum SearchStatus {
                case idle
                case noMatch

                var message: String? {
                    switch self {
                    case .idle: return nil
                    case .noMatch: return "No matches"
                    }
                }

                var color: Color {
                    switch self {
                    case .idle: return .secondary
                    case .noMatch: return Color.red
                    }
                }
            }

            struct ButtonPreference: Equatable {
                let id: UUID
                let width: CGFloat
                let midX: CGFloat
            }

            struct ButtonPreferenceKey: PreferenceKey {
                static var defaultValue: [ButtonPreference] = []

                static func reduce(value: inout [ButtonPreference], nextValue: () -> [ButtonPreference]) {
                    value.append(contentsOf: nextValue())
                }
            }

            struct Toolbar: View {
                var fontSize: CGFloat
                var files: [SessionSavedFile]
                var selectedID: UUID?
                var onAdd: () -> Void
                var onSelect: (UUID?) -> Void
                var onOpenTree: (UUID) -> Void
                var onRename: (UUID) -> Void
                var onDelete: (UUID) -> Void
                var onReorder: ((Int, Int) -> Void)?
                var onPopOut: (() -> Void)?
                var onFormatTree: ((UUID) -> Void)?
                var onFormatLine: ((UUID) -> Void)?
                var onCompare: (() -> Void)?
                var onCompareWith: ((UUID) -> Void)?

                @State private var draggedFileID: UUID? = nil
                @State private var dragStartIndex: Int? = nil
                @State private var currentDragIndex: Int? = nil
                @State private var buttonWidths: [UUID: CGFloat] = [:]
                @State private var buttonPositions: [UUID: CGFloat] = [:]
                @State private var accumulatedDragDistance: CGFloat = 0

                var body: some View {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 8) {
                            HStack(spacing: -8) {
                                if let onPopOut {
                                    Button {
                                        onPopOut()
                                    } label: {
                                        Label("Pop Out", systemImage: "rectangle.expand.vertical")
                                            .font(.system(size: (fontSize - 1) * 3, weight: .semibold))
                                            .padding(.leading, 36)
                                            .padding(.trailing, 20)
                                            .padding(.vertical, 18)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.extraLarge)
                                    .tint(Theme.accent)
                                }

                                if selectedID != nil {
                                    Button {
                                        if let id = selectedID {
                                            onOpenTree(id)
                                        }
                                    } label: {
                                        Label("Structure", systemImage: "point.3.connected.trianglepath.dotted")
                                            .font(.system(size: fontSize - 1, weight: .semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.accent)
                                }

                                // JSON formatting buttons - only show for JSON files
                                if let selectedID = selectedID,
                                   let selectedFile = files.first(where: { $0.id == selectedID }),
                                   selectedFile.format == .json {

                                    Button {
                                        if let onFormatTree {
                                            onFormatTree(selectedID)
                                        }
                                    } label: {
                                        Image(systemName: "list.bullet.indent")
                                            .font(.system(size: fontSize - 1, weight: .semibold))
                                    }
                                    .help("Format JSON (Tree)")
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(Theme.accent)

                                    Button {
                                        if let onFormatLine {
                                            onFormatLine(selectedID)
                                        }
                                    } label: {
                                        Image(systemName: "minus.rectangle")
                                            .font(.system(size: fontSize - 1, weight: .semibold))
                                    }
                                    .help("Minify JSON (Line)")
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .tint(Theme.accent)
                                }
                            }

                            // Compare Files button - show if there are at least 2 files
                            if files.count >= 2, let onCompare {
                                Button {
                                    onCompare()
                                } label: {
                                    Label("Compare", systemImage: "doc.on.doc")
                                        .font(.system(size: fontSize - 1, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.purple)
                            }

                            Button {
                                onAdd()
                            } label: {
                                Label("Add", systemImage: "plus")
                                    .font(.system(size: fontSize - 1, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.purple)

                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                                            let isSelected = file.id == selectedID
                                            let isDraggingThis = draggedFileID == file.id

                                            Button {
                                                if draggedFileID == nil {
                                                    onSelect(file.id)
                                                }
                                            } label: {
                                                Text(file.displayName)
                                                    .font(.system(size: fontSize - 1, weight: isSelected ? .semibold : .regular))
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 6)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(isSelected ? Theme.purple : Theme.purple.opacity(0.3))
                                            .opacity(isDraggingThis ? 0.6 : 1.0)
                                            .background(
                                                GeometryReader { geo in
                                                    Color.clear.preference(
                                                        key: ButtonPreferenceKey.self,
                                                        value: [ButtonPreference(
                                                            id: file.id,
                                                            width: geo.size.width,
                                                            midX: geo.frame(in: .named("fileButtonsScrollView")).midX
                                                        )]
                                                    )
                                                }
                                            )
                                            .contextMenu {
                                                Button("Structure View") { onOpenTree(file.id) }
                                                if files.count >= 2, let onCompareWith {
                                                    Button("Compare with this file...") { onCompareWith(file.id) }
                                                }
                                                Button("Rename…") { onRename(file.id) }
                                                Divider()
                                                if index > 0, let onReorder = onReorder {
                                                    Button("Move Left") { onReorder(index, index - 1) }
                                                }
                                                if index < files.count - 1, let onReorder = onReorder {
                                                    Button("Move Right") { onReorder(index, index + 1) }
                                                }
                                                Divider()
                                                Button("Delete", role: .destructive) { onDelete(file.id) }
                                            }
                                            .simultaneousGesture(
                                                DragGesture(minimumDistance: 5, coordinateSpace: .named("fileButtonsScrollView"))
                                                    .onChanged { value in
                                                        if draggedFileID == nil {
                                                            draggedFileID = file.id
                                                            dragStartIndex = index
                                                            currentDragIndex = index
                                                            accumulatedDragDistance = 0
                                                            LOG("Drag started", ctx: ["file": file.displayName, "index": "\(index)"])
                                                        }

                                                        guard draggedFileID == file.id,
                                                              let currentIdx = currentDragIndex,
                                                              let onReorder = onReorder else { return }

                                                        // Get current mouse position
                                                        let dragX = value.location.x

                                                        // Check if we need to swap with adjacent button
                                                        // Look at the button to the left
                                                        if currentIdx > 0 {
                                                            let leftIdx = currentIdx - 1
                                                            if let leftFile = files[safe: leftIdx],
                                                               let leftMidX = buttonPositions[leftFile.id] {
                                                                // If mouse crosses the midpoint of the left button, swap
                                                                if dragX < leftMidX {
                                                                    LOG("Crossed left midpoint", ctx: [
                                                                        "file": file.displayName,
                                                                        "from": "\(currentIdx)",
                                                                        "to": "\(leftIdx)",
                                                                        "dragX": "\(Int(dragX))",
                                                                        "leftMidX": "\(Int(leftMidX))"
                                                                    ])
                                                                    onReorder(currentIdx, leftIdx)
                                                                    currentDragIndex = leftIdx
                                                                    return
                                                                }
                                                            }
                                                        }

                                                        // Look at the button to the right
                                                        if currentIdx < files.count - 1 {
                                                            let rightIdx = currentIdx + 1
                                                            if let rightFile = files[safe: rightIdx],
                                                               let rightMidX = buttonPositions[rightFile.id] {
                                                                // If mouse crosses the midpoint of the right button, swap
                                                                if dragX > rightMidX {
                                                                    LOG("Crossed right midpoint", ctx: [
                                                                        "file": file.displayName,
                                                                        "from": "\(currentIdx)",
                                                                        "to": "\(rightIdx)",
                                                                        "dragX": "\(Int(dragX))",
                                                                        "rightMidX": "\(Int(rightMidX))"
                                                                    ])
                                                                    onReorder(currentIdx, rightIdx)
                                                                    currentDragIndex = rightIdx
                                                                    return
                                                                }
                                                            }
                                                        }
                                                    }
                                                    .onEnded { _ in
                                                        LOG("Drag ended", ctx: [
                                                            "file": file.displayName,
                                                            "startIndex": "\(dragStartIndex ?? -1)",
                                                            "endIndex": "\(currentDragIndex ?? -1)"
                                                        ])
                                                        draggedFileID = nil
                                                        dragStartIndex = nil
                                                        currentDragIndex = nil
                                                        accumulatedDragDistance = 0
                                                    }
                                            )
                                            .id(file.id)
                                        }
                                    }
                                    .coordinateSpace(name: "fileButtonsScrollView")
                                    .onPreferenceChange(ButtonPreferenceKey.self) { prefs in
                                        for pref in prefs {
                                            buttonWidths[pref.id] = pref.width
                                            buttonPositions[pref.id] = pref.midX
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                                .onChange(of: selectedID) { _, newValue in
                                    guard let newValue else { return }
                                    withAnimation {
                                        proxy.scrollTo(newValue, anchor: .center)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                        }
                    }
                }
            }

            var fontSize: CGFloat
            var files: [SessionSavedFile]
            var selectedID: UUID?
            var draftProvider: (UUID) -> String
            var validationProvider: (UUID) -> JSONValidationState
            var onAdd: () -> Void
            var onSelect: (UUID?) -> Void
            var onDelete: (UUID) -> Void
            var onRename: (UUID) -> Void
            var onContentChange: (UUID, String) -> Void
            var onFocusChange: (Bool) -> Void
            var onOpenTree: (UUID) -> Void
            var onFormatTree: ((UUID) -> Void)? = nil
            var onFormatLine: ((UUID) -> Void)? = nil
            var onSearchCancel: () -> Void
            var isSearchFieldFocused: FocusState<Bool>.Binding
            var editorMinHeight: CGFloat

            @StateObject private var editorController = JSONEditorController()
            @State private var searchQuery: String = ""
            @State private var searchStatus: SearchStatus = .idle

            var body: some View {
                VStack(alignment: .leading, spacing: 0) {
                    searchControls
                        .padding(.top, -20)
                        .padding(.bottom, 8)

                    if let selectedID, let selectedFile = files.first(where: { $0.id == selectedID }) {
                        let binding = Binding<String>(
                            get: { draftProvider(selectedID) },
                            set: { onContentChange(selectedID, $0) }
                        )

                        JSONEditor(
                            text: binding,
                            fontSize: fontSize * 1.35,
                            fileType: selectedFile.format,
                            onFocusChanged: onFocusChange,
                            controller: editorController,
                            onFindCommand: {
                                guard selectedID != nil else { return }
                                DispatchQueue.main.async {
                                    isSearchFieldFocused.wrappedValue = true
                                }
                            }
                        )
                        .padding(.top, -8)
                        .frame(maxWidth: .infinity, minHeight: editorMinHeight, maxHeight: .infinity, alignment: .top)
                        .clipped()
                        .layoutPriority(1)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(hex: "#2A2A35"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                                )
                        )

                        validationView(for: validationProvider(selectedID))
                            .padding(.top, 4)
                    } else {
                            emptyState
                    }
                }
                .padding(.top, 0)
                .onChange(of: selectedID) { _, newValue in
                    searchStatus = .idle
                    searchQuery = ""
                    if newValue != nil {
                        DispatchQueue.main.async {
                            editorController.focus()
                        }
                    }
                    isSearchFieldFocused.wrappedValue = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
            }

            private var searchControls: some View {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        TextField("Search within file", text: $searchQuery, onCommit: {
                            performSearch(.forward)
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize - 2, weight: .regular, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .disabled(selectedID == nil)
                        .focused(isSearchFieldFocused)
                        .onKeyPress(.escape) {
                            isSearchFieldFocused.wrappedValue = false
                            onSearchCancel()
                            return .handled
                        }
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                                searchStatus = .idle
                                editorController.focus()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: fontSize - 2))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedID == nil)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Theme.grayBG.opacity(0.35))
                    )
                    .overlay(
                        Capsule()
                            .stroke(Theme.purple.opacity(0.3), lineWidth: 1)
                    )
                    .frame(maxWidth: 260)

                    Button {
                        performSearch(.backward)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedID == nil || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        performSearch(.forward)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.purple)
                    .disabled(selectedID == nil || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let message = searchStatus.message {
                        Text(message)
                            .font(.system(size: fontSize - 4, weight: .medium))
                            .foregroundStyle(searchStatus.color)
                            .transition(.opacity)
                    }

                    Spacer()
                }
            }

            private func performSearch(_ direction: JSONEditor.SearchDirection) {
                let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    NSSound.beep()
                    return
                }
                let found = editorController.find(trimmed, direction: direction, wrap: true)
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchStatus = found ? .idle : .noMatch
                }
            }

            @ViewBuilder
            private func validationView(for state: JSONValidationState) -> some View {
                let formatLabel: String = {
                    guard let selectedID = selectedID,
                          let file = files.first(where: { $0.id == selectedID }) else {
                        return "JSON"
                    }
                    return file.format.rawValue.uppercased()
                }()

                switch state {
                case .valid:
                    Label("Valid \(formatLabel)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(Theme.accent)
                case .invalid(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Invalid \(formatLabel)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: fontSize - 2, weight: .semibold))
                            .foregroundStyle(Color.red)
                        Text(message)
                            .font(.system(size: fontSize - 3, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            private var emptyState: some View {
                VStack(spacing: 12) {
                    Text("add json or yaml text here")
                        .font(.system(size: fontSize - 1))
                        .foregroundStyle(.secondary)
                    Button {
                        onAdd()
                    } label: {
                        Label("Add Saved File", systemImage: "plus")
                            .font(.system(size: fontSize - 1, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.purple)
                }
                .frame(maxWidth: .infinity,
                       minHeight: editorMinHeight,
                       maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.grayBG.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.purple.opacity(0.15), lineWidth: 1)
                        )
                )
                .layoutPriority(1)
            }
        }
    }

#if canImport(AppKit)
    private struct SheetWindowConfigurator: NSViewRepresentable {
        let minSize: CGSize
        let preferredSize: CGSize
        let sizeStorageKey: String

        func makeCoordinator() -> Coordinator {
            Coordinator(minSize: minSize, preferredSize: preferredSize, storageKey: sizeStorageKey)
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async {
                context.coordinator.configureIfNeeded(for: view)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                context.coordinator.configureIfNeeded(for: nsView)
            }
        }

        final class Coordinator: NSObject, NSWindowDelegate {
            private weak var window: NSWindow?
            private let minSize: CGSize
            private let preferredSize: CGSize
            private let storageKey: String
            private var lastAppliedSize: CGSize?
            private var isUserResizing: Bool = false
            private let sizeTolerance: CGFloat = 0.5

            init(minSize: CGSize, preferredSize: CGSize, storageKey: String) {
                self.minSize = minSize
                self.preferredSize = preferredSize
                self.storageKey = storageKey
            }

            func configureIfNeeded(for view: NSView) {
                guard let window = view.window else { return }
                if self.window === window { return }

                self.window = window
                window.delegate = self
                window.styleMask.insert([.titled, .resizable])
                window.minSize = minSize

                let autosaveName = "SQLMaestro.\(storageKey)"
                window.setFrameAutosaveName(autosaveName)
                let restored = window.setFrameUsingName(autosaveName)
                LOG("Sheet window attached", ctx: [
                    "key": storageKey,
                    "restored": restored ? "1" : "0",
                    "initialFrame": format(window.frame.size)
                ])

                if let savedSize = loadSavedSize() {
                    apply(size: savedSize, to: window)
                } else {
                    apply(size: preferredSize, to: window)
                }

                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }

            func windowWillStartLiveResize(_ notification: Notification) {
                isUserResizing = true
            }

            func windowDidResize(_ notification: Notification) {
                guard let window else { return }
                guard !isUserResizing else { return }
                guard let current = window.contentView?.frame.size,
                      let saved = loadSavedSize() else { return }

                if shouldRestore(current: current, saved: saved) {
                    LOG("Sheet size restore triggered", ctx: [
                        "key": storageKey,
                        "current": format(current),
                        "target": format(saved)
                    ])
                    apply(size: saved, to: window)
                }
            }

            func windowDidEndLiveResize(_ notification: Notification) {
                isUserResizing = false
                persistCurrentSize(reason: "liveResizeEnd")
            }

            func windowDidMove(_ notification: Notification) {
                guard isUserResizing else { return }
                persistCurrentSize(reason: "move")
            }

            func windowWillClose(_ notification: Notification) {
                persistCurrentSize(reason: "close")
                window = nil
            }

            private func apply(size: CGSize, to window: NSWindow) {
                let clipped = CGSize(width: max(minSize.width, size.width),
                                     height: max(minSize.height, size.height))
                window.setContentSize(clipped)
                lastAppliedSize = clipped
                LOG("Sheet size applied", ctx: [
                    "key": storageKey,
                    "size": format(clipped)
                ])
            }

            private func persistCurrentSize(reason: String) {
                guard let current = window?.contentView?.frame.size else { return }
                let clipped = CGSize(width: max(minSize.width, current.width),
                                     height: max(minSize.height, current.height))
                guard !approximatelyEqual(clipped, lastAppliedSize, tolerance: sizeTolerance) else { return }
                lastAppliedSize = clipped

                let defaults = UserDefaults.standard
                defaults.set(Double(clipped.width), forKey: "\(storageKey).width")
                defaults.set(Double(clipped.height), forKey: "\(storageKey).height")
                LOG("Sheet size persisted", ctx: [
                    "key": storageKey,
                    "size": format(clipped),
                    "reason": reason
                ])
            }

            private func loadSavedSize() -> CGSize? {
                let defaults = UserDefaults.standard
                let width = defaults.double(forKey: "\(storageKey).width")
                let height = defaults.double(forKey: "\(storageKey).height")
                guard width > 0, height > 0 else { return nil }
                let size = CGSize(width: width, height: height)
                LOG("Sheet size loaded", ctx: [
                    "key": storageKey,
                    "size": format(size)
                ])
                return size
            }

            private func format(_ size: CGSize) -> String {
                String(format: "%.0fx%.0f", size.width, size.height)
            }

            private func shouldRestore(current: CGSize, saved: CGSize) -> Bool {
                guard !approximatelyEqual(current, saved, tolerance: sizeTolerance) else { return false }
                // Only restore when the saved size is larger than the current programmatic shrink.
                if saved.width >= current.width + sizeTolerance || saved.height >= current.height + sizeTolerance {
                    return true
                }
                return false
            }

            private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat) -> Bool {
                return abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
            }

            private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize?, tolerance: CGFloat) -> Bool {
                guard let rhs else { return false }
                return abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
            }
        }
    }

    private struct FloatingWindowConfigurator: NSViewRepresentable {
        let level: NSWindow.Level

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async {
                configureWindow(for: view)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                configureWindow(for: nsView)
            }
        }

        private func configureWindow(for view: NSView) {
            guard let window = view.window else { return }
            window.level = level
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            window.isMovableByWindowBackground = true
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private struct WindowSizeUpdater: NSViewRepresentable {
        let size: CGSize

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            DispatchQueue.main.async {
                applySize(using: view)
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            DispatchQueue.main.async {
                applySize(using: nsView)
            }
        }

        private func applySize(using view: NSView) {
            guard let window = view.window else { return }
            let targetWidth = max(size.width, window.minSize.width)
            let targetHeight = max(size.height, window.minSize.height)
            let currentSize = window.contentView?.frame.size ?? .zero

            if abs(currentSize.width - targetWidth) > 0.5 ||
                abs(currentSize.height - targetHeight) > 0.5 {
                window.setContentSize(CGSize(width: targetWidth, height: targetHeight))
            }
        }
    }

    private struct KeyboardShortcutOverlay: View {
        let onTrigger: () -> Void

        var body: some View {
            Button(action: onTrigger) {
                EmptyView()
            }
            .keyboardShortcut("e", modifiers: [.command])
            .buttonStyle(.plain)
            .opacity(0.0001)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
    }
#else
    private struct SheetWindowConfigurator: View {
        let minSize: CGSize
        let preferredSize: CGSize
        let sizeStorageKey: String

        var body: some View { EmptyView() }
    }

    private struct FloatingWindowConfigurator: View {
        let level: Int

        var body: some View { EmptyView() }
    }

    private struct WindowSizeUpdater: View {
        let size: CGSize

        var body: some View { EmptyView() }
    }

    private struct KeyboardShortcutOverlay: View {
        let onTrigger: () -> Void

        var body: some View { EmptyView() }
    }
#endif

    // MARK: – Guide + Session Notes Popout
    struct PanePopoutSheet: View {
        let pane: PopoutPaneContext
        var fontSize: CGFloat
        var editorMinHeight: CGFloat
        var selectedTemplate: TemplateItem?
        @Binding var guideText: String
        var guideDirty: Bool
        @ObservedObject var guideController: MarkdownEditorController
        @Binding var isPreview: Bool
        let onGuideSave: () -> Void
        let onGuideRevert: () -> Void
        let onGuideTextChanged: (String) -> Void
        let onGuideLinkRequested: (_ selectedText: String, _ source: MarkdownEditor.LinkRequestSource, _ completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) -> Void
        let onGuideImageAttachment: (MarkdownEditor.ImageDropInfo) -> MarkdownEditor.ImageInsertion?
        let onGuideLinkOpen: (URL, NSEvent.ModifierFlags) -> Void

        var session: TicketSession
        @Binding var sessionDraft: String
        var sessionSavedValue: String
        @ObservedObject var sessionController: MarkdownEditorController
        var savedFiles: [SessionSavedFile]
        var selectedSavedFileID: UUID?
        var savedFileDraftProvider: (UUID) -> String
        var savedFileValidationProvider: (UUID) -> JSONValidationState
        let onSavedFileSelect: (UUID?) -> Void
        let onSavedFileAdd: () -> Void
        let onSavedFileDelete: (UUID) -> Void
        let onSavedFileRename: (UUID) -> Void
        let onSavedFileReorder: (Int, Int) -> Void
        let onSavedFileContentChange: (UUID, String) -> Void
        let onSavedFileFocusChange: (Bool) -> Void
        let onSavedFileOpenTree: (UUID) -> Void
        let onSavedFileFormatTree: ((UUID) -> Void)?
        let onSavedFileFormatLine: ((UUID) -> Void)?
        let onSavedFilesModeExit: () -> Void
        let onSessionSave: () -> Void
        let onSessionRevert: () -> Void
        let onSessionLinkRequested: (_ selectedText: String, _ source: MarkdownEditor.LinkRequestSource, _ completion: @escaping (MarkdownEditor.LinkInsertion?) -> Void) -> Void
        let onSessionImageAttachment: (MarkdownEditor.ImageDropInfo) -> MarkdownEditor.ImageInsertion?
        let onSessionLinkOpen: (URL, NSEvent.ModifierFlags) -> Void
        let onClose: () -> Void
        let onTogglePreview: () -> Void
        let onImagePreview: () -> Void
        let onImagePreviewClose: () -> Void

        @FocusState private var popoutSavedFileSearchFocused: Bool
        @FocusState private var popoutGuideNotesSearchFocused: Bool
        @FocusState private var popoutSessionNotesSearchFocused: Bool
        @State private var shouldReopenAfterPreview = false
        @State private var popoutGuideNotesSearchQuery: String = ""
        @State private var popoutGuideNotesSearchMatches: [Range<String.Index>] = []
        @State private var popoutGuideNotesCurrentMatchIndex: Int = 0
        @State private var popoutSessionNotesSearchQuery: String = ""
        @State private var popoutSessionNotesSearchMatches: [Range<String.Index>] = []
        @State private var popoutSessionNotesCurrentMatchIndex: Int = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(20)
            .frame(minWidth: preferredSize.width, minHeight: preferredSize.height)
            .background(
                SheetWindowConfigurator(
                    minSize: preferredSize,
                    preferredSize: CGSize(width: preferredSize.width, height: preferredSize.height + 40),
                    sizeStorageKey: storageKey
                )
            )
            .onDisappear {
                if shouldReopenAfterPreview {
                    shouldReopenAfterPreview = false
                    onImagePreviewClose()
                } else {
                    onClose()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
                handlePopoutFocusSearch()
            }
        }

        private func handlePopoutFocusSearch() {
            // In popouts, Cmd+F should only focus the search field for that pane
            // It should NOT toggle to query template search
            switch pane {
            case .guide:
                // If in preview mode, switch to edit mode first
                if isPreview {
                    onTogglePreview()
                }
                popoutGuideNotesSearchFocused = true
            case .session:
                // If in preview mode, switch to edit mode first
                if isPreview {
                    onTogglePreview()
                }
                popoutSessionNotesSearchFocused = true
            case .saved:
                // Saved files workspace handles its own search
                popoutSavedFileSearchFocused = true
            case .sessionTemplate:
                break // Not handled here
            }
        }

        @ViewBuilder
        private var header: some View {
            HStack(alignment: .center, spacing: 12) {
                switch pane {
                case .guide:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Guide Notes")
                            .font(.system(size: fontSize + 4, weight: .semibold))
                            .foregroundStyle(Theme.aqua)
                        if let template = selectedTemplate {
                            Text(template.name)
                                .font(.system(size: fontSize - 1, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No template selected")
                                .font(.system(size: fontSize - 2))
                                .foregroundStyle(.secondary)
                        }
                    }
                case .session(let s):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Session Notes")
                            .font(.system(size: fontSize + 4, weight: .semibold))
                            .foregroundStyle(Theme.paneLabelColor)
                        Text("Session #\(s.rawValue)")
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                case .saved(let s):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saved Files")
                            .font(.system(size: fontSize + 4, weight: .semibold))
                            .foregroundStyle(Theme.paneLabelColor)
                        Text("Session #\(s.rawValue)")
                            .font(.system(size: fontSize - 1, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                case .sessionTemplate:
                    EmptyView() // This case is handled separately in popoutSheet
                }

                Spacer()

                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
                    .font(.system(size: fontSize - 1))

                if case .guide = pane, guideDirty {
                    Button("Save") { onGuideSave() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize - 1))
                    Button("Revert") { onGuideRevert() }
                        .buttonStyle(.bordered)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 1))
                }

                if case .session = pane, sessionDraft != sessionSavedValue {
                    Button("Save") { onSessionSave() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                        .font(.system(size: fontSize - 1))
                    Button("Revert") { onSessionRevert() }
                        .buttonStyle(.bordered)
                        .tint(Theme.pink)
                        .font(.system(size: fontSize - 1))
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            switch pane {
            case .guide:
                guideBody
            case .session:
                sessionBody
            case .saved:
                SessionNotesInline(
                    fontSize: fontSize,
                    editorMinHeight: editorMinHeight,
                    session: session,
                    draft: $sessionDraft,
                    savedValue: sessionSavedValue,
                    controller: sessionController,
                    isPreview: $isPreview,
                    mode: .constant(.savedFiles),
                    savedFiles: savedFiles,
                    selectedSavedFileID: selectedSavedFileID,
                    savedFileDraft: savedFileDraftProvider,
                    savedFileValidation: savedFileValidationProvider,
                    onSavedFileSelect: onSavedFileSelect,
                    onSavedFileAdd: onSavedFileAdd,
                    onSavedFileDelete: onSavedFileDelete,
                    onSavedFileRename: onSavedFileRename,
                    onSavedFileReorder: onSavedFileReorder,
                    onSavedFileContentChange: onSavedFileContentChange,
                    onSavedFileFocusChanged: onSavedFileFocusChange,
                    onSavedFileOpenTree: onSavedFileOpenTree,
                    onSavedFileFormatTree: onSavedFileFormatTree,
                    onSavedFileFormatLine: onSavedFileFormatLine,
                    onSavedFileSearchCancel: {
                        // No-op for popout windows
                    },
                    savedFileSearchFocused: $popoutSavedFileSearchFocused,
                    onSavedFilesModeExit: onSavedFilesModeExit,
                    onSavedFilesPopout: nil,
                    onSave: onSessionSave,
                    onRevert: onSessionRevert,
                    onLinkRequested: onSessionLinkRequested,
                    onLinkOpen: wrappedSessionLinkOpen,
                    onImageAttachment: onSessionImageAttachment,
                    showsModePicker: false,
                    showsModeToolbar: true,
                    showsOuterBackground: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay(
                    KeyboardShortcutOverlay(onTrigger: onTogglePreview)
                )
            case .sessionTemplate:
                EmptyView() // This case is handled separately in popoutSheet
            }
        }

        private var guideBody: some View {
            Group {
                if selectedTemplate != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !isPreview, controller: guideController)
                            PreviewModeToggle(isPreview: $isPreview)

                            InPaneSearchBar(
                                searchQuery: $popoutGuideNotesSearchQuery,
                                matchCount: popoutGuideNotesSearchMatches.count,
                                currentMatchIndex: popoutGuideNotesCurrentMatchIndex,
                                onPrevious: { navigateToPopoutGuideNotesPreviousMatch() },
                                onNext: { navigateToPopoutGuideNotesNextMatch() },
                                onEnter: { handlePopoutGuideNotesSearchEnter() },
                                onCancel: {
                                    popoutGuideNotesSearchFocused = false
                                    popoutGuideNotesSearchQuery = ""
                                },
                                fontSize: fontSize,
                                isSearchFocused: $popoutGuideNotesSearchFocused
                            )

                            Spacer(minLength: 0)
                        }
                        .onChange(of: popoutGuideNotesSearchQuery) { _, _ in
                            updatePopoutGuideNotesSearchMatches()
                        }
                        .onChange(of: guideText) { _, _ in
                            if !popoutGuideNotesSearchQuery.isEmpty {
                                updatePopoutGuideNotesSearchMatches()
                            }
                        }

                        Group {
                            if isPreview {
                                MarkdownPreviewView(
                                    text: guideText,
                                    fontSize: fontSize * 1.5,
                                    onLinkOpen: wrappedGuideLinkOpen
                                )
                            } else {
                                MarkdownEditor(
                                    text: $guideText,
                                    fontSize: fontSize * 1.5,
                                    controller: guideController,
                                    onLinkRequested: onGuideLinkRequested,
                                    onImageAttachment: { info in
                                        onGuideImageAttachment(info)
                                    },
                                    onFocusChange: { focused in
                                        // When editor gains focus, clear search (same as clicking 'x')
                                        if focused {
                                            popoutGuideNotesSearchFocused = false
                                            popoutGuideNotesSearchQuery = ""
                                        }
                                    }
                                )
                                .onChange(of: guideText) { _, newValue in
                                    onGuideTextChanged(newValue)
                                }
                            }
                        }
                        .frame(minHeight: 320)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(hex: "#2A2A35"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                                )
                        )
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a template to view its troubleshooting guide")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.grayBG.opacity(0.2))
                    )
                }
            }
            .overlay(
                KeyboardShortcutOverlay(onTrigger: onTogglePreview)
            )
        }

        private var sessionBody: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MarkdownToolbar(iconSize: fontSize + 2, isEnabled: !isPreview, controller: sessionController)
                    PreviewModeToggle(isPreview: $isPreview)

                    InPaneSearchBar(
                        searchQuery: $popoutSessionNotesSearchQuery,
                        matchCount: popoutSessionNotesSearchMatches.count,
                        currentMatchIndex: popoutSessionNotesCurrentMatchIndex,
                        onPrevious: { navigateToPopoutSessionNotesPreviousMatch() },
                        onNext: { navigateToPopoutSessionNotesNextMatch() },
                        onEnter: { handlePopoutSessionNotesSearchEnter() },
                        onCancel: {
                            popoutSessionNotesSearchFocused = false
                            popoutSessionNotesSearchQuery = ""
                        },
                        fontSize: fontSize,
                        isSearchFocused: $popoutSessionNotesSearchFocused
                    )

                    Spacer(minLength: 0)

                    if sessionDraft != sessionSavedValue {
                        Button("Save") { onSessionSave() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.purple)
                            .font(.system(size: fontSize - 1))
                        Button("Revert") { onSessionRevert() }
                            .buttonStyle(.bordered)
                            .tint(Theme.pink)
                            .font(.system(size: fontSize - 1))
                    }
                }
                .onChange(of: popoutSessionNotesSearchQuery) { _, _ in
                    updatePopoutSessionNotesSearchMatches()
                }
                .onChange(of: sessionDraft) { _, _ in
                    if !popoutSessionNotesSearchQuery.isEmpty {
                        updatePopoutSessionNotesSearchMatches()
                    }
                }

                Group {
                    if isPreview {
                        MarkdownPreviewView(
                            text: sessionDraft,
                            fontSize: fontSize * 1.5,
                            onLinkOpen: wrappedSessionLinkOpen
                        )
                    } else {
                        MarkdownEditor(
                            text: $sessionDraft,
                            fontSize: fontSize * 1.5,
                            controller: sessionController,
                            onLinkRequested: onSessionLinkRequested,
                            onImageAttachment: { info in
                                onSessionImageAttachment(info)
                            },
                            onFocusChange: { focused in
                                // When editor gains focus, clear search (same as clicking 'x')
                                if focused {
                                    popoutSessionNotesSearchFocused = false
                                    popoutSessionNotesSearchQuery = ""
                                }
                            }
                        )
                    }
                }
                .frame(minHeight: editorMinHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(hex: "#2A2A35"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Theme.purple.opacity(0.25), lineWidth: 1)
                        )
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(
                KeyboardShortcutOverlay(onTrigger: onTogglePreview)
            )
        }

        private func updatePopoutGuideNotesSearchMatches() {
            guard !popoutGuideNotesSearchQuery.isEmpty else {
                popoutGuideNotesSearchMatches = []
                popoutGuideNotesCurrentMatchIndex = 0
                return
            }

            let text = guideText
            var matches: [Range<String.Index>] = []
            var searchStartIndex = text.startIndex

            while searchStartIndex < text.endIndex,
                  let range = text.range(of: popoutGuideNotesSearchQuery,
                                        options: .caseInsensitive,
                                        range: searchStartIndex..<text.endIndex) {
                matches.append(range)
                searchStartIndex = range.upperBound
            }

            popoutGuideNotesSearchMatches = matches
            popoutGuideNotesCurrentMatchIndex = matches.isEmpty ? 0 : 0

            if !matches.isEmpty {
                scrollToPopoutGuideNotesMatch()
            }
        }

        private func navigateToPopoutGuideNotesPreviousMatch() {
            guard !popoutGuideNotesSearchMatches.isEmpty else { return }
            popoutGuideNotesCurrentMatchIndex = (popoutGuideNotesCurrentMatchIndex - 1 + popoutGuideNotesSearchMatches.count) % popoutGuideNotesSearchMatches.count
            scrollToPopoutGuideNotesMatch()
        }

        private func navigateToPopoutGuideNotesNextMatch() {
            guard !popoutGuideNotesSearchMatches.isEmpty else { return }
            popoutGuideNotesCurrentMatchIndex = (popoutGuideNotesCurrentMatchIndex + 1) % popoutGuideNotesSearchMatches.count
            scrollToPopoutGuideNotesMatch()
        }

        private func scrollToPopoutGuideNotesMatch() {
            guard popoutGuideNotesCurrentMatchIndex < popoutGuideNotesSearchMatches.count else { return }
            let range = popoutGuideNotesSearchMatches[popoutGuideNotesCurrentMatchIndex]

            let text = guideText
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)

            guideController.selectAndScrollToRange(offset: offset, length: length)
        }

        private func handlePopoutGuideNotesSearchEnter() {
            guard !popoutGuideNotesSearchQuery.isEmpty else { return }

            if isPreview {
                onTogglePreview()
            }

            if !popoutGuideNotesSearchMatches.isEmpty {
                navigateToPopoutGuideNotesNextMatch()
            }
        }

        private func updatePopoutSessionNotesSearchMatches() {
            guard !popoutSessionNotesSearchQuery.isEmpty else {
                popoutSessionNotesSearchMatches = []
                popoutSessionNotesCurrentMatchIndex = 0
                return
            }

            let text = sessionDraft
            var matches: [Range<String.Index>] = []
            var searchStartIndex = text.startIndex

            while searchStartIndex < text.endIndex,
                  let range = text.range(of: popoutSessionNotesSearchQuery,
                                        options: .caseInsensitive,
                                        range: searchStartIndex..<text.endIndex) {
                matches.append(range)
                searchStartIndex = range.upperBound
            }

            popoutSessionNotesSearchMatches = matches
            popoutSessionNotesCurrentMatchIndex = matches.isEmpty ? 0 : 0

            if !matches.isEmpty {
                scrollToPopoutSessionNotesMatch()
            }
        }

        private func navigateToPopoutSessionNotesPreviousMatch() {
            guard !popoutSessionNotesSearchMatches.isEmpty else { return }
            popoutSessionNotesCurrentMatchIndex = (popoutSessionNotesCurrentMatchIndex - 1 + popoutSessionNotesSearchMatches.count) % popoutSessionNotesSearchMatches.count
            scrollToPopoutSessionNotesMatch()
        }

        private func navigateToPopoutSessionNotesNextMatch() {
            guard !popoutSessionNotesSearchMatches.isEmpty else { return }
            popoutSessionNotesCurrentMatchIndex = (popoutSessionNotesCurrentMatchIndex + 1) % popoutSessionNotesSearchMatches.count
            scrollToPopoutSessionNotesMatch()
        }

        private func scrollToPopoutSessionNotesMatch() {
            guard popoutSessionNotesCurrentMatchIndex < popoutSessionNotesSearchMatches.count else { return }
            let range = popoutSessionNotesSearchMatches[popoutSessionNotesCurrentMatchIndex]

            let text = sessionDraft
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)

            sessionController.selectAndScrollToRange(offset: offset, length: length)
        }

        private func handlePopoutSessionNotesSearchEnter() {
            guard !popoutSessionNotesSearchQuery.isEmpty else { return }

            if isPreview {
                onTogglePreview()
            }

            if !popoutSessionNotesSearchMatches.isEmpty {
                navigateToPopoutSessionNotesNextMatch()
            }
        }

        private func wrappedGuideLinkOpen(_ url: URL, _ modifiers: NSEvent.ModifierFlags) {
            // Check if this is an image preview action
            let wantsPreview = modifiers.contains(.command)
            if url.isFileURL && wantsPreview {
                shouldReopenAfterPreview = true
                onImagePreview()
            }
            onGuideLinkOpen(url, modifiers)
        }

        private func wrappedSessionLinkOpen(_ url: URL, _ modifiers: NSEvent.ModifierFlags) {
            // Check if this is an image preview action
            let wantsPreview = modifiers.contains(.command)
            if url.isFileURL && wantsPreview {
                shouldReopenAfterPreview = true
                onImagePreview()
            }
            onSessionLinkOpen(url, modifiers)
        }

        private var preferredSize: CGSize {
            switch pane {
            case .guide:
                return CGSize(width: 960, height: 720)
            case .session:
                return CGSize(width: 940, height: 700)
            case .saved:
                return CGSize(width: 940, height: 700)
            case .sessionTemplate:
                return CGSize(width: 900, height: 700)
            }
        }

        private var storageKey: String {
            switch pane {
            case .guide:
                return "GuidePanePopoutSize"
            case .session:
                return "SessionPanePopoutSize"
            case .saved:
                return "SavedFilesPanePopoutSize"
            case .sessionTemplate:
                return "SessionTemplatePanePopoutSize"
            }
        }
    }

    // MARK: – Session & Template Pane Popout
    struct SessionTemplatePopoutSheet: View {
        var fontSize: CGFloat
        var session: TicketSession
        @Binding var selectedTab: SessionTemplateTab
        @ObservedObject var sessions: SessionManager
        @ObservedObject var templateGuideStore: TemplateGuideStore
        @ObservedObject var templateLinksStore: TemplateLinksStore
        var selectedTemplate: TemplateItem?
        let onClose: () -> Void
        let onImagePreview: (Any) -> Void
        let onImagePreviewClose: () -> Void
        let onSessionImageDelete: (SessionImage) -> Void
        let onSessionImageRename: (SessionImage) -> Void
        let onSessionImagePaste: () -> Void
        let onGuideImageDelete: (TemplateGuideImage) -> Void
        let onGuideImageRename: (TemplateGuideImage) -> Void
        let onGuideImageOpen: (TemplateGuideImage) -> Void
        let onGuideImagePaste: () -> Void
        let onTemplateLinkHover: (UUID?) -> Void
        let onTemplateLinkOpen: (TemplateLink) -> Void

        @State private var shouldReopenAfterPreview = false

        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(20)
            .frame(minWidth: 800, minHeight: 600)
            .background(
                SheetWindowConfigurator(
                    minSize: CGSize(width: 800, height: 600),
                    preferredSize: CGSize(width: 900, height: 700),
                    sizeStorageKey: "SessionTemplatePanePopoutSize"
                )
            )
            .onDisappear {
                if shouldReopenAfterPreview {
                    shouldReopenAfterPreview = false
                    onImagePreviewClose()
                } else {
                    onClose()
                }
            }
        }

        @ViewBuilder
        private var header: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session & Template")
                        .font(.system(size: fontSize + 4, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    Text("Session #\(session.rawValue)")
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
                    .font(.system(size: fontSize - 1))
            }
        }

        @ViewBuilder
        private var content: some View {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Tab", selection: $selectedTab) {
                    Text("Ses. Images").tag(SessionTemplateTab.sessionImages)
                    Text("Guide Images").tag(SessionTemplateTab.guideImages)
                    Text("Links").tag(SessionTemplateTab.templateLinks)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if selectedTab == .sessionImages {
                        buildSessionImagesView()
                    } else if selectedTab == .guideImages {
                        buildGuideImagesView()
                    } else {
                        buildLinksView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }

        @ViewBuilder
        private func buildSessionImagesView() -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Session \(session.rawValue) Images")
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(Theme.purple)

                    Spacer()

                    Button("Paste Screenshot") {
                        onSessionImagePaste()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.pink)
                    .font(.system(size: fontSize - 2))
                }

                let sessionImages = sessions.sessionImages[session] ?? []

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
                                    onDelete: { onSessionImageDelete($0) },
                                    onRename: { onSessionImageRename($0) },
                                    onPreview: { img in
                                        shouldReopenAfterPreview = true
                                        onImagePreview(img)
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
        }

        @ViewBuilder
        private func buildGuideImagesView() -> some View {
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
                        onGuideImagePaste()
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
                                        template: template,
                                        image: image,
                                        fontSize: fontSize,
                                        onOpen: { onGuideImageOpen(image) },
                                        onRename: { onGuideImageRename(image) },
                                        onDelete: { onGuideImageDelete(image) },
                                        onPreview: {
                                            shouldReopenAfterPreview = true
                                            let context = GuideImagePreviewContext(template: template, image: image)
                                            onImagePreview(context)
                                        }
                                    )
                                }
                            }
                            .padding(4)
                        }
                    }
                } else {
                    VStack {
                        Text("Select a template to view its guide images")
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

        @ViewBuilder
        private func buildLinksView() -> some View {
            VStack(alignment: .leading, spacing: 8) {
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
                }

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
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(templateLinks) { link in
                                    TemplateLinkRow(
                                        link: link,
                                        fontSize: fontSize,
                                        onOpen: { onTemplateLinkOpen(link) },
                                        onEdit: { },
                                        onDelete: { },
                                        hoveredLinkID: .constant(nil)
                                    )
                                    .onHover { hovering in
                                        if hovering {
                                            onTemplateLinkHover(link.id)
                                        } else {
                                            onTemplateLinkHover(nil)
                                        }
                                    }
                                }
                            }
                            .padding(4)
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

    private func focusTemplates(direction: Int) -> KeyPress.Result {
        guard !filteredTemplates.isEmpty else { return .ignored }
        if selectedTemplate == nil {
            let index = direction > 0 ? 0 : filteredTemplates.count - 1
            selectTemplate(filteredTemplates[index])
        }
        isListFocused = true
        return .handled
    }
}
