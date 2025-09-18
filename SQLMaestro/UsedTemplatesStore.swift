import Foundation
import Combine

/// Identifies a ticket session (you already use this type elsewhere)
/// enum TicketSession: CaseIterable { case one, two, three } // <- for reference

/// A record of a single template's usage inside a single ticket session.
struct UsedTemplateRecord: Codable, Hashable {
    let templateId: UUID
    var values: [String: String]   // placeholder -> value entered
    var lastUpdated: Date
}

/// Central store that tracks, per Ticket Session, which templates were "used"
/// (i.e., at least one dynamic field got a value) and the values entered.
///
/// NOTE:
/// - This store is designed to be UI-agnostic and persistence-agnostic for now.
/// - We can add disk persistence later if you want this to survive app restarts.
final class UsedTemplatesStore: ObservableObject {
    static let shared = UsedTemplatesStore()

    /// Mapping:
    ///   session -> (templateId -> record)
    @Published private(set) var usedBySession: [TicketSession: [UUID: UsedTemplateRecord]] = [
        .one: [:], .two: [:], .three: [:]
    ]

    private let lock = NSRecursiveLock()

    private init() {}

    // MARK: - Query

    /// Returns true if the given template has at least one recorded value for the session.
    func isTemplateUsed(in session: TicketSession, templateId: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return usedBySession[session]?[templateId]?.values.isEmpty == false
    }

    /// Returns a snapshot of all used template records for a session.
    func records(for session: TicketSession) -> [UsedTemplateRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(usedBySession[session]?.values ?? [:].values)
            .sorted(by: { $0.lastUpdated > $1.lastUpdated })
    }

    /// Get the current recorded values for a template in a session.
    func values(for session: TicketSession, templateId: UUID) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return usedBySession[session]?[templateId]?.values ?? [:]
    }

    // MARK: - Mutations

    /// Mark that a template is being used in this session (creates an empty record if needed).
    func markTemplateUsed(session: TicketSession, templateId: UUID) {
        lock.lock(); defer { lock.unlock() }
        var map = usedBySession[session] ?? [:]
        if map[templateId] == nil {
            map[templateId] = UsedTemplateRecord(templateId: templateId, values: [:], lastUpdated: Date())
            usedBySession[session] = map
            objectWillChange.send()
        }
    }

    /// Set a dynamic placeholder value for (session, template).
    /// This is the main entry point that the UI should call when a user commits a value.
    func setValue(_ value: String, for placeholder: String, session: TicketSession, templateId: UUID) {
        lock.lock(); defer { lock.unlock() }
        var map = usedBySession[session] ?? [:]
        var record = map[templateId] ?? UsedTemplateRecord(templateId: templateId, values: [:], lastUpdated: Date())

        // Only consider non-empty as a "used" trigger. (We can change this rule if you want.)
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.values[placeholder] = value
            record.lastUpdated = Date()
            map[templateId] = record
            usedBySession[session] = map
            objectWillChange.send()
        } else {
            // If an empty value is written, remove it from the record.
            record.values.removeValue(forKey: placeholder)
            record.lastUpdated = Date()
            // If the record becomes empty, we still keep it for now; we could also remove it.
            map[templateId] = record
            usedBySession[session] = map
            objectWillChange.send()
        }
    }

    /// Overwrite the entire values dict for a template in a session (optional helper).
    func setAllValues(_ values: [String: String], session: TicketSession, templateId: UUID) {
        lock.lock(); defer { lock.unlock() }
        var map = usedBySession[session] ?? [:]
        map[templateId] = UsedTemplateRecord(templateId: templateId, values: values, lastUpdated: Date())
        usedBySession[session] = map
        objectWillChange.send()
    }

    /// Clear all recorded usage for a specific session (invoked by "Clear Session #N").
    func clearSession(_ session: TicketSession) {
        lock.lock(); defer { lock.unlock() }
        usedBySession[session] = [:]
        objectWillChange.send()
    }
}
