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

    /// Verbose mode: also log server messages with transcript text and keep the last session's audio
    /// as ~/Library/Logs/Diktat-last.wav. Off by default (privacy); toggle in Settings.
    static var verbose: Bool { UserDefaults.standard.bool(forKey: "verboseLog") }
    static let lastAudioURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Diktat-last.wav")

    static func debug(_ msg: @autoclosure () -> String) { if verbose { write(msg()) } }

    static func saveWAV(_ pcm: Data, sampleRate: Int = 16000) {
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(Data("RIFF".utf8)); u32(36 + pcm.count); h.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        h.append(Data("data".utf8)); u32(pcm.count)
        try? (h + pcm).write(to: lastAudioURL)
    }

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
