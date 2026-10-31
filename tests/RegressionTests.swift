import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@main
struct RegressionTests {
    nonisolated(unsafe) private static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(description: message) }
        checks += 1
    }

    static func expectError(_ expected: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch let error as CloudError {
            try check(error.description == expected, "Unexpected error category: \(error.description)")
            return
        }
        throw TestFailure(description: "Expected CloudError: \(expected)")
    }

    static func testResponsePrivacy() throws {
        let sentinel = "PRIVATE_RESPONSE_SENTINEL"
        try expectError("http 401") {
            _ = try Cloud.decodeResponse(Data("{\"error\":\"\(sentinel)\"}".utf8), statusCode: 401)
        }
        try expectError("http 503") {
            _ = try Cloud.decodeResponse(Data("<html>\(sentinel)</html>".utf8), statusCode: 503)
        }
        // JSON parser diagnostics and non-object responses must not escape as NSError.
        for payload in ["{\"text\":\"\(sentinel)\"", "[\"\(sentinel)\"]", "null"] {
            try expectError("bad response") {
                _ = try Cloud.decodeResponse(Data(payload.utf8), statusCode: 200)
            }
        }
        try expectError("bad response") {
            _ = try Cloud.decodeResponse(Data([0xff, 0xfe, 0x80]), statusCode: 200)
        }
        try expectError("bad response") {
            _ = try Cloud.transcriptionText(from: ["unexpected": sentinel])
        }
        try expectError("bad response") {
            _ = try Cloud.completionText(from: ["choices": [["message": ["unexpected": sentinel]]]])
        }
        let decoded = try Cloud.decodeResponse(Data("{\"text\":\"  你好  \"}".utf8), statusCode: 200)
        try check(try Cloud.transcriptionText(from: decoded) == "你好", "Valid transcription changed")
        let completed = try Cloud.completionText(from: ["choices": [["finish_reason": "stop", "message": ["content": "  完整结果  "]]]])
        try check(completed == "完整结果", "Valid completion changed")
    }

    static func testTruncationFallback() async throws {
        let raw = "嗯，明天下午三点开会，讨论接口接入方案"
        let result = await Cleaner.run(raw, context: "", level: .light, engine: .cloud, app: "Test",
                                       cloudCleanup: { _, _, _, _ in
            try Cloud.completionText(from: ["choices": [["finish_reason": "length", "message": ["content": "不完整"]]]])
        })
        try check(result.engine == "rules", "Truncated completion did not fall back to rules")
        try check(result.text == "明天下午三点开会，讨论接口接入方案。", "Fallback lost the original ending")
        try check(result.note == "cloud failed: truncated response", "Truncation note contained unexpected data")
        let valid = await Cleaner.run("明天见", context: "", level: .light, engine: .cloud, app: "Test",
                                      cloudCleanup: { _, _, _, _ in
            try Cloud.completionText(from: ["choices": [["finish_reason": "stop", "message": ["content": "明天见！"]]]])
        })
        try check(valid.engine == "cloud" && valid.text == "明天见！", "Valid completion incorrectly fell back")
    }

    static func item(_ text: String, date: Date) -> HistoryItem {
        HistoryItem(date: date, app: "Test", raw: text, text: text, asr: "test", cleanup: "rules", status: "test")
    }

    static func testModelAttribution() async throws {
        let winner = Task { () throws -> (text: String, model: String) in
            ("来自备用模型", "openai/gpt-4o-mini-transcribe")
        }
        switch await waitFor(winner, seconds: 1) {
        case .ok(let text, let model):
            try check(text == "来自备用模型" && model == "openai/gpt-4o-mini-transcribe", "Cloud race lost the actual winning model")
        default: throw TestFailure(description: "Ready cloud result was not returned")
        }
        let late = Task { () throws -> (text: String, model: String) in
            try await Task.sleep(nanoseconds: 40_000_000)
            return ("迟到结果", "late-model")
        }
        switch await waitFor(late, seconds: 0.001) {
        case .late: break
        default: throw TestFailure(description: "Slow result did not yield to local recognition")
        }
        let eventual = try await late.value
        try check(eventual.model == "late-model", "Local-first timeout cancelled the model needed for an upgrade")

        let slowLocal = Task { try? await Task.sleep(nanoseconds: 200_000_000); return "local" }
        switch await firstAvailable(cloud: winner, local: slowLocal) {
        case .cloud(_, let model):
            try check(model == "openai/gpt-4o-mini-transcribe", "Ready cloud output waited behind slow local inference")
        default: throw TestFailure(description: "Slow local inference blocked the cloud result")
        }
        let failedCloud = Task<(text: String, model: String), Error> { throw CloudError.timeout }
        switch await firstAvailable(cloud: failedCloud, local: Task { "local fallback" }) {
        case .local(let text): try check(text == "local fallback", "Cloud failure lost the local fallback")
        default: throw TestFailure(description: "Failed cloud request claimed success")
        }
        let upgradeCloud = Task { () throws -> (text: String, model: String) in
            try await Task.sleep(nanoseconds: 40_000_000)
            return ("upgrade", "upgrade-model")
        }
        switch await firstAvailable(cloud: upgradeCloud, local: Task { "local first" }) {
        case .local(let text): try check(text == "local first", "Ready local result was not used")
        default: throw TestFailure(description: "Local-first race ignored local output")
        }
        let upgrade = try await upgradeCloud.value
        try check(upgrade.model == "upgrade-model", "Local winner cancelled the pending cloud upgrade")

        for unusable in ["", "嗯"] {
            let recoveredCloud = Task { () throws -> (text: String, model: String) in
                try await Task.sleep(nanoseconds: 20_000_000)
                return ("有效的云端文字", "recovered-model")
            }
            switch await firstAvailable(cloud: recoveredCloud, local: Task { unusable },
                                        isUsableLocal: { RulesCleaner.hasContent($0) }) {
            case .cloud(let text, let model):
                try check(text == "有效的云端文字" && model == "recovered-model", "Unusable local text swallowed pending cloud output")
            default: throw TestFailure(description: "Empty or filler local output won over valid cloud speech")
            }
        }

        let result = await Cleaner.run("明天见", context: "", level: .light, engine: .cloud, app: "Test",
                                      model: "session-model", cloudCleanup: { _, _, _, _ in "明天见！" })
        try check(result.model == "session-model", "Cleanup attributed a global setting instead of the session model")
        try check(ModelPresentation.cleanup(engine: result.engine, model: result.model ?? "") == "session-model（云端整理）", "Successful cleanup lost its model label")
        let fallback = await Cleaner.run("明天见", context: "", level: .light, engine: .cloud, app: "Test",
                                        model: "failed-model", cloudCleanup: { _, _, _, _ in throw CloudError.timeout })
        try check(fallback.model == nil && fallback.engine == "rules", "Failed cleanup was labeled as cloud optimization")
        try check(ModelPresentation.cleanup(engine: fallback.engine, model: "failed-model") == "本机规则整理", "Fallback displays the failed model")
        let guarded = await Cleaner.run("你好", context: "", level: .light, engine: .cloud, app: "Test",
                                       model: "rejected-model", cloudCleanup: { _, _, _, _ in String(repeating: "扩写", count: 100) })
        try check(guarded.model == nil && guarded.engine == "rules", "Rejected cloud output retained success attribution")
        let raw = await Cleaner.run("明天见", context: "", level: .raw, engine: .cloud, app: "Test", model: "unused-model",
                                   cloudCleanup: { _, _, _, _ in throw TestFailure(description: "Raw mode called cleanup") })
        try check(raw.model == nil && raw.engine == "raw", "Raw mode claims cloud processing")
    }

    static func testLateHistoryUpdate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saytype-history-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let entry = item("本机文字", date: Date())
        let store = HistoryStore(url: url, isEnabled: { true })
        store.add(entry)
        store.update(id: entry.id, text: "已更新文字", asr: "Qwen3-ASR 1.7B（云端）", cleanup: "本机规则整理")
        let updated = try readHistory(url)
        try check(updated.count == 1 && updated[0].id == entry.id && updated[0].text == "已更新文字", "Late upgrade duplicated or failed to update history")
        try check(updated[0].raw == "本机文字" && updated[0].asr == "Qwen3-ASR 1.7B（云端）", "Late update lost original text or model attribution")
        let disabled = HistoryStore(url: url, isEnabled: { false })
        disabled.update(id: entry.id, text: "must not save", asr: "test", cleanup: "test")
        try check(try readHistory(url)[0].text == "已更新文字", "Late update ignored disabled history")
        store.clear()
        store.update(id: entry.id, text: "must not reappear", asr: "test", cleanup: "test")
        try check(try readHistory(url).isEmpty, "Late upgrade resurrected cleared history")
    }

    static func testLocalModelValidation() throws {
        try check(LocalModelCatalog.isValidRepoID("mlx-community/Qwen3-ASR-0.6B-4bit"), "Valid model repo rejected")
        for invalid in ["../model", "https://example.com/model", "org/../model", "org/model?token=private", "org/model/extra"] {
            try check(!LocalModelCatalog.isValidRepoID(invalid), "Unsafe model repository accepted")
        }
        for unsafe in ["../config.json", "/tmp/config.json", "sub/config.json", "..", "sub\\config.json"] {
            try check(!LocalModelStorage.isSafeFilename(unsafe), "Model asset escaped its staging directory")
        }
        try check(LocalModelCatalog.model(id: "hf:openai/whisper-small")?.repoID == "openai/whisper-small", "Compatible custom models cannot be restored")
        try check(LocalModelCatalog.model(id: "hf:../secret") == nil, "Invalid saved model ID accepted")
        try check(ModelPresentation.displayName("sk-example-secret") == "自定义模型", "Token-like model input leaked into HUD")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saytype-model-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{\"model_type\":\"whisper\"}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer_config.json"))
        try Data([1]).write(to: folder.appendingPathComponent("model.safetensors"))
        do {
            _ = try LocalModelStorage.validateLocalFiles(in: folder)
            throw TestFailure(description: "Incomplete tokenizer was allowed to trigger a remote fallback")
        } catch LocalModelError.incompleteDownload { checks += 1 }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        try check(try LocalModelStorage.validateLocalFiles(in: folder) == "whisper", "Complete local Whisper assets rejected")
        try Data("{\"model_type\":\"unrelated-model\"}".utf8).write(to: folder.appendingPathComponent("config.json"))
        do {
            _ = try LocalModelStorage.validateLocalFiles(in: folder)
            throw TestFailure(description: "Unsupported architecture was allowed")
        } catch LocalModelError.unsupportedModel { checks += 1 }
    }

    static func readHistory(_ url: URL) throws -> [HistoryItem] {
        try JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: url))
    }

    static func testHistoryRetention() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saytype-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let clock = TestClock()
        let day: TimeInterval = 86400
        let expired = item("expired", date: clock.date.addingTimeInterval(-31 * day))
        let boundary = item("boundary", date: clock.date.addingTimeInterval(-30 * day))
        let recent = (0..<502).map { item("recent-\($0)", date: clock.date.addingTimeInterval(-Double($0 + 1))) }
        try JSONEncoder().encode([expired, boundary] + recent).write(to: url)

        let store = HistoryStore(url: url, now: { clock.date }, isEnabled: { true })
        let expected = Array(recent.prefix(500)).map(\.id)
        try check(store.items.map(\.id) == expected, "Load did not enforce age and count limits")
        try check(try readHistory(url).map(\.id) == expected, "Load did not persist cleaned history")
        let reopened = HistoryStore(url: url, now: { clock.date }, isEnabled: { false })
        try check(reopened.items.map(\.id) == expected, "Reopening restored removed history")

        // A long-running app must also prune expired entries on its next save.
        clock.date.addTimeInterval(31 * day)
        let fresh = item("fresh", date: clock.date)
        store.add(fresh)
        try check(store.items.map(\.id) == [fresh.id], "Save retained expired entries")
        try check(try readHistory(url).map(\.id) == [fresh.id], "Save did not persist expiration")

        for index in 0..<501 { store.add(item("new-\(index)", date: clock.date)) }
        try check(store.items.count == 500 && store.items.first?.text == "new-500" && store.items.last?.text == "new-1",
                  "Save did not retain the newest 500 entries")
        try check(try readHistory(url).map(\.id) == store.items.map(\.id), "Disk and memory differ after count limit")

        let disabled = HistoryStore(url: url, now: { clock.date }, isEnabled: { false })
        disabled.add(item("must-not-save", date: clock.date))
        try check(try readHistory(url).map(\.id) == store.items.map(\.id), "Disabled history added a new entry")
        store.clear()
        try check(try readHistory(url).isEmpty, "Clear did not empty the persisted file")
        let cleared = HistoryStore(url: url, now: { clock.date }, isEnabled: { true })
        try check(cleared.items.isEmpty, "Cleared history reappeared after reopening")
    }

    static func testConfigurationPaths() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("saytype-paths-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let installedOnly = [support.appendingPathComponent("local.config.json")]
        func candidates(_ bundle: URL) -> [URL] {
            ConfigurationPaths.candidates(bundleURL: bundle, supportURL: support)
        }

        for path in ["/Applications/SayType.app", "/Users/test/Applications/SayType.app",
                     "/Users/test/Downloads/SayType.app", "/Users/test/Downloads/SayType-0.1.0/SayType.app"] {
            try check(candidates(URL(fileURLWithPath: path)) == installedOnly, "Installed app searched outside its data directory")
        }

        let outputsApp = root.appendingPathComponent("outputs/SayType.app")
        let buildApp = root.appendingPathComponent("build/SayType.app")
        try check(candidates(outputsApp) == installedOnly, "Unmarked outputs directory was treated as source")
        try check(candidates(buildApp) == installedOnly, "Unmarked build directory was treated as source")

        let info = root.appendingPathComponent("app/Info.plist")
        let script = root.appendingPathComponent("scripts/build.sh")
        try manager.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: info)
        try check(candidates(outputsApp) == installedOnly, "One source marker was sufficient")
        try Data().write(to: script)
        let sourceThenInstalled = [root.appendingPathComponent("local.config.json"), installedOnly[0]]
        try check(candidates(outputsApp) == sourceThenInstalled, "Source outputs configuration priority changed")
        try check(candidates(buildApp) == sourceThenInstalled, "Source build configuration priority changed")
        try check(candidates(root.appendingPathComponent("release/SayType.app")) == installedOnly,
                  "Unrecognized build location was treated as source")
        try check(candidates(root.appendingPathComponent("outputs/SayType")) == installedOnly,
                  "A standalone binary was treated as an app bundle")

        try manager.removeItem(at: info)
        try check(candidates(outputsApp) == installedOnly, "Missing Info.plist was ignored")
        try manager.createDirectory(at: info, withIntermediateDirectories: true)
        try check(candidates(outputsApp) == installedOnly, "A directory was accepted as a source marker file")
    }

    static func main() async {
        do {
            try testResponsePrivacy()
            try await testTruncationFallback()
            try await testModelAttribution()
            try testLateHistoryUpdate()
            try testLocalModelValidation()
            try testHistoryRetention()
            try testConfigurationPaths()
            print("PASS: \(checks) offline regression checks")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
