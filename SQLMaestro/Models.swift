import Foundation

struct TemplateItem: Identifiable, Hashable {
    let id = UUID()
    let name: String            // filename without extension
    let url: URL
    let rawSQL: String
    let placeholders: [String]  // e.g., ["Org-id", "sig-id"]
}

struct MappingEntry: Codable {
    var mysqlDb: String
    var companyName: String?
}

typealias OrgMysqlMap = [String: MappingEntry] // orgId -> entry

enum TicketSession: Int, CaseIterable {
    case one = 1, two = 2, three = 3
}