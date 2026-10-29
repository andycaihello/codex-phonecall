import Foundation
import BridgeCore

enum CodexManagedEvent {
    case ready, interrupted, hangupRequested
    case audio(Data)
    case transcript(String, String, String, Bool)
    case healthAlert(String)
    case failed(String)
}

/// A private, bounded JSONL pipe to our WebRTC adapter. This owns an isolated
/// voice session; it never operates the desktop UI or changes default audio.
@MainActor final class CodexManagedVoice {
    var onEvent: ((CodexManagedEvent) -> Void)?
    private(set) var isReady = false
    private(set) var isRunning = false
    private(set) var lastError = ""
    private(set) var lastErrorCode = ""
    private(set) var health: [String: Any] = [:]
    private var process: Process?
    private var retiring: [Process] = []
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var epoch = UUID()
    private var queuedBytes = 0
    private let writes = DispatchQueue(label: "phonebridge.codex.voice.write")
    private let runtime = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PhoneBridge/codex-voice-runtime/bin/python3")
    var installed: Bool { FileManager.default.isExecutableFile(atPath: runtime.path) }
    var cleanupVerified: Bool { process == nil && retiring.allSatisfy { !$0.isRunning } }
    var snapshot: [String: Any] {
        ["installed": installed, "running": isRunning, "ready": isReady,
         "error": lastError, "errorCode": lastErrorCode, "cleanupVerified": cleanupVerified,
         "protocol": "v3", "transport": "webrtc", "context": "owner_supplied_task_only",
         "health": health]
    }

    func prepare(task: String, forIncomingCall: Bool = false) async throws {
        guard !isRunning, cleanupVerified, installed else {
            throw BridgeError("请先安装可选的 Codex 语音运行时，或等待上一轮语音退出。")
        }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("CodexVoice/codex_voice_runtime.py"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw BridgeError("当前程序未打包 Codex 自动语音模块。")
        }
        retiring.removeAll(); buffer.removeAll(); queuedBytes = 0
        lastError = ""; lastErrorCode = ""; health = [:]; epoch = UUID(); let run = epoch
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = runtime; child.arguments = ["-u", script.path]
        child.standardInput = incoming; child.standardOutput = outgoing
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.epoch == run else { return }
                self.fail("Codex 自动语音程序已退出。")
            }
        }
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.epoch == run else { return }
                self.receive(data)
            }
        }
        do { try child.run() }
        catch { output?.readabilityHandler = nil; input = nil; output = nil; throw error }
        process = child; isRunning = true
        send(["op": "start", "task": task, "incoming": forIncomingCall])
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        do {
            while !isReady {
                try Task.checkCancellation()
                guard epoch == run, isRunning else { throw BridgeError(lastError.isEmpty ? "Codex 语音启动已取消。" : lastError) }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeError("Codex 自动语音连接超时，未接听或拨号。") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch { if epoch == run { stop() }; throw error }
    }

    func beginCall() { guard isReady else { return }; send(["op": "begin_call"]) }
    func appendAudio(_ data: Data) {
        guard isReady else { return }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 9600, data.count)
            send(["op": "audio", "data": data.subdata(in: offset..<end).base64EncodedString()]); offset = end
        }
    }
    func steer(_ text: String) { guard isReady else { return }; send(["op": "steer", "text": text]) }
    private func send(_ value: [String: Any]) {
        guard isRunning, let handle = input, var data = try? JSONSerialization.data(withJSONObject: value), data.count < 65_536 else { return }
        data.append(10)
        guard queuedBytes + data.count <= 128 * 1024 else { fail("Codex 音频发送积压，已停止本轮。可以重新准备语音。"); return }
        queuedBytes += data.count
        let bytes = data, run = epoch
        writes.async { [weak self] in
            var failed = false
            do { try handle.write(contentsOf: bytes) } catch { failed = true }
            let writeFailed = failed
            Task { @MainActor in
                guard let self, self.epoch == run else { return }
                self.queuedBytes -= bytes.count
                if writeFailed { self.fail("Codex 语音管道已关闭。") }
            }
        }
    }
    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { fail("Codex 自动语音连接已关闭。"); return }
        buffer.append(bytes)
        guard buffer.count <= 512 * 1024 else { fail("Codex 语音输出积压，已停止。"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]; buffer.removeSubrange(...end)
            guard line.count <= 65_536, let v = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                fail("Codex 语音输出格式错误。"); return
            }
            switch v["type"] as? String {
            case "ready": isReady = true; onEvent?(.ready)
            case "audio":
                guard isReady, let text = v["data"] as? String, text.count <= 32_000,
                      let pcm = Data(base64Encoded: text), !pcm.isEmpty, pcm.count % 2 == 0 else { fail("Codex 语音音频格式错误。"); return }
                onEvent?(.audio(pcm))
            case "transcript":
                guard let role = v["role"] as? String, ["user", "assistant"].contains(role),
                      let id = v["id"] as? String, id.utf8.count <= 128,
                      let text = v["text"] as? String, text.utf8.count <= 64_000,
                      let final = v["final"] as? Bool else { fail("Codex 语音字幕格式错误。"); return }
                onEvent?(.transcript(id, role, text, final))
            case "interrupt": onEvent?(.interrupted)
            case "hangup_requested": onEvent?(.hangupRequested)
            case "health":
                let allowed = ["problem", "inputPCMBytes", "sentAudioFrames", "outputPCMBytes",
                               "userFinals", "assistantFinals", "inputAgeSeconds", "queueBytes", "connectionState"]
                health = v.filter { allowed.contains($0.key) && ($0.value is String || $0.value is NSNumber) }
            case "health_alert":
                if let problem = v["problem"] as? String, problem.utf8.count <= 64 {
                    onEvent?(.healthAlert(problem))
                }
            case "error":
                let code = v["code"] as? String ?? ""
                let message: String
                switch code {
                case "codex_capacity": message = "Codex 语音服务繁忙，请稍后重试。"
                case "input_audio_backlog": message = "电话声音输入积压，已停止本轮语音。"
                case "codex_media_disconnected", "codex_audio_stream_closed", "codex_voice_closed":
                    message = "Codex 实时音频连接中断，已停止本轮语音。"
                case "codex_voice_start_timeout": message = "Codex 实时语音启动超时，未拨号或接听。"
                case "codex_voice_request_timeout": message = "Codex 实时语音响应超时，已停止本轮语音。"
                default: message = "Codex 自动语音不可用，请检查登录、运行时及实验接口兼容性。"
                }
                fail(message, code: code)
            case "stopped": if isRunning { fail("Codex 自动语音已停止。") }
            default: break
            }
        }
    }
    private func fail(_ message: String, code: String = "local_runtime_error") {
        guard isRunning else { return }
        lastError = message
        lastErrorCode = code.range(of: "\\A[a-z_]{1,64}\\z", options: .regularExpression) != nil ? code : "local_runtime_error"
        stop(); onEvent?(.failed(message))
    }
    func stop() {
        epoch = UUID(); isReady = false; isRunning = false
        output?.readabilityHandler = nil
        if let input {
            writes.async { try? input.write(contentsOf: Data("{\"op\":\"stop\"}\n".utf8)); try? input.close() }
        }
        input = nil; output = nil; buffer.removeAll(); queuedBytes = 0
        if let child = process {
            retiring.append(child); child.terminationHandler = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if child.isRunning { child.terminate() }
            }
        }
        process = nil
    }
}
