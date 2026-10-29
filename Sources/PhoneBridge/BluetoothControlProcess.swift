import Foundation
import CoreFoundation
import BridgeCore

@MainActor
final class BluetoothControlProcess {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((Int32) -> Void)?
    private(set) var diagnosticEvents: [[String: Any]] = []
    private(set) var cleanupResult: [String: Any]?
    private(set) var exitStatus: Int32?
    private var launched = false
    private var stdoutEnded = false
    private var outputValid = true
    /// Local ownership only. This deliberately does not claim that the system
    /// Bluetooth stack confirmed every RFCOMM close callback.
    var resourcesReleased: Bool {
        process == nil && incoming == nil && outgoing == nil && errors == nil &&
            pending.isEmpty && timers.isEmpty
    }
    var cleanupVerified: Bool {
        if !launched { return process == nil }
        return process == nil && exitStatus == 0 && stdoutEnded && outputValid &&
            Self.provesCleanup(cleanupResult)
    }
    var cleanupSnapshot: [String: Any] {
        ["verified": cleanupVerified, "resourcesReleased": resourcesReleased, "processExited": launched && process == nil,
         "exitStatus": exitStatus.map { $0 as Any } ?? NSNull(), "stdoutEnded": stdoutEnded,
         "outputValid": outputValid, "nativeResult": cleanupResult.map { $0 as Any } ?? NSNull()]
    }
    private var process: Process?
    private var incoming: Pipe?
    private var outgoing: Pipe?
    private var errors: Pipe?
    private var bytes = Data()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var runID = UUID()
    private var stopping = false
    var isRunning: Bool { process?.isRunning == true }

