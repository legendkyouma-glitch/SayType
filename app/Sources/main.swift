import AppKit
import Foundation

// SayType 说写：macOS 菜单栏语音输入。
// 用法一：作为菜单栏应用运行（默认）。
// 用法二：命令行自检（不需要麦克风和辅助功能权限）：
//   SayType --selftest <音频文件> [--cloud]

enum Paths {
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayType", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let logs: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SayType", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

/// 运行事件及耗时、字数、应用信息等元数据；不主动记录口述正文或 Key。
final class Log: @unchecked Sendable {
    static let shared = Log()
    private let queue = DispatchQueue(label: "saytype.log")
    private let handle: FileHandle?
    let fileURL: URL
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = Paths.logs.appendingPathComponent("session-\(df.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    func ev(_ name: String, _ fields: [String: Any] = [:]) {
        var d = fields
        d["t"] = iso.string(from: Date())
        d["ev"] = name
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { return }
            var line = data
            line.append(0x0A)
            self.handle?.write(line)
            FileHandle.standardError.write(line)
        }
    }
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

if let idx = CommandLine.arguments.firstIndex(of: "--selftest") {
    let rest = Array(CommandLine.arguments.dropFirst(idx + 1))
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        await SelfTest.run(args: rest)
        sem.signal()
    }
    sem.wait()
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
