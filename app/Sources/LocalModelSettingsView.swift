import SwiftUI

/// 模型管理保留在设置内；下载、加载成功后才更新下一句使用的模型。
struct LocalModelSettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var manager = LocalModelManager.shared
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectingID: String?
    @State private var deletingID: String?
    @State private var requestedRemoval: LocalModelSpec?
    @State private var customRepoID = ""
    @State private var addingCustom = false
    @State private var customTask: Task<Void, Never>?
    @State private var message = ""
    @State private var messageIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("已选择：\(settings.localModelName)")
                .font(.callout.weight(.medium))
            Text("本机识别和云端识别失败后的备用识别使用此模型。下载完成并加载成功后，从下一句切换；云端模型仍由上方的识别和整理设置决定。")
                .font(.caption).foregroundStyle(.secondary)
            Text("首次下载需要联网，下载后的识别在这台 Mac 上完成。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)

        ForEach(manager.models) { model in
            modelRow(model)
        }

        DisclosureGroup("更多兼容模型") {
            VStack(alignment: .leading, spacing: 8) {
                Text("支持已适配的 Qwen3-ASR（MLX）和 Whisper（safetensors）仓库，需包含完整 tokenizer。添加时检查配置，下载后验证加载；不支持任意模型文件。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Hugging Face 仓库：作者/模型名", text: $customRepoID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(addingCustom)
                Text("例如：mlx-community/Qwen3-ASR-0.6B-8bit 或 openai/whisper-small")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if addingCustom {
                        ProgressView().controlSize(.small)
                        Text("正在检查配置…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { customTask?.cancel() }
                    } else {
                        Button("添加模型") { addCustomModel() }
                            .disabled(customRepoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasOperation)
                    }
                }
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }

        if !message.isEmpty {
            Text(message)
                .font(.caption)
                .foregroundStyle(messageIsError ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("正在使用的模型不能删除。要释放它占用的空间，请先切换到其他模型，并等当前口述结束。")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .confirmationDialog(
                "删除 \(requestedRemoval?.name ?? "模型")？",
                isPresented: Binding(
                    get: { requestedRemoval != nil },
                    set: { if !$0 { requestedRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let model = requestedRemoval {
                    Button("删除已下载的模型", role: .destructive) { remove(model) }
                }
                Button("取消", role: .cancel) { requestedRemoval = nil }
            } message: {
                Text("以后使用此模型时需要重新下载。")
            }
    }

    private func modelRow(_ model: LocalModelSpec) -> some View {
        let state = manager.state(for: model.id)
        let selected = settings.localModelID == model.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if selected {
                    Label("当前选择", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.tint)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isApple {
                HStack {
                    Text("下载大小：\(model.downloadSize)")
                        .foregroundStyle(.secondary)
                    if let repoID = model.repoID,
                       let url = URL(string: "https://huggingface.co/\(repoID)") {
                        Link("模型来源与许可", destination: url)
                    }
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                if case .preparing = state {
                    ProgressView().controlSize(.small)
                }
                Text(deletingID == model.id ? "正在删除…" : statusText(state, model: model))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if isBusy(state) {
                    Button("取消") { cancel(model) }
                        .controlSize(.small)
                } else {
                    if !selected || needsPreparation(state, model: model) {
                        Button(selectionTitle(state, model: model)) { select(model) }
                            .controlSize(.small)
                            .disabled(hasOperation)
                    }
                    if !model.isApple && manager.isReady(model.id) && manager.canRemove(model.id) {
                        Button("删除", role: .destructive) { requestedRemoval = model }
                            .controlSize(.small)
                            .disabled(selected || hasOperation)
                    }
                }
            }
            if case .downloading(let progress) = state {
                ProgressView(value: min(max(progress, 0), 1))
                    .accessibilityLabel("\(model.name) 下载进度")
            }
            if case .failed(let error) = state {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var hasOperation: Bool {
        selectingID != nil || deletingID != nil || addingCustom || manager.models.contains { isBusy(manager.state(for: $0.id)) }
    }

    private func isBusy(_ state: LocalModelState) -> Bool {
        switch state {
        case .downloading, .preparing: return true
        default: return false
        }
    }

    private func statusText(_ state: LocalModelState, model: LocalModelSpec) -> String {
        switch state {
        case .notDownloaded: return model.isApple ? "系统管理语言资源" : "尚未下载"
        case .downloading(let progress): return "正在下载 \(Int(min(max(progress, 0), 1) * 100))%"
        case .preparing: return "正在加载模型…"
        case .ready: return model.isApple ? "系统管理语言资源" : "已下载，可在本机使用"
        case .failed: return "模型准备失败"
        }
    }

    private func selectionTitle(_ state: LocalModelState, model: LocalModelSpec) -> String {
        if model.isApple || manager.isReady(model.id) { return "使用" }
        if case .failed = state { return "重试并使用" }
        return "下载并使用"
    }

    private func needsPreparation(_ state: LocalModelState, model: LocalModelSpec) -> Bool {
        switch state {
        case .failed: return true
        case .notDownloaded: return !model.isApple
        default: return false
        }
    }

    private func select(_ model: LocalModelSpec) {
        guard !hasOperation else { return }
        selectingID = model.id
        message = ""
        selectionTask = Task { @MainActor in
            defer { selectingID = nil; selectionTask = nil }
            do {
                if model.isApple || manager.isReady(model.id) {
                    try await manager.prepare(model.id)
                } else {
                    try await manager.downloadAndPrepare(model.id)
                }
                try Task.checkCancellation()
                settings.localModelID = model.id
                manager.selectionDidChange(to: model.id)
                messageIsError = false
                message = "已选择 \(model.name)，从下一句开始使用。"
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                messageIsError = !cancelled
                message = cancelled
                    ? "已取消，仍使用 \(settings.localModelName)。"
                    : "未能切换模型，仍使用 \(settings.localModelName)。\(error.localizedDescription)"
            }
        }
    }

    private func cancel(_ model: LocalModelSpec) {
        if selectingID == model.id { selectionTask?.cancel() }
        manager.cancelDownload(model.id)
    }

    private func remove(_ model: LocalModelSpec) {
        requestedRemoval = nil
        guard settings.localModelID != model.id, !hasOperation, manager.canRemove(model.id) else { return }
        deletingID = model.id
        message = ""
        Task { @MainActor in
            defer { deletingID = nil }
            do {
                try await manager.remove(model.id)
                messageIsError = false
                message = "已删除 \(model.name) 的下载文件。"
            } catch {
                messageIsError = true
                message = "未能删除模型：\(error.localizedDescription)"
            }
        }
    }

    private func addCustomModel() {
        guard !hasOperation else { return }
        let repoID = customRepoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoID.isEmpty else { return }
        addingCustom = true
        message = ""
        customTask = Task { @MainActor in
            defer { addingCustom = false; customTask = nil }
            do {
                let model = try await manager.addCustomModel(repoID: repoID)
                try Task.checkCancellation()
                customRepoID = ""
                messageIsError = false
                message = "已添加 \(model.name)。下载并使用后，从下一句切换。"
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                messageIsError = !cancelled
                message = cancelled ? "已取消添加模型。" : "未能添加模型：\(error.localizedDescription)"
            }
        }
    }
}
