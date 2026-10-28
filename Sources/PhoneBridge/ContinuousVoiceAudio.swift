import AVFoundation
import CoreAudio
import BridgeCore
import BluetoothShim

private final class ContinuousVoiceBuffer {
    let pointer: OpaquePointer
    init(capacity: UInt32) throws {
        guard let pointer = PBVoicePatchCreate(capacity) else { throw BridgeError("无法分配有界音频缓冲。") }
        self.pointer = pointer
    }
    deinit { PBVoicePatchDestroy(pointer) }
    var snapshot: [String: Any] {
        let s = PBVoicePatchGetStats(pointer)
        return ["capturedFrames": s.capturedFrames, "renderedFrames": s.renderedFrames,
                "droppedFrames": s.droppedFrames, "missingFrames": s.missingFrames, "queuedFrames": s.queuedFrames,
                "captureCallbacks": s.captureCallbacks, "offeredFrames": s.offeredFrames, "rejectedFrames": s.rejectedFrames,
                "lastBufferCount": s.lastBufferCount, "lastChannels": s.lastChannels, "lastBytes": s.lastBytes,
                "lastFrames": s.lastFrames, "lastRejectCode": s.lastRejectCode]
    }
}

/// Each I/O engine owns one device. The two engines communicate through an
/// allocation-free SPSC ring; the source node/mixer converts sample rates.
@MainActor
private final class ContinuousVoicePatch {
    private let capture = AVAudioEngine()
    private let playback = AVAudioEngine()
    private var buffer: ContinuousVoiceBuffer?
    private var formatInfo: [String: Any] = [:]
    private var captureUnit: AudioUnit?
    private var ownsInputTap = false
    var isRunning: Bool { capture.isRunning && playback.isRunning }
    var hasFlow: Bool {
        guard let buffer else { return false }; let s = PBVoicePatchGetStats(buffer.pointer)
        return isRunning && s.capturedFrames > 0 && s.renderedFrames > 0
    }
    var snapshot: [String: Any] {
        var result = buffer?.snapshot ?? [:]
        result["captureRunning"] = capture.isRunning; result["playbackRunning"] = playback.isRunning
        if let unit = captureUnit {
            var actual: AudioDeviceID = 0; var bytes = UInt32(MemoryLayout<AudioDeviceID>.size)
            result["actualInputDeviceStatus"] = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &actual, &bytes)
            result["actualInputDeviceID"] = actual
            for (name, scope, bus) in [("inputIO", kAudioUnitScope_Input, UInt32(1)), ("outputIO", kAudioUnitScope_Output, UInt32(0))] {
                var flag: UInt32 = 0; var size: UInt32 = 4
                result[name + "Status"] = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_EnableIO, scope, bus, &flag, &size)
                result[name + "Enabled"] = flag
            }
        }
        result["format"] = formatInfo; return result
    }
    init(input: AudioDeviceID, output: AudioDeviceID) throws {
        guard let inputUnit = capture.inputNode.audioUnit else { throw BridgeError("无法创建采集单元。") }
        captureUnit = inputUnit
        try Self.bind(inputUnit, to: input)
        // AVAudioEngine caches its default-device format. Binding AUHAL alone
        // does not refresh that cache (virtual stereo -> built-in mono).
        // Read the bound hardware bus, then explicitly set the client bus.
        let format = try Self.hardwareFormat(inputUnit, scope: kAudioUnitScope_Input, bus: 1)
        try Self.setClientFormat(inputUnit, format: format, scope: kAudioUnitScope_Output, bus: 1)
        formatInfo = ["inputDeviceID": input, "outputDeviceID": output, "sampleRate": format.sampleRate,
                      "channels": format.channelCount, "interleaved": format.isInterleaved]
        guard format.commonFormat == .pcmFormatFloat32, (8_000...192_000).contains(format.sampleRate),
              (1...8).contains(format.channelCount),
              let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1) else {
            throw BridgeError("连续语音输入格式不可用。")
        }
        let context = try ContinuousVoiceBuffer(capacity: UInt32(max(512, min(192000, format.sampleRate / 4))))
        buffer = context
        guard let inputDevice = AudioDeviceInfo.enumerate().first(where: { $0.id == input }) else {
            throw BridgeError("采集设备已离线。")
        }
        if inputDevice.outputChannels == 0 {
            formatInfo["captureMethod"] = "input_tap"
            capture.inputNode.installTap(onBus: 0, bufferSize: 256, format: format) { audio, _ in
                _ = PBVoicePatchCapture(context.pointer, audio.audioBufferList, audio.frameLength)
            }
            ownsInputTap = true
        } else {
            formatInfo["captureMethod"] = "sink_node"
            let sink = AVAudioSinkNode { _, frames, data in
                _ = PBVoicePatchCapture(context.pointer, data, frames)
                return noErr
            }
            capture.attach(sink)
            capture.connect(capture.inputNode, to: sink, format: format)
        }
        guard let outputUnit = playback.outputNode.audioUnit else { throw BridgeError("无法创建播放单元。") }
        try Self.bind(outputUnit, to: output)
        let outputFormat = try Self.hardwareFormat(outputUnit, scope: kAudioUnitScope_Output, bus: 0)
        try Self.setClientFormat(outputUnit, format: outputFormat, scope: kAudioUnitScope_Input, bus: 0)
        formatInfo["outputSampleRate"] = outputFormat.sampleRate
        formatInfo["outputChannels"] = outputFormat.channelCount
        let source = AVAudioSourceNode(format: mono) { silence, _, frames, data in
            let rendered = PBVoicePatchRender(context.pointer, data, frames)
            silence.pointee = ObjCBool(rendered == 0)
            return noErr
        }
        playback.attach(source)
        playback.connect(source, to: playback.mainMixerNode, format: mono)
        playback.connect(playback.mainMixerNode, to: playback.outputNode, format: outputFormat)
        playback.mainMixerNode.outputVolume = 1
        do { try capture.start(); try playback.start() }
        catch { capture.stop(); playback.stop(); throw error }
    }
    func stop() {
        capture.stop(); playback.stop()
        if ownsInputTap { capture.inputNode.removeTap(onBus: 0); ownsInputTap = false }
    }
    func restartStoppedEngines() throws {
        if !capture.isRunning { try capture.start() }
        if !playback.isRunning { try playback.start() }
    }
    private static func hardwareFormat(_ unit: AudioUnit, scope: AudioUnitScope, bus: UInt32) throws -> AVAudioFormat {
        var native = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, bus, &native, &size)
        guard status == noErr, (8_000...192_000).contains(native.mSampleRate),
              (1...8).contains(native.mChannelsPerFrame),
              let format = AVAudioFormat(standardFormatWithSampleRate: native.mSampleRate, channels: native.mChannelsPerFrame) else {
            throw BridgeError("无法读取实际硬件音频格式（\(status)）。")
        }
        return format
    }
    private static func setClientFormat(_ unit: AudioUnit, format: AVAudioFormat, scope: AudioUnitScope, bus: UInt32) throws {
        var requested = format.streamDescription.pointee
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, bus, &requested, size)
        guard status == noErr else { throw BridgeError("无法同步音频客户端格式（\(status)）。") }
        var actual = AudioStreamBasicDescription(); var bytes = size
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, bus, &actual, &bytes) == noErr,
              actual.mSampleRate == requested.mSampleRate, actual.mChannelsPerFrame == requested.mChannelsPerFrame,
              actual.mFormatFlags == requested.mFormatFlags else {
            throw BridgeError("音频客户端格式与硬件不一致。")
        }
    }
    private static func bind(_ unit: AudioUnit, to selected: AudioDeviceID) throws {
        var id = selected
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, size)
        guard status == noErr else { throw BridgeError("音频设备绑定失败（\(status)）。") }
        var actual: AudioDeviceID = 0; var count = size
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &count) == noErr,
              actual == selected else { throw BridgeError("系统没有采用指定的音频设备。") }
    }
}

