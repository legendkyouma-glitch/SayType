import Foundation

enum WaitResult: Sendable { case ok(String, String), failed, late }

private final class CompletionClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

/// 等一个云端任务最多 seconds 秒；超时不取消任务（它会继续跑，结果可以稍后用）
func waitFor(_ t: Task<(text: String, model: String), Error>, seconds: Double) async -> WaitResult {
    let once = CompletionClaim()
    return await withCheckedContinuation { (c: CheckedContinuation<WaitResult, Never>) in
        Task {
            do {
                let r = try await t.value
                if once.claim() { c.resume(returning: .ok(r.text, r.model)) }
            } catch {
                if once.claim() { c.resume(returning: .failed) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { c.resume(returning: .late) }
        }
    }
}

enum CloudOrLocal<Local: Sendable>: Sendable {
    case cloud(text: String, model: String)
    case local(Local)
}

/// After cloud patience expires, keep accepting cloud output while the local
/// fallback loads. Neither task is cancelled: a local winner may still upgrade.
func firstAvailable<Local: Sendable>(cloud: Task<(text: String, model: String), Error>,
                                    local: Task<Local, Never>,
                                    isUsableLocal: @escaping @Sendable (Local) -> Bool = { _ in true }) async -> CloudOrLocal<Local> {
    let once = CompletionClaim()
    return await withCheckedContinuation { continuation in
        Task {
            if let result = try? await cloud.value, once.claim() {
                continuation.resume(returning: .cloud(text: result.text, model: result.model))
            }
        }
        Task {
            let result = await local.value
            if !isUsableLocal(result), let recovered = try? await cloud.value {
                if once.claim() { continuation.resume(returning: .cloud(text: recovered.text, model: recovered.model)) }
                return
            }
            if once.claim() { continuation.resume(returning: .local(result)) }
        }
    }
}
