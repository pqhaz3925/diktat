import Foundation

/// Tiny append-only event log at ~/Library/Logs/Diktat.log (events only, never transcript text).
enum Log {
    private static let queue = DispatchQueue(label: "diktat.log")
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Diktat.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
