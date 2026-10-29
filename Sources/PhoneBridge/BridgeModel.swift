import Foundation
import SwiftUI
import AVFoundation
import BridgeCore

@MainActor final class BridgeModel: ObservableObject {
    let session = CallSessionCoordinator()
    let bluetooth = BluetoothBridge()
    let audio = AudioBridge()
    @Published var events: [String] = []
    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var inputID: UInt32 = 0
    @Published var outputID: UInt32 = 0
    let audioMode: AudioRouteMode = .bluetooth
    @Published var selectedPhone = ""
    @Published var number = ""
    @Published var text = "您好，我是机主委托的 AI 助手，想咨询一下副卡能否变更到配偶名下。"
    @Published var lastError = ""
    @Published var reportPath = ""
    let directory: URL
    lazy var captionWeb = CaptionWebServer(directory: directory, snapshot: { [weak self] in
        self?.webSnapshot() ?? [:]
    }, command: { [weak self] value in
        guard let self else { throw BridgeError("后台已退出。") }
        return self.webCommand(value)
    })
    lazy var pluginCalls = PluginCallSession(session: session, directory: directory)
    var webPermissionPending = false
    var webDialTask: Task<Void, Never>?
    var webDialGeneration = UUID()
    private var server: LocalServer?
    private var terminationObserver: NSObjectProtocol?
    private var audioPermissionRequest: UUID?

