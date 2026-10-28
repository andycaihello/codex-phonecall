import Combine
import CoreAudio
import Foundation
import BridgeCore

enum BuiltinVoiceRouteDirection: String, CaseIterable { case input, output }

struct BuiltinVoiceRouteDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let alive: Bool
    let bluetooth: Bool
    let inputChannels: Int
    let outputChannels: Int
    let phoneFormat: Bool
    let canBeDefaultInput: Bool
    let canBeDefaultOutput: Bool
}

@MainActor
protocol BuiltinVoiceRouteHardware: AnyObject {
    func devices() throws -> [BuiltinVoiceRouteDevice]
    func defaultDevice(_ direction: BuiltinVoiceRouteDirection) throws -> AudioDeviceID
    func defaultIsSettable(_ direction: BuiltinVoiceRouteDirection) throws -> Bool
    func setDefaultDevice(_ id: AudioDeviceID, direction: BuiltinVoiceRouteDirection) throws
}

struct BuiltinVoiceRouteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns only explicitly changed default-input/default-output fields, never an IOProc.
/// Stopping a phone call is not authorization to restore speakers: callers must wait
/// until the user has stopped the external voice chat before calling stop().
@MainActor
final class BuiltinVoiceRoute: ObservableObject {
    struct Status: Equatable {
        var available = false
        var ready = false
        var inputDefaultIsPhone = false
        var outputDefaultIsPhone = false
        var canRouteInput = false
        var canRouteOutput = false
        var message = "尚未检查电话音频端点。"
    }
    @Published private(set) var status = Status()
    // Remains true after a fault while this session still holds restoration duties.
    @Published private(set) var active = false
    var onFailure: ((String) -> Void)?

    private struct Change {
        let previousUID: String
        let installedUID: String
    }
    private let hardware: BuiltinVoiceRouteHardware
    private var phone: PhonePeerConfiguration?
    private let automaticallyMonitor: Bool
    private var changes: [BuiltinVoiceRouteDirection: Change] = [:]
    private var requested: Set<BuiltinVoiceRouteDirection> = []
    private var monitorTask: Task<Void, Never>?
    private var failureLatched = false
    private var monitorSuspended = false
    private var failureCode = ""
    private var checks = 0
    private var restoreResults: [String: String] = [:]

    init(hardware: BuiltinVoiceRouteHardware? = nil, automaticallyMonitor: Bool = true) {
        self.hardware = hardware ?? BuiltinVoiceHALHardware()
        self.automaticallyMonitor = automaticallyMonitor
        // Deliberately no enumeration, permission request, device open or route write.
    }
    deinit { monitorTask?.cancel() }

    func configure(phone: PhonePeerConfiguration) throws {
        guard !active, changes.isEmpty else {
            throw BuiltinVoiceRouteError(message: "请先停止内置语音并恢复音频，再更换手机。")
        }
        self.phone = phone
        status = Status(message: "手机已选择，等待电话音频端点就绪。")
        failureLatched = false; monitorSuspended = false; failureCode = ""
    }
    func clearPhoneConfiguration() throws {
        guard !active, changes.isEmpty else {
            throw BuiltinVoiceRouteError(message: "仍持有音频路由，无法取消选择手机。")
        }
        phone = nil; status = Status(message: "请先选择一部已配对手机。")
        failureLatched = false; monitorSuspended = false; failureCode = ""
    }

    var diagnosticSnapshot: [String: Any] {
        ["active": active, "phoneConfigured": phone != nil, "ready": status.ready, "endpointsAvailable": status.available,
         "inputDefaultIsPhone": status.inputDefaultIsPhone,
         "outputDefaultIsPhone": status.outputDefaultIsPhone,
         "canRouteInput": status.canRouteInput, "canRouteOutput": status.canRouteOutput,
         "requestedInputChange": requested.contains(.input), "requestedOutputChange": requested.contains(.output),
         "pendingInputRestore": changes[.input] != nil, "pendingOutputRestore": changes[.output] != nil,
         "monitoring": monitorTask != nil, "monitorChecks": checks, "failureLatched": failureLatched,
         "failureCode": failureCode, "restoreResults": restoreResults,
         "systemAlertOutputChanged": false, "audioIOStarted": false, "voiceChatStarted": false,
         "externalVoiceEndToEndVerified": false,
         "failurePolicy": "retain route; macOS itself may fall back if a device disappears"]
    }

