import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @State private var keyInput = ""
    @State private var keyStatus = ""
    @State private var testing = false
    var testKey: () async -> String = { "" }

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: set)
    }

    var body: some View {
        Form {
            Section {
                Text(s.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(currentRecognition).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(currentCleanup).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("修改后从下一句开始生效。").font(.caption).foregroundStyle(.secondary)
            } header: { Text("当前组合") }

            Section("识别和整理") {
                Picker("预设", selection: bind({ s.preset }, { s.preset = $0 })) {
                    Text("效果优先").tag(Preset.quality)
                    Text("隐私优先").tag(Preset.privacy)
                    Text("自定义").tag(Preset.custom)
                }
                .pickerStyle(.segmented)
                Text(dataFlow).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if s.preset == .custom {
                    Picker("语音识别", selection: bind({ s.customASR }, { s.customASR = $0 })) {
                        Text("本机（\(s.localModelName)）").tag(ASREngine.local)
                        Text("云端（OpenRouter）").tag(ASREngine.cloud)
                    }
                    Picker("文字整理", selection: bind({ s.customCleanup }, { s.customCleanup = $0 })) {
                        Text("本机规则").tag(CleanupEngine.rules)
                        Text("云端大模型（OpenRouter）").tag(CleanupEngine.cloud)
                    }
                    TextField("云端识别模型", text: bind({ s.sttModel }, { s.sttModel = $0 }))
                    Text("同时请求备用模型 \(ModelPresentation.displayName(backupSTTModel))，用先成功的结果。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    TextField("云端整理模型", text: bind({ s.llmModel }, { s.llmModel = $0 }))
                }
            }

            Section("本机识别模型") {
                LocalModelSettingsView()
            }

            Section("OpenRouter Key") {
                HStack {
                    SecureField(KeyStore.hasKey ? "已填写，可粘贴新的 Key 替换" : "粘贴 OpenRouter Key（sk-or-…）", text: $keyInput)
                    Button("保存") {
                        let k = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        let ok = KeyStore.save(k)
                        keyInput = ""
                        s.objectWillChange.send()
                        Log.shared.ev("key_saved", ["ok": ok])
                        keyStatus = ok ? "已保存到钥匙串，正在测试连接…" : "保存失败"
                        if ok { runTest() }
                    }
                    .disabled(keyInput.isEmpty)
                }
                HStack {
                    Text(KeyStore.hasKey ? "状态：已填写（\(KeyStore.source)）" : "状态：未填写，当前按隐私优先处理")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if KeyStore.hasKey {
                        Button("测试连接") { runTest() }.disabled(testing)
                        Button("清除") {
                            KeyStore.deleteKeychain()
                            s.objectWillChange.send()
                            keyStatus = KeyStore.hasKey ? "钥匙串已清除；本地配置文件里的 Key 仍在使用" : "已清除"
                        }
                    }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.caption) }
            }

            Section("输入") {
                Picker("录音方式", selection: bind({ s.recordMode }, { s.recordMode = $0 })) {
                    Text("按下开始，松开结束").tag(RecordMode.hold)
                    Text("按一下开始，再按一下结束").tag(RecordMode.toggle)
                }
                Text(s.recordMode == .hold
                     ? "按住快捷键时再按一下空格可锁定，松手继续说，再按一次快捷键结束。"
                     : "持续 30 秒没有声音会自动结束；单次最长 5 分钟。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("输入方式", selection: bind({ s.insertMode }, { s.insertMode = $0 })) {
                    Text("边说边逐段填入").tag(InsertMode.segment)
                    Text("说完后一次填入").tag(InsertMode.once)
                }
                Picker("整理力度", selection: bind({ s.cleanupLevel }, { s.cleanupLevel = $0 })) {
                    Text("原样").tag(CleanupLevel.raw)
                    Text("轻度整理").tag(CleanupLevel.light)
                    Text("润色").tag(CleanupLevel.polish).disabled(s.cleanupEngine != .cloud)
                }
                Text(levelHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("快捷键", selection: bind({ s.hotkey }, { s.hotkey = $0 })) {
                    Text("右 Option").tag(HotkeyMonitor.Key.rightOption)
                    Text("🌐 Fn").tag(HotkeyMonitor.Key.fn)
                }
                Text("系统“按下 🌐 键时”：\(GlobeKey.describe(GlobeKey.usageType()))。使用 🌐 Fn 前，建议把它改为“不执行任何操作”。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("其他") {
                Toggle("开始和结束时播放提示音", isOn: bind({ s.soundEnabled }, { s.soundEnabled = $0 }))
                Toggle("中英文、数字之间自动加空格", isOn: bind({ s.cjkSpacing }, { s.cjkSpacing = $0 }))
                Toggle("保存文字历史（仅本机，保留 \(HistoryStore.keepDays) 天）", isOn: bind({ s.historyEnabled }, { s.historyEnabled = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 720)
    }

    private var dataFlow: String {
        let cloudCleanup = s.cleanupEngine == .cloud && s.effectiveLevel != .raw
        if s.asr == .local && !cloudCleanup {
            let cleanup = s.effectiveLevel == .raw ? "本机文字规范化" : "本机整理规则"
            return "音频和文字都不离开这台 Mac：\(s.localModelName) + \(cleanup)。音频不保存，文字历史只存在本机。"
        }
        var parts: [String] = []
        if s.asr == .cloud { parts.append("音频按停顿分段，同时发送到 OpenRouter 上的两个识别模型，采用先成功的结果") }
        else { parts.append("音频由 \(s.localModelName) 在本机识别") }
        if cloudCleanup { parts.append("识别文字、本次口述前文的末尾和当前应用名发送到 OpenRouter 上的大模型整理") }
        var fallbacks: [String] = []
        if s.asr == .cloud { fallbacks.append("云端识别不可用时改用 \(s.localModelName)") }
        if cloudCleanup { fallbacks.append("云端整理不可用时改用本机规则") }
        return parts.joined(separator: "；") + "。音频不保存；文字历史只存在本机。" + fallbacks.joined(separator: "，") + "。"
    }

    private var backupSTTModel: String {
        s.sttModel == Cloud.backupSTTModel ? "qwen/qwen3-asr-1.7b" : Cloud.backupSTTModel
    }

    private var currentRecognition: String {
        if s.asr == .local { return "识别：\(s.localModelName)（本机）" }
        return "识别：\(ModelPresentation.displayName(s.sttModel)) / \(ModelPresentation.displayName(backupSTTModel))（云端）；本机备用：\(s.localModelName)"
    }

    private var currentCleanup: String {
        if s.effectiveLevel == .raw { return "整理：原样（本机文字规范化）" }
        if s.cleanupEngine == .cloud { return "整理：\(ModelPresentation.displayName(s.llmModel))（云端）" }
        return "整理：本机规则"
    }

    private var levelHint: String {
        switch s.cleanupLevel {
        case .raw: return "保留识别结果的措辞和标点，繁体字会转为简体字。"
        case .light: return s.cleanupEngine == .cloud
            ? "尝试纠错、补标点、去掉重复和语气词、处理改口。使用前请检查整理结果。"
            : "本机规则：补标点、去掉语气词和重复。"
        case .polish: return s.cleanupEngine == .cloud
            ? "调整语序和措辞，更通顺、更书面；润色时自动改为说完后一次填入。"
            : "润色需要云端整理（效果优先），当前按轻度整理处理。"
        }
    }

    private func runTest() {
        testing = true
        Task { @MainActor in
            keyStatus = await testKey()
            testing = false
            s.objectWillChange.send()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @ObservedObject var s = Settings.shared
    @State private var confirm = false

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("最近的语音输入").font(.headline)
                Text(s.historyEnabled ? "仅保存在这台 Mac，保留 \(HistoryStore.keepDays) 天，不保存音频" : "历史已关闭")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空全部", role: .destructive) { confirm = true }.disabled(store.items.isEmpty)
            }
            .padding(12)
            Divider()
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("还没有记录").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.items) { it in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(HistoryView.df.string(from: it.date)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(it.app).font(.caption.weight(.medium))
                            if it.status != "已填入" {
                                Text(it.status).font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(it.text, forType: .string)
                            }
                            .controlSize(.small)
                        }
                        Text("识别：\(it.asr) · 整理：\(it.cleanup)").font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(it.text).font(.system(size: 13.5)).textSelection(.enabled)
                        if it.raw != it.text && !it.raw.isEmpty {
                            Text("原话：\(it.raw)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 620, height: 540)
        .confirmationDialog("清空全部文字历史？", isPresented: $confirm) {
            Button("清空", role: .destructive) { store.clear() }
        }
    }
}
