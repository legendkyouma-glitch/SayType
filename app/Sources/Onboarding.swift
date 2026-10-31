import SwiftUI
import AppKit
import Combine

@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, permissions, hotkey, tryIt, done }
    @Published var step: Step = .welcome
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var globeUsage: Int? = nil
    @Published var hotkeyDetected = false
    @Published var practiceText = ""
    @Published var tryRaw = ""
    @Published var tryClean = ""
    @Published var tryNoSpeech = false
    @Published var listening = false

    var requestMic: () -> Void = {}
    var requestAX: () -> Void = {}
    var openKeyboardSettings: () -> Void = {}
    var openSettings: () -> Void = {}
    var finish: () -> Void = {}

    func resetPractice() { practiceText = ""; tryRaw = ""; tryClean = ""; tryNoSpeech = false }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @ObservedObject var s = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { st in
                    Capsule()
                        .fill(st.rawValue <= m.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 36).padding(.top, 22)

            Group {
                switch m.step {
                case .welcome: welcome
                case .permissions: permissions
                case .hotkey: hotkey
                case .tryIt: tryIt
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.vertical, 24)

            Divider()
            HStack {
                if m.step != .welcome {
                    Button("上一步") { go(-1) }
                }
                Spacer()
                nextButton
            }
            .padding(16)
        }
        .frame(width: 660, height: 600)
    }

    private func go(_ delta: Int) {
        if let st = OnboardingModel.Step(rawValue: m.step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) { m.step = st }
        }
    }

    @ViewBuilder private var nextButton: some View {
        switch m.step {
        case .welcome:
            Button("开始设置") { go(1) }.keyboardShortcut(.defaultAction)
        case .permissions:
            Button("下一步") { go(1) }.keyboardShortcut(.defaultAction).disabled(!(m.micGranted && m.axGranted))
        case .hotkey:
            Button(m.hotkeyDetected ? "下一步" : "跳过检测") { go(1) }.keyboardShortcut(.defaultAction)
        case .tryIt:
            Button(m.tryClean.isEmpty ? "先跳过" : "下一步") { go(1) }.keyboardShortcut(.defaultAction)
        case .done:
            Button("开始使用") { m.finish() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 1. 欢迎 + 数据去向

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 52)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SayType 说写").font(.system(size: 30, weight: .bold))
                    Text("按住快捷键说话，把整理后的文字填入当前输入框。").foregroundStyle(.secondary)
                }
            }
            Text("你的声音去哪里").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(icon: "mic", title: "由你开始和结束录音", text: "默认按住说话、松开结束；也可锁定或切换录音。录音时屏幕上有状态条，系统的麦克风指示灯也会亮起。")
                InfoRow(icon: "internaldrive", title: "音频不保存", text: "音频只在内存里处理，用完立即丢弃，不写入磁盘。")
                InfoRow(icon: "clock.arrow.circlepath", title: "文字历史只在这台 Mac 上", text: "保留 \(HistoryStore.keepDays) 天，可以在菜单栏里随时查看、清空或关闭。")
            }
            Text("识别和整理方式").font(.headline)
            Picker("", selection: Binding(get: { s.preset == .quality ? Preset.quality : Preset.privacy },
                                          set: { s.preset = $0 })) {
                Text("隐私优先：全部在这台 Mac 上处理").tag(Preset.privacy)
                Text("效果优先：使用云端识别和整理").tag(Preset.quality)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(presetExplain).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presetExplain: String {
        if s.preset == .quality {
            return KeyStore.hasKey
                ? "音频和文字会通过 OpenRouter 发送给云端模型识别和整理。"
                : "音频和文字会通过 OpenRouter 发送给云端模型识别和整理，需要先在设置里填写 OpenRouter Key；填写之前按隐私优先处理。"
        }
        return "使用 \(s.localModelName) 和本机整理规则，音频和文字都不离开这台 Mac。以后可以在设置里下载和切换本机识别模型。"
    }

    // MARK: 2. 权限

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("需要两项系统权限").font(.system(size: 24, weight: .bold))
            Text("授权后回到这里，会自动检测，不需要重启。").foregroundStyle(.secondary)
            PermissionRow(icon: "mic.fill", title: "麦克风",
                          text: "用来听你说话，在你开始录音后打开。",
                          granted: m.micGranted, button: "允许使用麦克风", action: m.requestMic)
            PermissionRow(icon: "accessibility", title: "辅助功能",
                          text: "用来响应快捷键、检查输入焦点并填入文字。替换文字时会读取目标输入框的文字，不会替你发送消息。",
                          granted: m.axGranted, button: "去授权", action: m.requestAX)
            if !m.axGranted {
                Text("点“去授权”后，在“系统设置 → 隐私与安全性 → 辅助功能”里打开 SayType 的开关。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 3. 快捷键

    private var hotkey: some View {
        let rec = GlobeKey.recommendedKey()
        return VStack(alignment: .leading, spacing: 16) {
            Text("选择快捷键").font(.system(size: 24, weight: .bold))
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("系统“按下 🌐 键时”的设置：\(GlobeKey.describe(m.globeUsage))")
            }
            .font(.callout).foregroundStyle(.secondary)
            Text(rec == .fn
                 ? "🌐 键没有被系统占用，推荐用 🌐 Fn 作为快捷键。"
                 : "🌐 键已经被系统用来切换输入法或显示表情，推荐用右 Option，不影响你现在的习惯。")
            HStack(spacing: 14) {
                KeyCard(title: "右 Option", symbol: "option", recommended: rec == .rightOption, selected: s.hotkey == .rightOption) {
                    s.hotkey = .rightOption; m.hotkeyDetected = false
                }
                KeyCard(title: "🌐 Fn", symbol: "globe", recommended: rec == .fn, selected: s.hotkey == .fn) {
                    s.hotkey = .fn; m.hotkeyDetected = false
                }
            }
            if rec != .fn {
                Button("想用 🌐 键？打开键盘设置，把“按下 🌐 键时”改为“不执行任何操作”") { m.openKeyboardSettings() }
                    .buttonStyle(.link)
            }
            HStack(spacing: 10) {
                Image(systemName: m.hotkeyDetected ? "checkmark.circle.fill" : "hand.point.up.left.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(m.hotkeyDetected ? Color.green : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.hotkeyDetected ? "检测到了，快捷键可以用" : "现在按一下 \(s.hotkeyName) 试试")
                        .font(.headline)
                    if !m.hotkeyDetected && s.hotkey == .fn {
                        Text("外接键盘按 Fn 没有反应时，请改用右 Option。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            Text(s.recordMode == .hold
                 ? "用法：按住说话，松开结束。说长段时，按住后再按一下空格即可松手继续说，再按一次快捷键结束。Esc 随时取消。"
                 : "用法：按一下开始说话，再按一下结束。Esc 随时取消。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 4. 试说

    static let sample = "嗯，我们明天下午三点开个会，讨论一下新版本的上线计划。"

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("试说一句").font(.system(size: 24, weight: .bold))
            Text(s.recordMode == .hold ? "按住 \(s.hotkeyName)，照着下面这句话说，说完松开：" : "按一下 \(s.hotkeyName)，照着下面这句话说，说完再按一下：")
                .foregroundStyle(.secondary)
            Text("“\(OnboardingView.sample)”")
                .font(.system(size: 17, weight: .medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.09)))
            VStack(alignment: .leading, spacing: 6) {
                Text("练习框").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(m.practiceText.isEmpty ? (m.listening ? "正在听…" : "文字会出现在这里") : m.practiceText)
                        .font(.system(size: 15))
                        .foregroundStyle(m.practiceText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 64)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(m.listening ? Color.red.opacity(0.6) : Color.secondary.opacity(0.3)))
            }
            if m.tryNoSpeech {
                Label("没有听到声音。请检查麦克风或输入设备，再大声一点试一次。", systemImage: "speaker.slash")
                    .foregroundStyle(.orange)
            }
            if !m.tryClean.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    CompareBox(title: "你说的原话", text: m.tryRaw, highlight: false)
                    CompareBox(title: "整理后填入的文字", text: m.tryClean, highlight: true)
                }
                Label("成功了！接下来可以去微信、备忘录或浏览器的输入框里试试。", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: 5. 完成

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("准备好了").font(.system(size: 28, weight: .bold))
            TipRow(icon: "keyboard", text: s.recordMode == .hold
                   ? "在任何应用的输入框里按住 \(s.hotkeyName) 说话，边说边填入，松开后最后一段也会填好。"
                   : "在任何应用的输入框里按一下 \(s.hotkeyName) 开始说话，再按一下结束。")
            if s.recordMode == .hold {
                TipRow(icon: "lock", text: "说长段时，按住快捷键再按一下空格锁定，松手继续说，再按一次快捷键结束。")
            }
            TipRow(icon: "escape", text: "说错了按 Esc 取消；填入后可以用 Cmd+Z 撤回。")
            TipRow(icon: "menubar.rectangle", text: "菜单栏的波形图标里可以改设置、查看和清空历史、粘贴上一次的结果。")
            if !KeyStore.hasKey {
                GroupBox {
                    HStack {
                        Text("想要更准确、更书面的结果？填写 OpenRouter Key，切换到「效果优先」。")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("打开设置") { m.openSettings() }
                    }
                    .padding(6)
                }
            }
        }
    }
}

// MARK: - 小组件

struct InfoRow: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PermissionRow: View {
    let icon: String, title: String, text: String
    let granted: Bool, button: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).frame(width: 34).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(button, action: action).controlSize(.large)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

struct KeyCard: View {
    let title: String, symbol: String
    let recommended: Bool, selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26, weight: .medium))
                Text(title).font(.headline)
                Text(recommended ? "推荐" : " ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(recommended ? Color.green : Color.clear))
            }
            .frame(width: 150, height: 104)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CompareBox: View {
    let title: String, text: String, highlight: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(highlight ? Color.accentColor : .secondary)
            Text(text).font(.system(size: 13.5)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(highlight ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07)))
    }
}

struct TipRow: View {
    let icon: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 24).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
