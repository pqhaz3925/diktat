import AppKit
import SwiftUI

/// Small floating pill at the bottom of the screen while dictating. Never takes focus.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func update(for phase: AppModel.Phase) {
        switch phase {
        case .connecting, .recording, .finishing:
            hideWork?.cancel()
            show()
        case .idle, .file:
            let w = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
        }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let host = NSHostingView(rootView: HUDView().environmentObject(AppModel.shared))
            host.frame = p.contentRect(forFrameRect: p.frame)
            p.contentView = host
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 48))
        panel.orderFrontRegardless()
    }
}

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            LevelBars(level: model.level, active: model.phase == .recording)
                .frame(width: 34, height: 22)
            Text(display)
                .font(.system(size: 14))
                .foregroundStyle(model.sessionText.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(8)
        .frame(width: 560, height: 96, alignment: .bottom)
    }

    private var display: String {
        if !model.sessionText.isEmpty { return model.sessionText }
        switch model.phase {
        case .connecting: return "Connecting…"
        case .recording: return "Listening…"
        case .finishing: return "Finishing…"
        default: return model.error ?? model.notice ?? ""
        }
    }
}

struct LevelBars: View {
    var level: Float
    var active: Bool
    private let weights: [Float] = [0.55, 0.85, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? Color.red : Color.secondary)
                    .frame(width: 4, height: CGFloat(4 + 18 * min(1, level * weights[i])))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
