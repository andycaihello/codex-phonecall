import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Speech
import Darwin
import BridgeCore

/// Single audio-thread writer. Main only reads the published, never-rewritten prefix.
/// OSAtomic barriers preserve macOS 14 support; no lock/allocation/Speech in render.
final class BuiltinCaptionSamples: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    let scratch: UnsafeMutablePointer<Float>
    let capacity: Int
    let maximumSlice = 4096
    let published = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    let failure = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var unit: AudioUnit?
    private var used = 0
    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity); scratch = .allocate(capacity: maximumSlice)
        published.initialize(to: 0); failure.initialize(to: 0)
    }
    deinit { samples.deallocate(); scratch.deallocate(); published.deinitialize(count: 1); published.deallocate(); failure.deinitialize(count: 1); failure.deallocate() }
    var publishedFrames: Int { Int(OSAtomicAdd32Barrier(0, published)) }
    var failureCode: Int32 { OSAtomicAdd32Barrier(0, failure) }
    func markFailure(_ code: Int32) { _ = OSAtomicCompareAndSwap32Barrier(0, code == 0 ? -1 : code, failure) }
    func append(_ source: UnsafePointer<Float>, count: Int) {
        guard failureCode == 0 else { return }
        guard count > 0, count <= maximumSlice, count <= capacity - used else { markFailure(-2); return }
        samples.advanced(by: used).update(from: source, count: count)
        used += count
        _ = OSAtomicAdd32Barrier(Int32(count), published)
    }
}

private let builtinCaptionRender: AURenderCallback = { context, flags, timestamp, _, frames, _ in
    let capture = Unmanaged<BuiltinCaptionSamples>.fromOpaque(context).takeUnretainedValue()
    guard capture.failureCode == 0 else { return kAudio_ParamError }
    guard let unit = capture.unit, frames > 0, frames <= capture.maximumSlice else { capture.markFailure(-3); return kAudio_ParamError }
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
        mDataByteSize: frames * 4, mData: capture.scratch))
    let status = AudioUnitRender(unit, flags, timestamp, 1, frames, &list)
    guard status == noErr, list.mNumberBuffers == 1, list.mBuffers.mNumberChannels == 1,
          list.mBuffers.mDataByteSize == frames * 4, list.mBuffers.mData == UnsafeMutableRawPointer(capture.scratch) else {
        capture.markFailure(status == 0 ? -4 : status); return status == 0 ? kAudio_ParamError : status
    }
    capture.append(capture.scratch, count: Int(frames))
    return noErr
}

