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

struct MysqlHostEntry: Codable {
    var hostname: String
    var port: Int
}

typealias MysqlHostsMap = [String: MysqlHostEntry] // mysqlDbName -> entry

struct UserConfig: Codable {
    var mysql_username: String
    var mysql_password: String
    var querious_path: String
    
    static var empty: UserConfig {
        UserConfig(
            mysql_username: "",
            mysql_password: "",
            querious_path: "/Applications/Querious.app"
        )
    }
}

enum TicketSession: Int, CaseIterable {
    case one = 1, two = 2, three = 3
}
struct TemplateLinks: Codable {
    var templateId: UUID
    var links: [TemplateLink]
    var updatedAt: String

    init(templateId: UUID, links: [TemplateLink], updatedAt: Date = Date()) {
        self.templateId = templateId
        self.links = links
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.updatedAt = iso.string(from: updatedAt)
    }
}

struct TemplateLink: Identifiable, Codable {
    let id = UUID()
    var title: String
    var url: String
    
    init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}
