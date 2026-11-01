import Foundation
import CryptoKit

struct LocalModelSpec: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let repoID: String?
    let isApple: Bool
    let downloadSize: String
}

enum LocalModelCatalog {
    static let appleID = "apple"
    static let models: [LocalModelSpec] = [
        .init(id: appleID, name: "Apple 语音识别", subtitle: "系统自带 · 中文听写", repoID: nil, isApple: true, downloadSize: "系统管理语言资源"),
        .init(id: "qwen3-asr-0.6b", name: "Qwen3-ASR 0.6B", subtitle: "推荐 · 中英混合 · 4-bit", repoID: "mlx-community/Qwen3-ASR-0.6B-4bit", isApple: false, downloadSize: "约 713 MB"),
        .init(id: "qwen3-asr-1.7b", name: "Qwen3-ASR 1.7B", subtitle: "更大模型 · 多语言 · 4-bit", repoID: "mlx-community/Qwen3-ASR-1.7B-4bit", isApple: false, downloadSize: "约 1.61 GB"),
        .init(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", subtitle: "多语言 · 更高内存占用", repoID: "openai/whisper-large-v3-turbo", isApple: false, downloadSize: "约 1.62 GB"),
    ]
    static func model(id: String) -> LocalModelSpec? {
        if let model = models.first(where: { $0.id == id }) { return model }
        guard id.hasPrefix("hf:") else { return nil }
        let repoID = String(id.dropFirst(3))
        guard isValidRepoID(repoID) else { return nil }
        return .init(id: id, name: String(repoID.split(separator: "/").last ?? ""), subtitle: "自定义本地模型", repoID: repoID, isApple: false, downloadSize: "按仓库大小下载")
    }
    static func isValidRepoID(_ repoID: String) -> Bool {
        repoID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$", options: .regularExpression) != nil
            && !repoID.contains("..")
    }
}

enum LocalModelError: LocalizedError {
    case unknownModel, notDownloaded, incompleteDownload, unsupportedModel, modelInUse, busy
    case server(Int), missingMetalLibrary
    var errorDescription: String? {
        switch self {
        case .unknownModel: return "找不到这个本地模型。"
        case .notDownloaded: return "请先在设置中下载并载入这个本地模型。"
        case .incompleteDownload: return "模型文件不完整或校验失败，请重新下载。"
        case .unsupportedModel: return "模型格式不兼容，目前支持 Qwen3-ASR 和 Whisper。"
        case .modelInUse: return "这个模型正在用于录音，处理完成后才能删除。"
        case .busy: return "模型正在下载或载入，请稍候。"
        case .server(let status): return "模型下载服务返回错误（\(status)），请稍后重试。"
        case .missingMetalLibrary: return "应用缺少本地识别所需的图形资源，请重新安装完整的 SayType.app。"
        }
    }
}

/// One immutable Hub revision is downloaded into a private staging folder. Only a
/// successfully loaded model receives an installation receipt and becomes visible.
enum LocalModelStorage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SayType/Models", isDirectory: true)
    }
    static func directory(_ id: String) -> URL {
        let component = id.hasPrefix("hf:")
            ? "custom-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            : id
        return root.appendingPathComponent(component, isDirectory: true)
    }
    static let receiptName = "saytype-installed.json"

    struct FileRecord: Codable, Sendable {
        let name: String
        let size: Int64
        let sha256: String?
    }
    struct Receipt: Codable, Sendable {
        let repoID: String
        let revision: String
        let files: [FileRecord]
    }
    struct StagedModel: Sendable {
        let directory: URL
        let receipt: Receipt
    }

    static func isInstalled(_ id: String) -> Bool {
        guard let spec = LocalModelCatalog.model(id: id) else { return false }
        if spec.isApple { return true }
        let folder = directory(id)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(receiptName)),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.repoID == spec.repoID, !receipt.files.isEmpty,
              receipt.files.contains(where: { $0.name.hasSuffix(".safetensors") }) else { return false }
        for file in receipt.files {
            guard isSafeFilename(file.name), file.size > 0,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path),
                  (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
        }
        return (try? validateLocalFiles(in: folder)) != nil
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    /// In particular, never let Whisper's local loader fall back to a remote tokenizer.
    static func validateLocalFiles(in folder: URL) throws -> String {
        let fm = FileManager.default
        let data = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocalModelError.unsupportedModel
        }
        let type = config["model_type"] as? String ?? ""
        guard type == "qwen3_asr" || type == "whisper" else { throw LocalModelError.unsupportedModel }
        func exists(_ name: String) -> Bool {
            let attributes = try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 0
        }
        guard exists("tokenizer_config.json"),
              exists("tokenizer.json") || (type == "qwen3_asr" && exists("vocab.json") && exists("merges.txt")) else {
            throw LocalModelError.incompleteDownload
        }
        let weights = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty, weights.allSatisfy({ exists($0.lastPathComponent) }) else {
            throw LocalModelError.incompleteDownload
        }
        return type
    }

    static func install(_ staged: StagedModel, id: String) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let data = try JSONEncoder().encode(staged.receipt)
        try data.write(to: staged.directory.appendingPathComponent(receiptName), options: .atomic)
        let destination = directory(id)
        // A valid existing installation is never overwritten by a partial replacement.
        guard !isInstalled(id) else { try fm.removeItem(at: staged.directory); return }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staged.directory, to: destination)
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    init(onProgress: @escaping @Sendable (Int64) -> Void) { self.onProgress = onProgress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let shouldUpdate = now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite
        if shouldUpdate { lastUpdate = now }
        lock.unlock()
        if shouldUpdate { onProgress(totalBytesWritten) }
    }
}

