import AppKit
import AVFoundation
import SwiftUI

// MARK: - 一次说话的会话

/// 一段识别的结果；pending 是还没回来的云端识别（本机结果先填入时）
struct SegOut: Sendable {
    let text: String
    let model: String
    let cloud: Bool
    var note: String? = nil
    let pending: Task<(text: String, model: String), Error>?
}

struct LocalSegmentResult: Sendable {
    let text: String
    let model: String
    var note: String? = nil
}

/// 已经填进输入框的一段（含段间空格），用于云端结果晚到时核对和替换
struct InsertedPiece {
    var text: String
    let method: String
    var at: Double
}


final class Session: @unchecked Sendable {
    let id: Int
    let t0 = nowMs()
    let target: Inserter.Target
    let asr: ASREngine
    let localModelID: String
    let localModelName: String
    let cloudASRModel: String
    let cloudCleanupModel: String
    let cloudBaseURL: String
    let cjkSpacing: Bool
    let insertMode: InsertMode
    let level: CleanupLevel
    let cleanupEngine: CleanupEngine
    let recordMode: RecordMode
    let practice: Bool
    let recorder: SegmentRecorder

    // 音频线程会访问的部分，用锁保护
    private let lock = NSLock()
    private var local: LocalASRSession?
    private var pending: [AVAudioPCMBuffer] = []

    // 以下只在主线程访问
    var chain: Task<Void, Never>?
    var raws: [String] = []      // 每段识别原文（按顺序）
    var inserted: [String] = []  // 已经填入的整理后文字
    var pieces: [InsertedPiece] = [] // 和 inserted 一一对应：实际填入的文字和方式
    var held: [String] = []      // 没能填入、结束后放进剪贴板的文字
    var cancelled = false
    var focusLost = false
    var insertFailed = false
    var locked = false
    var segments = 0
    var stopMs: Double?
    var asrUsed = Set<String>()
    var cleanupUsed = Set<String>()
    var methods = Set<String>()
    var warnedCap = false
    var localTasks: [Task<LocalSegmentResult, Never>] = []
    var cloudTasks: [Task<(text: String, model: String), Error>] = []
    var releasedLocalModel = false
    var lastRecognition = ""
    var lastCleanup = ""
    var lastUpgradeTitle: String?
    var historyID: UUID?

    init(id: Int, target: Inserter.Target, settings s: Settings, practice: Bool) {
        self.id = id
        self.target = target
        self.asr = s.asr
        self.localModelID = s.localModelID
        self.localModelName = s.localModelName
        self.cloudASRModel = s.sttModel
        self.cloudCleanupModel = s.llmModel
        self.cloudBaseURL = s.baseURL
        self.cjkSpacing = s.cjkSpacing
        self.level = s.effectiveLevel
        self.cleanupEngine = s.cleanupEngine
        self.insertMode = s.effectiveInsertMode
        self.recordMode = s.recordMode
        self.practice = practice
        self.recorder = SegmentRecorder(pauseSeconds: s.pauseSeconds)
    }

    func onAudio(_ buf: AVAudioPCMBuffer) {
        recorder.feed(buf)
        // Other local models produce their own segment previews; never label Apple text as theirs.
        guard localModelID == LocalModelCatalog.appleID else { return }
        lock.lock()
        if let l = local { lock.unlock(); l.feed(buf); return }
        // 本机识别还没准备好：先存起来，准备好后补喂，避免丢掉开头的字
        if let copy = buf.copy() as? AVAudioPCMBuffer { pending.append(copy) }
        lock.unlock()
    }

    func attachLocal(_ l: LocalASRSession) {
        lock.lock()
        let backlog = pending
        pending.removeAll()
        local = l
        lock.unlock()
        for b in backlog { l.feed(b) }
    }

    var localSession: LocalASRSession? { lock.lock(); defer { lock.unlock() }; return local }
}