@MainActor
final class BuiltinVoiceCaptions {
    var onTranscript: ((String, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var running = false
    private(set) var prepared = false
    private(set) var cleanupVerified = true
    private var phone: PhonePeerConfiguration?
    private var outgoingVoice = false
    private var modernStorage: AnyObject?
    private var backendPreparation = UUID()
    private var device: AudioDeviceInfo?
    private var rate: Double = 0
    private var unit: AudioUnit?
    private var capture: BuiltinCaptionSamples?
    private var initialized = false
    private var run: UUID?
    private var timer: Timer?
    private var began: TimeInterval = 0
    private var cursor = 0
    private var overlapFrames = 0
    private var segments: [Segment] = []
    private var current: Segment?
    private var recognizer: SFSpeechRecognizer?
    private var format: AVAudioFormat?
    private var failureStage = ""
    private var recognitionErrorCode = 0
    private var stopStatus: OSStatus = 0
    private var uninitializeStatus: OSStatus = 0
    private var disposeStatus: OSStatus = 0
    private var lastPublished = 0
    private var lastSegmentCount = 0
    private var recognitionStopRequested = false
    private var permissionRequest: UUID?
    // A failed dispose cannot free a render context potentially still in use.
    private static var retainedFailedUnits: [(AudioUnit, BuiltinCaptionSamples)] = []

    func configure(phone: PhonePeerConfiguration) throws {
        guard !running, cleanupVerified, unit == nil, capture == nil, permissionRequest == nil else {
            throw BridgeError("本机字幕仍在运行或清理，请结束后再更换手机。")
        }
        self.phone = phone; outgoingVoice = false; prepared = false; device = nil; recognizer = nil; format = nil; rate = 0
    }
    func clearPhoneConfiguration() throws {
        guard !running, cleanupVerified, unit == nil, capture == nil, permissionRequest == nil else {
            throw BridgeError("本机字幕仍在运行或清理，无法取消选择手机。")
        }
        phone = nil; outgoingVoice = false; prepared = false; device = nil; recognizer = nil; format = nil; rate = 0
    }

    /// Explicitly capture the stable output cable, never a default microphone.
    func configureOutgoingVoice() throws {
        guard !running, cleanupVerified, unit == nil, capture == nil, permissionRequest == nil else {
            throw BridgeError("我方字幕仍在运行或清理。")
        }
        phone = nil; outgoingVoice = true; prepared = false
        device = nil; recognizer = nil; format = nil; rate = 0
    }
    nonisolated static func selectOutgoingDevice(_ devices: [AudioDeviceInfo]) throws -> AudioDeviceInfo {
        let matches = devices.filter { $0.uid == "cn.andy.phonebridge.audio.output.device" }
        guard matches.count == 1, let selected = matches.first, selected.id != 0,
              selected.name == "PhoneBridge Voice Output", !selected.bluetooth,
              selected.inputChannels == 2, selected.outputChannels == 2 else {
            throw BridgeError("我方语音输出设备不可用，未改用其他音源。")
        }
        return selected
    }
    private func selectConfiguredDevice() throws -> AudioDeviceInfo {
        if outgoingVoice { return try Self.selectOutgoingDevice(AudioDeviceInfo.enumerate()) }
        guard let phone else { throw BridgeError("请先选择字幕音源。") }
        return try Self.selectDevice(AudioDeviceInfo.enumerate(), phone: phone)
    }
    private final class Segment {
        let id: String
        let startFrame: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        var final = false
        var sawText = false
        var endingAt: TimeInterval?
        var completedAt: TimeInterval?
        init(id: String, startFrame: Int, request: SFSpeechAudioBufferRecognitionRequest) {
            self.id = id; self.startFrame = startFrame; self.request = request
        }
    }

    var diagnosticSnapshot: [String: Any] {
        ["phoneConfigured": phone != nil, "outgoingVoice": outgoingVoice, "prepared": prepared, "running": running, "cleanupVerified": cleanupVerified,
         "onDeviceOnly": true, "inputOnly": true, "sampleRate": rate, "modernBackend": modernStorage != nil,
         "publishedFrames": capture?.publishedFrames ?? lastPublished, "submittedThroughFrame": cursor,
         "segmentCount": segments.isEmpty ? lastSegmentCount : segments.count, "overlapFrames": overlapFrames,
         "recognitionStopRequested": recognitionStopRequested,
         "failureStage": failureStage, "recognitionErrorCode": recognitionErrorCode,
         "stopStatus": stopStatus, "uninitializeStatus": uninitializeStatus, "disposeStatus": disposeStatus]
    }

    /// Explicit permission action, separate from prepare/start. Never starts audio.
    func requestPermissions() async {
        guard !running, permissionRequest == nil else { return }
        let request = UUID(); permissionRequest = request
        defer { if permissionRequest == request { permissionRequest = nil } }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard !Task.isCancelled, permissionRequest == request else { return }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
        }
    }

    nonisolated static func validatePermissions(microphone: Bool, speech: Bool) throws {
        guard microphone else { throw BridgeError("请先允许通话桥使用音频输入权限。") }
        guard speech else { throw BridgeError("请先允许通话桥使用语音识别权限。") }
    }
    nonisolated static func selectDevice(_ devices: [AudioDeviceInfo], phone: PhonePeerConfiguration) throws -> AudioDeviceInfo {
        let matches = devices.filter { $0.uid == phone.inputUID }
        guard matches.count == 1, let selected = matches.first, selected.id != 0,
              selected.name == phone.name, selected.bluetooth, selected.transport == .bluetooth,
              selected.inputChannels == 1, selected.outputChannels == 0 else {
            throw BridgeError("所选手机的单声道蓝牙输入尚未就绪，已取消本机字幕。")
        }
        return selected
    }
    private func checkPermissions() throws {
        try Self.validatePermissions(microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                                     speech: SFSpeechRecognizer.authorizationStatus() == .authorized)
    }
    private func makeRecognizer() throws -> SFSpeechRecognizer {
        guard let value = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              value.locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == "zh-cn",
              value.supportsOnDeviceRecognition, value.isAvailable else {
            throw BridgeError("本机中文语音识别不可用，无法启动本地字幕。")
        }
        value.queue = .main
        return value
    }
    private static func deviceRate(_ id: AudioDeviceID, outgoing: Bool = false) throws -> Double {
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0, transportSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
              transportSize == MemoryLayout<UInt32>.size,
              transport == (outgoing ? kAudioDeviceTransportTypeVirtual : kAudioDeviceTransportTypeBluetooth) else {
            throw BridgeError("所选手机未保持蓝牙通话输入，本机字幕已停止。")
        }
        var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &aliveAddress, 0, nil, &size, &alive) == noErr, alive == 1 else { throw BridgeError("手机蓝牙输入已离线。") }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0; size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              [8000.0, 16000, 24000, 32000, 44100, 48000].contains(value) else { throw BridgeError("手机输入采样格式不可用。") }
        return value
    }