    /// Read-only. A true result proves endpoint identity/format and requested default
    /// fields only; it does not prove which microphone the external voice app uses.
    @discardableResult
    func inspect() -> Status {
        guard phone != nil else { status = Status(message: "请先选择一部已配对手机。"); return status }
        if checks < Int.max { checks += 1 }
        do {
            let devices = try hardware.devices()
            let pair = try fixedPair(devices)
            let input = try hardware.defaultDevice(.input)
            let output = try hardware.defaultDevice(.output)
            var next = Status()
            next.available = true
            next.inputDefaultIsPhone = input == pair.input.id
            next.outputDefaultIsPhone = output == pair.output.id
            next.canRouteInput = pair.input.canBeDefaultInput && ((try? hardware.defaultIsSettable(.input)) == true)
            next.canRouteOutput = pair.output.canBeDefaultOutput && ((try? hardware.defaultIsSettable(.output)) == true)
            let defaultsMatch = (!requested.contains(.input) || next.inputDefaultIsPhone) &&
                (!requested.contains(.output) || next.outputDefaultIsPhone)
            next.ready = !failureLatched && !monitorSuspended && (!active || defaultsMatch)
            next.message = next.ready ? "电话输入与输出端点可用；内置语音的设备选择仍需确认。" :
                "电话音频路由已失效或暂停，请停止内置语音后显式恢复音频。"
            status = next
        } catch {
            status = Status(message: "电话输入与输出端点不可用，请停止内置语音并检查蓝牙连接。")
        }
        return status
    }

    /// The only entry point that may switch defaults. Selection of input in the
    /// external app usually makes changeInput unnecessary.
    func activate(changeInput: Bool = false, changeOutput: Bool = true) throws {
        guard phone != nil else { throw BuiltinVoiceRouteError(message: "请先选择一部已配对手机，再准备音频。") }
        let directions = Set([changeInput ? BuiltinVoiceRouteDirection.input : nil,
                              changeOutput ? BuiltinVoiceRouteDirection.output : nil].compactMap { $0 })
        if active {
            guard directions == requested, inspect().ready else {
                throw BuiltinVoiceRouteError(message: "上一轮音频路由仍待恢复，请先停止内置语音并显式恢复音频。")
            }
            return
        }
        failureCode = ""; failureLatched = false; monitorSuspended = false; restoreResults = [:]
        let devices = try hardware.devices()
        let pair = try fixedPair(devices)
        var original: [BuiltinVoiceRouteDirection: BuiltinVoiceRouteDevice] = [:]
        // Validate both fields before making the first write.
        for direction in BuiltinVoiceRouteDirection.allCases where directions.contains(direction) {
            let target = direction == .input ? pair.input : pair.output
            let canSelect = direction == .input ? target.canBeDefaultInput : target.canBeDefaultOutput
            guard canSelect, try hardware.defaultIsSettable(direction) else {
                throw BuiltinVoiceRouteError(message: "系统不允许将电话端点设为所选默认音频设备。")
            }
            let id = try hardware.defaultDevice(direction)
            guard let previous = uniqueDevice(id: id, devices: devices), previous.alive, !previous.uid.isEmpty else {
                throw BuiltinVoiceRouteError(message: "无法可靠保存原音频设备，因此没有改变路由。")
            }
            original[direction] = previous
        }
        requested = directions; active = true
        do {
            for direction in BuiltinVoiceRouteDirection.allCases where directions.contains(direction) {
                let target = direction == .input ? pair.input : pair.output
                guard let previous = original[direction], try hardware.defaultDevice(direction) == previous.id else {
                    throw BuiltinVoiceRouteError(message: "准备时默认设备已被其他操作改变，停止切换。")
                }
                if previous.uid == target.uid { continue } // No change, no restoration ownership.
                // Record before the call: an error may still follow a partially applied write.
                changes[direction] = Change(previousUID: previous.uid, installedUID: target.uid)
                try hardware.setDefaultDevice(target.id, direction: direction)
                guard try hardware.defaultDevice(direction) == target.id else {
                    throw BuiltinVoiceRouteError(message: "音频路由写入后没有得到确认。")
                }
            }
            guard inspect().ready else { throw BuiltinVoiceRouteError(message: "电话音频端点在准备期间发生变化。") }
            startMonitoring()
        } catch {
            // CoreAudio has no atomic two-property transaction. Conditional rollback
            // never overwrites a later user choice, and failed restores remain owned.
            failureCode = "activation_failed"; failureLatched = true
            restoreOwnedChanges()
            if changes.isEmpty { active = false; requested.removeAll(); failureLatched = false }
            _ = inspect()
            throw error
        }
    }