// MARK: - 主流程

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let audio = AudioCapture()
    private let inserter = Inserter()
    private let history = HistoryStore.shared
    private var hud: HUD!
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var session: Session?
    private var finishing: Session?
    private var nextID = 1
    private var lastCompletedSessionID: Int?
    /// 最近一次往其他应用填入文字的时间（用于判断“选中再粘贴”替换是否安全）
    private var lastInsertMs: Double = 0
    private var noticed = Set<String>()
    private let onboarding = OnboardingModel()
    private var windows: [String: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        hud = HUD()
        hotkey.keyProvider = { Settings.shared.hotkey }
        hotkey.modeProvider = { Settings.shared.recordMode }
        hotkey.busyProvider = { [weak self] in
            MainActor.assumeIsolated { self?.finishing != nil && self?.session == nil }
        }
        hotkey.onStart = { [weak self] in MainActor.assumeIsolated { self?.startSession() } }
        hotkey.onStop = { [weak self] in MainActor.assumeIsolated { self?.stopSession(reason: "hotkey") } }
        hotkey.onLock = { [weak self] in MainActor.assumeIsolated { self?.lockSession() } }
        hotkey.onCancel = { [weak self] r in MainActor.assumeIsolated { self?.cancelSession(r) } }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        setupOnboardingModel()

        let os = ProcessInfo.processInfo.operatingSystemVersion
        Log.shared.ev("launch", [
            "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "bundle": Bundle.main.bundlePath,
            "hotkey": settings.hotkey.rawValue,
            "globeUsage": GlobeKey.usageType().map { "\($0)" } ?? "unset",
            "preset": settings.preset.rawValue, "hasKey": KeyStore.hasKey,
            "axTrusted": Inserter.isTrusted, "mic": AudioCapture.micStatus,
        ])

        Task {
            let assets = await LocalASRSession.ensureAssets()
            Log.shared.ev("local_assets", ["status": assets])
        }

        if Inserter.isTrusted { startHotkey(announce: settings.onboarded) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if !settings.onboarded || !Inserter.isTrusted || !AudioCapture.micAuthorized {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: 权限和快捷键监听

    private func poll() {
        onboarding.micGranted = AudioCapture.micAuthorized
        onboarding.axGranted = Inserter.isTrusted
        onboarding.globeUsage = GlobeKey.usageType()
        if Inserter.isTrusted && !hotkey.isRunning {
            startHotkey(announce: false)
        }
        updateIcon()
    }

    private func startHotkey(announce: Bool) {
        let ok = hotkey.start()
        Log.shared.ev("hotkey_tap", ["ok": ok, "key": settings.hotkey.rawValue])
        if ok && announce {
            hud.setModels(configuredModels())
            hud.flash(.info, "SayType 已就绪", hintIdle, tag: engineTag(), seconds: 3)
        }
    }

    private var hintIdle: String {
        settings.recordMode == .hold
            ? "按住 \(settings.hotkeyName) 说话，松开填入；按住时按空格可锁定"
            : "按一下 \(settings.hotkeyName) 开始说话，再按一下结束"
    }

    private func engineTag(_ s: Session? = nil) -> String {
        let mode = s?.insertMode ?? settings.effectiveInsertMode
        let level = s?.level ?? settings.effectiveLevel
        let l: String = { switch level { case .raw: return "原样"; case .light: return "轻度整理"; case .polish: return "润色" } }()
        return "\(mode == .segment ? "逐段填入" : "一次填入") · \(l)"
    }

    private func configuredModels(_ s: Session? = nil) -> String {
        let asr = s?.asr ?? settings.asr
        let local = s?.localModelName ?? settings.localModelName
        let primary = s?.cloudASRModel ?? settings.sttModel
        let backup = primary == Cloud.backupSTTModel ? "qwen/qwen3-asr-1.7b" : Cloud.backupSTTModel
        let recognition = asr == .local
            ? ModelPresentation.recognition(local, cloud: false)
            : "\(ModelPresentation.displayName(primary)) / \(ModelPresentation.displayName(backup))（云端候选）"
        let level = s?.level ?? settings.effectiveLevel
        let cleanup = level == .raw ? "原样" : ModelPresentation.cleanup(
            engine: (s?.cleanupEngine ?? settings.cleanupEngine) == .cloud ? "cloud" : "rules",
            model: s?.cloudCleanupModel ?? settings.llmModel)
        return "识别：\(recognition)\n整理：\(cleanup)"
    }

    private func isVisible(_ s: Session) -> Bool {
        s.id == nextID - 1 && (session === s || (session == nil && finishing === s))
    }

    private func updateModelInfo(_ s: Session) {
        guard s.id == nextID - 1 else { return }
        guard session === s || (session == nil && finishing === s)
                || (session == nil && finishing == nil && lastCompletedSessionID == s.id) else { return }
        if s.lastRecognition.isEmpty {
            hud.setModels(configuredModels(s))
        } else {
            hud.setModels("识别：\(s.lastRecognition)\n整理：\(s.lastCleanup.isEmpty ? "待处理" : s.lastCleanup)")
        }
    }

    private func releaseLocalModel(_ s: Session) {
        guard !s.releasedLocalModel else { return }
        s.releasedLocalModel = true
        let tasks = s.localTasks
        Task { @MainActor in
            for task in tasks { _ = await task.value }
            LocalModelManager.shared.endSession(s.localModelID)
        }
    }

    // MARK: 会话

    private func onboardingVisible() -> Bool { windows["onboarding"]?.isVisible == true }

    private func startSession() {
        // 引导里“按一下试试”：只确认能收到快捷键
        if onboardingVisible() && onboarding.step == .hotkey {
            onboarding.hotkeyDetected = true
            hotkey.reset()
            Log.shared.ev("onboarding_hotkey_detected", ["key": settings.hotkey.rawValue])
            return
        }
        guard session == nil else { return }
        guard AudioCapture.micAuthorized else {
            hotkey.reset()
            hud.flash(.failed, "还没有麦克风权限", "点菜单栏的波形图标 → 完成授权", seconds: 4)
            showOnboarding()
            return
        }
        let practice = onboardingVisible() && onboarding.step == .tryIt && NSApp.isActive
        let target = inserter.captureTarget()
        if !practice && (Inserter.secureInputOn || target.role == "AXSecureTextField") {
            hotkey.reset()
            Log.shared.ev("secure_input_blocked", ["app": target.bundleID])
            hud.flash(.failed, "这里不支持语音输入", "当前是密码框或安全输入状态，SayType 不会在这里录音", seconds: 3)
            return
        }
        if finishing != nil { Log.shared.ev("start_while_finishing") }

        let s = Session(id: nextID, target: target, settings: settings, practice: practice)
        nextID += 1
        lastCompletedSessionID = nil
        session = s
        LocalModelManager.shared.beginSession(s.localModelID)
        Log.shared.ev("session_start", ["id": s.id, "app": target.bundleID, "role": target.role,
                                         "hasElement": target.element != nil, "asr": s.asr.rawValue,
                                         "insertMode": s.insertMode.rawValue, "level": s.level.rawValue,
                                         "cleanup": s.cleanupEngine.rawValue, "practice": practice])

        // 按停顿切段：云端识别逐段上传；本机识别逐段做一次性识别（流式会话只在停顿处不出最终结果）
        s.recorder.onSegment = { [weak self] samples, idx in
            Task { @MainActor in
                if s.asr == .cloud { self?.cloudSegment(samples, idx, s) } else { self?.localSegment(samples, idx, s) }
            }
        }
        audio.onBuffer = { [weak s] buf in s?.onAudio(buf) }
        audio.onLevel = { [weak self] db in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.hud.model.push(db: db) } }
        }
        do {
            try audio.start()
        } catch {
            Log.shared.ev("mic_start_error", ["error": "\(error)"])
            session = nil
            releaseLocalModel(s)
            hotkey.reset()
            hud.flash(.failed, "麦克风没有启动", "请检查输入设备：系统设置 → 声音 → 输入", seconds: 4)
            return
        }
        if settings.soundEnabled { NSSound(named: "Tink")?.play() }
        if practice { onboarding.resetPractice(); onboarding.listening = true }
        updateIcon()
        hud.model.elapsed = "0:00"
        hud.setModels(configuredModels(s))
        hud.show(.listening, "正在听…", listeningHint(s), tag: engineTag(s))
        startTick(s)

        // Apple preview is used only when Apple is the selected local model.
        guard s.localModelID == LocalModelCatalog.appleID else { return }
        Task {
            do {
                let l = try await LocalASRSession.make()
                l.onVolatile = { [weak self] text in
                    Task { @MainActor in
                        guard let self, !s.cancelled, self.session === s else { return }
                        self.hud.setDetail(text)
                    }
                }
                l.onFinal = { [weak self] text in
                    Task { @MainActor in
                        guard let self, !s.cancelled, self.session === s else { return }
                        self.hud.setDetail(text)
                    }
                }
                try await l.start()
                guard !s.cancelled, self.session === s else { _ = await l.finish(); return }
                s.attachLocal(l)
                Log.shared.ev("local_ready", ["id": s.id, "ms": Int(nowMs() - s.t0)])
            } catch {
                Log.shared.ev("local_start_error", ["id": s.id, "error": "\(error)"])
            }
        }
    }

    private func listeningHint(_ s: Session) -> String {
        if s.locked || s.recordMode == .toggle { return "再按一次 \(settings.hotkeyName) 结束 · Esc 取消" }
        return "松开 \(settings.hotkeyName) 结束 · 按空格锁定 · Esc 取消"
    }

    private func startTick(_ s: Session) {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session === s else { return }
                let sec = Int((nowMs() - s.t0) / 1000)
                self.hud.model.elapsed = String(format: "%d:%02d", sec / 60, sec % 60)
                // 单次最长 5 分钟
                if sec >= 300 {
                    self.hotkey.reset()
                    self.stopSession(reason: "max-duration")
                    return
                }
                if sec >= 285 && !s.warnedCap {
                    s.warnedCap = true
                    self.hud.setDetail("快到 5 分钟上限了，到时会自动结束并填入")
                }
                // 按一下开始或锁定时：30 秒没有声音自动结束
                if (s.recordMode == .toggle || s.locked) && nowMs() - max(s.recorder.lastSpeechMs, s.t0) > 30_000 {
                    self.hotkey.reset()
                    self.stopSession(reason: "silence")
                }
            }
        }
    }

    private func lockSession() {
        guard let s = session else { return }
        s.locked = true
        Log.shared.ev("session_lock", ["id": s.id, "ms": Int(nowMs() - s.t0)])
        hud.show(.locked, "已锁定，可以松手说话", listeningHint(s), tag: engineTag(s))
    }

    private func cancelSession(_ reason: String) {
        let s: Session
        if let cur = session {
            s = cur
            audio.stop()
            session = nil
            tickTimer?.invalidate()
        } else if let f = finishing {
            s = f
        } else { return }
        s.cancelled = true
        for task in s.localTasks { task.cancel() }
        for task in s.cloudTasks { task.cancel() }
        releaseLocalModel(s)
        s.recorder.discard()
        Task { _ = await s.localSession?.finish() }
        if finishing === s { finishing = nil }
        onboarding.listening = false
        updateIcon()
        let dur = nowMs() - s.t0
        Log.shared.ev("session_cancel", ["id": s.id, "reason": reason, "ms": Int(dur), "insertedSegments": s.inserted.count])
        if reason == "combo" && dur < 800 {
            hud.hide()
        } else {
            hud.flash(.info, "已取消",
                      s.inserted.isEmpty ? "这次没有填入任何文字" : "已填入 \(s.inserted.count) 段，可按 Cmd+Z 撤回",
                      seconds: 1.8)
        }
    }

    private func stopSession(reason: String) {
        guard let s = session else { return }
        let dur = nowMs() - s.t0
        s.stopMs = nowMs()
        audio.stop()
        session = nil
        tickTimer?.invalidate()
        onboarding.listening = false
        updateIcon()
        if settings.soundEnabled { NSSound(named: "Pop")?.play() }
        if s.recordMode == .hold && !s.locked && reason == "hotkey" && dur < settings.minPressSeconds * 1000 {
            s.cancelled = true
            releaseLocalModel(s)
            s.recorder.discard()
            Task { _ = await s.localSession?.finish() }
            Log.shared.ev("session_discard_short", ["id": s.id, "ms": Int(dur)])
            hud.hide()
            return
        }
        Log.shared.ev("session_stop", ["id": s.id, "reason": reason, "ms": Int(dur)])
        let title = reason == "silence" ? "长时间没有声音，已自动结束" : (s.insertMode == .once ? "整理中…" : "处理中…")
        hud.show(.processing, title, s.inserted.isEmpty ? "" : "已填入 \(s.inserted.count) 段", tag: engineTag(s))
        finishing = s
        if s.asr == .cloud || s.cleanupEngine == .cloud {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible(s), self.session == nil, !s.cancelled else { return }
                    self.hud.setDetail("云端响应有点慢，正在等待；按 Esc 可取消")
                }
            }
        }
        Task { @MainActor in
            if let l = s.localSession { _ = await l.finish() }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.recorder.flush { c.resume() } }
            // 让识别回调排进来的段落先入队，再等全部段落处理完
            for _ in 0..<3 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 60_000_000)
            while true {
                let c = s.chain
                await c?.value
                if s.chain == c { break }
            }
            await self.finalize(s)
        }
    }

    // MARK: 段落流水线：识别可以并行，整理和填入按顺序

    private func enqueue(_ s: Session, produce: @escaping @Sendable () async -> SegOut) {
        let idx = s.segments
        s.segments += 1
        let produceTask = Task { await produce() }
        let prev = s.chain
        s.chain = Task { @MainActor in
            let out = await produceTask.value
            let raw = out.text
            await prev?.value
            guard !s.cancelled else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // 没有检测到说话声：不插入任何东西（防止“不说话也出字”）
            guard s.recorder.speechSeen else {
                Log.shared.ev("drop_no_speech", ["id": s.id, "seg": idx])
                return
            }
            // 只有“嗯”“呃”或标点的段落（例如停顿时的噪声）：丢弃
            guard s.level == .raw || RulesCleaner.hasContent(trimmed) else {
                Log.shared.ev("drop_filler_only", ["id": s.id, "seg": idx, "chars": trimmed.count])
                return
            }
            s.raws.append(trimmed)
            let recognition = ModelPresentation.recognition(out.model, cloud: out.cloud)
            s.asrUsed.insert(recognition)
            s.lastRecognition = recognition
            self.updateModelInfo(s)
            if let note = out.note, self.isVisible(s) {
                self.hud.setDetail(note)
            }
            if s.insertMode == .once { return } // 一次填入：结束后整段整理
            let c = await Cleaner.run(trimmed, context: s.inserted.joined(), level: s.level,
                                      engine: s.cleanupEngine, app: s.target.appName,
                                      model: s.cloudCleanupModel, baseURL: s.cloudBaseURL, cjkSpacing: s.cjkSpacing)
            let cleanup = ModelPresentation.cleanup(engine: c.engine, model: c.model ?? "")
            s.cleanupUsed.insert(cleanup)
            s.lastCleanup = cleanup
            self.updateModelInfo(s)
            Log.shared.ev("cleanup", ["id": s.id, "seg": idx, "engine": c.engine, "inChars": trimmed.count,
                                      "outChars": c.text.count, "ms": Int(c.ms), "note": c.note.map { String($0.prefix(160)) } ?? ""])
            if let note = c.note, note.hasPrefix("cloud failed"), !s.cancelled,
               self.isVisible(s) {
                self.noticeOnce("cleanup-fail", "云端整理暂时不可用，这次改用本机规则", "文字会更口语一些")
            }
            guard !s.cancelled else { return }
            guard RulesCleaner.hasContent(c.text) || s.level == .raw else {
                Log.shared.ev("drop_empty_cleanup", ["id": s.id, "seg": idx])
                return
            }
            let before = s.pieces.count
            self.deliver(c.text, s, seg: idx)
            // 本机先填入的段落：云端结果晚到后覆盖
            if let pending = out.pending, s.pieces.count == before + 1 {
                self.scheduleUpgrade(s, pieceIndex: before, seg: idx, pending: pending)
            }
        }
    }

    private func cloudSegment(_ samples: [Float], _ idx: Int, _ s: Session) {
        guard !s.cancelled else { return }
        let seconds = Double(samples.count) / SegmentRecorder.rate
        let t0 = nowMs()
        // 云端和本机同时开始；云端 4 秒内回来就用云端，否则先用本机结果，云端回来后再覆盖
        let race = Task { () throws -> (text: String, model: String) in
            do {
                let r = try await Cloud.transcribeRace(samples: samples, primaryModel: s.cloudASRModel, baseURL: s.cloudBaseURL)
                Log.shared.ev("cloud_asr", ["id": s.id, "seg": idx, "audioSec": seconds, "ms": Int(nowMs() - t0),
                                            "chars": r.text.count, "model": r.model])
                return r
            } catch {
                Log.shared.ev("cloud_asr_error", ["id": s.id, "seg": idx, "audioSec": seconds, "ms": Int(nowMs() - t0),
                                                  "error": String("\(error)".prefix(200))])
                throw error
            }
        }
        let local = makeLocalTask(samples, s)
        s.cloudTasks.append(race)
        enqueue(s) {
            switch await waitFor(race, seconds: AppDelegate.cloudPatience) {
            case .ok(let text, let model):
                return SegOut(text: text, model: model, cloud: true, pending: nil)
            case .failed:
                let result = await local.value
                return SegOut(text: result.text, model: result.model, cloud: false,
                              note: "云端识别失败，已用 \(result.model) 识别", pending: nil)
            case .late:
                Log.shared.ev("cloud_asr_late_local_first", ["id": s.id, "seg": idx, "audioSec": seconds])
                let available = await firstAvailable(cloud: race, local: local, isUsableLocal: { result in
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !text.isEmpty && (s.level == .raw || RulesCleaner.hasContent(text))
                })
                switch available {
                case .cloud(let text, let model):
                    return SegOut(text: text, model: model, cloud: true, pending: nil)
                case .local(let result):
                    return SegOut(text: result.text, model: result.model, cloud: false,
                                  note: "先用 \(result.model) 出字，等待云端结果",
                                  pending: s.insertMode == .segment ? race : nil)
                }
            }
        }
    }

    /// 云端识别等待多久后先用本机结果（秒），默认 4 秒；调试时可用 defaults 修改 cloudPatience
    static var cloudPatience: Double { UserDefaults.standard.object(forKey: "cloudPatience") as? Double ?? 4 }

    private func localSegment(_ samples: [Float], _ idx: Int, _ s: Session) {
        guard !s.cancelled else { return }
        let seconds = Double(samples.count) / SegmentRecorder.rate
        let t0 = nowMs()
        let local = makeLocalTask(samples, s)
        enqueue(s) {
            let result = await local.value
            Log.shared.ev("local_asr", ["id": s.id, "seg": idx, "audioSec": seconds, "ms": Int(nowMs() - t0),
                                        "chars": result.text.count, "model": result.model])
            return SegOut(text: result.text, model: result.model, cloud: false, note: result.note, pending: nil)
        }
    }

    private func makeLocalTask(_ samples: [Float], _ s: Session) -> Task<LocalSegmentResult, Never> {
        let id = s.localModelID
        let name = s.localModelName
        let task = Task { () -> LocalSegmentResult in
            guard !Task.isCancelled else { return LocalSegmentResult(text: "", model: name) }
            if id == LocalModelCatalog.appleID {
                return LocalSegmentResult(text: await LocalASRSession.transcribe(samples: samples), model: ModelPresentation.appleName)
            }
            do {
                let text = try await LocalModelRuntime.shared.transcribe(samples: samples, modelID: id)
                guard !Task.isCancelled else { return LocalSegmentResult(text: "", model: name) }
                return LocalSegmentResult(text: text, model: name)
            } catch {
                guard !Task.isCancelled else { return LocalSegmentResult(text: "", model: name) }
                Log.shared.ev("local_model_fallback", ["model": id])
                return LocalSegmentResult(text: await LocalASRSession.transcribe(samples: samples),
                                          model: ModelPresentation.appleName,
                                          note: "\(name) 暂时不可用，已改用 Apple 语音识别")
            }
        }
        s.localTasks.append(task)
        return task
    }

    /// 云端结果晚到：整理后替换掉先填入的本机文字。只有能核对原文时才替换，否则保留本机结果。
    private func scheduleUpgrade(_ s: Session, pieceIndex i: Int, seg: Int, pending: Task<(text: String, model: String), Error>) {
        Task { @MainActor [weak self] in
            guard let r = try? await pending.value, let self, !s.cancelled else { return }
            let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RulesCleaner.hasContent(trimmed), i < s.pieces.count else { return }
            let c = await Cleaner.run(trimmed, context: s.inserted.prefix(i).joined(), level: s.level,
                                      engine: s.cleanupEngine, app: s.target.appName,
                                      model: s.cloudCleanupModel, baseURL: s.cloudBaseURL, cjkSpacing: s.cjkSpacing)
            guard !s.cancelled, RulesCleaner.hasContent(c.text), i < s.pieces.count else { return }
            let p = s.pieces[i]
            let newPiece = self.joinPiece(previous: i > 0 ? s.inserted[i - 1] : nil, next: c.text)
            if newPiece == p.text { return }
            let suffix = s.pieces[(i + 1)...].map { $0.text }.joined()
            var ok = false
            var how = "none"
            if s.practice {
                if let range = self.onboarding.practiceText.range(of: p.text + suffix, options: .backwards) {
                    self.onboarding.practiceText.replaceSubrange(range, with: newPiece + suffix)
                    ok = true; how = "practice"
                }
            } else if !s.focusLost && self.inserter.focusStillOn(s.target) {
                if self.inserter.replaceAX(old: p.text, new: newPiece, suffixAfter: suffix, in: s.target) {
                    ok = true; how = "ax"
                }
            }
            Log.shared.ev("cloud_upgrade", ["id": s.id, "seg": seg, "ok": ok, "how": how, "model": r.model,
                                            "oldChars": p.text.count, "newChars": newPiece.count])
            guard ok else { return }
            s.pieces[i].text = newPiece
            s.pieces[i].at = nowMs()
            if self.lastInsertMs == p.at { self.lastInsertMs = s.pieces[i].at }
            s.inserted[i] = c.text
            s.lastRecognition = ModelPresentation.recognition(r.model, cloud: true)
            s.lastCleanup = ModelPresentation.cleanup(engine: c.engine, model: c.model ?? "")
            s.asrUsed.insert(s.lastRecognition)
            s.cleanupUsed.insert(s.lastCleanup)
            s.lastUpgradeTitle = ModelPresentation.upgradeTitle(recognitionModel: r.model, cleanupModel: c.model)
            self.updateModelInfo(s)
            if let historyID = s.historyID {
                self.history.update(id: historyID, text: self.fullText(s),
                                    asr: s.asrUsed.sorted().joined(separator: " + "), cleanup: self.cleanupName(s))
            }
            if self.isVisible(s) {
                self.hud.model.title = s.lastUpgradeTitle!
            } else if self.session == nil && self.finishing == nil && self.lastCompletedSessionID == s.id
                        && s.id == self.nextID - 1 {
                self.hud.flash(.done, s.lastUpgradeTitle!, String(c.text.suffix(60)), tag: self.engineTag(s), seconds: 3)
            }
        }
    }

    private func deliver(_ text: String, _ s: Session, seg: Int) {
        guard !text.isEmpty else { return }
        let piece = joinPiece(previous: s.inserted.last, next: text)
        if s.practice {
            onboarding.practiceText += piece
            s.inserted.append(text)
            s.pieces.append(InsertedPiece(text: piece, method: "practice", at: nowMs()))
            return
        }
        if s.focusLost || s.insertFailed || !inserter.focusStillOn(s.target) {
            if !s.focusLost && !s.insertFailed {
                Log.shared.ev("focus_changed", ["id": s.id, "seg": seg])
                if session === s { hud.setDetail("输入框已切换：后面的文字会放进剪贴板，不会填到别处") }
                s.focusLost = true
            }
            s.held.append(text)
            return
        }
        let out = inserter.insert(piece, into: s.target)
        s.methods.insert(out.method)
        Log.shared.ev("insert", ["id": s.id, "seg": seg, "method": out.method, "ok": out.ok, "detail": out.detail,
                                 "ms": Int(out.ms), "app": s.target.bundleID, "role": s.target.role,
                                 "sinceStartMs": Int(nowMs() - s.t0),
                                 "sinceReleaseMs": s.stopMs.map { Int(nowMs() - $0) } ?? -1])
        if out.ok {
            s.inserted.append(text)
            let at = nowMs()
            s.pieces.append(InsertedPiece(text: piece, method: out.method, at: at))
            lastInsertMs = at
            if session === s { hud.setTag(engineTag(s) + " · 已填入 \(s.inserted.count) 段") }
        } else {
            s.insertFailed = true
            s.held.append(text)
        }
    }

    private func finalize(_ s: Session) async {
        guard !s.cancelled else { return }
        // 一次填入：整段整理后插入
        if s.insertMode == .once && !s.raws.isEmpty {
            let raw = s.raws.reduce("") { $0 + joinPiece(previous: $0.isEmpty ? nil : $0, next: $1) }
            let c = await Cleaner.run(raw, context: "", level: s.level, engine: s.cleanupEngine, app: s.target.appName,
                                      model: s.cloudCleanupModel, baseURL: s.cloudBaseURL, cjkSpacing: s.cjkSpacing)
            s.lastCleanup = ModelPresentation.cleanup(engine: c.engine, model: c.model ?? "")
            s.cleanupUsed.insert(s.lastCleanup)
            updateModelInfo(s)
            Log.shared.ev("cleanup", ["id": s.id, "seg": -1, "engine": c.engine, "inChars": raw.count,
                                      "outChars": c.text.count, "ms": Int(c.ms), "note": c.note.map { String($0.prefix(160)) } ?? ""])
            if let note = c.note, note.hasPrefix("cloud failed"), !s.cancelled,
               isVisible(s) {
                noticeOnce("cleanup-fail", "云端整理暂时不可用，这次改用本机规则", "文字会更口语一些")
            }
            guard !s.cancelled else { return }
            if s.practice {
                onboarding.practiceText = c.text
                s.inserted.append(c.text)
            } else if inserter.focusStillOn(s.target) {
                let out = inserter.insert(c.text, into: s.target)
                s.methods.insert(out.method)
                Log.shared.ev("insert", ["id": s.id, "seg": -1, "method": out.method, "ok": out.ok, "detail": out.detail,
                                         "ms": Int(out.ms), "app": s.target.bundleID,
                                         "sinceReleaseMs": s.stopMs.map { Int(nowMs() - $0) } ?? -1])
                if out.ok { s.inserted.append(c.text); lastInsertMs = nowMs() } else { s.insertFailed = true; s.held.append(c.text) }
            } else {
                s.focusLost = true
                s.held.append(c.text)
            }
        }

        var heldText = ""
        for h in s.held { heldText += joinPiece(previous: heldText.isEmpty ? nil : heldText, next: h) }
        if !heldText.isEmpty { inserter.copyOnly(heldText) }

        let insertedText = s.inserted.reduce("") { $0 + joinPiece(previous: $0.isEmpty ? nil : $0, next: $1) }
        let fullText = [insertedText, heldText].filter { !$0.isEmpty }.joined(separator: insertedText.isEmpty || heldText.isEmpty ? "" : "")
        let rawText = s.raws.reduce("") { $0 + joinPiece(previous: $0.isEmpty ? nil : $0, next: $1) }
        let status: String = heldText.isEmpty ? "已填入" : (s.focusLost ? "输入框已切换，已复制" : "未能填入，已复制")

        Log.shared.ev("session_end", ["id": s.id, "segments": s.segments, "inserted": s.inserted.count,
                                       "held": s.held.count, "chars": fullText.count,
                                       "asr": Array(s.asrUsed).sorted(), "cleanup": Array(s.cleanupUsed).sorted(),
                                       "methods": Array(s.methods).sorted(), "speech": s.recorder.speechSeen,
                                       "releaseToEndMs": s.stopMs.map { Int(nowMs() - $0) } ?? -1])
        s.recorder.discard()
        releaseLocalModel(s)
        if finishing === s { finishing = nil }
        if s.id == nextID - 1 { lastCompletedSessionID = s.id }

        if !fullText.isEmpty {
            let entry = HistoryItem(date: Date(), app: s.practice ? "SayType 练习" : s.target.appName,
                                    raw: rawText, text: fullText,
                                    asr: s.asrUsed.sorted().joined(separator: " + "),
                                    cleanup: cleanupName(s), status: status)
            s.historyID = entry.id
            history.add(entry)
        }
        if s.practice {
            if fullText.isEmpty {
                onboarding.tryNoSpeech = true
            } else {
                onboarding.tryRaw = rawText
                onboarding.tryClean = fullText
            }
        }

        guard session == nil, s.id == nextID - 1 else { return } // 不覆盖更新的口述或取消状态
        updateModelInfo(s)
        if fullText.isEmpty {
            hud.flash(.failed, s.recorder.speechSeen ? "没有听清" : "没有听到声音",
                      s.recorder.speechSeen ? "可以再说一次" : "请检查麦克风或输入设备，或者说话声音再大一点", seconds: 2.5)
        } else if !heldText.isEmpty {
            hud.flash(.failed, "文字已复制到剪贴板",
                      s.focusLost ? "输入框已切换，按 Cmd+V 粘贴到需要的位置" : "这里没能直接填入，按 Cmd+V 粘贴；也可以在历史里找到",
                      seconds: 3.5)
        } else {
            hud.flash(.done, s.lastUpgradeTitle ?? "已填入", String(fullText.suffix(60)), tag: engineTag(s), seconds: 3)
        }
    }

    private func cleanupName(_ s: Session) -> String {
        if s.level == .raw { return "原样" }
        return s.cleanupUsed.isEmpty ? "未整理" : s.cleanupUsed.sorted().joined(separator: " + ")
    }

    private func fullText(_ s: Session) -> String {
        (s.inserted + s.held).reduce("") { $0 + joinPiece(previous: $0.isEmpty ? nil : $0, next: $1) }
    }

    /// 段与段之间：英文/数字相邻时补一个空格，中文直接相连
    private func joinPiece(previous: String?, next: String) -> String {
        guard let p = previous?.last, let n = next.first else { return next }
        let isWord: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if isWord(n) && (isWord(p) || ".,!?;:".contains(p)) { return " " + next }
        return next
    }

    private func noticeOnce(_ key: String, _ title: String, _ detail: String) {
        guard !noticed.contains(key) else { return }
        noticed.insert(key)
        Log.shared.ev("notice", ["key": key])
        if session != nil || finishing != nil {
            hud.model.title = title
            hud.setDetail(detail)
        } else {
            hud.flash(.info, title, detail, seconds: 3)
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let missing = !Inserter.isTrusted || !AudioCapture.micAuthorized
        let name = session != nil ? "waveform.circle.fill" : (missing ? "exclamationmark.triangle" : "waveform")
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "SayType")
        button.contentTintColor = session != nil ? .systemRed : nil
    }

    // MARK: 窗口

    private func showWindow<V: View>(_ id: String, title: String, view: V) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }

    private func setupOnboardingModel() {
        onboarding.micGranted = AudioCapture.micAuthorized
        onboarding.axGranted = Inserter.isTrusted
        onboarding.globeUsage = GlobeKey.usageType()
        onboarding.requestMic = { [weak self] in
            Task { @MainActor in
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .notDetermined {
                    let ok = await AudioCapture.requestMicAccess()
                    Log.shared.ev("perm_mic", ["granted": ok])
                } else if status != .authorized {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                self?.poll()
            }
        }
        onboarding.requestAX = {
            Inserter.promptForTrust()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            Log.shared.ev("perm_ax_prompted")
        }
        onboarding.openKeyboardSettings = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        }
        onboarding.openSettings = { [weak self] in self?.openSettings() }
        onboarding.finish = { [weak self] in
            guard let self else { return }
            self.settings.onboarded = true
            self.windows["onboarding"]?.close()
            Log.shared.ev("onboarding_done", ["tried": !self.onboarding.tryClean.isEmpty])
            self.hud.flash(.info, "去任意应用里试试吧", self.hintIdle, tag: self.engineTag(), seconds: 3.5)
        }
    }

    private func showOnboarding() {
        if !onboardingVisible() {
            if !(AudioCapture.micAuthorized && Inserter.isTrusted) { onboarding.step = .welcome }
        }
        showWindow("onboarding", title: "欢迎使用 SayType", view: OnboardingView(m: onboarding))
    }

    @objc private func openSettings() {
        showWindow("settings", title: "SayType 设置", view: SettingsView(testKey: { await AppDelegate.testKey() }))
    }

    @objc private func openHistory() {
        showWindow("history", title: "SayType 历史", view: HistoryView())
    }

    @objc private func openOnboarding() {
        onboarding.step = .welcome
        onboarding.hotkeyDetected = false
        onboarding.resetPractice()
        showOnboarding()
    }

    /// 用一次极短的整理请求确认 Key 可用（产品自身的连通性检查）
    static func testKey() async -> String {
        let t0 = nowMs()
        do {
            _ = try await Cloud.cleanup("嗯测试一下", context: "", level: .light, app: "")
            Log.shared.ev("key_check", ["ok": true, "ms": Int(nowMs() - t0)])
            return "连接正常（\(Int(nowMs() - t0)) ms），已可以使用效果优先"
        } catch {
            Log.shared.ev("key_check", ["ok": false, "ms": Int(nowMs() - t0), "error": String("\(error)".prefix(200))])
            return "暂时连不上：\(String("\(error)".prefix(120)))"
        }
    }

    // MARK: 菜单

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ title: String, _ sel: Selector, key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
        }
        info("SayType 说写")
        info(hintIdle)
        info(settings.summary)
        if !Inserter.isTrusted || !AudioCapture.micAuthorized {
            menu.addItem(.separator())
            item("⚠︎ 还差系统权限，点这里完成授权…", #selector(openOnboarding))
        } else if !hotkey.isRunning {
            menu.addItem(.separator())
            item("⚠︎ 快捷键监听没有运行，点这里重试", #selector(retryHotkey))
        }
        menu.addItem(.separator())
        item("设置…", #selector(openSettings), key: ",")
        item("历史记录…", #selector(openHistory))
        let paste = NSMenuItem(title: "粘贴上一次的结果", action: #selector(pasteLast), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = history.last != nil
        menu.addItem(paste)
        item("清空历史", #selector(clearHistory))
        menu.addItem(.separator())
        item("重新打开引导…", #selector(openOnboarding))
        item("退出 SayType", #selector(quit), key: "q")
    }

    @objc private func retryHotkey() { startHotkey(announce: true) }

    @objc private func pasteLast() {
        guard let last = history.last else { return }
        // 菜单关闭后焦点回到原来的应用，再填入
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = self.inserter.captureTarget()
                let out = self.inserter.insert(last.text, into: t)
                self.lastInsertMs = nowMs()
                Log.shared.ev("paste_last", ["method": out.method, "ok": out.ok, "app": t.bundleID])
            }
        }
    }

    @objc private func clearHistory() {
        history.clear()
        hud.flash(.done, "历史已清空", "", seconds: 1.2)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
