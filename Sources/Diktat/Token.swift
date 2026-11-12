import Foundation

/// Reads the claude.ai OAuth access token that Claude Code stores after `/login`.
/// Order: $CLAUDE_CODE_OAUTH_TOKEN → macOS keychain ("Claude Code-credentials") → ~/.claude/.credentials.json
enum Token {
    enum Failure: LocalizedError {
        case missing, expired, unreadable
        var errorDescription: String? {
            switch self {
            case .missing: return "No Claude Code login found. Run `claude` and /login with a Claude.ai account."
            case .expired: return "Claude Code token expired. Run `claude` once to refresh it."
            case .unreadable: return "Could not parse Claude Code credentials."
            }
        }
    }

    static func load() throws -> String {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty { return t }
        var raw = keychain()
        if raw == nil {
            let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            raw = try? Data(contentsOf: p)
        }
        guard let raw else { throw Failure.missing }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw Failure.unreadable }
        if let exp = oauth["expiresAt"] as? Double, exp / 1000 < Date().timeIntervalSince1970 {
            throw Failure.expired
        }
        return token
    }

    private static func keychain() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 && !data.isEmpty ? data : nil
    }
}
