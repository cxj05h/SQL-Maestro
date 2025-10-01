import Foundation
import Combine

/// A record of a single template's usage inside a single ticket session.
struct UsedTemplateRecord: Codable, Hashable {
    let templateId: UUID
    var values: [String: String]
    var lastUpdated: Date
}

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
        return usedBySession[session]?[templateId] != nil
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
        lock.lock()
        var map = usedBySession[session] ?? [:]
        if map[templateId] == nil {
            map[templateId] = UsedTemplateRecord(templateId: templateId, values: [:], lastUpdated: Date())
            usedBySession[session] = map
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        } else {
            lock.unlock()
        }
    }

    /// Update or create a record and bump its timestamp without altering values.
    func touch(session: TicketSession, templateId: UUID) {
        lock.lock()
        var map = usedBySession[session] ?? [:]
        if var record = map[templateId] {
            record.lastUpdated = Date()
            map[templateId] = record
        } else {
            map[templateId] = UsedTemplateRecord(templateId: templateId, values: [:], lastUpdated: Date())
        }
        usedBySession[session] = map
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// Set a dynamic placeholder value for (session, template).
    /// This is the main entry point that the UI should call when a user commits a value.
    func setValue(_ value: String, for placeholder: String, session: TicketSession, templateId: UUID) {
        lock.lock()
        var map = usedBySession[session] ?? [:]
        var record = map[templateId] ?? UsedTemplateRecord(templateId: templateId, values: [:], lastUpdated: Date())

        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            record.values[placeholder] = value
            record.lastUpdated = Date()
            map[templateId] = record
            usedBySession[session] = map
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        } else {
            record.values.removeValue(forKey: placeholder)
            record.lastUpdated = Date()
            map[templateId] = record
            usedBySession[session] = map
            lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Overwrite the entire values dict for a template in a session (optional helper).
    func setAllValues(_ values: [String: String], session: TicketSession, templateId: UUID) {
        lock.lock()
        var map = usedBySession[session] ?? [:]
        map[templateId] = UsedTemplateRecord(templateId: templateId, values: values, lastUpdated: Date())
        usedBySession[session] = map
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// Remove a specific template usage record for the given session.
    func clearTemplate(session: TicketSession, templateId: UUID) {
        lock.lock()
        var map = usedBySession[session] ?? [:]
        map.removeValue(forKey: templateId)
        usedBySession[session] = map
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// Clear all recorded usage for a specific session (invoked by "Clear Session #N").
    func clearSession(_ session: TicketSession) {
        lock.lock()
        usedBySession[session] = [:]
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }

    /// Clear all recorded usage for all sessions (useful on app launch).
    func clearAll() {
        lock.lock()
        usedBySession = [
            .one: [:], .two: [:], .three: [:]
        ]
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
}
