import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct DiktatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: icon)
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        switch model.phase {
        case .idle: return "waveform"
        case .connecting, .finishing: return "ellipsis.circle"
        case .recording: return "record.circle.fill"
        case .file: return "doc.text.magnifyingglass"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private let hud = HUDController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        registerHotkey()
        model.onHotkeyChange = { [weak self] in self?.registerHotkey() }
        model.onPhaseChange = { [weak self] phase in self?.hud.update(for: phase) }
        // `diktat-cli`-style quick test: `Diktat.app/Contents/MacOS/Diktat --transcribe file.m4a`
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            model.transcribe(file: URL(fileURLWithPath: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--dictate"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            model.startDictation()
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { model.stopDictation() }
        }
    }

    private func registerHotkey() {
        hotKey = nil
        let p = AppModel.shared.hotkey
        hotKey = HotKey(keyCode: p.keyCode, modifiers: p.carbonModifiers,
                        onPress: { DispatchQueue.main.async { AppModel.shared.hotkeyPressed() } },
                        onRelease: { DispatchQueue.main.async { AppModel.shared.hotkeyReleased() } })
        if hotKey == nil { AppModel.shared.error = "Hotkey \(p.label) is taken by another app — pick another one." }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            transcriptBox
            if let e = model.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let n = model.notice {
                Label(n, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            controls
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) { settings.padding(.top, 6) }
                .font(.callout)
            if !model.history.isEmpty {
                Divider()
                history
            }
            Divider()
            HStack {
                Text("Uses your Claude Code login").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(width: 380)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first, !model.phase.busy else { return false }
            model.transcribe(file: u)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [6]))
                    .padding(4)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Diktat").font(.headline)
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: return "\(model.hotkey.label) to \(model.holdToTalk ? "hold" : "toggle")"
        case .connecting: return "Connecting…"
        case .recording: return "Listening"
        case .finishing: return "Finishing…"
        case .file(let s): return s
        }
    }

    private var transcriptBox: some View {
        Group {
            if model.phase.busy {
                // read-only while a session is running; new text streams in at the end
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.displayText.isEmpty ? "Listening…" : model.displayText)
                            .foregroundStyle(model.displayText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .onChange(of: model.displayText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                }
            } else {
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 3)
                    .overlay(alignment: .topLeading) {
                        if model.text.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 3).allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(height: 160)
        .padding(5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: String { "Press record or drop an audio/video file here. New dictation is appended; edit freely." }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleDictation) {
                HStack(spacing: 6) {
                    if model.phase == .recording {
                        LevelBars(level: model.level, active: true).frame(width: 26, height: 14)
                        Text("Stop")
                    } else {
                        Image(systemName: "mic.fill")
                        Text(model.phase == .connecting ? "Connecting…" : "Record")
                    }
                }
                .frame(minWidth: 96)
            }
            .disabled(model.phase == .finishing || { if case .file = model.phase { return true }; return false }())

            Button {
                pickFile()
            } label: { Label("File…", systemImage: "doc") }
            .disabled(model.phase.busy)

            Spacer()
            if case .file = model.phase {
                Button("Cancel", action: model.cancel)
            } else {
                Button { model.copy(model.text) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy all").disabled(model.text.isEmpty || model.phase.busy)
                Button(action: model.clearDraft) { Image(systemName: "trash") }
                    .help("Clear (moves the text to Recent)").disabled(model.text.isEmpty || model.phase.busy)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Language", selection: $model.language) {
                ForEach(VoiceStream.languages, id: \.self) { Text($0).tag($0) }
            }
            Picker("Hotkey", selection: $model.hotkey) {
                ForEach(HotkeyPreset.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Hold to talk (otherwise toggle)", isOn: $model.holdToTalk)
            Toggle("Auto-paste into the front app", isOn: $model.autoPaste)
            Toggle("Save .txt next to transcribed files", isOn: $model.saveTxtNextToFile)
            Toggle("Include Claude Code's built-in terms", isOn: $model.useBuiltinTerms)
            Text("Key terms — one per line, ASCII only (Latin spelling is what the model will output)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.keyterms)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .font(.callout)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: model.clearHistory).buttonStyle(.borderless).font(.caption)
            }
            ForEach(model.history.prefix(5)) { e in
                Button { model.copy(e.text) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: e.source == nil ? "mic" : "doc").font(.caption2).foregroundStyle(.secondary)
                        Text(e.text).lineLimit(2).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to copy")
            }
        }
    }

    private func pickFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie, .audiovisualContent, UTType(filenameExtension: "ogg") ?? .audio,
                                 UTType(filenameExtension: "opus") ?? .audio, UTType(filenameExtension: "webm") ?? .movie]
        p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { model.transcribe(file: u) }
    }
}