actor LocalModelDownloader {
    static let shared = LocalModelDownloader()
    private struct Manifest: Decodable {
        let sha: String
        let siblings: [Sibling]
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let sha256: String; let size: Int64 }
        }
    }
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7200
        config.httpAdditionalHeaders = ["User-Agent": "SayType/0.1 local-model-download"]
        return URLSession(configuration: config)
    }()

    func inspect(repoID: String) async throws -> LocalModelSpec {
        guard LocalModelCatalog.isValidRepoID(repoID) else { throw LocalModelError.unknownModel }
        let (data, response) = try await session.data(from: URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true")!)
        try validate(response)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else { throw LocalModelError.incompleteDownload }
        let names = Set(manifest.siblings.map(\.rfilename))
        guard names.contains("config.json"), names.contains("tokenizer_config.json"),
              names.contains(where: { LocalModelStorage.isSafeFilename($0) && $0.hasSuffix(".safetensors") }) else {
            throw LocalModelError.unsupportedModel
        }
        let configURL = URL(string: "https://huggingface.co/\(repoID)/resolve/\(manifest.sha)/config.json")!
        let (configData, configResponse) = try await session.data(from: configURL)
        try validate(configResponse)
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        let type = config?["model_type"] as? String ?? ""
        guard type == "qwen3_asr" || type == "whisper" else { throw LocalModelError.unsupportedModel }
        guard names.contains("tokenizer.json") || (type == "qwen3_asr" && names.contains("vocab.json") && names.contains("merges.txt")) else {
            throw NSError(domain: "SayType.Model", code: 3, userInfo: [NSLocalizedDescriptionKey: "这个仓库缺少完整分词器。请选用包含分词器的 Qwen3-ASR MLX 或 openai/whisper-* 仓库，以便完全离线识别。"])
        }
        let bytes = manifest.siblings.filter { $0.rfilename.hasSuffix(".safetensors") }
            .reduce(Int64(0)) { $0 + ($1.size ?? $1.lfs?.size ?? 0) }
        return .init(id: "hf:\(repoID)", name: String(repoID.split(separator: "/").last!),
                     subtitle: "自定义 · \(type == "whisper" ? "Whisper" : "Qwen3-ASR")", repoID: repoID,
                     isApple: false, downloadSize: "约 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    func download(_ spec: LocalModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalModelStorage.StagedModel {
        guard let repoID = spec.repoID else { throw LocalModelError.unknownModel }
        let manifestURL = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true")!
        let (data, response) = try await session.data(from: manifestURL)
        try validate(response)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.sha.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil else {
            throw LocalModelError.incompleteDownload
        }
        let assets: Set<String> = ["config.json", "generation_config.json", "preprocessor_config.json", "tokenizer.json",
                                   "tokenizer_config.json", "vocab.json", "merges.txt", "special_tokens_map.json", "added_tokens.json"]
        let files: [LocalModelStorage.FileRecord] = manifest.siblings.compactMap { sibling in
            let name = sibling.rfilename
            guard LocalModelStorage.isSafeFilename(name), name.hasSuffix(".safetensors") || assets.contains(name),
                  let size = sibling.size ?? sibling.lfs?.size, size > 0 else { return nil }
            return .init(name: name, size: size, sha256: sibling.lfs?.sha256)
        }.sorted { $0.name < $1.name }
        guard files.contains(where: { $0.name == "config.json" }), files.contains(where: { $0.name.hasSuffix(".safetensors") }) else {
            throw LocalModelError.incompleteDownload
        }
        let folder = LocalModelStorage.root.appendingPathComponent(".staging/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < total + 256_000_000 {
            throw NSError(domain: "SayType.Model", code: 1, userInfo: [NSLocalizedDescriptionKey: "磁盘空间不足，请留出至少 \(ByteCountFormatter.string(fromByteCount: total + 256_000_000, countStyle: .file)) 后重试。"])
        }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let completedBefore = completed
            let delegate = ModelDownloadProgress { bytes in
                progress(min(1, Double(completedBefore + min(bytes, file.size)) / Double(total)))
            }
            let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(manifest.sha)/\(file.name)")!
            let (temporary, response) = try await session.download(from: url, delegate: delegate)
            try validate(response)
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(file.name)
            try FileManager.default.moveItem(at: temporary, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size else { throw LocalModelError.incompleteDownload }
            if let expectedHash = file.sha256 {
                let handle = try FileHandle(forReadingFrom: destination)
                defer { try? handle.close() }
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                }
                let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == expectedHash else { throw LocalModelError.incompleteDownload }
            }
            completed += file.size
            progress(Double(completed) / Double(total))
        }
        _ = try LocalModelStorage.validateLocalFiles(in: folder)
        succeeded = true
        return .init(directory: folder, receipt: .init(repoID: repoID, revision: manifest.sha, files: files))
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw LocalModelError.incompleteDownload }
        guard (200...299).contains(response.statusCode) else { throw LocalModelError.server(response.statusCode) }
    }
}