    var eligibleAudioDevices: [AudioDeviceInfo] { audioDevices.filter { $0.bluetooth } }
    var canStartAudio: Bool {
        bluetooth.state.connected && bluetooth.state.scoConnected &&
        (try? AudioBridge.validateDevices(mode: .bluetooth, inputID: inputID, outputID: outputID)) != nil
    }
    var canSendSpeech: Bool {
        audio.running && bluetooth.state.connected && bluetooth.state.scoConnected && bluetooth.state.active
    }
    var callLabel: String { bluetooth.connectionLabel }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneBridge", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { lastError = error.localizedDescription }
        bluetooth.log = { [weak self] in self?.log($0) }
        audio.log = { [weak self] in self?.log($0) }
        session.onLog = { [weak self] in self?.log($0) }
        session.waitForBluetoothReady = { [weak self] in
            guard let self else { throw BridgeError("通话桥已停止。") }
            // A saved peer is revalidated by the native ACL/RFCOMM handshake.
            // Avoid initializing the app process's private IOBluetooth device
            // coordinator solely to enumerate already-known pairings: on this
            // macOS build it can wait indefinitely while the CLI still works.
            if self.session.phone != nil { return }
            if self.bluetooth.radioState == "未初始化" { self.bluetooth.refresh() }
            let until = ProcessInfo.processInfo.systemUptime + 12
            // A saved, paired phone can be verified by the native connection
            // handshake once CoreBluetooth confirms the radio is on. Do not
            // make a slow paired-device list refresh block that path.
            while self.bluetooth.refreshing && self.bluetooth.radioState != "蓝牙已开启" {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard ProcessInfo.processInfo.systemUptime < until else { throw BridgeError("Mac 蓝牙初始化尚未完成，请稍后重试。") }
            }
            guard self.bluetooth.radioState == "蓝牙已开启" else { throw BridgeError("Mac 蓝牙尚未开启或获得授权。") }
        }
        loadConsoleSettings()
        bluetooth.lostAudio = { [weak self] in
            guard let self, self.audioMode == .bluetooth else { return }
            self.stopAudio()
        }
        audio.onStopped = { [weak self] in
            self?.audioPermissionRequest = nil
        }
        let server = LocalServer(directory: directory)
        server.handler = { [weak self] command in
            guard let self else { throw BridgeError("程序已退出") }
            return try self.command(command)
        }
        server.log = { [weak self] in self?.log($0) }
        self.server = server
        run { try server.start() }
        captionWeb.start()
        pluginCalls.captionURL = { [weak self] in self?.captionWeb.url }
        refreshAudio()
        // Initialize the system Bluetooth coordinator before a short-lived
        // connection-preparation helper asks it for controller identity.
        // Enumerate paired devices only when the user opens device selection.
        // The selected phone configuration is loaded above and verified at
        // connection time by the independent native Bluetooth process.
        log("PhoneBridge 0.8.3：后台通话服务与本地 Web 控制台。")
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.audio.stop(); self?.bluetooth.disconnect(); self?.server?.stop(); self?.captionWeb.stop()
                }
            }
    }
    func log(_ message: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        events.append("\(formatter.string(from: Date()))  \(message)")
        if events.count > 250 { events.removeFirst(events.count - 250) }
    }
    func run(_ action: () throws -> Void) {
        do { try action(); lastError = "" }
        catch { lastError = error.localizedDescription; log("操作未完成：\(error.localizedDescription)") }
    }
    func refreshAudio() {
        audioDevices = AudioDeviceInfo.enumerate()
        if !eligibleAudioDevices.contains(where: { $0.id == inputID }) { inputID = 0 }
        if !eligibleAudioDevices.contains(where: { $0.id == outputID }) { outputID = 0 }
    }
    func stopAudio() {
        audioPermissionRequest = nil
        audio.stop()
    }
    func speak(_ text: String) throws {
        guard canSendSpeech else { throw BridgeError("请先启用音频并确认测试电话已接通。") }
        try audio.speak(text)
    }
    func takeover() throws {
        stopAudio()
        try bluetooth.audioToPhone()
    }
    private func validateAudioContext() throws {
        if audioMode == .bluetooth {
            guard bluetooth.state.connected, bluetooth.state.scoConnected else { throw BridgeError("请先连接免提服务并将通话音频转到 Mac。") }
        }
        _ = try AudioBridge.validateDevices(mode: audioMode, inputID: inputID, outputID: outputID)
    }
    func enableAudio() {
        do { try validateAudioContext() }
        catch { lastError = error.localizedDescription; return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let request = UUID()
            audioPermissionRequest = request
            let mode = audioMode, input = inputID, output = outputID
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.audioPermissionRequest == request,
                          self.audioMode == mode, self.inputID == input, self.outputID == output else { return }
                    self.audioPermissionRequest = nil
                    if granted { self.startAudio() }
                    else { self.lastError = "音频输入权限未获允许。" }
                }
            }
        } else { startAudio() }
    }
    private func startAudio() {
        run {
            try validateAudioContext()
            try audio.start(mode: audioMode, inputID: inputID, outputID: outputID)
        }
    }
    func snapshot() -> [String: Any] {
        let state = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(bluetooth.state))) ?? [:]
        let phones = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(bluetooth.devices))) ?? []
        let devices = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(audioDevices))) ?? []
        return ["version": "0.8.3", "integratedSession": session.snapshot(),
            "captionWeb": ["url": captionWeb.url?.absoluteString ?? "", "error": captionWeb.error],
            "call": state, "callLabel": callLabel,
            "audioMode": audioMode.rawValue,
            "phoneCallStateSource": "bluetooth_indicators",
            "canStartAudio": canStartAudio,
            "deviceRefreshPending": bluetooth.refreshing,
            "connecting": bluetooth.connecting,
            "waitingForPhone": bluetooth.waitingForPhone,
            "localHandsFreeService": bluetooth.localServiceDiagnostic,
            "rawHfpProbe": bluetooth.rawProbeDiagnostic,
            "incomingHfp": bluetooth.incomingDiagnostic,
            "handsFreeAudioDriver": bluetooth.audioDriverDiagnostic,
            "selectedPhoneAddress": bluetooth.selectedAddress,
            "bluetoothRadioState": bluetooth.radioState,
            "devices": phones, "audioDevices": devices, "audioRunning": audio.running,
            "receivedFrames": audio.receivedFrames, "inputRate": audio.inputRate,
            "recordingPath": audio.recordingPath, "recording": audio.recording,
            "continuousAI": "openai_realtime_explicit_start", "events": events]
    }
    func record() throws {
        let name = "receive-\(Int(Date().timeIntervalSince1970)).caf"
        try audio.recordTenSeconds(to: directory.appendingPathComponent(name))
    }
    func report() throws -> String {
        let destination = directory.appendingPathComponent("diagnostic-\(Int(Date().timeIntervalSince1970)).json")
        let data = try JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination, options: .atomic)
        reportPath = destination.path
        return destination.path
    }
    func command(_ command: [String: Any]) throws -> [String: Any] {
        guard let action = command["action"] as? String else { throw BridgeError("缺少 action") }
        func string(_ key: String) throws -> String {
            guard let value = command[key] as? String else { throw BridgeError("缺少 \(key)") }; return value
        }
        switch action {
        case "plugin_console":
            guard let url = captionWeb.url else { throw BridgeError("控制台尚未就绪。") }
            return ["consoleURL": url.absoluteString, "backendRunning": true, "version": "0.8.3"]
        case "plugin_status": return pluginCalls.status()
        case "plugin_prepare", "plugin_prepare_incoming":
            guard let duration = command["max_seconds"] as? NSNumber,
                  CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue == Double(duration.intValue) else {
                throw BridgeError("通话时长必须是整数。")
            }
            if action == "plugin_prepare_incoming" {
                return try pluginCalls.prepareIncoming(task: string("task"), maximumSeconds: duration.intValue,
                                                      codexThreadID: command["codex_thread_id"] as? String,
                                                      mode: command["mode"] as? String ?? "builtin_voice")
            }
            return try pluginCalls.prepare(number: string("number"), task: string("task"), mode: string("mode"), maximumSeconds: duration.intValue,
                                           codexThreadID: command["codex_thread_id"] as? String)
        case "plugin_prepare_managed": return try pluginCalls.prepareManaged(id: string("session_id"))
        case "plugin_answer": return try pluginCalls.answer(id: string("session_id"))
        case "plugin_start": return try pluginCalls.start(id: string("session_id"))
        case "plugin_prepare_builtin": return try pluginCalls.prepareBuiltin(id: string("session_id"))
        case "plugin_confirm_builtin": return try pluginCalls.confirmBuiltin(id: string("session_id"))
        case "plugin_restore_audio": return try pluginCalls.restoreAudio(id: string("session_id"))
        case "plugin_end": return try pluginCalls.end(id: string("session_id"))
        case "plugin_steer": return try pluginCalls.steer(id: string("session_id"), instruction: string("instruction"))
        case "plugin_read":
            guard let cursor = command["cursor"] as? NSNumber,
                  CFGetTypeID(cursor) != CFBooleanGetTypeID(), cursor.doubleValue == Double(cursor.intValue) else {
                throw BridgeError("字幕游标必须是整数。")
            }
            return try pluginCalls.read(id: string("session_id"), after: cursor.intValue)
        case "status": refreshAudio(); return snapshot()
        default: throw BridgeError("不支持的指令：\(action)")
        }
    }
}
