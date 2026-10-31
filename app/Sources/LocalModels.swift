import Foundation
import Combine
import MLX
import MLXAudioSTT

enum LocalModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case preparing
    case ready
    case failed(String)
}

@MainActor
final class LocalModelManager: ObservableObject {
    static let shared = LocalModelManager()
    @Published private(set) var models = LocalModelCatalog.models
    @Published private(set) var states: [String: LocalModelState] = [:]
    private var operations: [String: Task<Void, Error>] = [:]
    private var operationIDs: [String: UUID] = [:]
    private var sessions: [String: Int] = [:]
    private var leaseVersion: UInt64 = 0
    private var selectionVersion: UInt64 = 0

    private init() {
        if let data = try? Data(contentsOf: LocalModelStorage.root.appendingPathComponent("custom-models.json")),
           let custom = try? JSONDecoder().decode([LocalModelSpec].self, from: data) {
            models += custom.filter { $0.id.hasPrefix("hf:") && LocalModelCatalog.model(id: $0.id) != nil }
        }
        for model in models { states[model.id] = LocalModelStorage.isInstalled(model.id) ? .ready : .notDownloaded }
        selectionDidChange(to: UserDefaults.standard.string(forKey: "localModelID") ?? LocalModelCatalog.appleID)
    }

    func state(for id: String) -> LocalModelState { states[id] ?? .notDownloaded }
    func isReady(_ id: String) -> Bool { LocalModelStorage.isInstalled(id) }
    func canRemove(_ id: String) -> Bool {
        id != LocalModelCatalog.appleID && operations[id] == nil && sessions[id, default: 0] == 0
    }

    /// A recording keeps its model even when the next recording's selection changes.
    func beginSession(_ modelID: String) {
        objectWillChange.send()
        sessions[modelID, default: 0] += 1
        let protected = Set(sessions.keys)
        leaseVersion += 1
        let version = leaseVersion
        Task { await LocalModelRuntime.shared.setProtectedModels(protected, version: version) }
    }
    func endSession(_ modelID: String) {
        objectWillChange.send()
        if sessions[modelID, default: 0] <= 1 { sessions.removeValue(forKey: modelID) }
        else { sessions[modelID, default: 0] -= 1 }
        let protected = Set(sessions.keys)
        leaseVersion += 1
        let version = leaseVersion
        Task { await LocalModelRuntime.shared.setProtectedModels(protected, version: version) }
    }

    /// Call synchronously after persisting a successful choice in Settings.
    /// Preparation alone never changes which model the cache keeps resident.
    func selectionDidChange(to id: String) {
        selectionVersion += 1
        let version = selectionVersion
        Task { await LocalModelRuntime.shared.commitSelection(modelID: id, version: version) }
    }

    func downloadAndPrepare(_ id: String) async throws { try await run(id, allowDownload: true) }
    func prepare(_ id: String) async throws { try await run(id, allowDownload: false) }
    func cancelDownload(_ id: String) {
        operations[id]?.cancel()
        Task { await LocalModelRuntime.shared.discardPreparation(modelID: id) }
    }

    private func run(_ id: String, allowDownload: Bool) async throws {
        guard let model = models.first(where: { $0.id == id }) else { throw LocalModelError.unknownModel }
        if model.isApple { return }
        if let operation = operations[id] { try await operation.value; return }
        let token = UUID()
        operationIDs[id] = token
        let task = Task { try await self.perform(model, allowDownload: allowDownload, token: token) }
        operations[id] = task
        defer {
            if operationIDs[id] == token {
                objectWillChange.send()
                operations[id] = nil
                operationIDs[id] = nil
            }
        }
        try await task.value
    }

    private func perform(_ model: LocalModelSpec, allowDownload: Bool, token: UUID) async throws {
        let id = model.id
        var staged: LocalModelStorage.StagedModel?
        defer { if let staged { try? FileManager.default.removeItem(at: staged.directory) } }
        do {
            let folder: URL
            if LocalModelStorage.isInstalled(id) { folder = LocalModelStorage.directory(id) }
            else {
                guard allowDownload else { throw LocalModelError.notDownloaded }
                states[id] = .downloading(0)
                let downloaded = try await LocalModelDownloader.shared.download(model) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationIDs[id] == token,
                              case .downloading = self.states[id] else { return }
                        self.states[id] = .downloading(fraction)
                    }
                }
                staged = downloaded
                folder = downloaded.directory
            }
            try Task.checkCancellation()
            states[id] = .preparing
            try await LocalModelRuntime.shared.prepare(modelID: id, directory: folder,
                                                      protectedModels: Set(sessions.keys), leaseVersion: leaseVersion)
            try Task.checkCancellation()
            if let staged { try LocalModelStorage.install(staged, id: id) }
            states[id] = .ready
        } catch {
            await LocalModelRuntime.shared.discardPreparation(modelID: id)
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                states[id] = LocalModelStorage.isInstalled(id) ? .ready : .notDownloaded
                throw CancellationError()
            }
            states[id] = .failed(error.localizedDescription)
            throw error
        }
    }

    func remove(_ id: String) async throws {
        guard id != LocalModelCatalog.appleID else { return }
        guard sessions[id, default: 0] == 0 else { throw LocalModelError.modelInUse }
        guard operations[id] == nil else { throw LocalModelError.busy }
        try await LocalModelRuntime.shared.unload(modelID: id)
        guard sessions[id, default: 0] == 0 else { throw LocalModelError.modelInUse }
        guard operations[id] == nil else { throw LocalModelError.busy }
        let folder = LocalModelStorage.directory(id)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        states[id] = .notDownloaded
    }

    func addCustomModel(repoID rawID: String) async throws -> LocalModelSpec {
        let repoID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalModelCatalog.isValidRepoID(repoID) else {
            throw NSError(domain: "SayType.Model", code: 2, userInfo: [NSLocalizedDescriptionKey: "请填写 Hugging Face 仓库 ID，例如 openai/whisper-small。"])
        }
        if let model = models.first(where: { $0.repoID == repoID }) { return model }
        let model = try await LocalModelDownloader.shared.inspect(repoID: repoID)
        try Task.checkCancellation()
        // The request may have been submitted twice while the metadata was loading.
        if let existing = models.first(where: { $0.id == model.id }) { return existing }
        let updated = models + [model]
        try FileManager.default.createDirectory(at: LocalModelStorage.root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(updated.filter { $0.id.hasPrefix("hf:") })
        try data.write(to: LocalModelStorage.root.appendingPathComponent("custom-models.json"), options: .atomic)
        models = updated
        states[model.id] = LocalModelStorage.isInstalled(model.id) ? .ready : .notDownloaded
        return model
    }
}