    func launchIncoming(_ executable: URL, phone: PhonePeerConfiguration) throws {
        try launch(executable, allowedNumber: "", phone: phone, incomingOnly: true)
    }
    func launch(_ executable: URL, allowedNumber: String, phone: PhonePeerConfiguration, incomingOnly: Bool = false) throws {
        guard process == nil else { throw BridgeError("蓝牙控制进程仍在运行或清理。") }
        guard incomingOnly ? allowedNumber.isEmpty : PhoneNumber.valid(allowedNumber) else { throw BridgeError("本次允许拨打的号码格式无效。") }
        let run = UUID(); runID = run
        diagnosticEvents.removeAll(keepingCapacity: true)
        cleanupResult = nil; exitStatus = nil; launched = false; stdoutEnded = false; outputValid = true
        stopping = false
        let child = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        child.executableURL = executable
        child.arguments = ["--run", "--max-seconds", "0", "--phone-address", phone.address, "--phone-name", phone.name] +
            (incomingOnly ? ["--incoming-only"] : ["--allow-number", allowedNumber])
        child.standardInput = input; child.standardOutput = output; child.standardError = error
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.runID == run else { return }
                if !data.isEmpty { self.receive(data) }
                else {
                    self.stdoutEnded = true
                    if !self.bytes.isEmpty { self.outputValid = false }
                    self.outgoing?.fileHandleForReading.readabilityHandler = nil
                    self.finishPending("蓝牙控制输出已关闭。")
                    self.shutdown()
                }
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.runID == run else { return }
                self.exitStatus = ended.terminationStatus
                self.finishPending("蓝牙控制进程已结束。")
                // A process can exit before its final pipe callback reaches the
                // main actor. Do not discard cleanup_finished or infer it from exit0.
                for _ in 0..<100 {
                    if self.stdoutEnded { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    guard self.runID == run else { return }
                }
                self.closePipes(); self.process = nil
                self.onExit?(ended.terminationStatus)
            }
        }
        process = child; incoming = input; outgoing = output; errors = error
        do { try child.run(); launched = true; try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close() }
        catch { closePipes(); process = nil; throw BridgeError("无法启动蓝牙控制程序。") }
    }
    func request(_ op: String, fields: [String: Any] = [:], timeout: TimeInterval = 12) async throws -> [String: Any] {
        guard isRunning, !stopping, let input = incoming?.fileHandleForWriting else { throw BridgeError("蓝牙控制尚未启动或正在清理。") }
        guard timeout.isFinite, (1...60).contains(timeout), pending.count < 32 else { throw BridgeError("蓝牙操作参数或队列无效。") }
        let id = UUID().uuidString
        var value = fields; value["id"] = id; value["op"] = op
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.reject(id, message: "蓝牙操作超时：" + op)
                }
                do { try input.write(contentsOf: data) }
                catch { reject(id, message: "蓝牙控制写入失败。") }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.reject(id, message: "蓝牙操作已取消。") } })
    }
    private func receive(_ data: Data) {
        bytes.append(data)
        guard bytes.count <= 256 * 1024 else { outputValid = false; finishPending("蓝牙控制消息过大。"); shutdown(); return }
        while let newline = bytes.firstIndex(of: 10) {
            let line = Data(bytes.prefix(upTo: newline)); bytes.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { outputValid = false; continue }
            // This channel carries Bluetooth control only; never retain API
            // credentials or PCM payloads even if a future event adds them.
            diagnosticEvents.append(Self.diagnosticValue(value) as! [String: Any])
            if diagnosticEvents.count > 1024 { diagnosticEvents.removeFirst(diagnosticEvents.count - 1024) }
            if value["event"] as? String == "cleanup_finished" { cleanupResult = Self.diagnosticValue(value) as? [String: Any] }
            onEvent?(value)
            if let id = value["id"] as? String, let ok = value["ok"] as? Bool,
               (value["type"] as? String == "result" || value["event"] as? String == "result"),
               let continuation = pending.removeValue(forKey: id) {
                timers.removeValue(forKey: id)?.cancel()
                if ok { continuation.resume(returning: value) }
                else { continuation.resume(throwing: BridgeError("蓝牙操作未完成：" +
                    (value["error"] as? String ?? value["detail"] as? String ?? "状态未确认"))) }
            }
        }
    }
    static func provesCleanup(_ value: [String: Any]?) -> Bool {
        guard let value, value["event"] as? String == "cleanup_finished" else { return false }
        func flag(_ name: String) -> Bool? {
            guard let number = value[name] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        guard flag("ok") == true, flag("cleanupVerified") == true,
              flag("ownedChannelsClosed") == true, flag("ownedCallEndVerified") == true,
              flag("helperStoppedVerified") == true, flag("pendingOpenUnverified") == false,
              let removed = value["localSDPRemoveStatus"] as? NSNumber,
              CFGetTypeID(removed) != CFBooleanGetTypeID(), removed.doubleValue == 0 else { return false }
        return true
    }
    private static func diagnosticValue(_ value: Any) -> Any {
        if let fields = value as? [String: Any] {
            let excluded: Set<String> = ["key", "apikey", "authorization", "token", "secret", "audio", "pcm", "pcm16", "samples"]
            return fields.reduce(into: [String: Any]()) { result, entry in
                let field = entry.key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
                if !excluded.contains(field) { result[entry.key] = diagnosticValue(entry.value) }
            }
        }
        if let values = value as? [Any] { return values.map(diagnosticValue) }
        return value
    }
    private func reject(_ id: String, message: String) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: BridgeError(message))
    }
    private func finishPending(_ message: String) {
        for timer in timers.values { timer.cancel() }; timers.removeAll()
        let values = Array(pending.values); pending.removeAll()
        for continuation in values { continuation.resume(throwing: BridgeError(message)) }
    }
    private func closePipes() {
        outgoing?.fileHandleForReading.readabilityHandler = nil
        errors?.fileHandleForReading.readabilityHandler = nil
        try? incoming?.fileHandleForWriting.close()
        try? outgoing?.fileHandleForReading.close(); try? errors?.fileHandleForReading.close()
        incoming = nil; outgoing = nil; errors = nil; bytes.removeAll()
    }
    func shutdown() {
        guard !stopping else { return }
        stopping = true
        finishPending("蓝牙会话已停止。")
        // EOF allows the native owner to run its bounded owned-call cleanup.
        try? incoming?.fileHandleForWriting.close(); incoming = nil
        guard let child = process else { closePipes(); return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if child.isRunning { child.terminate() }
        }
    }
    func shutdownAndWait() async -> Bool {
        shutdown()
        let run = runID
        for _ in 0..<1600 {
            guard runID == run else { return false }
            if process == nil { return cleanupVerified }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
