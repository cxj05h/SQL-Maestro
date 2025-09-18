
import Foundation
struct SessionImage: Identifiable, Codable {
    let id = UUID()
    let fileName: String
    let originalPath: String?
    let savedAt: Date
    
    var displayName: String {
        let number = fileName.components(separatedBy: "_").last?.components(separatedBy: ".").first ?? "0"
        return "Image \(number)"
    }
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
    func clearAllFieldsForCurrentSession() {
        sessionValues[current] = [:]
        sessionNames[current] = "#\(current.rawValue)"
        sessionNotes[current] = ""
        sessionLinks.removeValue(forKey: current)
        clearSessionImages(for: current) 
        sessionAlternateFields[current] = []
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
}