/// All MLX loads and inference use one gate. An actor alone would allow concurrent
/// GPU work during the SDK's async tokenizer load, because actors are reentrant.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()
    private enum Loaded {
        case qwen(Qwen3ASRModel)
        case whisper(WhisperModel)
    }
    private var loaded: [String: Loaded] = [:]
    private var preferredID: String?
    private var preferredVersion: UInt64 = 0
    private var pendingModels: Set<String> = []
    private var protectedModels: Set<String> = []
    private var protectionVersion: UInt64 = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var metalConfigured = false

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
    func setProtectedModels(_ ids: Set<String>, version: UInt64) async {
        await acquire(); defer { release() }
        updateProtection(ids, version: version)
        trim()
    }
    private func updateProtection(_ ids: Set<String>, version: UInt64) {
        guard version >= protectionVersion else { return }
        protectedModels = ids
        protectionVersion = version
    }
    private func trim() {
        loaded = loaded.filter { $0.key == preferredID || protectedModels.contains($0.key) || pendingModels.contains($0.key) }
        if metalConfigured { Memory.clearCache() }
    }

    func commitSelection(modelID: String, version: UInt64) async {
        await acquire(); defer { release() }
        pendingModels.remove(modelID)
        if version >= preferredVersion {
            preferredID = modelID == LocalModelCatalog.appleID ? nil : modelID
            preferredVersion = version
        }
        trim()
    }

    func discardPreparation(modelID: String) async {
        await acquire(); defer { release() }
        pendingModels.remove(modelID)
        trim()
    }

    private func configureMetal() throws {
        guard !metalConfigured else { return }
        // MLX 0.31 finds its SwiftPM resource bundle inside an installed app.
        // The colocated path also supports the standalone development smoke test.
        let bundledLibrary = Bundle.main.resourceURL?
            .appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        let colocatedLibrary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        guard [bundledLibrary, colocatedLibrary].compactMap({ $0 }).contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            throw LocalModelError.missingMetalLibrary
        }
        Memory.cacheLimit = 256 * 1024 * 1024
        metalConfigured = true
    }

    private func load(directory: URL) async throws -> Loaded {
        let type = try LocalModelStorage.validateLocalFiles(in: directory)
        try configureMetal()
        try Task.checkCancellation()
        let model: Loaded
        if type == "qwen3_asr" { model = .qwen(try await Qwen3ASRModel.fromModelDirectory(directory)) }
        else { model = .whisper(try await WhisperModel.fromDirectory(directory)) }
        try Task.checkCancellation()
        return model
    }

    func prepare(modelID: String, directory: URL, protectedModels: Set<String>, leaseVersion: UInt64 = 0) async throws {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        if loaded[modelID] == nil {
            let candidate = try await load(directory: directory)
            try Task.checkCancellation()
            loaded[modelID] = candidate
        }
        pendingModels.insert(modelID)
        updateProtection(protectedModels, version: leaseVersion)
        trim()
    }

    func unload(modelID: String) async throws {
        await acquire(); defer { release() }
        guard !protectedModels.contains(modelID) else { throw LocalModelError.modelInUse }
        loaded[modelID] = nil
        pendingModels.remove(modelID)
        if preferredID == modelID { preferredID = nil }
        if metalConfigured { Memory.clearCache() }
    }

    /// Input is mono PCM at 16 kHz, matching the application's microphone pipeline.
    /// This method has no network path: missing files are reported to Settings.
    func transcribe(samples: [Float], modelID: String) async throws -> String {
        guard !samples.isEmpty else { return "" }
        await acquire(); defer { release() }
        try Task.checkCancellation()
        guard LocalModelStorage.isInstalled(modelID) else { throw LocalModelError.notDownloaded }
        if loaded[modelID] == nil { loaded[modelID] = try await load(directory: LocalModelStorage.directory(modelID)) }
        guard let model = loaded[modelID] else { throw LocalModelError.notDownloaded }
        let audio = MLXArray(samples.map { $0.isFinite ? $0 : 0 })
        let text: String
        switch model {
        case .qwen(let model):
            text = model.generate(audio: audio, maxTokens: 4096, chunkDuration: 30, repetitionPenalty: 1.1).text
        case .whisper(let model):
            text = model.generate(audio: audio, generationParameters: STTGenerateParameters(maxTokens: 448)).text
        }
        try Task.checkCancellation()
        Memory.clearCache()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
