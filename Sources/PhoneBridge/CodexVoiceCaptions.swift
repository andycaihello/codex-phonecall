import Foundation
import Darwin
import Dispatch
import BridgeCore

/// Mirrors only the selected Codex conversation's new committed voice text.
/// Never controls Codex voice or reads authentication/configuration files.
@MainActor
final class CodexVoiceCaptions {
    var onTranscript: ((String, String, String) -> Void)?
    var onFailure: ((String) -> Void)?
    private var process: Process?
    private var pipe: Pipe?
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var generation = UUID()
    private var threadID: String?
    private(set) var ready = false
    private var received = 0
    private var lag: Int?
    private var failure = ""
    private let bundledScript: URL?
    init(scriptURL: URL? = nil) {
        bundledScript = scriptURL ?? Bundle.main.url(forResource: "codex_voice_captions", withExtension: "py", subdirectory: "CodexVoice")
    }
    var snapshot: [String: Any] {
        ["configured": threadID != nil, "running": process?.isRunning == true, "ready": ready,
         "receivedSegments": received, "lastRecordLagMilliseconds": lag as Any? ?? NSNull(),
         "error": failure, "source": "codex_transcript", "granularity": "committed_segment",
         "recognitionRepeated": false]
    }

    func prepare(threadID: String) async throws {
        guard let parsed = UUID(uuidString: threadID), parsed.uuidString.lowercased() == threadID else {
            throw BridgeError("Codex 会话标识无效，未读取其他对话。")
        }
        if self.threadID == threadID, ready, process?.isRunning == true { return }
        stop()
        guard let script = bundledScript else {
            throw BridgeError("当前安装包缺少 Codex 语音文字同步程序。")
        }
        self.threadID = threadID; failure = ""; received = 0; lag = nil
        let run = UUID(); generation = run
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [script.path, "tail", "--thread-id", threadID, "--seconds", "0",
                           "--events-only", "--parent-pid", String(getpid())]
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "PYTHONIOENCODING": "utf-8"]
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] { environment["CODEX_HOME"] = home }
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        let readFD = Darwin.dup(output.fileHandleForReading.fileDescriptor)
        guard readFD >= 0 else { throw BridgeError("无法创建字幕读取通道。") }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: DispatchQueue(label: "phonebridge.codex-caption-read"))
        source.setCancelHandler { Darwin.close(readFD) }
        source.setEventHandler { [weak self] in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            let data = count > 0 ? Data(bytes.prefix(count)) : Data()
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                if !data.isEmpty { self.consume(data) }
                else if count == 0 { self.readSource?.cancel() }
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                self.fail("Codex 语音文字同步程序已退出；电话不因此挂断。")
            }
        }
        process = child; pipe = output; readSource = source
        source.resume()
        do { try child.run() }
        catch { stop(); throw BridgeError("无法启动 Codex 语音文字同步程序。") }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        do {
            while generation == run, !ready, failure.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch { stop(); throw error }
        guard generation == run, ready else {
            let message = failure.isEmpty ? "Codex 语音文字同步准备超时。" : failure
            stop(); throw BridgeError(message)
        }
    }

    private func consume(_ data: Data) {
        guard buffer.count + data.count <= 262_144 else { fail("Codex 字幕消息超过上限。") ; return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                fail("Codex 字幕消息格式变化，文字同步已停止。") ; return
            }
            switch object["type"] as? String {
            case "watching":
                guard object["watching"] as? Bool == true, object["source"] as? String == "codex_transcript" else {
                    fail("Codex 字幕来源校验失败。") ; return
                }
                ready = true
            case "voice_transcript":
                guard ready, let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 1024,
                      let role = object["role"] as? String, ["user", "assistant"].contains(role),
                      let text = object["text"] as? String, text.count <= 32768,
                      object["final"] as? Bool == true, object["source"] as? String == "codex_transcript" else {
                    fail("Codex 语音字幕字段不兼容。") ; return
                }
                received += 1; lag = object["lastSourceLagMs"] as? Int
                onTranscript?(id, role, text)
            case "voice_started", "voice_ended": break
            default:
                if object["ok"] as? Bool == false { fail("无法读取当前 Codex 会话的语音文字，未切换到其他会话。") ; return }
                fail("Codex 字幕协议不兼容。") ; return
            }
        }
    }

    private func fail(_ message: String) {
        stop(); failure = message; onFailure?(message)
    }
    func stop() {
        generation = UUID(); ready = false
        readSource?.cancel(); readSource = nil
        try? pipe?.fileHandleForReading.close()
        if let child = process, child.isRunning {
            child.terminate()
            // Only terminate the child this adapter owns, never Codex itself.
        }
        process = nil; pipe = nil; buffer.removeAll(keepingCapacity: false)
    }
}
