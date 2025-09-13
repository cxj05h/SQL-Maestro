import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var templates: TemplateManager
    @StateObject private var mapping = MappingStore()
    @EnvironmentObject var sessions: SessionManager
    
    @State private var selectedTemplate: TemplateItem?
    @State private var currentSQL: String = ""
    @State private var populatedSQL: String = ""
    @State private var toastCopied: Bool = false
    @State private var fontSize: CGFloat = 13
    
    @State private var searchText: String = ""
    
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    
    // Static fields
    @State private var orgId: String = ""
    @State private var acctId: String = ""
    @State private var mysqlDb: String = ""
    @State private var companyLabel: String = ""
    
    var body: some View {
        NavigationSplitView {
            // Query Templates Pane
            VStack(spacing: 8) {
                // Header with buttons
                HStack(spacing: 8) {
                    Text("Query Templates").font(.headline).foregroundStyle(Theme.purple)
                    Spacer()
                    Button("New Template") { createNewTemplateFlow() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                    Button("Reload") { templates.loadTemplates() }
                        .buttonStyle(.bordered)
                }
                
                // Search field - RIGHT UNDER THE HEADER
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
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
                            // Transfer focus to list and auto-select first result
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
                    }
                }
                
                // Enhanced List - RIGHT UNDER THE SEARCH
                List(filteredTemplates, selection: $selectedTemplate) { template in
                    HStack {
                        // Icon for visual appeal
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(selectedTemplate?.id == template.id ? .white : Theme.gold.opacity(0.6))
                            .font(.system(size: 14))
                        
                        // Template name
                        Text(template.name)
                            .font(.system(size: fontSize, weight: selectedTemplate?.id == template.id ? .medium : .regular))
                            .foregroundStyle(selectedTemplate?.id == template.id ? .white : .primary)  // CHANGED TO WHITE
                        
                        Spacer()
                        
                        // Placeholder count badge
                        if !template.placeholders.isEmpty {
                            Text("\(template.placeholders.count)")
                                .font(.caption2)
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
                        Divider()
                        Button("Rename…") { renameTemplateFlow(template) }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTemplate = template
                        }
                        LOG("Template selected", ctx: ["template": template.name])
                    }
                    .onTapGesture(count: 2) {
                        loadTemplate(template)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    if let selected = selectedTemplate {
                        loadTemplate(selected)
                        LOG("Template loaded via Enter key", ctx: ["template": selected.name])
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
                .onChange(of: searchText) { oldVal, newVal in
                    LOG("Template search", ctx: ["query": newVal, "results": "\(filteredTemplates.count)"])
                    
                    // Auto-select first result when searching
                    if !filteredTemplates.isEmpty && selectedTemplate == nil {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTemplate = filteredTemplates.first
                        }
                        LOG("Auto-selected first search result", ctx: ["template": filteredTemplates.first?.name ?? "none"])
                    }
                }
                .focused($isListFocused)
                
                // Search results info at the bottom
                if !searchText.isEmpty {
                    Text("\(filteredTemplates.count) of \(templates.templates.count) templates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Theme.grayBG)
        }
            detail: {
            // Right side: Fields + Output
            VStack(spacing: 12) {
                staticFields
                Divider()
                dynamicFields
                HStack {
                    Button("Populate Query") { populateQuery() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink)
                        .keyboardShortcut(.return, modifiers: [.command])
                    Button("Clear All Fields (Session)") {
                        // Clear session fields (dynamic fields)
                        sessions.clearAllFieldsForCurrentSession()
                        
                        // Clear static fields
                        orgId = ""
                        acctId = ""
                        mysqlDb = ""
                        companyLabel = ""
                        
                        LOG("All fields cleared (including static)", ctx: ["session": "\(sessions.current.rawValue)"])
                    }.buttonStyle(.bordered)
                        .keyboardShortcut("k", modifiers: [.command])
                    Spacer()
                    sessionButtons
                }
                outputView
                
                // Invisible button for focus search keyboard shortcut
                Button("Focus Search") {
                    isSearchFocused = true
                    LOG("Search focused via keyboard shortcut")
                }
                .keyboardShortcut("f", modifiers: [.command])
                .hidden()
            }
            .padding()
            .background(Theme.grayBG)
        }
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .top) {
            if toastCopied {
                Text("Copied to clipboard")
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Theme.aqua.opacity(0.9)).foregroundStyle(.black)
                    .clipShape(Capsule())
                    .padding(.top, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fontBump)) { note in
            if let delta = note.object as? Int {
                fontSize = max(10, min(22, fontSize + CGFloat(delta)))
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Text(selectedTemplate?.name ?? "No template loaded")
                    .font(.callout).foregroundStyle(Theme.gold)
            }
        }
        .onAppear {
            LOG("App started")
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
    
    // MARK: – Static fields (always visible)
    private var staticFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Static Info").font(.title3).foregroundStyle(Theme.purple)
            HStack {
                labeledField("Org-ID", text: $orgId, placeholder: "e.g., 606079893960")
                    .onChange(of: orgId) { oldVal, newVal in
                        if let m = mapping.lookup(orgId: newVal) {
                            mysqlDb = m.mysqlDb
                            companyLabel = m.companyName ?? ""
                        } else {
                            companyLabel = ""
                        }
                        LOG("OrgID changed", ctx: ["old": oldVal, "new": newVal])
                    }
                labeledField("Acct-ID", text: $acctId, placeholder: "e.g., 123456")
                VStack(alignment: .leading) {
                    HStack {
                        labeledField("MySQL DB", text: $mysqlDb, placeholder: "e.g., mySQL04")
                        Button("Save") {
                            saveMapping()
                        }.buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }
                    if !companyLabel.isEmpty {
                        Text("Company: \(companyLabel)")
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
    
    // MARK: – Dynamic fields from template placeholders
    private var dynamicFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Field Names").font(.title3).foregroundStyle(Theme.pink)
            if let t = selectedTemplate {
                // Filter out static placeholders that are already handled in the static section
                let staticPlaceholders = ["Org-ID", "Acct-ID"] // These are handled by static fields
                let dynamicPlaceholders = t.placeholders.filter { !staticPlaceholders.contains($0) }
                
                if dynamicPlaceholders.isEmpty {
                    Text("This template only uses static fields (Org-ID, Acct-ID).")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(dynamicPlaceholders, id: \.self) { ph in
                                dynamicFieldRow(ph)
                            }
                        }
                    }.frame(maxHeight: 260)
                }
            } else {
                Text("Load a template to see its fields.")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    //   this function inside ContentView (before the final closing brace):
    private func navigateTemplate(direction: Int) {
        guard !filteredTemplates.isEmpty else { return }
        
        if let currentIndex = filteredTemplates.firstIndex(where: { $0.id == selectedTemplate?.id }) {
            let newIndex = currentIndex + direction
            if newIndex >= 0 && newIndex < filteredTemplates.count {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedTemplate = filteredTemplates[newIndex]
                }
                LOG("Template navigation", ctx: ["direction": "\(direction)", "template": filteredTemplates[newIndex].name])
            }
        } else {
            // No selection, select first or last based on direction
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTemplate = direction > 0 ? filteredTemplates.first : filteredTemplates.last
            }
            LOG("Template navigation start", ctx: ["template": selectedTemplate?.name ?? "none"])
        }
    }
    
    
    
    private func dynamicFieldRow(_ placeholder: String) -> some View {
        let valBinding = Binding<String>(
            get: { sessions.value(for: placeholder) },
            set: { newVal in sessions.setValue(newVal, for: placeholder) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(placeholder).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Value for \(placeholder)", text: valBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: fontSize))
                Menu("Recent") {
                    let recents = sessions.globalRecents[placeholder] ?? []
                    if recents.isEmpty {
                        Text("No recent values")
                    } else {
                        ForEach(recents, id: \.self) { v in
                            Button(v) { sessions.setValue(v, for: placeholder) }
                        }
                    }
                }.menuStyle(.borderlessButton)
            }
        }
        .onTapGesture { LOG("Field focus", ctx: ["placeholder": placeholder]) }
    }
    
    // MARK: – Output area
    private var outputView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output SQL").font(.title3).foregroundStyle(Theme.aqua)
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
    
    private var sessionButtons: some View {
        HStack(spacing: 8) {
            ForEach(TicketSession.allCases, id: \.self) { s in
                Button(sessions.sessionNames[s] ?? "#\(s.rawValue)") {
                    sessions.setCurrent(s)
                }
                .contextMenu {
                    Button("Rename…") { promptRename(for: s) }
                }
                .buttonStyle(.borderedProminent)
                .tint(sessions.current == s ? Theme.purple : Theme.purple.opacity(0.4))
            }
        }
    }
    
    // MARK: – Actions
    private func loadTemplate(_ t: TemplateItem) {
        selectedTemplate = t
        currentSQL = t.rawSQL
        LOG("Template loaded", ctx: ["template": t.name, "phCount":"\(t.placeholders.count)"])
    }
    
    private func editTemplateInline(_ t: TemplateItem) {
        // simple in-app edit: open a small editor window
        TemplateEditorWindow.present(for: t, manager: templates)
        LOG("Inline edit open", ctx: ["template": t.name])
    }
    
    private func openInVSCode(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["code", url.path]
        try? task.run()
        LOG("Open in VSCode", ctx: ["file": url.lastPathComponent])
    }
    
    private func populateQuery() {
        guard let t = selectedTemplate else { return }
        var sql = t.rawSQL
        
        // Static placeholders that should always use static field values
        let staticPlaceholderMap = [
            "Org-ID": orgId,
            "Acct-ID": acctId
        ]
        
        // Build values map: start with dynamic session values
        var values: [String:String] = [:]
        for ph in t.placeholders {
            if let staticValue = staticPlaceholderMap[ph] {
                // Always use static field value for static placeholders
                values[ph] = staticValue
            } else {
                // Use session value for dynamic placeholders
                values[ph] = sessions.value(for: ph)
            }
        }
        
        // Replace {{placeholder}} with values (handle both with and without spaces)
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
        
        // Update mapping lookup after populate (if not already done)
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
    
    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: fontSize))
        }
        .onTapGesture { LOG("Static field focus", ctx: ["label": label]) }
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
            // Ask how to edit
            let edit = NSAlert()
            edit.messageText = "Edit Template"
            edit.informativeText = "Open in VS Code or edit inside the app?"
            edit.addButton(withTitle: "VS Code")
            edit.addButton(withTitle: "In App")
            edit.addButton(withTitle: "Later")
            let choice = edit.runModal()
            
            // Select it in UI
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
                selectedTemplate = renamed
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
        
        // Check if org already exists
        if mapping.lookup(orgId: orgId) != nil {
            showAlert(
                title: "Org Already Exists",
                message: "Org ID \(orgId) already has a mapping.\n\nTo avoid editing JSON files, please use a different Org-ID or clear the fields and start over."
            )
            LOG("Save mapping failed - org already exists", ctx: ["orgId": orgId])
            return
        }
        
        // Show popup to get company name - REQUIRED
        let alert = NSAlert()
        alert.messageText = "Company Name Required"
        alert.informativeText = "Enter the company name for Org ID: \(orgId)\n(This field is required and cannot be left empty)"
        alert.alertStyle = .informational
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.placeholderString = "Company name is required..."
        alert.accessoryView = input
        
        alert.addButton(withTitle: "Save Mapping")
        alert.addButton(withTitle: "Cancel")
        
        // Keep asking until they provide a company name or cancel
        repeat {
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let companyName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if companyName.isEmpty {
                    // Show error and ask again
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Company Name Required"
                    errorAlert.informativeText = "Company name cannot be empty. Please enter a company name."
                    errorAlert.alertStyle = .critical
                    errorAlert.addButton(withTitle: "Try Again")
                    errorAlert.runModal()
                    continue // Loop back to ask for company name again
                }
                
                // Company name provided - save it
                do {
                    try mapping.saveIfNew(
                        orgId: orgId,
                        mysqlDb: mysqlDb,
                        companyName: companyName // Now guaranteed to be non-empty
                    )
                    
                    // Update the display
                    companyLabel = companyName
                    
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
    
    
    // Helper function for showing alerts
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    
    
    // Simple in-app editor window
    final class TemplateEditorWindow: NSWindowController {
        static func present(for item: TemplateItem, manager: TemplateManager) {
            let vc = NSHostingController(rootView: TemplateEditorView(item: item, manager: manager))
            let win = NSWindow(contentViewController: vc)
            win.title = "Edit: \(item.name)"
            win.setContentSize(NSSize(width: 780, height: 520))
            let ctl = TemplateEditorWindow(window: win)
            ctl.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    struct TemplateEditorView: View {
        let item: TemplateItem
        @ObservedObject var manager: TemplateManager
        @State private var text: String = ""
        @Environment(\.dismiss) var dismiss
        
        var body: some View {
            VStack(spacing: 8) {
                Text("Editing \(item.name).sql").font(.headline).foregroundStyle(Theme.aqua)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
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
                HStack {
                    Button("Open in VS Code") { openInVSCode(item.url) }.buttonStyle(.bordered)
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Save") {
                        do {
                            try manager.saveTemplate(url: item.url, newContent: text)
                            dismiss()
                        } catch {
                            NSSound.beep()
                        }
                    }.buttonStyle(.borderedProminent).tint(Theme.pink)
                }
            }
            .padding()
            .onAppear {
                text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? item.rawSQL
            }
        }
        
        private func openInVSCode(_ url: URL) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["code", url.path]
            try? p.run()
        }
        
        
        
    }
}
