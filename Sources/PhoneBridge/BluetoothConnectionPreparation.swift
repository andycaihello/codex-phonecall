import Foundation
import CoreFoundation
import Darwin
import BridgeCore

/// Owns only a short-lived, fixed-argument ACL preparation subprocess. The
/// subprocess refreshes the selected paired phone's ACL when necessary and
/// launches no profile, audio, dial, or phone controller operation.
@MainActor
final class BluetoothConnectionPreparation {
    private var child: Process?
    private var pipe: Pipe?
    private var output = Data()
    private var runID = UUID()
    private var terminationTask: Task<Bool, Never>?
    private(set) var lastResult: [String: Any] = [:]
    var cleanupVerified: Bool { child == nil && terminationTask == nil }
    private let timeout: TimeInterval
    init(timeout: TimeInterval = 16) { self.timeout = min(16, max(0.05, timeout.isFinite ? timeout : 16)) }

    func prepare(_ executable: URL, phone: PhonePeerConfiguration) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard cleanupVerified else { throw BridgeError("基础连接准备程序仍在清理。") }
        let process = Process(), stdout = Pipe(), run = UUID()
        process.executableURL = executable
        process.arguments = ["--prepare-paired-phone", "--phone-address", phone.address, "--phone-name", phone.name]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice // Never surface diagnostic stderr.
        let fd = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BridgeError("无法准备基础连接输出通道。") }
        runID = run; child = process; pipe = stdout; output.removeAll(); lastResult = [:]
        do {
            let result = try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try process.run()
                // Only the child retains a write end, so its exit also yields EOF.
                try? stdout.fileHandleForWriting.close()
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while process.isRunning {
                    try Task.checkCancellation()
                    guard runID == run, terminationTask == nil else { throw CancellationError() }
                    try readAvailable(fd)
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw BridgeError("基础蓝牙连接准备超时。") }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                try Task.checkCancellation()
                guard runID == run, terminationTask == nil else { throw CancellationError() }
                try readAvailable(fd)
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    lastResult = Self.failureDiagnostic(output, exitStatus: process.terminationStatus)
                    let stage = lastResult["stage"] as? String ?? "unknown"
                    throw BridgeError("基础蓝牙连接准备未成功退出（\(stage)）。")
                }
                return try Self.validate(output)
            }, onCancel: { [weak self] in
                Task { @MainActor in
                    guard let self, self.runID == run else { return }
                    _ = await self.stopAndWait()
                }
            })
            guard runID == run, terminationTask == nil, !process.isRunning else { throw CancellationError() }
            lastResult = result
            releaseExited(process, run: run)
            return result
        } catch {
            guard runID == run else { throw CancellationError() }
            // This task is intentionally independent of the cancelled operation.
            let stopped = await stopAndWait()
            if !stopped { throw BridgeError("基础连接准备程序退出尚未确认。") }
            if error is CancellationError { throw CancellationError() }
            if let known = error as? BridgeError { throw known }
            throw BridgeError("无法完成基础蓝牙连接准备。")
        }
    }

    private func readAvailable(_ fd: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Bounded work per main-actor turn, including an overproducing child.
        for _ in 0..<5 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                guard output.count + count <= 16 * 1024 else { throw BridgeError("基础连接准备结果过大。") }
                output.append(contentsOf: bytes.prefix(count))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw BridgeError("无法读取基础连接准备结果。") }
        }
    }

    /// Accept only a single JSON object and actual Boolean fields. A new ACL
    /// additionally needs an observed success callback, never submission alone.
    static func validate(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 16 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError("基础连接准备未返回有效结果。")
        }
        func boolean(_ key: String) -> Bool? {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let postResetObserved = boolean("postResetConnectionObserved") == true
        guard boolean("ok") == true, boolean("connectedObserved") == true,
              boolean("connectionPreserved") == true,
              let before = boolean("connectedBefore"), let fresh = boolean("freshACLRequested"),
              boolean("disconnectedObserved") == true,
              let callback = boolean("callbackSeen"), let status = value["status"] as? NSNumber,
              CFGetTypeID(status) != CFBooleanGetTypeID(), status.doubleValue == 0,
              (fresh && callback) || (before && postResetObserved) else {
            throw BridgeError("基础蓝牙连接尚未取得完整成功证据。")
        }
        return ["ok": true, "connectedObserved": true, "connectedBefore": before,
                "freshACLRequested": fresh, "callbackSeen": callback, "status": 0,
                "disconnectedObserved": true, "staleACLReset": before,
                "postResetConnectionObserved": postResetObserved, "connectionPreserved": true]
    }

    private static func failureDiagnostic(_ data: Data, exitStatus: Int32) -> [String: Any] {
        guard data.count <= 16 * 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false, "stage": "invalid-result", "exitStatus": Int(exitStatus)]
        }
        let allowed: Set<String> = ["ok", "stage", "connectedBefore", "connectionCloseRequested",
            "disconnectedObserved", "freshACLRequested", "callbackSeen", "status",
            "connectedObserved", "postResetConnectionObserved", "elapsedSeconds",
            "nativePendingMayRemain", "submitStatus", "callbackStatus", "execErrno"]
        var safe: [String: Any] = ["exitStatus": Int(exitStatus)]
        for key in allowed where value[key] is String || value[key] is NSNumber || value[key] is NSNull {
            safe[key] = value[key]
        }
        return safe
    }

    func stopAndWait() async -> Bool {
        if let terminationTask { return await terminationTask.value }
        guard let process = child else { return true }
        let run = runID
        let task = Task { [weak self] () -> Bool in
            guard let self, self.child === process, self.runID == run else { return false }
            if process.isRunning { process.terminate() }
            for _ in 0..<100 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Exact owned Process only; never discover or signal another PID.
            if self.child === process, self.runID == run, process.isRunning, process.processIdentifier > 1 {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            for _ in 0..<100 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard !process.isRunning else { self.terminationTask = nil; return false }
            self.releaseExited(process, run: run)
            self.terminationTask = nil
            return true
        }
        terminationTask = task
        return await task.value
    }
    private func releaseExited(_ process: Process, run: UUID) {
        guard child === process, runID == run, !process.isRunning else { return }
        try? pipe?.fileHandleForReading.close(); try? pipe?.fileHandleForWriting.close()
        pipe = nil; child = nil; output.removeAll()
    }
}
