import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import BridgeCore

final class AudioBridge: NSObject, ObservableObject {
    @Published var running = false
    @Published var level: Float = 0
    @Published var receivedFrames: UInt64 = 0
    @Published var inputRate: Double = 0
    @Published var recordingPath = ""
    @Published var recording = false
    var log: (String) -> Void = { _ in }
    var onStopped: () -> Void = {}
    private var engine: AVAudioEngine?
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayerNode?
    private let speechFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var generation = UUID()
    private var speechGeneration = UUID()
    private let recordingQueue = DispatchQueue(label: "PhoneBridge.recording")
    private var recordingFile: AVAudioFile?
    private var recordedFrames: AVAudioFramePosition = 0
    private var recordingLimit: AVAudioFramePosition = 0
    private var devices: (AudioDeviceID, AudioDeviceID)?
    private var deviceUIDs: (String, String)?
    private var routeMode: AudioRouteMode = .usb
    private var monitor: Timer?

    static func validateDevices(mode: AudioRouteMode, inputID: AudioDeviceID, outputID: AudioDeviceID) throws -> (AudioDeviceInfo, AudioDeviceInfo) {
        let available = AudioDeviceInfo.enumerate()
        guard let input = available.first(where: { $0.id == inputID }),
              let output = available.first(where: { $0.id == outputID }) else {
            throw BridgeError("所选音频设备未连接，请先连接通话音频接口并刷新设备。")
        }
        try AudioRoutePolicy.validate(mode: mode, input: input.endpoint, output: output.endpoint)
        return (input, output)
    }

