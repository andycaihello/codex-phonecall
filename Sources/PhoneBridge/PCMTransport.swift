import AppKit
import Foundation
import Security
import BridgeCore
import Darwin

@MainActor
final class PCMTransport {
    var onEvent: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var phone: PhonePeerConfiguration?
    func configure(phone: PhonePeerConfiguration) throws {
        guard !running, cleanupVerified, startup == nil else { throw BridgeError("音频程序仍在运行或清理，请结束后再更换手机。") }
        self.phone = phone
    }
    func clearPhoneConfiguration() throws {
        guard !running, cleanupVerified, startup == nil else { throw BridgeError("音频程序仍在运行或清理，无法取消选择手机。") }
        phone = nil
    }
    nonisolated static func phoneArguments(_ phone: PhonePeerConfiguration) -> [String] {
        ["--phone-address", phone.address, "--phone-name", phone.name]
    }
    private var listener: Int32 = -1
    private var client: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var input = Data()
    private var output = Data()
    private var directory: URL?
    private var token = ""
    private var app: NSRunningApplication?
    private var pendingLaunches = 0
    private var retiringApps: [NSRunningApplication] = []
    private var peerPID: Int?
    private var kernelPeerPID: Int?
    private var helloVerified = false
    private var epoch = UUID()
    private(set) var authenticated = false
    private(set) var running = false
    private(set) var generation = 0
    private var clearing = false
    private var deferred: [[String: Any]] = []
    private var deferredBytes = 0
    private var lastPosition: RealtimePlaybackPosition?
    private struct OutputPart: Hashable { let responseID: String, itemID: String; let contentIndex: Int }
    private var responseItems: [String: [OutputPart]] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var clearTimeout: Task<Void, Never>?
    // Counts only: never retain PCM, tokens, paths or transcripts in snapshots.
    private var diagnosticCounts: [String: Int] = [:]
    private var diagnosticPlayback: [String: Int] = [:]
    private var diagnosticReportURL: URL?
    private var diagnosticNative: [String: Any] = [:]
    private var diagnosticLaunch: [String: Any] = [:]
    var diagnosticSnapshot: [String: Any] {
        readDiagnosticNativeReport()
        return ["schema": 1, "phoneConfigured": phone != nil, "counts": diagnosticCounts, "authenticated": authenticated,
                "ioReady": running, "generation": generation, "pendingLaunches": pendingLaunches,
                "processAndSocketCleanupVerified": cleanupVerified,
                "nativeReport": diagnosticNative, "launch": diagnosticLaunch,
                "scope": "IPC counts and HAL submissions; remote hearing is not confirmed"]
    }
    private func countDiagnostic(_ key: String, _ amount: Int = 1) {
        guard amount >= 0 else { return }
        let old = diagnosticCounts[key, default: 0]
        diagnosticCounts[key] = old > Int.max - amount ? Int.max : old + amount
    }
    private func pcmByteCount(_ value: [String: Any]) -> Int {
        guard let encoded = value["audio"] as? String, encoded.utf8.count <= 100_000,
              encoded.utf8.count % 4 == 0 else { return 0 }
        return encoded.utf8.count / 4 * 3 - (encoded.hasSuffix("==") ? 2 : encoded.hasSuffix("=") ? 1 : 0)
    }
    private func recordDiagnosticEvent(_ value: [String: Any]) {
        switch value["type"] as? String {
        case "ready": countDiagnostic("readyEvents")
        case "input_audio":
            countDiagnostic("inputChunksReceived"); countDiagnostic("inputPCMBytesReceived", pcmByteCount(value))
        case "clear_ack": countDiagnostic("clearAcknowledgements")
        case "output_rejected": countDiagnostic("outputRejectedEvents")
        case "playback":
            countDiagnostic("playbackEvents")
            guard let generation = value["generation"] as? Int, let response = value["response_id"] as? String,
                  let item = value["item_id"] as? String, let index = value["content_index"] as? Int,
                  let frames = value["device_frames_submitted"] as? Int, frames >= 0, frames <= 2_500_000,
                  response.utf8.count <= 128, item.utf8.count <= 128 else { return }
            let key = "\(generation)|\(response)|\(item)|\(index)"
            guard diagnosticPlayback[key] != nil || diagnosticPlayback.count < 512 else {
                countDiagnostic("playbackCountersOmittedAtBound"); return
            }
            let prior = diagnosticPlayback[key, default: 0]
            if frames > prior {
                countDiagnostic("outputHALFramesSubmitted8000", frames - prior); diagnosticPlayback[key] = frames
            }
        case "stopped": countDiagnostic("stoppedEvents")
        default: break
        }
    }
    private func readDiagnosticNativeReport() {
        guard diagnosticNative.isEmpty, let url = diagnosticReportURL else { return }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 65_536 else { return }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let read = Darwin.read(fd, &bytes, bytes.count)
        guard read == bytes.count, let report = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              report["bundleIdentifier"] as? String == "local.phonebridge.PCMBridge" else { return }
        var safe: [String: Any] = ["observed": true]
        for key in ["stage", "authorizationBefore", "fullDuplexStarted", "ioStarted", "success", "interrupted",
                    "cleanupVerified", "identityStable", "elapsedIOSeconds", "inputFrames8000",
                    "inputFramesQueuedToIPC8000", "inputNonfiniteSanitized", "inputCallbacks", "outputCallbacks",
                    "realtimeFault", "generation", "outputItems", "stopReason"] {
            if let value = report[key], value is String || value is NSNumber { safe[key] = value }
        }
        for role in ["input", "output"] {
            if let endpoint = report[role] as? [String: Any] {
                var codes: [String: Any] = [:]
                for key in ["createStatus", "startStatus", "stopStatus", "destroyStatus"] {
                    if let value = endpoint[key], value is NSNumber || value is NSNull { codes[key] = value }
                }
                safe[role] = codes
            }
        }
        diagnosticNative = safe
    }
    var cleanupVerified: Bool {
        app == nil && pendingLaunches == 0 && retiringApps.allSatisfy(\.isTerminated) && listener < 0 && client < 0
    }

