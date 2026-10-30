import AVFoundation
import Foundation
import Speech

// MARK: - 录音

/// 只在按下快捷键后启动麦克风，结束后立即关闭（不常驻、不写盘）。
final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private(set) var running = false
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 音量（dBFS），约每 50ms 回调一次，用于状态条波形
    var onLevel: ((Float) -> Void)?
    private var lastLevelMs: Double = 0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            let now = nowMs()
            if now - self.lastLevelMs > 45, let ch = buffer.floatChannelData?[0] {
                self.lastLevelMs = now
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                self.onLevel?(20 * log10(max(rms, 1e-7)))
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    static var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static var micStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - 格式转换（参考 Apple 示例 BufferConversion.swift）

final class BufferConverter {
    enum Err: Error { case noConverter, noBuffer, failed(NSError?) }
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.outputFormat != format || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { throw Err.noConverter }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let cap = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: cap) else { throw Err.noBuffer }
        var nsError: NSError?
        var done = false
        let status = converter.convert(to: out, error: &nsError) { _, statusPtr in
            defer { done = true }
            statusPtr.pointee = done ? .noDataNow : .haveData
            return done ? nil : buffer
        }
        if status == .error { throw Err.failed(nsError) }
        return out
    }
}

// MARK: - 本机识别：macOS 自带 DictationTranscriber（简体中文，自动标点）

final class LocalASRSession: @unchecked Sendable {
    static let locale = Locale(identifier: "zh-CN")

    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    private let converter = BufferConverter()
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private(set) var finals: [String] = []

    var onVolatile: ((String) -> Void)?
    var onFinal: ((String) -> Void)?

    private init(transcriber: DictationTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    static func make() async throws -> LocalASRSession {
        let t = DictationTranscriber(locale: locale,
                                     contentHints: [],
                                     transcriptionOptions: [.punctuation],
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        let a = SpeechAnalyzer(modules: [t])
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw NSError(domain: "SayType", code: 1, userInfo: [NSLocalizedDescriptionKey: "no analyzer format"])
        }
        return LocalASRSession(transcriber: t, analyzer: a, format: f)
    }

    /// 本机语言包是否已就绪；没有的话让系统下载
    static func ensureAssets() async -> String {
        let installed = await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if installed.contains("zh-CN") { return "installed" }
        do {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try await req.downloadAndInstall()
                return "downloaded"
            }
            return "no-request"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    func start() async throws {
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await r in self.transcriber.results {
                    let text = String(r.text.characters)
                    if r.isFinal {
                        self.lock.withLock { self.finals.append(text) }
                        self.onFinal?(text)
                    } else {
                        self.onVolatile?(text)
                    }
                }
            } catch {
                Log.shared.ev("local_asr_results_error", ["error": "\(error)"])
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        do {
            let converted = try converter.convert(buffer, to: format)
            continuation.yield(AnalyzerInput(buffer: converted))
        } catch {
            Log.shared.ev("local_asr_convert_error", ["error": "\(error)"])
        }
    }

    /// 结束输入并等所有最终结果回来
    func finish() async -> [String] {
        continuation.finish()
        do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch {
            Log.shared.ev("local_asr_finish_error", ["error": "\(error)"])
        }
        await resultsTask?.value
        return lock.withLock { finals }
    }

    /// 用一段 16k 单声道样本做一次性识别（云端失败时的本机兜底、命令行自检）
    static func transcribe(samples: [Float], sampleRate: Double = 16000) async -> String {
        await transcribeParts(samples: samples, sampleRate: sampleRate).joined()
    }

    static func transcribeParts(samples: [Float], sampleRate: Double = 16000) async -> [String] {
        do {
            let s = try await make()
            try await s.start()
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            let chunk = Int(sampleRate * 0.1)
            var i = 0
            while i < samples.count {
                let n = min(chunk, samples.count - i)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                samples.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + i, count: n)
                }
                s.feed(buf)
                i += n
            }
            return await s.finish()
        } catch {
            Log.shared.ev("local_asr_oneshot_error", ["error": "\(error)"])
            return []
        }
    }
}

// MARK: - 16k 单声道采集 + 语音活动检测 + 按停顿切段

/// 每次说话都会用到：判断“有没有说话”（没说话不插入）、记录最后一次有声音的时间（按一下开始方式下 30 秒无声自动结束），
/// 云端识别时按停顿切段上传。音频只在内存里。
final class SegmentRecorder: @unchecked Sendable {
    static let rate: Double = 16000
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    private let converter = BufferConverter()
    private let q = DispatchQueue(label: "saytype.segment")

    private var all: [Float] = []
    private var segStart = 0
    private var hadSpeech = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var noiseFloor: Float = -60
    private var frameBuf: [Float] = []
    private let frameLen = Int(rate * 0.03) // 30ms
    private let pauseFrames: Int

    private let stateLock = NSLock()
    private var _speechSeen = false
    private var _lastSpeechMs: Double = nowMs()
    var speechSeen: Bool { stateLock.withLock { _speechSeen } }
    var lastSpeechMs: Double { stateLock.withLock { _lastSpeechMs } }

    /// 切出一段时回调（样本、段号）
    var onSegment: (([Float], Int) -> Void)?
    private var segIndex = 0

    init(pauseSeconds: Double) {
        pauseFrames = max(5, Int(pauseSeconds / 0.03))
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let out = try? converter.convert(buffer, to: target), let ch = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        q.async { self.process(samples) }
    }

    private func process(_ samples: [Float]) {
        all.append(contentsOf: samples)
        frameBuf.append(contentsOf: samples)
        while frameBuf.count >= frameLen {
            let frame = Array(frameBuf.prefix(frameLen))
            frameBuf.removeFirst(frameLen)
            var sum: Float = 0
            for v in frame { sum += v * v }
            let rms = sqrt(sum / Float(frameLen))
            let db = 20 * log10(max(rms, 1e-7))
            // 噪声底：缓慢跟随较低的能量
            if db < noiseFloor + 3 { noiseFloor = noiseFloor * 0.95 + db * 0.05 }
            let isSpeech = db > max(noiseFloor + 10, -52)
            if isSpeech {
                speechFrames += 1
                silentFrames = 0
                if speechFrames >= 3 {
                    hadSpeech = true
                    stateLock.withLock { _speechSeen = true; _lastSpeechMs = nowMs() }
                }
            } else {
                silentFrames += 1
                if hadSpeech && silentFrames >= pauseFrames {
                    cut(at: all.count - frameBuf.count - (silentFrames - 8) * frameLen)
                }
            }
        }
    }

    private func cut(at endIndex: Int) {
        let end = max(segStart, min(endIndex, all.count))
        let start = max(0, segStart - Int(SegmentRecorder.rate * 0.2))
        if end - segStart > Int(SegmentRecorder.rate * 0.3) {
            let seg = Array(all[start..<end])
            let idx = segIndex
            segIndex += 1
            onSegment?(seg, idx)
        }
        segStart = end
        hadSpeech = false
        speechFrames = 0
        silentFrames = 0
    }

    /// 结束：把最后一段交出去
    func flush(completion: @escaping () -> Void) {
        q.async {
            if self.hadSpeech || self.speechFrames > 0 {
                self.cut(at: self.all.count)
            }
            completion()
        }
    }

    /// 结束后释放内存里的音频
    func discard() { q.async { self.all.removeAll(); self.frameBuf.removeAll() } }
}

enum WAV {
    static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        var d = Data()
        let dataLen = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataLen))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(dataLen))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, v) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, v)) * 32767) }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
