import Foundation
import Combine
import AVFoundation

/// 文字历史：只保存在本机（~/Library/Application Support/SayType/history.json），默认保留 30 天。不保存音频。
struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var app: String
    var raw: String
    var text: String
    var asr: String
    var cleanup: String
    var status: String
}

final class HistoryStore: ObservableObject, @unchecked Sendable {
    static let shared = HistoryStore()
    @Published private(set) var items: [HistoryItem] = []
    private let url: URL
    private let now: () -> Date
    private let isEnabled: () -> Bool
    static let keepDays = 30
    static let maxItems = 500

    init(url: URL = Paths.support.appendingPathComponent("history.json"),
         now: @escaping () -> Date = Date.init,
         isEnabled: @escaping () -> Bool = { Settings.shared.historyEnabled }) {
        self.url = url
        self.now = now
        self.isEnabled = isEnabled
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = list
            // 启动时也写回，确保过期文字从本机文件中移除。
            save()
        }
    }

    var last: HistoryItem? { items.first }

    func add(_ item: HistoryItem) {
        guard isEnabled() else { return }
        items.insert(item, at: 0)
        save()
    }

    func clear() {
        items.removeAll()
        save()
        Log.shared.ev("history_cleared")
    }

    private func save() {
        let cutoff = now().addingTimeInterval(-Double(HistoryStore.keepDays) * 86400)
        items = Array(items.lazy.filter { $0.date > cutoff }.prefix(HistoryStore.maxItems))
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

/// 命令行自检：不用麦克风、不用辅助功能，用一个音频文件跑“识别 → 整理”。
///   SayType --selftest <音频文件> [--cloud]
enum SelfTest {
    static func run(args: [String]) async {
        // 只测云端整理：SayType --selftest --text "要整理的话"（可用环境变量 SAYTYPE_LLM 临时指定模型）
        if let i = args.firstIndex(of: "--text"), i + 1 < args.count {
            let model = ProcessInfo.processInfo.environment["SAYTYPE_LLM"] ?? Settings.shared.llmModel
            let t0 = nowMs()
            do {
                let out = try await Cloud.cleanup(args[i + 1], context: "", level: .light, app: "", model: model)
                print(String(format: "[%@] %.0f ms: %@", model, nowMs() - t0, out))
            } catch {
                print(String(format: "[%@] %.0f ms 失败: %@", model, nowMs() - t0, String("\(error)".prefix(160))))
            }
            return
        }
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            print("用法: SayType --selftest <音频文件> [--cloud]")
            return
        }
        let useCloud = args.contains("--cloud")
        print("== 自检文件: \(path)")
        print("本机语言包: \(await LocalASRSession.ensureAssets())")
        guard let samples = load16k(path) else { print("读取音频失败"); return }
        print(String(format: "音频长度: %.2f 秒", Double(samples.count) / 16000))

        var t0 = nowMs()
        let parts = await LocalASRSession.transcribeParts(samples: samples)
        let local = parts.joined()
        print(String(format: "[本机识别] %.0f ms，%d 段: %@", nowMs() - t0, parts.count, parts.joined(separator: " | ")))
        let rules = await Cleaner.run(local, context: "", level: .light, engine: .rules, app: "")
        print("[规则整理] \(rules.text)")

        if args.contains("--concurrent") {
            // 模拟说话时：一个识别会话做实时预览，同时对切出来的段做一次性识别
            t0 = nowMs()
            let half = samples.count / 2
            async let whole = LocalASRSession.transcribeParts(samples: samples)
            async let a = LocalASRSession.transcribe(samples: Array(samples[0..<half]))
            async let b = LocalASRSession.transcribe(samples: Array(samples[half...]))
            let (w, x, y) = await (whole, a, b)
            print(String(format: "[并发] %.0f ms 预览=%@ | 段1=%@ | 段2=%@", nowMs() - t0, w.joined(), x, y))
        }

        guard useCloud else { return }
        guard KeyStore.hasKey else { print("[云端] 没有 Key，跳过"); return }
        t0 = nowMs()
        do {
            let r = try await Cloud.transcribeRace(samples: samples)
            print(String(format: "[云端识别 并行，采用 %@] %.0f ms: %@", r.model, nowMs() - t0, r.text))
        } catch {
            print(String(format: "[云端识别] %.0f ms 失败: %@", nowMs() - t0, String("\(error)".prefix(200))))
        }
        t0 = nowMs()
        let c = await Cleaner.run(local, context: "", level: .light, engine: .cloud, app: "")
        print(String(format: "[云端整理 %@] %.0f ms (%@): %@", Settings.shared.llmModel, nowMs() - t0, c.engine, c.text))
        if let n = c.note { print("  note: \(n.prefix(200))") }
    }

    static func load16k(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let out = try? BufferConverter().convert(buf, to: target), let ch = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}
