import Foundation

final class SessionManager: ObservableObject {
    // per-session key/value cache: placeholder -> last used value
    @Published private(set) var sessionValues: [TicketSession: [String:String]] = [
        .one: [:], .two: [:], .three: [:]
    ]
    // global (app-run) recent values for each placeholder
    @Published private(set) var globalRecents: [String: [String]] = [:] // placeholder -> [values newest..]

    @Published var current: TicketSession = .one
    @Published var sessionNames: [TicketSession: String] = [.one:"#1", .two:"#2", .three:"#3"]

    // per-session markdown notes (to be shown in the right-side notes panel)
    @Published var sessionNotes: [TicketSession: String] = [
        .one: "",
        .two: "",
        .three: ""
    ]
    
    // optional per-session link (URL as string). Absence => no link
    @Published var sessionLinks: [TicketSession: String] = [:]

    func setCurrent(_ s: TicketSession) {
        current = s
        LOG("Switch session", ctx: ["session":"\(s.rawValue)"])
    }

    func renameCurrent(to newName: String) {
        sessionNames[current] = newName
        LOG("Rename session", ctx: ["session":"\(current.rawValue)", "name": newName])
    }

    func setValue(_ value: String, for placeholder: String) {
        var vals = sessionValues[current] ?? [:]
        vals[placeholder] = value
        sessionValues[current] = vals

        // track global recents
        var list = globalRecents[placeholder] ?? []
        if let idx = list.firstIndex(of: value) { list.remove(at: idx) }
        list.insert(value, at: 0)
        // keep only recent ~20
        if list.count > 20 { list = Array(list.prefix(20)) }
        globalRecents[placeholder] = list

        LOG("Set value", ctx: ["session":"\(current.rawValue)", "placeholder":placeholder, "value": value])
    }

    func value(for placeholder: String) -> String {
        sessionValues[current]?[placeholder] ?? ""
    }

    func clearAllFieldsForCurrentSession() {
        sessionValues[current] = [:]
        sessionNames[current] = "#\(current.rawValue)"
        // also clear notes and any link for this session
        sessionNotes[current] = ""
        sessionLinks.removeValue(forKey: current)
        LOG("Cleared fields", ctx: ["session":"\(current.rawValue)"])
    }
}
