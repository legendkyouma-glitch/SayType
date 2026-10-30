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
            try testHistoryRetention()
            try testConfigurationPaths()
            print("PASS: \(checks) offline regression checks")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }
}
