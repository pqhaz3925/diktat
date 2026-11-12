import AppKit
import ApplicationServices
import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var text: String
    var source: String?   // file name, nil for dictation
}

enum HotkeyPreset: String, CaseIterable, Identifiable {
    case ctrlOptSpace, optSpace, cmdShiftSpace, ctrlOptD
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ctrlOptSpace: return "⌃⌥Space"
        case .optSpace: return "⌥Space"
        case .cmdShiftSpace: return "⌘⇧Space"
        case .ctrlOptD: return "⌃⌥D"
        }
    }
    var keyCode: UInt32 { self == .ctrlOptD ? 2 : 49 }
    var carbonModifiers: UInt32 {
        // cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000
        switch self {
        case .ctrlOptSpace, .ctrlOptD: return 0x1000 | 0x800
        case .optSpace: return 0x800
        case .cmdShiftSpace: return 0x100 | 0x200
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle, connecting, recording, finishing
        case file(String)
        var busy: Bool { self != .idle }
    }

    @Published var phase: Phase = .idle
    /// The editable draft. New dictation/file transcripts are appended to it; only "Clear" empties it.
    @Published var text: String { didSet { d.set(text, forKey: "draft") } }
    /// Current session (recording or file) — not yet merged into `text`.
    @Published var finals: [String] = []
    @Published var pending = ""
    @Published var level: Float = 0
    @Published var error: String?
    @Published var notice: String?
    @Published var history: [HistoryEntry] = []

    // Settings
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var keyterms: String { didSet { d.set(keyterms, forKey: "keyterms") } }
    @Published var useBuiltinTerms: Bool { didSet { d.set(useBuiltinTerms, forKey: "useBuiltinTerms") } }
    @Published var holdToTalk: Bool { didSet { d.set(holdToTalk, forKey: "holdToTalk") } }
    @Published var autoPaste: Bool { didSet { d.set(autoPaste, forKey: "autoPaste"); if autoPaste { ensureAccessibility() } } }
    @Published var saveTxtNextToFile: Bool { didSet { d.set(saveTxtNextToFile, forKey: "saveTxt") } }
    @Published var hotkey: HotkeyPreset { didSet { d.set(hotkey.rawValue, forKey: "hotkey"); onHotkeyChange?() } }

    var onHotkeyChange: (() -> Void)?
    var onPhaseChange: ((Phase) -> Void)?

    private let d = UserDefaults.standard
    private var stream: VoiceStream? { didSet { audioSink.set(stream) } }
    private var mic: MicCapture?
    /// Audio-thread-safe pointer to the current stream (swapped on reconnect).
    private let audioSink = StreamSink()
    private var token = ""
    private var reconnects = 0
    private var stopRequested = false
    private var sessionID = 0

    /// What the current session has recognized so far (shown in the HUD).
    var sessionText: String {
        (finals + (pending.isEmpty ? [] : [pending])).joined(separator: " ")
    }

    /// Draft + the in-progress session, for display while busy.
    var displayText: String { Self.join(text, sessionText) }

    static func join(_ a: String, _ b: String) -> String {
        if b.isEmpty { return a }
        if a.isEmpty { return b }
        return a.last!.isWhitespace ? a + b : a + " " + b
    }

    private init() {
        d.register(defaults: ["language": "ru", "keyterms": "", "useBuiltinTerms": true, "holdToTalk": false,
                              "autoPaste": false, "saveTxt": true, "hotkey": HotkeyPreset.ctrlOptSpace.rawValue])
        text = d.string(forKey: "draft") ?? ""
        language = d.string(forKey: "language") ?? "ru"
        keyterms = d.string(forKey: "keyterms") ?? ""
        useBuiltinTerms = d.bool(forKey: "useBuiltinTerms")
        holdToTalk = d.bool(forKey: "holdToTalk")
        autoPaste = d.bool(forKey: "autoPaste")
        saveTxtNextToFile = d.bool(forKey: "saveTxt")
        hotkey = HotkeyPreset(rawValue: d.string(forKey: "hotkey") ?? "") ?? .ctrlOptSpace
        if let data = d.data(forKey: "history"), let h = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = h
        }
    }

    private func setPhase(_ p: Phase) { phase = p; onPhaseChange?(p) }

    var allKeyterms: [String] {
        let user = keyterms.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        // user terms first so they survive the 1024-char cap
        return user + (useBuiltinTerms ? VoiceStream.builtinTerms : [])
    }

    // MARK: - Dictation

    func hotkeyPressed() {
        if holdToTalk { if phase == .idle { startDictation() } }
        else { toggleDictation() }
    }

    func hotkeyReleased() {
        if holdToTalk { stopDictation() }
    }

    func toggleDictation() {
        switch phase {
        case .idle: startDictation()
        case .connecting, .recording: stopDictation()
        default: break
        }
    }

    func startDictation() {
        guard phase == .idle else { return }
        error = nil; notice = nil; finals = []; pending = ""; level = 0
        stopRequested = false
        sessionID += 1
        let sid = sessionID
        setPhase(.connecting)
        Task {
            guard await MicCapture.requestPermission() else {
                fail("Microphone access denied. Enable it in System Settings → Privacy → Microphone.")
                return
            }
            guard sid == sessionID else { return }
            do {
                token = try Token.load()
                reconnects = 0
                Log.write("dictation start (lang \(language))")
                let s = makeStream(sid: sid)
                s.connect(token: token, language: language, keyterms: allKeyterms)
                stream = s
                let m = MicCapture()
                let sink = audioSink
                m.onChunk = { data in sink.send(data) }
                m.onLevel = { lvl in DispatchQueue.main.async { AppModel.shared.level = lvl } }
                try m.start()
                mic = m
                setPhase(.recording)
                if stopRequested { stopDictation() }
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func stopDictation() {
        if phase == .connecting && mic == nil { stopRequested = true; return }
        guard phase == .recording || phase == .connecting else { return }
        mic?.stop(); mic = nil
        level = 0
        setPhase(.finishing)
        let s = stream
        let sid = sessionID
        Task {
            let rest = await s?.finish() ?? ""
            guard sid == sessionID else { return }
            stream = nil
            pending = ""
            if !rest.isEmpty { finals.append(rest) }
            deliver(source: nil)
            setPhase(.idle)
        }
    }

    func cancel() {
        sessionID += 1
        mic?.stop(); mic = nil
        stream?.cancel(); stream = nil
        pending = ""; level = 0
        setPhase(.idle)
    }

    // MARK: - Files

    func transcribe(file url: URL) {
        guard phase == .idle else { return }
        error = nil; notice = nil; finals = []; pending = ""
        sessionID += 1
        let sid = sessionID
        setPhase(.file("Decoding \(url.lastPathComponent)…"))
        Task {
            do {
                let token = try Token.load()
                let pcm = try await AudioDecoder.pcm16k(url)
                guard sid == sessionID else { return }
                let s = makeStream(sid: sid)
                stream = s
                s.connect(token: token, language: language, keyterms: allKeyterms)
                let total = Double(pcm.count) / Double(VoiceStream.bytesPerSecond)
                let chunk = VoiceStream.bytesPerSecond / 10            // 100 ms frames
                let speed = 4.0                                         // ×4 realtime is reliable; faster drops the tail
                let start = Date()
                var off = 0
                while off < pcm.count {
                    guard sid == sessionID else { return }
                    let end = min(off + chunk, pcm.count)
                    s.send(pcm.subdata(in: off..<end))
                    off = end
                    let sent = Double(off) / Double(VoiceStream.bytesPerSecond)
                    setPhase(.file(String(format: "%@ — %.0f%% of %@", url.lastPathComponent, sent / total * 100, fmt(total))))
                    let ahead = sent / speed - Date().timeIntervalSince(start)
                    if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
                }
                setPhase(.file("Finishing \(url.lastPathComponent)…"))
                let rest = await s.finish(timeout: 15)
                stream = nil
                guard sid == sessionID else { return }
                pending = ""
                if !rest.isEmpty { finals.append(rest) }
                let result = deliver(source: url.lastPathComponent, paste: false)
                if saveTxtNextToFile, !result.isEmpty {
                    let out = url.deletingPathExtension().appendingPathExtension("txt")
                    if (try? (result + "\n").write(to: out, atomically: true, encoding: .utf8)) != nil {
                        notice = "Saved \(out.lastPathComponent)"
                    }
                }
                setPhase(.idle)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    // MARK: - helpers

    private func makeStream(sid: Int) -> VoiceStream {
        VoiceStream { [weak self] event in
            guard let self, sid == self.sessionID else { return }
            switch event {
            case .ready: break
            case .interim(let t): self.pending = t
            case .final(let t): self.finals.append(t); self.pending = ""
            case .failure(let msg, let wasOpen):
                // Mid-dictation drop: keep what we have and continue on a fresh connection.
                if wasOpen, self.phase == .recording, self.reconnects < 5 {
                    self.reconnects += 1
                    Log.write("reconnecting (#\(self.reconnects)) after: \(msg)")
                    if !self.pending.isEmpty { self.finals.append(self.pending); self.pending = "" }
                    let s = self.makeStream(sid: sid)
                    s.connect(token: self.token, language: self.language, keyterms: self.allKeyterms)
                    self.stream = s
                    return
                }
                Log.write("session failed: \(msg)")
                self.error = msg
                if self.phase == .recording || self.phase == .connecting {
                    self.mic?.stop(); self.mic = nil
                    self.stream?.cancel(); self.stream = nil
                    self.deliver(source: nil)
                    self.setPhase(.idle)
                } else if case .file = self.phase {
                    self.sessionID += 1
                    self.stream?.cancel(); self.stream = nil
                    self.setPhase(.idle)
                }
            }
        }
    }

    /// Merges the finished session into the draft. Returns the session's own text.
    @discardableResult
    private func deliver(source: String?, paste: Bool = true) -> String {
        if !pending.isEmpty { finals.append(pending); pending = "" }
        let segment = finals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        finals = []
        guard !segment.isEmpty else {
            if error == nil && source == nil { notice = "Nothing recognized" }
            return ""
        }
        // a file transcript starts on its own paragraph
        text = source != nil && !text.isEmpty
            ? text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + segment
            : Self.join(text, segment)
        if source != nil { addHistory(segment, source: source) }
        if paste && autoPaste { pasteIntoFrontApp(segment) }   // only the new piece goes into the other app
        return segment
    }

    /// Archives the draft to history and empties it.
    func clearDraft() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, history.first?.text != t { addHistory(t, source: nil) }
        text = ""
        notice = nil; error = nil
    }

    private func addHistory(_ t: String, source: String?) {
        history.insert(HistoryEntry(text: t, source: source), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        if let data = try? JSONEncoder().encode(history) { d.set(data, forKey: "history") }
    }

    private func fail(_ msg: String) {
        error = msg
        mic?.stop(); mic = nil
        stream?.cancel(); stream = nil
        setPhase(.idle)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clearHistory() {
        history = []
        d.removeObject(forKey: "history")
    }

    @discardableResult
    func ensureAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    private func pasteIntoFrontApp(_ segment: String) {
        copy(segment)
        guard AXIsProcessTrusted() else { notice = "Copied. Grant Accessibility to auto-paste."; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // kVK_ANSI_V
            let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Lets the realtime audio thread hand chunks to whichever stream is current.
final class StreamSink {
    private let lock = NSLock()
    private var stream: VoiceStream?
    func set(_ s: VoiceStream?) { lock.withLock { stream = s } }
    func send(_ data: Data) { lock.withLock { stream }?.send(data) }
}