/// The external voice app owns stable software devices, never the phone's SCO
/// endpoints. Only these two private patch engines change at call boundaries.
/// No recordings, network/API access, or phone-control commands live here.
@MainActor
final class ContinuousVoiceAudio {
    static let inputUID = "cn.andy.phonebridge.audio.input.device"
    static let outputUID = "cn.andy.phonebridge.audio.output.device"
    private(set) var active = false
    private(set) var target = "stopped"
    private(set) var error = ""
    private var upstream: ContinuousVoicePatch?
    private var downstream: ContinuousVoicePatch?
    private var ownerInput: AudioDeviceInfo?
    private var ownerOutput: AudioDeviceInfo?
    private var savedDefaults: [AudioObjectPropertySelector: String] = [:]
    private var installedDefaults: [AudioObjectPropertySelector: String] = [:]
    var onFailure: ((String) -> Void)?
    private var monitor: Task<Void, Never>?
    private var warmupUntil: TimeInterval = 0
    private var restartAttempts = 0
    private var lastUpstream: [String: Any] = [:], lastDownstream: [String: Any] = [:]

    var installed: Bool {
        let devices = AudioDeviceInfo.enumerate()
        return devices.filter { $0.uid == Self.inputUID && $0.inputChannels == 2 && $0.outputChannels == 2 }.count == 1 &&
            devices.filter { $0.uid == Self.outputUID && $0.inputChannels == 2 && $0.outputChannels == 2 }.count == 1
    }
    private var routeConfigured: Bool {
        active && installed && error.isEmpty &&
        Self.defaultUID(kAudioHardwarePropertyDefaultInputDevice) == Self.inputUID &&
        Self.defaultUID(kAudioHardwarePropertyDefaultOutputDevice) == Self.outputUID
    }
    var ready: Bool { routeConfigured && upstream?.hasFlow == true && downstream?.hasFlow == true }
    var snapshot: [String: Any] {
        ["installed": installed, "active": active, "ready": ready, "target": target,
         "error": error, "voiceInputName": "PhoneBridge Voice Input", "voiceOutputName": "PhoneBridge Voice Output",
         "patchEnginesRunning": upstream?.isRunning == true && downstream?.isRunning == true,
         "upstream": upstream?.snapshot ?? lastUpstream, "downstream": downstream?.snapshot ?? lastDownstream,
         "restartAttempts": restartAttempts,
         "phoneRouteVerified": false, "externalVoiceStartedVerified": false,
         "pendingDefaultRestores": savedDefaults.count,
         "outputScope": "system default output; other applications may also render here"]
    }

