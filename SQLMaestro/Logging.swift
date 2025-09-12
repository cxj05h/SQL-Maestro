import Foundation

struct LogEvent: Codable {
    let ts: String
    let level: String
    let message: String
    let context: [String:String]?
}

final class AppLogger {
    static let shared = AppLogger()
    private let queue = DispatchQueue(label: "log.queue")
    private var fileURL: URL

    private init() {
        AppPaths.ensureAll()
        fileURL = AppLogger.logFileURLForToday()
        pruneLogs(olderThanDays: 14)
        log(level: "INFO", "Logger initialized", nil)
    }

    static func logFileURLForToday() -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return AppPaths.logs.appendingPathComponent("\(df.string(from: Date())).jsonl")
    }

    func log(level: String, _ message: String, _ context: [String:String]?) {
        queue.async {
            let iso = ISO8601DateFormatter().string(from: Date())
            let evt = LogEvent(ts: iso, level: level, message: message, context: context)
            do {
                let line = try String(data: JSONEncoder().encode(evt), encoding: .utf8)! + "\n"
                if !FileManager.default.fileExists(atPath: self.fileURL.path) {
                    FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: self.fileURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                // swallow logging errors
            }
        }
    }

    func pruneLogs(olderThanDays days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        if let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.logs, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files {
                if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mdate = vals.contentModificationDate, mdate < cutoff {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }
}

func LOG(_ message: String, ctx: [String:String]? = nil) {
    AppLogger.shared.log(level: "INFO", message, ctx)
}
func WARN(_ message: String, ctx: [String:String]? = nil) {
    AppLogger.shared.log(level: "WARN", message, ctx)
}
func ERROR(_ message: String, ctx: [String:String]? = nil) {
    AppLogger.shared.log(level: "ERROR", message, ctx)
}