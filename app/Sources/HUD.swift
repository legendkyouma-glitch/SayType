import AppKit
import SwiftUI
import Combine

/// 状态条的数据
@MainActor
final class HUDModel: ObservableObject {
    enum Phase { case listening, locked, processing, done, failed, info }
    @Published var phase: Phase = .info
    @Published var title = ""
    @Published var detail = ""
    @Published var tag = ""
    @Published var modelInfo = ""
    @Published var elapsed = ""
    @Published var levels: [CGFloat] = Array(repeating: 0.04, count: 32)

    func push(db: Float) {
        // -55 dB 以下视为静音，-15 dB 视为满格
        let v = CGFloat(max(0, min(1, (db + 55) / 40)))
        levels.removeFirst()
        levels.append(max(0.04, v))
    }
    func resetLevels() { levels = Array(repeating: 0.04, count: 32) }
}

struct HUDView: View {
    @ObservedObject var m: HUDModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            indicator.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(m.title).font(.system(size: 14, weight: .semibold))
                    if !m.tag.isEmpty {
                        Text(m.tag)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !m.elapsed.isEmpty {
                        Text(m.elapsed).font(.system(size: 11.5, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !m.detail.isEmpty {
                    Text(m.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
                if !m.modelInfo.isEmpty {
                    Text(m.modelInfo)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if m.phase == .listening || m.phase == .locked {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(m.levels.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(m.phase == .locked ? Color.orange : Color(red: 1, green: 0.32, blue: 0.32))
                            .frame(width: 2.5, height: 3 + m.levels[i] * 26)
                    }
                }
                .frame(width: 32 * 4.5, height: 32)
                .animation(.linear(duration: 0.08), value: m.levels)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 520, alignment: .leading)
        .background(
            VisualEffect()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var indicator: some View {
        switch m.phase {
        case .listening, .locked:
            ZStack {
                Circle().fill((m.phase == .locked ? Color.orange : Color.red).opacity(0.25))
                    .scaleEffect(pulse ? 1.15 : 0.8)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: m.phase == .locked ? "lock.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(m.phase == .locked ? Color.orange : Color.red)
            }
            .onAppear { pulse = true }
        case .processing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(.yellow)
        case .info:
            Image(systemName: "waveform").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 不抢焦点、不接收点击的浮动面板：否则文字就插不回原来的输入框
@MainActor
final class HUD {
    let model = HUDModel()
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var generation = 0
    private var titleSubscription: AnyCancellable?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 70),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host = NSHostingView(rootView: HUDView(m: model))
        panel.contentView = host
        // A late cloud replacement updates the title without calling show().
        // Resize after SwiftUI sees that change, including titles that wrap.
        titleSubscription = model.$title.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    func show(_ phase: HUDModel.Phase, _ title: String, _ detail: String = "", tag: String = "") {
        generation += 1
        model.phase = phase
        model.title = title
        model.detail = detail
        model.tag = tag
        if phase != .listening && phase != .locked { model.elapsed = "" }
        layout()
        panel.orderFrontRegardless()
    }

    func flash(_ phase: HUDModel.Phase, _ title: String, _ detail: String = "", tag: String = "", seconds: Double = 2.5) {
        show(phase, title, detail, tag: tag)
        hide(after: seconds)
    }

    func setDetail(_ d: String) { model.detail = d; layout() }
    func setTag(_ t: String) { model.tag = t }
    func setModels(_ text: String) { model.modelInfo = text; layout() }

    private func layout() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 72, width: size.width, height: size.height), display: true)
    }

    func hide(after seconds: Double = 0) {
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == g else { return }
                self.panel.orderOut(nil)
                self.model.resetLevels()
            }
        }
    }
}
