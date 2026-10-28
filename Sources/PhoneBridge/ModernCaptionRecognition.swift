import AVFoundation
import Speech
import CoreMedia
import BridgeCore

/// One independently scheduled, on-device decoder per call direction.
/// Bounded input; no files, network fallback or global resource-limit override.
@available(macOS 26.0, *)
@MainActor final class ModernCaptionRecognition {
    var onTranscript: ((String, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var ready = false
    private(set) var submittedFrames: UInt64 = 0
    private(set) var resultCount = 0
    private var analyzer: SpeechAnalyzer?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var shutdown: Task<Void, Never>?
    private var generation = UUID()
    var snapshot: [String: Any] { ["backend": "SpeechAnalyzer", "ready": ready,
        "submittedFrames": submittedFrames, "resultCount": resultCount, "onDeviceOnly": true] }

    func prepare(format: AVAudioFormat) async throws {
        await stopAndWait()
        let installed = await SpeechTranscriber.installedLocales
        guard let locale = installed.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == "zh-cn" }) else {
            throw BridgeError("本机尚未安装新版中文识别模型，未启动双向字幕。")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw BridgeError("无法建立本机识别采样转换。")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: target)
        let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingOldest(64)) { self.continuation = $0 }
        self.analyzer = analyzer; self.converter = converter; targetFormat = target
        let run = UUID(); generation = run; submittedFrames = 0; resultCount = 0; ready = true
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.ready, self.generation == run else { return }
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    self.resultCount += 1
                    let start = CMTimeConvertScale(result.range.start, timescale: 48_000, method: .default).value
                    self.onTranscript?("modern-\(run.uuidString)-\(start)", text, result.isFinal)
                }
            } catch { self?.fail(run, message: "本机字幕识别中断。") }
        }
        analysisTask = Task { [weak self] in
            do { try await analyzer.start(inputSequence: stream) }
            catch { self?.fail(run, message: "本机字幕分析中断。") }
        }
    }
    func append(_ input: AVAudioPCMBuffer) throws {
        guard ready, let converter, let target = targetFormat, let continuation else { throw BridgeError("本机字幕分析尚未准备好。") }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw BridgeError("无法准备字幕转换缓冲。") }
        var supplied = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, result in
            if supplied { result.pointee = .noDataNow; return nil }
            supplied = true; result.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { throw BridgeError("本机字幕采样转换失败。") }
        guard output.frameLength > 0 else { return }
        switch continuation.yield(AnalyzerInput(buffer: output)) {
        case .enqueued: submittedFrames += UInt64(output.frameLength)
        case .dropped, .terminated: throw BridgeError("字幕分析未能及时消费输入，已停止该路字幕。")
        @unknown default: throw BridgeError("字幕输入状态不可用。")
        }
    }
    private func fail(_ run: UUID, message: String) {
        guard ready, generation == run else { return }
        stop(); onFailure?(message)
    }
    func stop() {
        generation = UUID(); ready = false
        continuation?.finish(); continuation = nil
        analysisTask?.cancel(); resultTask?.cancel(); analysisTask = nil; resultTask = nil
        if let analyzer {
            let previous = shutdown
            shutdown = Task { await previous?.value; await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil; converter = nil; targetFormat = nil
    }
    func stopAndWait() async { stop(); await shutdown?.value; shutdown = nil }
}
