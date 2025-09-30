
import Foundation
struct SessionImage: Identifiable, Codable {
    let id = UUID()
    let fileName: String
    let originalPath: String?
    let savedAt: Date
    var customName: String? // New: custom user-defined name
    
    var displayName: String {
        if let custom = customName, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        // Fallback to auto-generated name
        let number = fileName.components(separatedBy: "_").last?.components(separatedBy: ".").first ?? "0"
        return "Image \(number)"
    }
}

struct SessionSavedFile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, content: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String { "\(name).json" }
}

// MARK: – Model for alternate fields
struct AlternateField: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var value: String
}

// MARK: – Session Manager
final class SessionManager: ObservableObject {
    // Per-session key/value cache: placeholder -> last used value
    @Published private(set) var sessionValues: [TicketSession: [String:String]] = [
        .one: [:], .two: [:], .three: [:]
    ]

    // Global (app-run) recent values for each placeholder
    @Published private(set) var globalRecents: [String: [String]] = [:] // placeholder -> [values newest..]

    // Current session
    @Published var current: TicketSession = .one

    // Per-session display names
    @Published var sessionNames: [TicketSession: String] = [
        .one:"#1", .two:"#2", .three:"#3"
    ]

    // Per-session alternate fields (stored as array with stable IDs)
    @Published var sessionAlternateFields: [TicketSession:[AlternateField]] = [:]

    // Per-session markdown notes (shown in right-side notes panel)
    @Published var sessionNotes: [TicketSession: String] = [
        .one: "",
        .two: "",
        .three: ""
    ]

    // Per-session saved JSON files
    @Published var sessionSavedFiles: [TicketSession: [SessionSavedFile]] = [
        .one: [],
        .two: [],
        .three: []
    ]

    // Optional per-session link (URL as string)
    @Published var sessionLinks: [TicketSession: String] = [:]
    
    // Session images tracking
    @Published var sessionImages: [TicketSession: [SessionImage]] = [
        .one: [], .two: [], .three: []
    ]

    // MARK: – Session controls
    func setCurrent(_ s: TicketSession) {
        current = s
        LOG("Switch session", ctx: ["session":"\(s.rawValue)"])
    }

    func renameCurrent(to newName: String) {
        sessionNames[current] = newName
        LOG("Rename session", ctx: ["session":"\(current.rawValue)", "name": newName])
    }

    // MARK: – Placeholder value handling
    func setValue(_ value: String, for placeholder: String) {
        var vals = sessionValues[current] ?? [:]
        vals[placeholder] = value
        sessionValues[current] = vals

        // Track global recents
        var list = globalRecents[placeholder] ?? []
        if let idx = list.firstIndex(of: value) { list.remove(at: idx) }
        list.insert(value, at: 0)
        if list.count > 20 { list = Array(list.prefix(20)) }
        globalRecents[placeholder] = list

        LOG("Set value", ctx: ["session":"\(current.rawValue)", "placeholder":placeholder, "value": value])
    }

    func value(for placeholder: String) -> String {
        sessionValues[current]?[placeholder] ?? ""
    }

    // MARK: – Alternate fields handling
    func setAlternateField(name: String, value: String) {
        if sessionAlternateFields[current] == nil {
            sessionAlternateFields[current] = []
        }
        if let idx = sessionAlternateFields[current]?.firstIndex(where: { $0.name == name }) {
            sessionAlternateFields[current]?[idx].value = value
            LOG("Updated alternate field", ctx: [
                "session":"\(current.rawValue)",
                "name": name,
                "value": value
            ])
        } else {
            let newField = AlternateField(name: name, value: value)
            sessionAlternateFields[current]?.append(newField)
            LOG("Added alternate field", ctx: [
                "session":"\(current.rawValue)",
                "name": name,
                "value": value
            ])
        }
    }

    func removeAlternateField(name: String) {
        if let idx = sessionAlternateFields[current]?.firstIndex(where: { $0.name == name }) {
            let removed = sessionAlternateFields[current]?.remove(at: idx)
            LOG("Removed alternate field", ctx: [
                "session":"\(current.rawValue)",
                "name": removed?.name ?? "unknown"
            ])
        }
    }


    // MARK: – Clear session
    func clearAllFields(for session: TicketSession) {
        sessionValues[session] = [:]
        sessionNames[session] = "#\(session.rawValue)"
        sessionNotes[session] = ""
        sessionLinks.removeValue(forKey: session)
        clearSessionImages(for: session)
        sessionAlternateFields[session] = []
        sessionSavedFiles[session] = []
        LOG("Cleared fields", ctx: ["session":"\(session.rawValue)"])
    }

    func clearAllFieldsForCurrentSession() {
        sessionValues[current] = [:]
        sessionNames[current] = "#\(current.rawValue)"
        sessionNotes[current] = ""
        sessionLinks.removeValue(forKey: current)
        clearSessionImages(for: current)
        sessionAlternateFields[current] = []
        sessionSavedFiles[current] = []
        LOG("Cleared fields", ctx: ["session":"\(current.rawValue)"])
    }
    