    func prepare(helperURL: URL) async throws {
        try Task.checkCancellation()
        guard let phone else { throw BridgeError("请先选择一部已配对手机，再启动音频程序。") }
        guard cleanupVerified else { throw BridgeError("上一轮音频程序仍在准备或清理。") }
        diagnosticCounts = [:]; diagnosticPlayback = [:]; diagnosticNative = [:]; diagnosticLaunch = [:]; diagnosticReportURL = nil
        countDiagnostic("prepareAttempts")
        retiringApps.removeAll()
        let run = UUID(); epoch = run
        let proposedDirectory = URL(fileURLWithPath: "/private/tmp/pbpcm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: proposedDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // NSString standardization may rewrite an existing /private/tmp path to
        // /tmp while leaving a not-yet-created report path unchanged. Normalize
        // the existing parent once before deriving *all* native argument paths.
        let dir = URL(fileURLWithPath: (proposedDirectory.path as NSString).standardizingPath, isDirectory: true)
        directory = dir
        diagnosticReportURL = dir.appendingPathComponent("report.json")
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            stop(); throw BridgeError("无法生成音频会话令牌。")
        }
        token = random.map { String(format: "%02x", $0) }.joined()
        let tokenURL = dir.appendingPathComponent("token")
        guard FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            stop(); throw BridgeError("无法准备私人音频会话。")
        }
        let socketPath = dir.appendingPathComponent("s").path
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { stop(); throw BridgeError("无法创建本机音频连接。") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { stop(); throw BridgeError("音频路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(listener, 1) == 0 else {
            stop(); throw BridgeError("本机音频连接初始化失败。")
        }
        _ = fcntl(listener, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        source.setEventHandler { [weak self] in guard self?.epoch == run else { return }; self?.acceptClient() }; listenerSource = source; source.resume()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = ["--bridge"] + Self.phoneArguments(phone) + ["--socket", socketPath, "--token-file", tokenURL.path,
                                   "--max-seconds", "300", "--report", dir.appendingPathComponent("report.json").path]
        // URL equality includes directory/base representation. Match resolved
        // filesystem paths, as in the verified public permission launcher.
        let expectedBundlePath = helperURL.resolvingSymlinksInPath().standardizedFileURL.path
        let expectedExecutablePath = helperURL.appendingPathComponent("Contents/MacOS/phonebridge-pcm")
            .resolvingSymlinksInPath().standardizedFileURL.path
        diagnosticLaunch = ["requested": false, "completionReceived": false,
                            "createsNewInstance": true, "allowsSubstitution": false,
                            "addsToRecentItems": false, "promptsUserIfNeeded": false]
        try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !Task.isCancelled else { stop(); continuation.resume(throwing: CancellationError()); return }
            startup = continuation
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self, self.epoch == run, self.startup != nil else { return }
                self.fail("音频程序未能及时就绪，请检查系统麦克风授权。")
            }
            pendingLaunches += 1
            diagnosticLaunch["requested"] = true
            NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { [weak self] opened, error in
                Task { @MainActor in
                    let bundleIDMatches = opened?.bundleIdentifier == "local.phonebridge.PCMBridge"
                    let bundlePathMatches = opened?.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == expectedBundlePath
                    let executablePathMatches = opened?.executableURL?.resolvingSymlinksInPath().standardizedFileURL.path == expectedExecutablePath
                    let previousURLComparisonMatches = opened?.bundleURL?.standardizedFileURL == helperURL.standardizedFileURL
                    let identityMatches = bundleIDMatches && bundlePathMatches && executablePathMatches && (opened?.processIdentifier ?? 0) > 1
                    guard let self else {
                        if identityMatches, let opened { Self.terminateOwned(opened) }
                        return
                    }
                    self.pendingLaunches -= 1
                    guard self.epoch == run else {
                        if identityMatches, let opened { self.retire(opened) }
                        return
                    }
                    self.diagnosticLaunch["completionReceived"] = true
                    self.diagnosticLaunch["returnedApplication"] = opened != nil
                    self.diagnosticLaunch["returnedPID"] = opened.map { Int($0.processIdentifier) } ?? -1
                    self.diagnosticLaunch["returnedTerminated"] = opened.map(\.isTerminated) ?? true
                    self.diagnosticLaunch["bundleIdentifierMatches"] = bundleIDMatches
                    self.diagnosticLaunch["canonicalBundlePathMatches"] = bundlePathMatches
                    self.diagnosticLaunch["canonicalExecutablePathMatches"] = executablePathMatches
                    self.diagnosticLaunch["previousURLObjectComparisonMatches"] = previousURLComparisonMatches
                    self.diagnosticLaunch["identityMatches"] = identityMatches
                    if let failure = error as NSError? {
                        self.diagnosticLaunch["errorDomain"] = String(failure.domain.prefix(256))
                        self.diagnosticLaunch["errorCode"] = failure.code
                        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                            self.diagnosticLaunch["underlyingErrorDomain"] = String(underlying.domain.prefix(256))
                            self.diagnosticLaunch["underlyingErrorCode"] = underlying.code
                        }
                    }
                    guard error == nil, let opened, identityMatches, !opened.isTerminated else {
                        if identityMatches, let opened { self.retire(opened) }
                        self.fail("音频程序启动失败。"); return
                    }
                    self.app = opened
                    // The peer token proves the connection; LS separately proves
                    // ownership of the exact executable that must be terminated.
                    self.completeStartupIfReady()
                }
            }
          }
        }, onCancel: { [weak self] in Task { @MainActor in
            guard let self, self.epoch == run else { return }; self.stop()
        } })
    }
    private func acceptClient() {
        guard listener >= 0 else { return }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid: uid_t = 0; var gid: gid_t = 0
        var pid: pid_t = 0; var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard client < 0, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0,
              pidSize == MemoryLayout<pid_t>.size, pid > 1, pid != getpid() else { Darwin.close(fd); return }
        kernelPeerPID = Int(pid)
        client = fd; _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        let run = epoch
        source.setEventHandler { [weak self] in guard self?.epoch == run else { return }; self?.receive() }; readSource = source; source.resume()
    }
    private func receive() {
        guard client >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        while client >= 0 {
            let count = Darwin.recv(client, &bytes, bytes.count, 0)
            if count == 0 { fail("本机音频连接已结束。"); return }
            if count < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { fail("本机音频读取失败。") }; return }
            input.append(contentsOf: bytes.prefix(count))
            guard input.count <= 262144 else { fail("本机音频消息过大。"); return }
            while let newline = input.firstIndex(of: 10) {
                let line = input.prefix(upTo: newline); input.removeSubrange(...newline)
                guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { fail("音频消息格式错误。"); return }
                handle(value)
                if client < 0 { return }
            }
        }
    }
    private func handle(_ value: [String: Any]) {
        let type = value["type"] as? String ?? ""
        if !helloVerified {
            guard type == "hello", value["protocol"] as? Int == 1, value["token"] as? String == token,
                  let pid = value["pid"] as? Int, pid == kernelPeerPID else { fail("音频连接身份核验失败。"); return }
            peerPID = pid; helloVerified = true; completeStartupIfReady(); return
        }
        guard authenticated else { fail("音频程序尚未完成启动身份核验。"); return }
        recordDiagnosticEvent(value)
        if type == "ready" { running = true }
        if type == "clear_ack", value["generation"] as? Int == generation {
            clearing = false
            clearTimeout?.cancel(); clearTimeout = nil
            let pending = deferred; deferred.removeAll(); deferredBytes = 0
            for item in pending { guard authenticated else { return }; send(item) }
        }
        if type == "playback", value["generation"] as? Int == generation,
           let item = value["item_id"] as? String, let ms = value["audio_end_ms"] as? Int {
            lastPosition = RealtimePlaybackPosition(itemID: item, contentIndex: value["content_index"] as? Int ?? 0,
                                                    playedMilliseconds: max(0, ms))
        }
        if type == "error" { fail("蓝牙音频引擎已停止：" + (value["message"] as? String ?? "音频状态异常")); return }
        onEvent?(value)
    }
    private func completeStartupIfReady() {
        guard helloVerified, let app else { return }
        guard !app.isTerminated, peerPID == Int(app.processIdentifier), peerPID == kernelPeerPID else { fail("音频程序与连接身份不一致。"); return }
        authenticated = true
        startupTimeout?.cancel(); startupTimeout = nil
        let continuation = startup; startup = nil; continuation?.resume()
    }
    func start() { guard authenticated else { return }; send(["op": "start"]) }
    func play(_ chunk: RealtimeAudioChunk) {
        guard authenticated, running else { return }
        let part = OutputPart(responseID: chunk.responseID, itemID: chunk.itemID, contentIndex: chunk.contentIndex)
        if responseItems[chunk.responseID]?.contains(part) != true { responseItems[chunk.responseID, default: []].append(part) }
        if responseItems.count > 20 { fail("本轮语音响应数量超出限制。"); return }
        if responseItems.values.reduce(0, { $0 + $1.count }) > 128 { fail("本轮语音片段数量超出限制。"); return }
        var offset = 0
        while offset < chunk.pcm16.count {
            guard authenticated, running else { return }
            let end = min(chunk.pcm16.count, offset + 24000)
            let data = chunk.pcm16.subdata(in: offset..<end); offset = end
            enqueueOutput(["op": "output_audio", "generation": generation, "response_id": chunk.responseID,
                           "item_id": chunk.itemID, "content_index": chunk.contentIndex, "audio": data.base64EncodedString()])
        }
    }
    func endResponse(_ id: String) {
        guard let parts = responseItems[id] else { return }
        for part in parts {
            guard authenticated else { return }
            endPart(responseID: id, itemID: part.itemID, contentIndex: part.contentIndex)
        }
    }
    func endPart(responseID: String, itemID: String, contentIndex: Int) {
        let part = OutputPart(responseID: responseID, itemID: itemID, contentIndex: contentIndex)
        guard var parts = responseItems[responseID], let index = parts.firstIndex(of: part) else { return }
        parts.remove(at: index)
        if parts.isEmpty { responseItems.removeValue(forKey: responseID) }
        else { responseItems[responseID] = parts }
        guard authenticated, running else { return }
        enqueueOutput(["op": "output_end", "generation": generation, "response_id": responseID,
                       "item_id": itemID, "content_index": contentIndex])
    }
    func interrupt() -> RealtimePlaybackPosition? {
        let position = lastPosition
        guard authenticated, running, client >= 0 else { return position }
        generation += 1; clearing = true; deferred.removeAll(); deferredBytes = 0
        // Keep one last observed position; never accumulate per-item playback history.
        responseItems.removeAll()
        // queued socket messages remain ordered; clear acknowledges that the
        // new epoch reached HAL before new-epoch playback can begin.
        send(["op": "clear_output", "generation": generation])
        guard authenticated else { return position }
        let run = epoch, clearedGeneration = generation
        clearTimeout?.cancel()
        clearTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.epoch == run,
                  self.generation == clearedGeneration, self.clearing else { return }
            self.fail("蓝牙音频未确认停止发声。")
        }
        return position
    }
    private func enqueueOutput(_ value: [String: Any]) {
        if clearing {
            deferredBytes += (value["audio"] as? String)?.utf8.count ?? 100
            guard deferredBytes <= 128000 else { fail("等待停止发声确认超时。"); return }
            deferred.append(value)
        } else { send(value) }
    }
    private func send(_ value: [String: Any]) {
        guard client >= 0, let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        guard output.count + data.count < 1024 * 1024 else { fail("蓝牙播放数据积压。"); return }
        switch value["op"] as? String {
        case "start": countDiagnostic("startCommandsQueued")
        case "output_audio": countDiagnostic("outputChunksQueuedToNative"); countDiagnostic("outputPCMBytesQueuedToNative", pcmByteCount(value))
        case "output_end": countDiagnostic("outputEndsQueued")
        case "clear_output": countDiagnostic("clearCommandsQueued")
        default: break
        }
        output.append(data); output.append(10); flush()
    }
    private func flush() {
        guard client >= 0 else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: client, queue: .main)
                        let run = epoch
                        source.setEventHandler { [weak self] in guard self?.epoch == run else { return }; self?.flush() }; writeSource = source; source.resume()
                    }; return
                }
                fail("蓝牙播放连接已关闭。"); return
            }
            if count == 0 { return }
            countDiagnostic("socketBytesWrittenToNative", count)
            output.removeFirst(count)
        }
        writeSource?.cancel(); writeSource = nil
    }
    private func fail(_ message: String) {
        let callback = onFailure
        let continuation = startup; startup = nil
        stop(); continuation?.resume(throwing: BridgeError(message)); callback?(message)
    }
    func stop() {
        let old = app; app = nil
        if client >= 0 {
            let stop = Data("{\"op\":\"stop\"}\n".utf8)
            _ = stop.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        }
        epoch = UUID(); running = false; authenticated = false; helloVerified = false; peerPID = nil; kernelPeerPID = nil
        startupTimeout?.cancel(); startupTimeout = nil
        clearTimeout?.cancel(); clearTimeout = nil
        let continuation = startup; startup = nil; continuation?.resume(throwing: BridgeError("音频准备已取消。"))
        listenerSource?.cancel(); listenerSource = nil
        readSource?.cancel(); readSource = nil; writeSource?.cancel(); writeSource = nil
        if client >= 0 { Darwin.close(client); client = -1 }
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        input.removeAll(); output.removeAll(); token = ""; generation = 0; clearing = false
        deferred.removeAll(); deferredBytes = 0; lastPosition = nil; responseItems.removeAll()
        if let old { retire(old) }
        // The small private report directory is retained for cleanup evidence.
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("token")) }
        directory = nil
    }
    /// Reports unknown cleanup when LS has not returned, or the exact owned App
    /// has not exited. A new prepare cannot overlap either condition.
    func waitForStop() async -> Bool {
        for _ in 0..<45 {
            if cleanupVerified { return true }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
        }
        return cleanupVerified
    }
    private func retire(_ app: NSRunningApplication) {
        retiringApps.append(app)
        Self.terminateOwned(app)
    }
    private static func terminateOwned(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !app.isTerminated { app.forceTerminate() }
        }
    }
}
