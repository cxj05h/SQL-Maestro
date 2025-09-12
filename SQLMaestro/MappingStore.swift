import Foundation

final class MappingStore: ObservableObject {
    @Published var map: OrgMysqlMap = [:]

    init() {
        AppPaths.ensureAll()
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: AppPaths.orgMysqlMap)
            let decoded = try JSONDecoder().decode(OrgMysqlMap.self, from: data)
            self.map = decoded
            LOG("OrgMysql map loaded", ctx: ["count":"\(decoded.count)"])
        } catch {
            self.map = [:]
            WARN("Failed to load org_mysql_map.json")
        }
    }

    func saveIfNew(orgId: String, mysqlDb: String, companyName: String?) throws {
        guard map[orgId] == nil else {
            throw NSError(domain: "MappingStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Org already exists; edit JSON manually"])
        }
        map[orgId] = MappingEntry(mysqlDb: mysqlDb, companyName: companyName)
        try persist()
        LOG("Mapping added", ctx: ["orgId": orgId, "mysqlDb": mysqlDb])
    }

    func persist() throws {
        let data = try JSONEncoder().encode(map)
        try data.write(to: AppPaths.orgMysqlMap, options: [.atomic])
    }

    func lookup(orgId: String) -> MappingEntry? {
        map[orgId]
    }
}