    /// Permission, language capability and exact device checks only. No AU/Speech task.
    func prepare() throws {
        guard outgoingVoice || phone != nil else { throw BridgeError("请先选择字幕音源，再准备本机字幕。") }
        guard !running, cleanupVerified else { throw BridgeError("上一次本机字幕仍在清理。") }
        prepared = false
        try checkPermissions()
        let selected = try selectConfiguredDevice()
        let selectedRate = try Self.deviceRate(selected.id, outgoing: outgoingVoice)
        let speech = try makeRecognizer()
        device = selected; rate = selectedRate; recognizer = speech
        prepared = true; failureStage = ""; recognitionErrorCode = 0
    }

    /// Warm recognition before dialing; this starts no hardware capture.
    func prepareRecognitionBackend() async throws {
        guard prepared, !running, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw BridgeError("请先准备字幕音源。")
        }
        let preparation = UUID(); backendPreparation = preparation
        if #available(macOS 26.0, *) {
            let modern = ModernCaptionRecognition()
            modern.onTranscript = { [weak self] id, text, final in
                guard let self, self.running else { return }
                self.onTranscript?(id, text, final)
            }
            modern.onFailure = { [weak self] message in self?.fail(message, stage: "modern-recognition") }
            try await modern.prepare(format: format)
            guard !Task.isCancelled, backendPreparation == preparation, prepared, !running else {
                await modern.stopAndWait(); throw CancellationError()
            }
            modernStorage = modern
        } else if outgoingVoice {
            throw BridgeError("双向本机字幕需要 macOS 26 或更新版本。")
        }
    }
    /// Caller invokes only after the owned call is connected.
    func start() throws {
        guard (outgoingVoice || phone != nil), prepared, !running, cleanupVerified, let expected = device else { throw BridgeError("请先准备本机字幕，再在电话接通后启动。") }
        try checkPermissions()
        let selected = try selectConfiguredDevice()
        guard selected.id == expected.id, try Self.deviceRate(selected.id, outgoing: outgoingVoice) == rate else { throw BridgeError("手机音频路由已变化，请重新准备本机字幕。") }
        if modernStorage == nil { recognizer = try makeRecognizer() }
        guard let nextFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { throw BridgeError("无法创建本机字幕输入格式。") }
        format = nextFormat
        let generation = UUID(); run = generation
        cursor = 0; overlapFrames = 0; lastPublished = 0; lastSegmentCount = 0; recognitionStopRequested = false; segments.removeAll(); current = nil
        stopStatus = 0; uninitializeStatus = 0; disposeStatus = 0
        failureStage = ""; recognitionErrorCode = 0
        let context = BuiltinCaptionSamples(capacity: Int(rate * 300))
        capture = context
        do {
            var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else { throw BridgeError("无法创建手机输入音频单元。") }
            var next: AudioUnit?
            try require(AudioComponentInstanceNew(component, &next), stage: "create")
            guard let next else { throw BridgeError("手机输入音频单元为空。") }
            unit = next; context.unit = next; cleanupVerified = false
            var enabled: UInt32 = 1, disabled: UInt32 = 0, id = selected.id
            try property(next, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            try property(next, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled)
            try property(next, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id)
            var maximum: UInt32 = UInt32(context.maximumSlice)
            try property(next, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum)
            var streamDescription = nextFormat.streamDescription.pointee
            try property(next, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamDescription)
            if outgoingVoice {
                // Both output cable channels contain the same mono voice mix.
                // Select channel zero explicitly; AUHAL does not downmix itself.
                var channel: Int32 = 0
                try property(next, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &channel)
            }
            var callback = AURenderCallbackStruct(inputProc: builtinCaptionRender, inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
            try property(next, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
            try verifyRoute()
            try require(AudioUnitInitialize(next), stage: "initialize"); initialized = true
            try verifyRoute()
            if modernStorage == nil { try beginSegment(generation) }
            began = ProcessInfo.processInfo.systemUptime
            running = true
            try require(AudioOutputUnitStart(next), stage: "start")
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self, self.run == generation else { return }; self.pump(generation) }
            }
        } catch {
            stop()
            throw error
        }
    }
    private func require(_ status: OSStatus, stage: String) throws {
        guard status == noErr else { failureStage = stage; throw BridgeError("本机字幕音频初始化失败（\(stage)，\(status)）。") }
    }
    private func property<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout T) throws {
        // This private helper is used only with the fixed POD CoreAudio values above.
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, element, $0, UInt32(MemoryLayout<T>.size))
        }
        try require(status, stage: "configure")
    }
    private func verifyRoute() throws {
        guard (outgoingVoice || phone != nil), let unit, let expected = device else { throw BridgeError("本机字幕输入未绑定。") }
        let selected = try selectConfiguredDevice()
        guard selected.id == expected.id, try Self.deviceRate(selected.id, outgoing: outgoingVoice) == rate else { throw BridgeError("手机蓝牙输入已变化，本机字幕已停止。") }
        var actual: AudioDeviceID = 0, size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size) == noErr,
              actual == expected.id else { throw BridgeError("系统未保持指定手机输入，本机字幕已停止。") }
        var asbd = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, &size) == noErr,
              asbd.mSampleRate == rate, asbd.mChannelsPerFrame == 1, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32, asbd.mBytesPerFrame == 4, asbd.mFramesPerPacket == 1,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
            throw BridgeError("手机输入格式已变化，本机字幕已停止。")
        }
    }
    private func beginSegment(_ generation: UUID) throws {
        try checkPermissions()
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition,
              segments.count < 180 else { throw BridgeError("本机中文识别已不可用，字幕已停止。") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        guard request.requiresOnDeviceRecognition else { throw BridgeError("无法限定本机识别，字幕已停止。") }
        let segment = Segment(id: "local-\(generation.uuidString)-\(segments.count + 1)", startFrame: cursor, request: request)
        segments.append(segment); current = segment
        let id = segment.id
        segment.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.run == generation, let record = self.segments.first(where: { $0.id == id }) else { return }
                if let result, !record.final {
                    record.sawText = record.sawText || !result.bestTranscription.formattedString.isEmpty
                    record.final = result.isFinal
                    self.onTranscript?(id, result.bestTranscription.formattedString, result.isFinal)
                    if result.isFinal { record.endingAt = record.endingAt ?? ProcessInfo.processInfo.systemUptime; record.request.endAudio() }
                }
                if let error {
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 {
                        record.endingAt = record.endingAt ?? ProcessInfo.processInfo.systemUptime
                    } else { self.recognitionErrorCode = ns.code; self.fail("本机语音识别失败，字幕已停止。", stage: "recognition") }
                }
            }
        }
    }
    private func pump(_ generation: UUID) {
        guard running, run == generation, let capture, let format else { return }
        if #available(macOS 26.0, *), let modern = modernStorage as? ModernCaptionRecognition {
            pumpModern(modern, capture: capture, format: format)
            return
        }
        guard let current else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - began < 300 else { fail("本机字幕已达到 5 分钟上限。", stage: "deadline"); return }
        guard capture.failureCode == 0 else { fail("手机音频输入失败，本机字幕已停止。", stage: "render"); return }
        guard recognizer?.isAvailable == true, recognizer?.supportsOnDeviceRecognition == true else { fail("本机中文识别已不可用，字幕已停止。", stage: "capability"); return }
        do {
            try checkPermissions(); try verifyRoute()
            let published = capture.publishedFrames
            let state = current.task?.state
            if current.endingAt != nil || state == .finishing || state == .completed {
                current.endingAt = current.endingAt ?? now
                current.request.endAudio()
                if state != .completed {
                    if now - current.endingAt! > 2 { fail("本机识别分段未及时结束。", stage: "segment-timeout") }; return
                }
                current.completedAt = current.completedAt ?? now
                guard now - current.completedAt! >= 0.15, published > cursor else { return }
                // A task may end before consuming its queued tail. Replay at most
                // half a second into a new, separately labelled hypothesis.
                let rewind = min(Int(rate / 2), cursor - current.startFrame)
                cursor -= rewind; overlapFrames += rewind
                try beginSegment(generation)
                return
            }
            if state == .canceling { fail("本机识别意外中断。", stage: "recognition-cancelled"); return }
            // All allocation and Speech work occurs on main, after atomic acquire.
            var batches = 0
            while cursor < published && batches < 16 {
                let count = min(2048, published - cursor)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let samples = buffer.floatChannelData?[0] else { throw BridgeError("无法准备本机字幕音频。") }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.update(from: capture.samples.advanced(by: cursor), count: count)
                current.request.append(buffer)
                cursor += count; batches += 1
            }
        } catch { fail("手机音频路由或本机识别状态已变化，字幕已停止。", stage: "route") }
    }
    @available(macOS 26.0, *)
    private func pumpModern(_ modern: ModernCaptionRecognition, capture: BuiltinCaptionSamples, format: AVAudioFormat) {
        guard ProcessInfo.processInfo.systemUptime - began < 300 else { fail("字幕已达到五分钟上限。", stage: "deadline"); return }
        guard capture.failureCode == 0 else { fail("字幕输入读取失败。", stage: "render"); return }
        do {
            try checkPermissions(); try verifyRoute()
            let published = capture.publishedFrames
            var batches = 0
            while cursor < published && batches < 16 {
                let count = min(2048, published - cursor)
                guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let samples = block.floatChannelData?[0] else { throw BridgeError("字幕缓冲不可用。") }
                block.frameLength = AVAudioFrameCount(count)
                samples.update(from: capture.samples.advanced(by: cursor), count: count)
                try modern.append(block); cursor += count; batches += 1
            }
        } catch { fail(error.localizedDescription, stage: "modern-input") }
    }
    private func fail(_ message: String, stage: String) {
        guard run != nil else { return }
        failureStage = stage; stop(); onFailure?(message)
    }
    func stop() {
        run = nil; backendPreparation = UUID(); permissionRequest = nil; timer?.invalidate(); timer = nil
        if #available(macOS 26.0, *), let modern = modernStorage as? ModernCaptionRecognition { modern.stop() }
        modernStorage = nil
        // Revoke rendering/copying before any fallible HAL cleanup. A context
        // retained after failed disposal must never continue accepting samples.
        capture?.markFailure(-5)
        let wasRunning = running
        running = false; prepared = false
        if let unit {
            if wasRunning { stopStatus = AudioOutputUnitStop(unit) }
            if initialized { uninitializeStatus = AudioUnitUninitialize(unit) }
            disposeStatus = AudioComponentInstanceDispose(unit)
            cleanupVerified = stopStatus == noErr && uninitializeStatus == noErr && disposeStatus == noErr
            if disposeStatus != noErr, let capture { Self.retainedFailedUnits.append((unit, capture)) }
        }
        lastPublished = capture?.publishedFrames ?? lastPublished
        self.unit = nil; initialized = false; capture = nil
        lastSegmentCount = max(lastSegmentCount, segments.count)
        recognitionStopRequested = recognitionStopRequested || !segments.isEmpty
        for segment in segments { segment.request.endAudio(); segment.task?.cancel() }
        segments.removeAll()
        current = nil; recognizer = nil; format = nil; device = nil
    }
}
