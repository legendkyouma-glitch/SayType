import Foundation
import AVFoundation

// Only dependencies outside the two production files are replaced. Any accidental
// request for credentials, app storage, or speech processing fails the test run.
enum CleanupLevel: String { case raw, light, polish }
enum CleanupEngine: String { case cloud, rules }

final class Settings: @unchecked Sendable {
    static let shared = Settings()
    var baseURL = "https://example.invalid"
    var sttModel = "test-asr"
    var llmModel = "test-cleanup"
    var cjkSpacing = true
    var historyEnabled = true
}

enum KeyStore {
    static var key: String? { fatalError("Offline tests must not request credentials") }
    static var hasKey: Bool { fatalError("Offline tests must not request credentials") }
}

enum Paths {
    static var support: URL { fatalError("Offline tests must use a temporary history file") }
}

final class Log: @unchecked Sendable {
    static let shared = Log()
    func ev(_ name: String, _ fields: [String: Any] = [:]) {}
}

enum SegmentRecorder { static let rate: Double = 16000 }
enum WAV {
    static func encode(_ samples: [Float]) -> Data {
        fatalError("Offline tests must not process recorded audio")
    }
}

enum LocalASRSession {
    static func ensureAssets() async -> String { fatalError("No speech assets in offline tests") }
    static func transcribeParts(samples: [Float]) async -> [String] { fatalError("No speech recognition in offline tests") }
    static func transcribe(samples: [Float]) async -> String { fatalError("No speech recognition in offline tests") }
}

final class BufferConverter {
    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        fatalError("No audio conversion in offline tests")
    }
}

func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
