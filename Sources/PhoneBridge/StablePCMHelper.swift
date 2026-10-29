import CryptoKit
import Foundation
import Darwin
import BridgeCore

/// Keeps the signed audio helper at a stable path. Re-signing the host app for
/// a web UI edit must not replace the binary whose microphone access macOS
/// grants. A helper change still requires a fresh system authorization.
final class StablePCMHelper {
    private var cached: URL?

    func readyURL() throws -> URL {
        if let cached { return cached }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PhoneBridgePCM.app")
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PhoneBridge/AudioHelper", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try verifyOwnedDirectory(root)
        let target = root.appendingPathComponent("PhoneBridgePCM.app", isDirectory: true)
        try verifySigned(bundled)
        let expected = try fingerprint(bundled)
        if FileManager.default.fileExists(atPath: target.path) {
            try verifyOwnedDirectory(target)
            if (try? fingerprint(target)) == expected, (try? verifySigned(target)) != nil {
                cached = target
                return target
            }
        }

        let staging = root.appendingPathComponent(".PhoneBridgePCM-" + UUID().uuidString + ".app", isDirectory: true)
        let backup = root.appendingPathComponent(".PhoneBridgePCM-backup-" + UUID().uuidString + ".app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: bundled, to: staging)
        try verifyOwnedDirectory(staging)
        try verifySigned(staging)
        guard try fingerprint(staging) == expected else { throw BridgeError("音频助手复制校验失败。") }
        let replacing = FileManager.default.fileExists(atPath: target.path)
        if replacing { try FileManager.default.moveItem(at: target, to: backup) }
        do {
            try FileManager.default.moveItem(at: staging, to: target)
            try verifySigned(target)
            if replacing { try? FileManager.default.removeItem(at: backup) }
        } catch {
            try? FileManager.default.removeItem(at: target)
            if replacing { try? FileManager.default.moveItem(at: backup, to: target) }
            throw error
        }
        cached = target
        return target
    }

    private func verifyOwnedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isDirectory == true, values.isSymbolicLink != true,
              attributes[.ownerAccountID] as? UInt32 == getuid() else {
            throw BridgeError("音频助手目录不是当前用户的普通目录。")
        }
    }

    private func fingerprint(_ app: URL) throws -> [String] {
        try ["Contents/MacOS/phonebridge-pcm", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"].map {
            let data = try Data(contentsOf: app.appendingPathComponent($0), options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private func verifySigned(_ app: URL) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        child.arguments = ["--verify", "--deep", "--strict", app.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        guard child.terminationStatus == 0 else { throw BridgeError("音频助手签名校验失败。") }
    }
}