    /// Explicit restoration only. restore:false retains ownership and marks the
    /// session unready; it cannot accidentally route an ongoing voice to speakers.
    func stop(restore: Bool = true) {
        monitorTask?.cancel(); monitorTask = nil
        if !restore {
            monitorSuspended = true
            _ = inspect()
            return
        }
        restoreOwnedChanges()
        if changes.isEmpty {
            active = false; requested.removeAll(); failureLatched = false; monitorSuspended = false
        } else {
            failureLatched = true; failureCode = "restore_incomplete"
        }
        _ = inspect()
    }

    /// Exposed internally for deterministic fake-hardware tests; no route writes.
    func checkForChanges() {
        guard active, !failureLatched, !monitorSuspended else { return }
        guard inspect().ready else {
            failureLatched = true
            failureCode = status.available ? "default_changed" : "endpoint_unavailable"
            monitorTask?.cancel(); monitorTask = nil
            onFailure?(status.message)
            return
        }
    }

    private func startMonitoring() {
        guard automaticallyMonitor else { return }
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard let self, !Task.isCancelled, self.active else { return }
                self.checkForChanges()
                if self.failureLatched { return }
            }
        }
    }

    private func fixedPair(_ devices: [BuiltinVoiceRouteDevice]) throws ->
        (input: BuiltinVoiceRouteDevice, output: BuiltinVoiceRouteDevice) {
        guard let phone else { throw BuiltinVoiceRouteError(message: "尚未选择手机。") }
        let inputs = devices.filter { $0.uid == phone.inputUID }
        let outputs = devices.filter { $0.uid == phone.outputUID }
        guard inputs.count == 1, outputs.count == 1,
              let input = inputs.first, let output = outputs.first, input.id != output.id,
              [input, output].allSatisfy({ $0.id != kAudioObjectUnknown && $0.name == phone.name &&
                  $0.alive && $0.bluetooth && $0.phoneFormat }),
              input.inputChannels == 1, input.outputChannels == 0,
              output.inputChannels == 0, output.outputChannels == 1 else {
            throw BuiltinVoiceRouteError(message: "未找到唯一且匹配的电话蓝牙输入/输出端点。")
        }
        return (input, output)
    }

    private func uniqueDevice(id: AudioDeviceID, devices: [BuiltinVoiceRouteDevice]) -> BuiltinVoiceRouteDevice? {
        let matches = devices.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }

    private func restoreOwnedChanges() {
        for direction in BuiltinVoiceRouteDirection.allCases.reversed() {
            guard let change = changes[direction] else { continue }
            do {
                let devices = try hardware.devices()
                let currentID = try hardware.defaultDevice(direction)
                guard let current = uniqueDevice(id: currentID, devices: devices) else {
                    restoreResults[direction.rawValue] = "current_identity_unknown"; continue
                }
                guard current.uid == change.installedUID else {
                    restoreResults[direction.rawValue] = "external_choice_preserved"
                    changes.removeValue(forKey: direction); continue
                }
                let prior = devices.filter { $0.uid == change.previousUID }
                guard prior.count == 1, let previous = prior.first, previous.alive,
                      direction == .input ? previous.canBeDefaultInput : previous.canBeDefaultOutput else {
                    restoreResults[direction.rawValue] = "previous_device_unavailable"; continue
                }
                // Recheck immediately before writing; CoreAudio offers no compare-and-swap.
                guard try hardware.defaultDevice(direction) == currentID else {
                    restoreResults[direction.rawValue] = "changed_during_restore"; continue
                }
                try hardware.setDefaultDevice(previous.id, direction: direction)
                guard try hardware.defaultDevice(direction) == previous.id else {
                    restoreResults[direction.rawValue] = "restore_not_confirmed"; continue
                }
                restoreResults[direction.rawValue] = "restored"
                changes.removeValue(forKey: direction)
            } catch { restoreResults[direction.rawValue] = "restore_failed" }
        }
    }
}

