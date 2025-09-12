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

    // Static fields
    @State private var orgId: String = ""
    @State private var acctId: String = ""
    @State private var mysqlDb: String = ""
    @State private var companyLabel: String = ""

    var body: some View {
        NavigationSplitView {
            // Query Templates Pane
            // Replace the entire VStack inside NavigationSplitView with this:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Query Templates").font(.headline).foregroundStyle(Theme.purple)
                    Spacer()
                    Button("New Template") { createNewTemplateFlow() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.purple)
                    Button("Reload") { templates.loadTemplates() }
                        .buttonStyle(.bordered)
                }
                
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search templates...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: fontSize))
                        .onTapGesture {
                            LOG("Template search focused")
                        }
                        .onChange(of: searchText) { oldVal, newVal in
                            LOG("Template search", ctx: ["query": newVal, "results": "\(filteredTemplates.count)"])
                        }
                    if !searchText.isEmpty {
                        Button("Clear") {
                            searchText = ""
                            LOG("Template search cleared")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.pink)
                    }
                }
                
                List(filteredTemplates, selection: $selectedTemplate) { t in
                    Text(t.name)
                        .contextMenu {
                            Button("Open in VS Code") { openInVSCode(t.url) }
                            Button("Edit in App") { editTemplateInline(t) }
                            Divider()
                            Button("Rename…") { renameTemplateFlow(t) }
                        }
                        .onTapGesture(count: 2) {
                            loadTemplate(t)
                        }
                }
                
                // Show search results info
                if !searchText.isEmpty {
                    Text("\(filteredTemplates.count) of \(templates.templates.count) templates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Theme.grayBG)
        } detail: {
            // Right side: Fields + Output
            VStack(spacing: 12) {
                staticFields
                Divider()
                dynamicFields
                HStack {
                    Button("Populate Query") { populateQuery() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.pink)
                    Button("Clear All Fields (Session)") {
                        sessions.clearAllFieldsForCurrentSession()
                    }.buttonStyle(.bordered)
                    Spacer()
                    sessionButtons
                }
                outputView
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
                            do {
                                guard !orgId.trimmingCharacters(in: .whitespaces).isEmpty else {
                                    throw NSError(domain: "map", code: 1, userInfo: [NSLocalizedDescriptionKey:"Org-ID required"])
                                }
                                try mapping.saveIfNew(orgId: orgId, mysqlDb: mysqlDb, companyName: companyLabel.isEmpty ? nil : companyLabel)
                            } catch {
                                NSSound.beep()
                            }
                        }.buttonStyle(.bordered)
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
                let staticPlaceholders = ["Org-id", "Acct-ID"] // These are handled by static fields
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
