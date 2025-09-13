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
    @State private var hoverRecentKey: String? = nil
    
    @State private var searchText: String = ""
    
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
                        .keyboardShortcut("k", modifiers: [.command])
                        .font(.system(size: fontSize))
                        
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
            }
            .padding()
            .background(Theme.grayBG)
        }
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .top) {
            if toastCopied {
                Text("Copied to clipboard")
                    .font(.system(size: fontSize))
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
        .onAppear {
            LOG("App started")
            // Initialize with session 1
            sessions.setCurrent(.one)
            if let tid = sessionSelectedTemplate[sessions.current],
               let found = templates.templates.first(where: { $0.id == tid }) {
                selectedTemplate = found
                currentSQL = found.rawSQL
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
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .font(.system(size: fontSize))
                    }
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
                                dynamicFieldRow(ph)
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
        // Opens with user’s default app for .json/.sql
        NSWorkspace.shared.open(item.url)
        LOG("Open JSON", ctx: ["file": item.url.lastPathComponent])
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
        commitDraftsForCurrentSession() // commit on action
        TemplateEditorWindow.present(for: t, manager: templates)
        LOG("Inline edit open", ctx: ["template": t.name])
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
    
    // Template Editor Window
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
        @State private var fontSize: CGFloat = 13
        
        var body: some View {
            VStack(spacing: 8) {
                Text("Editing \(item.name).sql")
                    .font(.system(size: fontSize + 4, weight: .semibold))
                    .foregroundStyle(Theme.aqua)
                TextEditor(text: $text)
                    .font(.system(size: fontSize, design: .monospaced))
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
                    Button("Open in VS Code") { openInVSCode(item.url) }
                        .buttonStyle(.bordered)
                        .font(.system(size: fontSize))
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .font(.system(size: fontSize))
                    Button("Save") {
                        do {
                            try manager.saveTemplate(url: item.url, newContent: text)
                            dismiss()
                        } catch {
                            NSSound.beep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.pink)
                    .font(.system(size: fontSize))
                }
            }
            .padding()
            .onAppear {
                text = (try? String(contentsOf: item.url, encoding: .utf8)) ?? item.rawSQL
            }
            .onReceive(NotificationCenter.default.publisher(for: .fontBump)) { note in
                if let delta = note.object as? Int {
                    fontSize = max(10, min(22, fontSize + CGFloat(delta)))
                }
            }
        }
        
        private func openInVSCode(_ url: URL) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            let stable = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
            let insiders = URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app")
            let fm = FileManager.default

            if fm.fileExists(atPath: stable.path) {
                NSWorkspace.shared.open([url], withApplicationAt: stable, configuration: cfg, completionHandler: nil)
                return
            }
            if fm.fileExists(atPath: insiders.path) {
                NSWorkspace.shared.open([url], withApplicationAt: insiders, configuration: cfg, completionHandler: nil)
                return
            }
            // Generic fallback
            NSWorkspace.shared.open(url)
        }
    }
}

