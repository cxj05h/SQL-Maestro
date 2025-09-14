import Foundation

final class MysqlHostStore: ObservableObject {
    @Published var hostsMap: MysqlHostsMap = [:]

    init() {
        AppPaths.ensureAll()
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: AppPaths.mysqlHostsMap)
            let decoded = try JSONDecoder().decode(MysqlHostsMap.self, from: data)
            self.hostsMap = decoded
            LOG("MySQL hosts map loaded", ctx: ["count":"\(decoded.count)"])
        } catch {
            self.hostsMap = [:]
            WARN("Failed to load mysql_hosts_map.json")
        }
    }

    func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(hostsMap)
        try data.write(to: AppPaths.mysqlHostsMap, options: [.atomic])
        LOG("MySQL hosts map saved", ctx: ["count":"\(hostsMap.count)"])
    }

    func lookup(mysqlDb: String) -> MysqlHostEntry? {
        hostsMap[mysqlDb]
    }

    func addOrUpdate(mysqlDb: String, hostname: String, port: Int) throws {
        hostsMap[mysqlDb] = MysqlHostEntry(hostname: hostname, port: port)
        try persist()
        LOG("MySQL host mapping updated", ctx: ["mysqlDb": mysqlDb, "hostname": hostname])
    }

    func remove(mysqlDb: String) throws {
        hostsMap.removeValue(forKey: mysqlDb)
        try persist()
        LOG("MySQL host mapping removed", ctx: ["mysqlDb": mysqlDb])
    }
}
