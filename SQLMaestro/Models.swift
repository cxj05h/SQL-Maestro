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
