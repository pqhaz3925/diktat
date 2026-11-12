import Foundation

/// Client for the speech-to-text WebSocket used by Claude Code's voice mode.
///
/// Wire protocol (observed in Claude Code 2.1.x):
///   → binary frames: PCM s16le, 16 kHz, mono
///   → text: {"type":"KeepAlive"} on open and every 8 s, {"type":"CloseStream"} to finish
///   ← {"type":"TranscriptInterim"|"TranscriptText","data":"…"}  current hypothesis of the segment
///   ← {"type":"TranscriptEndpoint"}                               segment done → last hypothesis is final
///   ← {"type":"TranscriptError","description"…} / {"type":"error","message"…}
final class VoiceStream: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case ready
        case interim(String)
        case final(String)
        /// `wasOpen`: the socket had connected before failing (i.e. a mid-stream drop, worth reconnecting).
        case failure(String, wasOpen: Bool)
    }

    /// Terms Claude Code itself always sends.
    static let builtinTerms = ["MCP", "symlink", "grep", "regex", "localhost", "codebase", "TypeScript", "JSON",
                               "OAuth", "webhook", "gRPC", "dotfiles", "subagent", "worktree"]
    static let languages = ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "pl", "nl", "tr", "cs", "el",
                            "da", "sv", "no", "ja", "ko", "hi", "id"]

    static let sampleRate = 16000
    static let bytesPerSecond = sampleRate * 2

    private let queue = DispatchQueue(label: "diktat.voicestream")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var isOpen = false
    private var backlog: [Data] = []
    private var keepAlive: DispatchSourceTimer?
    private var pending = ""
    private var closing = false
    private var endpointAfterClose = false
    private var dead = false
    private var lastMessage = Date()
    private var everOpen = false
    private var bytesSent = 0
    private let onEvent: (Event) -> Void

    /// `onEvent` is always called on the main queue.
    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
        let oq = OperationQueue()
        oq.underlyingQueue = queue
        oq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: oq)
    }

    static func packKeyterms(_ terms: [String]) -> String {
        // Same rules as Claude Code: drop commas and non-ASCII, collapse spaces, dedupe, ≤1024 chars.
        var seen = Set<String>(), out: [String] = [], n = 0
        for t in terms {
            let ascii = String(String.UnicodeScalarView(t.replacingOccurrences(of: ",", with: " ")
                .unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }))
            let p = ascii.split(whereSeparator: { $0 == " " }).joined(separator: " ")
            if p.isEmpty || seen.contains(p) { continue }
            let add = p.count + (out.isEmpty ? 0 : 1)
            if n + add > 1024 { break }
            seen.insert(p); out.append(p); n += add
        }
        return out.joined(separator: ",")
    }

    func connect(token: String, language: String, keyterms: [String]) {
        let base = ProcessInfo.processInfo.environment["DIKTAT_BASE_URL"] ?? "wss://api.anthropic.com"
        var c = URLComponents(string: base + "/api/ws/speech_to_text/voice_stream")!
        c.queryItems = [
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: String(Self.sampleRate)),
            .init(name: "channels", value: "1"),
            .init(name: "endpointing_ms", value: "300"),
            .init(name: "utterance_end_ms", value: "1000"),
            .init(name: "language", value: language),
            .init(name: "use_conversation_engine", value: "true"),
            .init(name: "forward_interims", value: "typed"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("claude-cli/2.1.322 (external, cli)", forHTTPHeaderField: "User-Agent")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.setValue("macos", forHTTPHeaderField: "anthropic-client-platform")
        let kt = Self.packKeyterms(keyterms)
        if !kt.isEmpty { req.setValue(kt, forHTTPHeaderField: "x-config-keyterms") }
        queue.async {
            let t = self.session.webSocketTask(with: req)
            t.maximumMessageSize = 16 << 20
            self.task = t
            t.resume()
            self.receive()
        }
    }

    func send(_ data: Data) {
        queue.async {
            guard !self.closing, !self.dead else { return }
            if self.isOpen { self.task?.send(.data(data)) { _ in } } else { self.backlog.append(data) }
            self.bytesSent += data.count
        }
    }

    /// Sends CloseStream, waits for the trailing transcript, closes the socket.
    /// Returns the last not-yet-final text (the caller appends it; it is not emitted as `.final`).
    func finish(timeout: TimeInterval = 8) async -> String {
        queue.sync {
            closing = true
            Log.write("→ CloseStream (open=\(isOpen), pending \(pending.count) chars)")
            if isOpen { sendText(#"{"type":"CloseStream"}"#) }
        }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let done: Bool = queue.sync {
                if dead { return true }
                if !isOpen { return false }
                if endpointAfterClose && pending.isEmpty { return true }
                return pending.isEmpty && Date().timeIntervalSince(lastMessage) > 3
            }
            if done { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let rest: String = queue.sync {
            let r = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.debug("finish leftover: \(r)")
            pending = ""
            dead = true
            keepAlive?.cancel(); keepAlive = nil
            task?.cancel(with: .normalClosure, reason: nil)
            Log.write("stream finished: \(bytesSent / Self.bytesPerSecond)s audio sent")
            return r
        }
        session.finishTasksAndInvalidate()
        return rest
    }

    func cancel() {
        queue.async {
            self.dead = true
            self.keepAlive?.cancel(); self.keepAlive = nil
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.session.invalidateAndCancel()
        }
    }

    // MARK: - internals (all on `queue`)

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent(e) } }

    private func sendText(_ s: String) { task?.send(.string(s)) { _ in } }

    private func flushPending() {
        let s = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !s.isEmpty { emit(.final(s)) }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                if !self.dead { self.receive() }
            case .failure(let err):
                self.connectionFailed(err)
            }
        }
    }

    private func handle(_ text: String) {
        lastMessage = Date()
        Log.debug("← \(text.count > 600 ? String(text.prefix(600)) + "…" : text)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "TranscriptInterim", "TranscriptText":
            if let d = obj["data"] as? String, !d.isEmpty { pending = d; emit(.interim(d)) }
        case "TranscriptEndpoint":
            flushPending()
            if closing { endpointAfterClose = true }
        case "TranscriptError":
            flushPending()
            Log.write("TranscriptError \(obj["error_code"] ?? "")")
            if !closing { emit(.failure((obj["description"] ?? obj["error_code"]).map { "\($0)" } ?? "transcription error", wasOpen: true)) }
        case "error":
            flushPending()
            Log.write("server error frame")
            if !closing { emit(.failure((obj["message"] as? String) ?? "server error", wasOpen: true)) }
        default:
            break
        }
    }

    private func connectionFailed(_ err: Error) {
        guard !dead else { return }
        flushPending()
        dead = true
        keepAlive?.cancel(); keepAlive = nil
        Log.write("stream failed (open=\(everOpen), closing=\(closing)): \(err.localizedDescription)")
        if closing { return }
        if let http = task?.response as? HTTPURLResponse, http.statusCode != 101 {
            let hint = http.statusCode == 401 || http.statusCode == 403
                ? " — is Claude Code logged in with a Claude.ai subscription?" : ""
            emit(.failure("Voice stream rejected: HTTP \(http.statusCode)\(hint)", wasOpen: false))
        } else {
            emit(.failure("Voice stream error: \(err.localizedDescription)", wasOpen: everOpen))
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isOpen = true
        everOpen = true
        lastMessage = Date()
        Log.write("stream open (\(backlog.count) chunks buffered)")
        sendText(#"{"type":"KeepAlive"}"#)
        // Coalesce whatever was captured while connecting into ≤32 KB frames (as Claude Code does).
        var frame = Data()
        for chunk in backlog {
            if !frame.isEmpty && frame.count + chunk.count > 32000 { task?.send(.data(frame)) { _ in }; frame = Data() }
            frame.append(chunk)
        }
        if !frame.isEmpty { task?.send(.data(frame)) { _ in } }
        backlog.removeAll()
        if closing { sendText(#"{"type":"CloseStream"}"#) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in self?.sendText(#"{"type":"KeepAlive"}"#) }
        t.resume()
        keepAlive = t
        emit(.ready)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        Log.write("stream closed by server: code \(closeCode.rawValue) \(why) (closing=\(closing))")
        flushPending()
        guard !dead else { return }
        dead = true
        keepAlive?.cancel(); keepAlive = nil
        if !closing { emit(.failure("Connection closed (code \(closeCode.rawValue))", wasOpen: true)) }
    }
}
