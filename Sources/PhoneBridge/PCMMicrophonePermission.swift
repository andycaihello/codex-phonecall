import Foundation
import BridgeCore
import Darwin

/// Permission-only LaunchServices supervisor. It never opens audio devices and
/// checks the permission of the actual PCM helper, not the unrelated host App.
@MainActor final class PCMMicrophonePermission {
    private(set) var status = "unknown"
    private(set) var checking = false

    func check(helperURL: URL, request: Bool) async throws -> String {
        guard !checking else { throw BridgeError("音频助手授权正在检查。") }
        let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/pcm-permission-launcher")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { throw BridgeError("未打包音频权限检查程序。") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pb-audio-permission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let native = folder.appendingPathComponent("native.json"), report = folder.appendingPathComponent("launch.json")
        let child = Process()
        child.executableURL = launcher
        child.arguments = ["--application", helperURL.path, "--report", native.path, "--status", report.path,
                           "--limit", request ? "55" : "12", "--", request ? "--request-microphone-permission" : "--microphone-permission-status"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        checking = true
        defer { checking = false }
        do {
            try child.run()
            let until = ProcessInfo.processInfo.systemUptime + (request ? 67 : 24)
            while child.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < until else { throw BridgeError("音频权限检查超时。") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let value = try Self.read(native), launch = try Self.read(report)
            guard value["bundleIdentifier"] as? String == "local.phonebridge.PCMBridge",
                  value["stage"] as? String == (request ? "permission-only" : "permission-status-only"),
                  value["ioStarted"] as? Bool == false, value["deviceQueries"] as? Bool == false,
                  value["cleanupVerified"] as? Bool == true,
                  launch["nativePermissionResultValid"] as? Bool == true,
                  launch["appTerminated"] as? Bool == true,
                  (!request || (launch["cleanupVerified"] as? Bool == true && launch["ownedAppVerified"] as? Bool == true)),
                  let authorization = value["authorizationAfter"] as? String,
                  ["authorized", "denied", "restricted", "notDetermined"].contains(authorization) else {
                throw BridgeError("未能核实音频助手权限或清理状态，未拨号。")
            }
            status = authorization
            try? FileManager.default.removeItem(at: folder)
            return authorization
        } catch {
            // This supervisor signals only its own identity-checked App. Its
            // reports stay private when cancellation/termination is uncertain.
            if child.isRunning { child.terminate() }
            status = "unknown"
            throw error
        }
    }
    private static func read(_ url: URL) throws -> [String: Any] {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeError("音频授权报告尚未生成。") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size < 32768 else { throw BridgeError("音频授权报告无效。") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(fd, &bytes, bytes.count) == bytes.count,
              let value = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { throw BridgeError("音频授权报告读取失败。") }
        return value
    }
}
