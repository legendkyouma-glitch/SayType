import Foundation
import Security
import Combine

enum Preset: String, CaseIterable { case quality, privacy, custom }
enum ASREngine: String { case local, cloud }
enum CleanupEngine: String { case cloud, rules }
enum RecordMode: String { case hold, toggle }
enum InsertMode: String { case segment, once }
enum CleanupLevel: String { case raw, light, polish }

/// 用户设置，存在 UserDefaults。API Key 不放这里（见 KeyStore）。
/// 所有修改从下一句开始生效：每次开始说话时取一次快照。
final class Settings: ObservableObject, @unchecked Sendable {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func enumValue<T: RawRepresentable>(_ k: String, _ def: T) -> T where T.RawValue == String {
        T(rawValue: d.string(forKey: k) ?? "") ?? def
    }
    private func store(_ k: String, _ v: Any) {
        if Thread.isMainThread { objectWillChange.send() }
        d.set(v, forKey: k)
    }

    // MARK: 引擎预设

    var preset: Preset {
        get {
            if let s = d.string(forKey: "preset"), let p = Preset(rawValue: s) { return p }
            return KeyStore.hasKey ? .quality : .privacy
        }
        set { store("preset", newValue.rawValue) }
    }
    var customASR: ASREngine {
        get { enumValue("customASR", ASREngine.local) }
        set { store("customASR", newValue.rawValue) }
    }
    var customCleanup: CleanupEngine {
        get { enumValue("customCleanup", CleanupEngine.rules) }
        set { store("customCleanup", newValue.rawValue) }
    }

    /// 实际使用的识别引擎：没有 Key 时一律本机
    var asr: ASREngine {
        guard KeyStore.hasKey else { return .local }
        switch preset {
        case .quality: return .cloud
        case .privacy: return .local
        case .custom: return customASR
        }
    }
    /// 实际使用的整理引擎：没有 Key 时一律规则
    var cleanupEngine: CleanupEngine {
        guard KeyStore.hasKey else { return .rules }
        switch preset {
        case .quality: return .cloud
        case .privacy: return .rules
        case .custom: return customCleanup
        }
    }

    var baseURL: String {
        get { d.string(forKey: "baseURL") ?? "https://openrouter.ai/api/v1" }
        set { store("baseURL", newValue) }
    }
    var sttModel: String {
        get { d.string(forKey: "sttModel") ?? "qwen/qwen3-asr-1.7b" }
        set { store("sttModel", newValue) }
    }
    var llmModel: String {
        get { d.string(forKey: "llmModel") ?? "google/gemini-2.5-flash-lite" }
        set { store("llmModel", newValue) }
    }

    // MARK: 输入选项

    var recordMode: RecordMode {
        get { enumValue("recordMode", RecordMode.hold) }
        set { store("recordMode", newValue.rawValue) }
    }
    var insertMode: InsertMode {
        get { enumValue("insertMode", InsertMode.segment) }
        set { store("insertMode", newValue.rawValue) }
    }
    var cleanupLevel: CleanupLevel {
        get { enumValue("cleanupLevel", CleanupLevel.light) }
        set { store("cleanupLevel", newValue.rawValue) }
    }
    /// 润色需要云端大模型；没有时按轻度整理处理
    var effectiveLevel: CleanupLevel {
        cleanupLevel == .polish && cleanupEngine != .cloud ? .light : cleanupLevel
    }
    /// 润色时这一次自动改为说完后一次填入
    var effectiveInsertMode: InsertMode {
        effectiveLevel == .polish ? .once : insertMode
    }

    // MARK: 快捷键

    var hotkey: HotkeyMonitor.Key {
        get {
            if let s = d.string(forKey: "hotkey"), let k = HotkeyMonitor.Key(rawValue: s) { return k }
            return GlobeKey.cachedRecommendedKey
        }
        set { store("hotkey", newValue.rawValue) }
    }
    var hotkeyName: String { hotkey == .fn ? "🌐 Fn" : "右 Option" }

    // MARK: 其他

    var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { store("onboarded", newValue) }
    }
    var historyEnabled: Bool {
        get { d.object(forKey: "historyEnabled") as? Bool ?? true }
        set { store("historyEnabled", newValue) }
    }
    var soundEnabled: Bool {
        get { d.bool(forKey: "soundEnabled") }
        set { store("soundEnabled", newValue) }
    }
    var cjkSpacing: Bool {
        get { d.object(forKey: "cjkSpacing") as? Bool ?? true }
        set { store("cjkSpacing", newValue) }
    }
    /// 逐段填入：停顿多久切成一段（秒）
    var pauseSeconds: Double { d.object(forKey: "pauseSeconds") as? Double ?? 0.8 }
    /// 按住说：按下不足这个时长视为误触（秒）
    var minPressSeconds: Double { d.object(forKey: "minPressSeconds") as? Double ?? 0.35 }

    // MARK: 展示用文字

    var presetName: String {
        switch preset { case .quality: return "效果优先"; case .privacy: return "隐私优先"; case .custom: return "自定义" }
    }
    var recordModeName: String { recordMode == .hold ? "按住说话" : "按一下开始/结束" }
    var insertModeName: String { insertMode == .segment ? "边说边逐段填入" : "说完后一次填入" }
    var levelName: String {
        switch cleanupLevel { case .raw: return "原样"; case .light: return "轻度整理"; case .polish: return "润色" }
    }
    var summary: String {
        "\(presetName) · \(recordModeName) · \(insertModeName) · \(levelName) · 快捷键 \(hotkeyName)"
    }
}

/// API Key：优先读钥匙串（在设置里填写），其次读被 gitignore 的本地配置文件。
/// Key 不写进日志，也不写进仓库。
enum KeyStore {
    static let service = "io.github.legendkyouma-glitch.saytype.openrouter"
    static let account = "default"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?? = nil

    static var hasKey: Bool { key != nil }

    static var key: String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let k = readKeychain() ?? readConfigFile()
        cached = .some(k)
        return k
    }

    static var source: String {
        if readKeychain() != nil { return "钥匙串" }
        if readConfigFile() != nil { return "本地配置文件" }
        return "无"
    }

    static func reload() { lock.lock(); cached = nil; lock.unlock() }

    private static func readKeychain() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    /// local.config.json：{"openrouter_api_key": "sk-or-..."}
    static var configFileCandidates: [URL] {
        ConfigurationPaths.candidates(bundleURL: Bundle.main.bundleURL, supportURL: Paths.support)
    }

    private static func readConfigFile() -> String? {
        for url in configFileCandidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let k = (obj["openrouter_api_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !k.isEmpty, !k.hasPrefix("<") else { continue }
            return k
        }
        return nil
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        deleteKeychain()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        reload()
        return ok
    }

    static func deleteKeychain() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        reload()
    }
}