    func addSessionImage(_ image: SessionImage, for session: TicketSession) {
        var images = sessionImages[session] ?? []
        images.append(image)
        sessionImages[session] = images
        LOG("Session image added", ctx: ["session": "\(session.rawValue)", "fileName": image.fileName])
    }

    func clearSessionImages(for session: TicketSession) {
        sessionImages[session] = []
        LOG("Session images cleared", ctx: ["session": "\(session.rawValue)"])
    }
    func renameSessionImage(imageId: UUID, newName: String, for session: TicketSession) {
        guard var images = sessionImages[session] else { return }
        
        if let index = images.firstIndex(where: { $0.id == imageId }) {
            images[index].customName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionImages[session] = images
            LOG("Session image renamed", ctx: [
                "session": "\(session.rawValue)",
                "imageId": imageId.uuidString,
                "newName": newName
            ])
        }
    }

    func setSessionImageName(fileName: String, to newName: String?, for session: TicketSession) {
        guard var images = sessionImages[session],
              let index = images.firstIndex(where: { $0.fileName == fileName }) else { return }

        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String?
        if let trimmed, !trimmed.isEmpty {
            normalized = trimmed
        } else {
            normalized = nil
        }

        if images[index].customName == normalized { return }

        images[index].customName = normalized
        sessionImages[session] = images
        LOG("Session image name synced from notes", ctx: [
            "session": "\(session.rawValue)",
            "fileName": fileName,
            "newName": normalized ?? "(default)"
        ])
    }

    // MARK: – Saved file helpers
    func savedFiles(for session: TicketSession) -> [SessionSavedFile] {
        sessionSavedFiles[session] ?? []
    }

    func setSavedFiles(_ files: [SessionSavedFile], for session: TicketSession) {
        sessionSavedFiles[session] = files
    }

    func addSavedFile(name: String, content: String = "{\n  \"key\": \"value\"\n}\n", for session: TicketSession) -> SessionSavedFile {
        var files = sessionSavedFiles[session] ?? []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? generateDefaultFileName(for: session, existing: files) : resolveDuplicateName(trimmed, within: files)
        let now = Date()
        let file = SessionSavedFile(name: normalized, content: content, createdAt: now, updatedAt: now)
        files.append(file)
        sessionSavedFiles[session] = files
        LOG("Saved file created", ctx: [
            "session": "\(session.rawValue)",
            "file": file.displayName
        ])
        return file
    }

    func updateSavedFileContent(_ content: String, for fileId: SessionSavedFile.ID, in session: TicketSession) {
        guard var files = sessionSavedFiles[session], let index = files.firstIndex(where: { $0.id == fileId }) else { return }
        if files[index].content == content { return }
        files[index].content = content
        files[index].updatedAt = Date()
        sessionSavedFiles[session] = files
        LOG("Saved file content updated", ctx: [
            "session": "\(session.rawValue)",
            "file": files[index].displayName,
            "chars": "\(content.count)"
        ])
    }

    @discardableResult
    func syncSavedFileDraft(_ content: String, for fileId: SessionSavedFile.ID, in session: TicketSession) -> Bool {
        guard var files = sessionSavedFiles[session], let index = files.firstIndex(where: { $0.id == fileId }) else { return false }
        if files[index].content == content { return false }
        files[index].content = content
        sessionSavedFiles[session] = files
        return true
    }

    func renameSavedFile(id: SessionSavedFile.ID, to newName: String, in session: TicketSession) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var files = sessionSavedFiles[session], let index = files.firstIndex(where: { $0.id == id }) else { return }
        let resolved = resolveDuplicateName(trimmed.isEmpty ? files[index].name : trimmed, within: files, excluding: id)
        if files[index].name == resolved { return }
        files[index].name = resolved
        files[index].updatedAt = Date()
        sessionSavedFiles[session] = files
        LOG("Saved file renamed", ctx: [
            "session": "\(session.rawValue)",
            "fileId": id.uuidString,
            "newName": resolved
        ])
    }

    func removeSavedFile(id: SessionSavedFile.ID, from session: TicketSession) {
        guard var files = sessionSavedFiles[session], let index = files.firstIndex(where: { $0.id == id }) else { return }
        let removed = files.remove(at: index)
        sessionSavedFiles[session] = files
        LOG("Saved file removed", ctx: [
            "session": "\(session.rawValue)",
            "file": removed.displayName
        ])
    }

    func generateDefaultFileName(for session: TicketSession) -> String {
        let files = sessionSavedFiles[session] ?? []
        return generateDefaultFileName(for: session, existing: files)
    }

    // MARK: – Helpers
    private func resolveDuplicateName(_ name: String, within files: [SessionSavedFile], excluding id: SessionSavedFile.ID? = nil) -> String {
        let base = name
        var candidate = base
        var suffix = 1
        let existingNames = Set(files.filter { $0.id != id }.map { $0.name.lowercased() })
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(base)\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func generateDefaultFileName(for session: TicketSession, existing: [SessionSavedFile]) -> String {
        let base = "name"
        let existingNames = Set(existing.map { $0.name.lowercased() })
        if !existingNames.contains(base) { return base }
        var suffix = 1
        while existingNames.contains("\(base)\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base)\(suffix)"
    }
}
