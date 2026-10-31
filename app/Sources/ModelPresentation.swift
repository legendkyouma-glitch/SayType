import Foundation

/// UI labels are derived from the model that produced a result, never just a preset.
enum ModelPresentation {
    static let appleName = "Apple 语音识别"

    static func displayName(_ modelID: String) -> String {
        let candidate = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = candidate.lowercased()
        if lower.hasPrefix("sk-") || lower.hasPrefix("hf_") || lower.hasPrefix("bearer ") {
            return "自定义模型"
        }
        switch modelID {
        case "qwen/qwen3-asr-1.7b": return "Qwen3-ASR 1.7B"
        case "openai/gpt-4o-mini-transcribe": return "GPT-4o mini Transcribe"
        case "google/gemini-2.5-flash-lite": return "Gemini 2.5 Flash Lite"
        default: return String(candidate.prefix(100))
        }
    }

    static func recognition(_ name: String, cloud: Bool) -> String {
        "\(displayName(name))（\(cloud ? "云端" : "本机")）"
    }

    static func cleanup(engine: String, model: String) -> String {
        switch engine {
        case "cloud": return "\(displayName(model))（云端整理）"
        case "raw": return "原样"
        case "none": return "未整理"
        default: return "本机规则整理"
        }
    }

    /// Only call after a replacement succeeded; a pending/failed request is not an optimization.
    static func upgradeTitle(recognitionModel: String, cleanupModel: String?) -> String {
        var names = [displayName(recognitionModel)]
        if let cleanupModel {
            let name = displayName(cleanupModel)
            if !names.contains(name) { names.append(name) }
        }
        return "已用 \(names.joined(separator: " + ")) 优化"
    }
}