    func start() throws {
        if active { guard ready else { throw BridgeError("连续语音接口待恢复。") }; return }
        guard installed else { throw BridgeError("请先安装 PhoneBridge 连续语音设备。") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw BridgeError("请先完成通话桥麦克风授权。")
        }
        // Choose explicit hardware, never an incidental Bluetooth/default
        // microphone. This prevents opening SCO before an actual phone call.
        let devices = AudioDeviceInfo.enumerate()
        let builtInInputs = devices.filter { Self.transport($0.id) == kAudioDeviceTransportTypeBuiltIn && $0.inputChannels > 0 }
        let builtInOutputs = devices.filter { Self.transport($0.id) == kAudioDeviceTransportTypeBuiltIn && $0.outputChannels > 0 }
        guard builtInInputs.count == 1, builtInOutputs.count == 1 else {
            throw BridgeError("没有找到唯一的 Mac 内置麦克风和扬声器，不能自动选择连续语音的本机设备。")
        }
        ownerInput = builtInInputs[0]; ownerOutput = builtInOutputs[0]
        error = ""; active = true
        do {
            for (selector, uid) in [(kAudioHardwarePropertyDefaultInputDevice, Self.inputUID),
                                    (kAudioHardwarePropertyDefaultOutputDevice, Self.outputUID)] {
                let previous = Self.defaultUID(selector)
                guard let previous, !previous.isEmpty else { throw BridgeError("无法保存原音频设备。") }
                if previous == uid { continue }
                savedDefaults[selector] = previous; installedDefaults[selector] = uid
                try Self.setDefault(selector, uid: uid)
            }
            try switchToOwner()
            guard routeConfigured else { throw BridgeError("连续语音设备写入后未通过核对。") }
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    guard let self, self.active else { return }
                    if !self.routeConfigured {
                        self.error = "连续语音设备或默认路由发生变化。"
                        self.suspendForDial(); self.onFailure?(self.error); return
                    }
                    if self.target == "owner" || self.target == "phone" {
                        if !self.ready && ProcessInfo.processInfo.systemUptime < self.warmupUntil {
                            if self.restartAttempts < 2 {
                                do { try self.upstream?.restartStoppedEngines(); try self.downstream?.restartStoppedEngines(); self.restartAttempts += 1 }
                                catch { self.error = error.localizedDescription }
                            }
                            continue
                        }
                        if !self.ready {
                            self.error = "连续音频未持续收到有效输入帧，不能拨号。"
                            self.suspendForDial(); self.onFailure?(self.error); return
                        }
                    }
                }
            }
        } catch {
            stopAfterVoiceEnded()
            throw error
        }
    }

    /// Stops only owned patch clients. The devices and external voice client
    /// stay alive; no phone endpoint is opened while the phone is ringing.
    func suspendForDial() {
        stopPatches(); flushCables(); if active { target = "waiting_for_phone" }
    }
    func prepareForDial() throws {
        guard ready, target == "owner", upstream?.isRunning == true, downstream?.isRunning == true else {
            throw BridgeError("请先恢复连续语音的本机交流路径。")
        }
        // Keep the owner able to speak/cancel while the destination rings.
        // These are built-in Mac devices; no phone SCO client is opened here.
        flushCables()
        guard error.isEmpty else { throw BridgeError(error) }
        target = "owner_dialing"
    }
    func switchToPhone(_ phone: PhonePeerConfiguration) throws {
        guard ready else { throw BridgeError("连续语音接口未就绪。") }
        let devices = AudioDeviceInfo.enumerate()
        guard let input = devices.first(where: { $0.uid == phone.inputUID }),
              let output = devices.first(where: { $0.uid == phone.outputUID }) else {
            throw BridgeError("手机通话音频端点尚未出现。")
        }
        _ = try AudioBridge.validateDevices(mode: .bluetooth, inputID: input.id, outputID: output.id)
        try patch(input: input, output: output)
        target = "phone"
    }
    func switchToOwner() throws {
        guard active, let input = ownerInput, let output = ownerOutput else { return }
        do { try patch(input: input, output: output); target = "owner" }
        catch { stopPatches(); target = "muted"; self.error = error.localizedDescription; throw error }
    }
    private func patch(input: AudioDeviceInfo, output: AudioDeviceInfo) throws {
        stopPatches()
        restartAttempts = 0; warmupUntil = ProcessInfo.processInfo.systemUptime + 8
        flushCables()
        guard error.isEmpty else { throw BridgeError(error) }
        let devices = AudioDeviceInfo.enumerate()
        guard devices.contains(where: { $0.id == input.id && $0.uid == input.uid }),
              devices.contains(where: { $0.id == output.id && $0.uid == output.uid }) else {
            throw BridgeError("所选硬件音频设备身份已改变。")
        }
        guard let voiceIn = devices.first(where: { $0.uid == Self.inputUID }),
              let voiceOut = devices.first(where: { $0.uid == Self.outputUID }) else {
            throw BridgeError("连续语音设备已离线。")
        }
        do {
            // Independent graphs: remote/owner -> AI microphone, AI -> remote/owner.
            // There is no connection from AI output back to AI input.
            upstream = try ContinuousVoicePatch(input: input.id, output: voiceIn.id)
            downstream = try ContinuousVoicePatch(input: voiceOut.id, output: output.id)
        } catch { stopPatches(); throw error }
    }
    private func stopPatches() {
        if let upstream { lastUpstream = upstream.snapshot }
        if let downstream { lastDownstream = downstream.snapshot }
        upstream?.stop(); downstream?.stop(); upstream = nil; downstream = nil
    }
    private func flushCables() {
        for device in AudioDeviceInfo.enumerate() where [Self.inputUID, Self.outputUID].contains(device.uid) {
            var a = AudioObjectPropertyAddress(mSelector: 0x5042666C, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            let value = NSNumber(value: 1)
            var pointer = Unmanaged.passUnretained(value).toOpaque()
            let result = withExtendedLifetime(value) {
                AudioObjectSetPropertyData(device.id, &a, 0, nil, UInt32(MemoryLayout.size(ofValue: pointer)), &pointer)
            }
            if result != noErr {
                error = "连续语音缓冲清理未得到确认。"
            }
        }
    }

    /// Caller must know the independent frontend voice has actually ended.
    /// Restore only fields we wrote and only if still pointing to our device.
    func stopAfterVoiceEnded() {
        monitor?.cancel(); monitor = nil; stopPatches(); target = "stopped"
        for (selector, previous) in savedDefaults {
            if Self.defaultUID(selector) == installedDefaults[selector] {
                do {
                    let devices = AudioDeviceInfo.enumerate()
                    let destination: String
                    if devices.contains(where: { $0.uid == previous }) { destination = previous }
                    else {
                        // A disconnected headset/temporary device cannot be
                        // restored. Return to explicit Mac hardware rather than
                        // leaving virtual devices selected with stopped patches.
                        let candidates = devices.filter {
                            Self.transport($0.id) == kAudioDeviceTransportTypeBuiltIn &&
                            (selector == kAudioHardwarePropertyDefaultInputDevice ? $0.inputChannels > 0 : $0.outputChannels > 0)
                        }
                        guard candidates.count == 1 else { throw BridgeError("原音频设备已离线，且无法唯一确定 Mac 内置设备。") }
                        destination = candidates[0].uid
                    }
                    try Self.setDefault(selector, uid: destination)
                }
                catch { self.error = error.localizedDescription; continue }
            }
            savedDefaults.removeValue(forKey: selector); installedDefaults.removeValue(forKey: selector)
        }
        active = !savedDefaults.isEmpty
        if !active { error = "" }
    }
    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr else { return nil }
        return AudioDeviceInfo.enumerate().first(where: { $0.id == id })?.uid
    }
    private static func setDefault(_ selector: AudioObjectPropertySelector, uid: String) throws {
        guard let device = AudioDeviceInfo.enumerate().first(where: { $0.uid == uid }) else {
            throw BridgeError("待选择的音频设备不可用。")
        }
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var id = device.id
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr,
              defaultUID(selector) == uid else { throw BridgeError("默认音频路由设置失败。") }
    }
    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: UInt32 = 0; var size: UInt32 = 4
        _ = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value)
        return value
    }
}
