import Foundation

final class UserConfigStore: ObservableObject {
    @Published var config: UserConfig = UserConfig.empty

    init() {
        AppPaths.ensureAll()
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: AppPaths.userConfig)
            let decoded = try JSONDecoder().decode(UserConfig.self, from: data)
            self.config = decoded
            LOG("User config loaded", ctx: ["username": decoded.mysql_username.isEmpty ? "empty" : "set"])
        } catch {
            self.config = UserConfig.empty
            WARN("Failed to load user_config.json")
        }
    }

    func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: AppPaths.userConfig, options: [.atomic])
        LOG("User config saved", ctx: ["username": config.mysql_username.isEmpty ? "empty" : "set"])
    }

    func updateCredentials(username: String, password: String, queriousPath: String) throws {
        config.mysql_username = username
        config.mysql_password = password
        config.querious_path = queriousPath
        try persist()
        LOG("User credentials updated", ctx: ["username": username.isEmpty ? "empty" : "set"])
    }

    func hasValidCredentials() -> Bool {
        !config.mysql_username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !config.mysql_password.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func queriousExists() -> Bool {
        FileManager.default.fileExists(atPath: config.querious_path)
    }
}