/// Ordinary public HAL property access only. No audio IO, process tap, permission
/// request, sample-rate setter, HogMode setter or system-alert-output setter.
@MainActor
private final class BuiltinVoiceHALHardware: BuiltinVoiceRouteHardware {
    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func selector(_ direction: BuiltinVoiceRouteDirection) -> AudioObjectPropertySelector {
        direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }
    private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) throws {
        var property = address(selector, scope), size = UInt32(MemoryLayout<T>.size)
        let code = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        guard code == noErr, size == MemoryLayout<T>.size else {
            throw BuiltinVoiceRouteError(message: "读取音频属性失败（\(code)）。")
        }
    }
    private func scalar(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var value: UInt32 = 0
        return (try? read(id, selector, scope, into: &value)) == nil ? nil : value
    }
    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var value: UnsafeRawPointer?
        guard (try? read(id, selector, into: &value)) != nil else { return "" }
        guard let value else { return "" }
        return Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
    }
    private func ids(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope), size: UInt32 = 0
        let measured = AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size)
        guard measured == noErr, size <= 65_536, size % 4 == 0 else {
            throw BuiltinVoiceRouteError(message: "音频设备列表不可用。")
        }
        if size == 0 { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size / 4))
        let code = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!) }
        guard code == noErr, size <= values.count * 4, size % 4 == 0 else {
            throw BuiltinVoiceRouteError(message: "读取音频设备列表失败。")
        }
        return Array(values.prefix(Int(size / 4)))
    }
    private func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= 8, size <= 65_536 else { return -1 }
        let capacity = Int(size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, raw) == noErr,
              size >= 8, size <= capacity else { return -1 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard 8 + Int(list.pointee.mNumberBuffers) * MemoryLayout<AudioBuffer>.stride <= Int(size) else { return -1 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    private func formatMatches(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        guard let streams = try? ids(id, kAudioDevicePropertyStreams, scope), streams.count == 1 else { return false }
        var format = AudioStreamBasicDescription()
        guard (try? read(streams[0], kAudioStreamPropertyVirtualFormat, into: &format)) != nil else { return false }
        let required = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let allowed = required | kAudioFormatFlagIsNonInterleaved
        return format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate == 8000 &&
            format.mChannelsPerFrame == 1 && format.mBitsPerChannel == 32 && format.mBytesPerFrame == 4 &&
            format.mBytesPerPacket == 4 && format.mFramesPerPacket == 1 &&
            format.mFormatFlags & required == required && format.mFormatFlags & ~allowed == 0
    }
    func devices() throws -> [BuiltinVoiceRouteDevice] {
        try ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map { id in
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            let inputs = channels(id, kAudioObjectPropertyScopeInput), outputs = channels(id, kAudioObjectPropertyScopeOutput)
            let splitMono = (inputs == 1 && outputs == 0) || (inputs == 0 && outputs == 1)
            let scope = inputs == 1 && outputs == 0 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
            return BuiltinVoiceRouteDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName),
                alive: scalar(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                bluetooth: scalar(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBluetooth,
                inputChannels: inputs, outputChannels: outputs,
                phoneFormat: splitMono && formatMatches(id, scope),
                canBeDefaultInput: scalar(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput) == 1,
                canBeDefaultOutput: scalar(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput) == 1)
        }
    }
    func defaultDevice(_ direction: BuiltinVoiceRouteDirection) throws -> AudioDeviceID {
        var id: AudioDeviceID = 0
        try read(AudioObjectID(kAudioObjectSystemObject), selector(direction), into: &id)
        guard id != kAudioObjectUnknown else { throw BuiltinVoiceRouteError(message: "默认音频设备尚不可用。") }
        return id
    }
    func defaultIsSettable(_ direction: BuiltinVoiceRouteDirection) throws -> Bool {
        var property = address(selector(direction)), settable = DarwinBoolean(false)
        let code = AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject), &property, &settable)
        guard code == noErr else { throw BuiltinVoiceRouteError(message: "无法查询默认音频设备的可写状态。") }
        return settable.boolValue
    }
    func setDefaultDevice(_ id: AudioDeviceID, direction: BuiltinVoiceRouteDirection) throws {
        var property = address(selector(direction)), value = id
        let code = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
                                              UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        guard code == noErr else { throw BuiltinVoiceRouteError(message: "改变默认音频设备失败（\(code)）。") }
    }
}