    func start(mode: AudioRouteMode, inputID: AudioDeviceID, outputID: AudioDeviceID) throws {
        let (input, output) = try Self.validateDevices(mode: mode, inputID: inputID, outputID: outputID)
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw BridgeError("请先在窗口点击“启用音频”，允许 macOS 的音频输入权限。")
        }
        stop()
        let newEngine = AVAudioEngine()
        guard let inputUnit = newEngine.inputNode.audioUnit, let outputUnit = newEngine.outputNode.audioUnit else {
            throw BridgeError("无法创建 Core Audio 输入输出单元。")
        }
        var selectedInput = input.id
        var selectedOutput = output.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let inputResult = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selectedInput, size)
        let outputResult = AudioUnitSetProperty(outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selectedOutput, size)
        guard inputResult == noErr, outputResult == noErr else {
            throw BridgeError("无法选择音频设备：输入 \(inputResult)，输出 \(outputResult)。")
        }
        for (unit, expected) in [(inputUnit, input.id), (outputUnit, output.id)] {
            var actual: AudioDeviceID = 0
            var actualSize = size
            guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &actualSize) == noErr, actual == expected else {
                throw BridgeError("系统未采用指定音频设备，已取消启动。")
            }
        }
        let format = newEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            throw BridgeError("所选音频输入格式不可用。")
        }
        let player = AVAudioPlayerNode()
        newEngine.attach(player)
        newEngine.connect(player, to: newEngine.mainMixerNode, format: speechFormat)
        receivedFrames = 0
        inputRate = format.sampleRate
        let currentGeneration = UUID()
        generation = currentGeneration
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(count))
            // Copy before returning from the engine callback; AVAudioEngine owns its buffers.
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
            if let copy {
                copy.frameLength = buffer.frameLength
                for channel in 0..<Int(buffer.format.channelCount) {
                    copy.floatChannelData?[channel].update(from: buffer.floatChannelData![channel], count: count)
                }
                self.recordingQueue.async { [weak self] in self?.writeRecording(copy) }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration, self.running else { return }
                self.level = min(1, rms * 8)
                self.receivedFrames += UInt64(count)
            }
        }
        do { try newEngine.start() } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            throw error
        }
        engine = newEngine
        self.player = player
        devices = (inputID, outputID)
        deviceUIDs = (input.uid, output.uid)
        routeMode = mode
        running = true
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.verifyRoute() }
        log("音频引擎已启动：\(Int(format.sampleRate)) Hz。收到帧不等于收到可辨认的客服语音。")
    }

    private func verifyRoute() {
        guard let engine, let devices, let deviceUIDs else { return }
        let available = AudioDeviceInfo.enumerate()
        guard let input = available.first(where: { $0.id == devices.0 && $0.uid == deviceUIDs.0 }),
              let output = available.first(where: { $0.id == devices.1 && $0.uid == deviceUIDs.1 }),
              (try? AudioRoutePolicy.validate(mode: routeMode, input: input.endpoint, output: output.endpoint)) != nil else {
            stop(); log("选定音频设备消失或改变，已停止音频。")
            return
        }
        for (unit, expected) in [(engine.inputNode.audioUnit, devices.0), (engine.outputNode.audioUnit, devices.1)] {
            var actual: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard let unit, AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &size) == noErr, actual == expected else {
                stop(); log("检测到音频路由变化，已停止音频。")
                return
            }
        }
    }

    func speak(_ text: String) throws {
        verifyRoute()
        guard running, let player, engine?.isRunning == true else { throw BridgeError("需要先启用通话音频接口。") }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 1500 else { throw BridgeError("每次输入 1–1500 个字符。") }
        stopSpeech()
        let current = speechGeneration
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        synthesizer.write(utterance) { [weak self, weak player] audio in
            guard let self, let input = audio as? AVAudioPCMBuffer, input.frameLength > 0 else { return }
            DispatchQueue.main.async {
                guard self.running, self.speechGeneration == current, let player else { return }
                do {
                    let output = try Self.convert(input, to: self.speechFormat)
                    player.scheduleBuffer(output)
                    if !player.isPlaying { player.play() }
                } catch { self.stopSpeech(); self.log("语音转换失败：\(error.localizedDescription)") }
            }
        }
        log("文字已交给本机语音合成，音频将送往所选接口；需要对端确认是否听到。")
    }

    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 128) else {
            throw BridgeError("无法创建语音采样转换器。")
        }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if result == .error {
            if let conversionError { throw conversionError }
            throw BridgeError("音频转换失败")
        }
        return output
    }

    func stopSpeech() {
        speechGeneration = UUID()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
    }

    func recordTenSeconds(to url: URL) throws {
        verifyRoute()
        guard running, let format = engine?.inputNode.outputFormat(forBus: 0) else { throw BridgeError("请先启用音频。") }
        try recordingQueue.sync {
            guard recordingFile == nil else { throw BridgeError("正在录制测试片段。") }
            recordingFile = try AVAudioFile(forWriting: url, settings: format.settings)
            recordedFrames = 0
            recordingLimit = AVAudioFramePosition(format.sampleRate * 10)
        }
        recordingPath = url.path
        recording = true
        log("开始录制最多 10 秒的所选音频输入，仅保存在本机。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.recording == true { self?.stopRecording() }
        }
    }
    private func writeRecording(_ buffer: AVAudioPCMBuffer) {
        guard let file = recordingFile else { return }
        do {
            buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(max(0, recordingLimit - recordedFrames)))
            try file.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            if recordedFrames >= recordingLimit {
                recordingFile = nil
                DispatchQueue.main.async { [weak self] in self?.recording = false; self?.log("10 秒测试片段已保存。") }
            }
        } catch {
            recordingFile = nil
            DispatchQueue.main.async { [weak self] in self?.recording = false; self?.log("测试片段写入失败：\(error.localizedDescription)") }
        }
    }
    func stopRecording() {
        recordingQueue.sync { recordingFile = nil }
        recording = false
    }
    func stop() {
        generation = UUID()
        monitor?.invalidate(); monitor = nil
        stopSpeech()
        stopRecording()
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil; player = nil; devices = nil; deviceUIDs = nil; running = false; level = 0
        onStopped()
    }
}
