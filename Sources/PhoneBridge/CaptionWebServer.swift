import Foundation
import Combine
import Network
import Darwin

/// Local Web console, isolated from LocalServer's command port and credentials.
@MainActor
final class CaptionWebServer: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var error = ""
    private let directory: URL
    private let snapshot: () -> [String: Any]
    private let command: (([String: Any]) throws -> [String: Any])?
    private let resourceBundle: Bundle
    private let preferredPort: UInt16
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var runID: UUID?
    private var secretPath = ""
    private var boundPort: UInt16 = 0

    convenience init(directory: URL, port: UInt16 = 53063, snapshot: @escaping () -> [String: Any]) {
        self.init(directory: directory, port: port, snapshot: snapshot, command: nil)
    }
    init(directory: URL, port: UInt16 = 53063, snapshot: @escaping () -> [String: Any],
         command: (([String: Any]) throws -> [String: Any])?, resourceBundle: Bundle = .main) {
        self.directory = directory; self.preferredPort = port; self.snapshot = snapshot
        self.command = command; self.resourceBundle = resourceBundle
    }

    func start() {
        guard listener == nil else { return }
        error = ""; url = nil
        do {
            secretPath = try loadPath()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: preferredPort)!)
            let next = try NWListener(using: parameters)
            let run = UUID(); runID = run; listener = next
            next.stateUpdateHandler = { [weak self, weak next] state in
                Task { @MainActor in
                    guard let self, self.runID == run else { return }
                    switch state {
                    case .ready:
                        guard let port = next?.port?.rawValue else { self.fail("字幕网页端口不可用。"); return }
                        self.boundPort = port
                        let address = URL(string: "http://127.0.0.1:\(port)\(self.secretPath)/")!
                        do { try self.saveRuntime(address); self.url = address }
                        catch { self.fail("无法保存字幕网页地址。"); }
                    case .failed: self.fail("字幕网页启动失败，端口可能已被占用。请关闭旧字幕服务后重试。")
                    default: break
                    }
                }
            }
            next.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.runID == run, self.url != nil, self.connections.count < 12 else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.start(queue: .main)
                    self.receive(connection, id: id, run: run, accumulated: Data())
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.runID == run else { return }
                        self.connections.removeValue(forKey: id)?.cancel()
                    }
                }
            }
            next.start(queue: .main)
        } catch { fail("无法启动本机字幕网页，请检查应用目录。") }
    }

    func stop() {
        runID = nil; url = nil; boundPort = 0
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        // Keep the private path so a normal App restart retains its bookmark.
    }
    private func fail(_ message: String) { stop(); error = message }

    private func receive(_ connection: NWConnection, id: UUID, run: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] next, _, complete, failure in
            Task { @MainActor in
                guard let self, self.runID == run, self.connections[id] === connection else { connection.cancel(); return }
                var bytes = accumulated; if let next { bytes.append(next) }
                let parsed = Self.parse(bytes, port: self.boundPort, secretPath: self.secretPath)
                if parsed.route == .incomplete && !complete && failure == nil {
                    self.receive(connection, id: id, run: run, accumulated: bytes); return
                }
                switch parsed.route {
                case .page:
                    guard let resource = self.resourceBundle.url(forResource: "console", withExtension: "html", subdirectory: "Web"),
                          let values = try? resource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true, (values.fileSize ?? Int.max) <= 1_048_576,
                          let page = try? Data(contentsOf: resource) else {
                        self.respond(connection, id: id, run: run, status: 503, body: Data("网页资源尚未就绪，请更新通话桥。".utf8)); return
                    }
                    self.respond(connection, id: id, run: run, status: 200, type: "text/html; charset=utf-8", body: page)
                case .state:
                    let state = Self.safeSnapshot(self.snapshot())
                    let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data("{}".utf8)
                    self.respond(connection, id: id, run: run, status: 200, type: "application/json; charset=utf-8", body: data)
                case .command:
                    guard let command = self.command else { self.respond(connection, id: id, run: run, status: 405); return }
                    do {
                        guard let object = try JSONSerialization.jsonObject(with: parsed.body) as? [String: Any] else {
                            throw CocoaError(.propertyListReadCorrupt)
                        }
                        let result = try command(object)
                        guard JSONSerialization.isValidJSONObject(result) else { throw CocoaError(.propertyListWriteInvalid) }
                        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                        guard data.count <= 2_097_152 else { throw CocoaError(.fileWriteOutOfSpace) }
                        self.respond(connection, id: id, run: run, status: 200, type: "application/json; charset=utf-8", body: data)
                    } catch {
                        let data = Data("{\"ok\":false,\"error\":\"操作未能完成，请查看页面状态。\"}".utf8)
                        self.respond(connection, id: id, run: run, status: 400, type: "application/json; charset=utf-8", body: data)
                    }
                case .forbidden: self.respond(connection, id: id, run: run, status: 403)
                case .notFound: self.respond(connection, id: id, run: run, status: 404)
                case .methodNotAllowed: self.respond(connection, id: id, run: run, status: 405)
                default: self.respond(connection, id: id, run: run, status: 400)
                }
            }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, run: UUID, status: Int,
                         type: String = "text/plain; charset=utf-8", body: Data = Data()) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][status]!
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n"
        var data = Data(headers.utf8); data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in
                guard let self, self.runID == run else { return }
                self.connections.removeValue(forKey: id)
            }
        })
    }

    enum Route: Equatable { case incomplete, badRequest, forbidden, notFound, methodNotAllowed, page, state, command }
    struct ParsedRequest { let route: Route; var body = Data() }
    nonisolated static let maximumBodyBytes = 20 * 1024
    /// Exactly one bounded HTTP/1.1 request. Fragmented headers/body wait for
    /// completion; extra bytes are rejected and no second command is dispatched.
    nonisolated static func parse(_ bytes: Data, port: UInt16, secretPath: String) -> ParsedRequest {
        func result(_ route: Route) -> ParsedRequest { ParsedRequest(route: route) }
        guard bytes.count <= 8192 + maximumBodyBytes else { return result(.badRequest) }
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return result(bytes.count > 8192 ? .badRequest : .incomplete)
        }
        guard end.upperBound <= 8192, let text = String(data: bytes[..<end.lowerBound], encoding: .ascii) else { return result(.badRequest) }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { return result(.badRequest) }
        guard request[0] == "GET" || request[0] == "POST" else { return result(.methodNotAllowed) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { return result(.badRequest) }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[key] == nil else { return result(.badRequest) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else { return result(.badRequest) }
            headers[key] = value
        }
        let host = "127.0.0.1:\(port)", origin = "http://127.0.0.1:\(port)"
        guard headers["host"] == host, headers["origin"] == nil || headers["origin"] == origin else { return result(.forbidden) }
        if let site = headers["sec-fetch-site"], site != "same-origin" && site != "none" { return result(.forbidden) }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil, headers["upgrade"] == nil else { return result(.badRequest) }
        if request[0] == "GET" {
            guard headers["content-length"] == nil || headers["content-length"] == "0", end.upperBound == bytes.endIndex else { return result(.badRequest) }
            if request[1] == secretPath + "/" { return result(.page) }
            if request[1] == secretPath + "/state" { return result(.state) }
            return result(.notFound)
        }
        guard request[1] == secretPath + "/command" else { return result(.methodNotAllowed) }
        guard headers["origin"] == origin else { return result(.forbidden) }
        guard headers["content-type"] == "application/json", let length = headers["content-length"],
              length.range(of: "\\A[1-9][0-9]{0,4}\\z", options: .regularExpression) != nil,
              let count = Int(length), count <= maximumBodyBytes else { return result(.badRequest) }
        let actual = bytes.count - end.upperBound
        guard actual <= count else { return result(.badRequest) }
        guard actual == count else { return result(.incomplete) }
        return ParsedRequest(route: .command, body: Data(bytes[end.upperBound...]))
    }
    nonisolated static func route(_ bytes: Data, port: UInt16, secretPath: String) -> Route {
        parse(bytes, port: port, secretPath: secretPath).route
    }

    nonisolated static func safeSnapshot(_ source: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["updatedAt": Date().timeIntervalSince1970, "backendRunning": true]
        func copyText(_ key: String, limit: Int = 512) {
            if let value = source[key] as? String { result[key] = String(value.prefix(limit)) }
        }
        for key in ["status", "error", "captionWarning", "mode", "voiceServiceStatus"] { copyText(key, limit: 1024) }
        for key in ["version", "modeID", "number", "voice", "pluginPhase", "dialerStage", "dialTransport", "microphonePermission", "speechPermission", "phoneName", "phoneAddress", "continuousVoiceTarget"] { copyText(key, limit: 128) }
        copyText("instructions", limit: 12_000)
        copyText("diagnosticSummary", limit: 4096)
        copyText("audioValidationStopReason", limit: 64)
        for key in ["audioValidationStartedAt", "audioValidationStoppedAt", "audioValidationVoiceConfirmedAt"] {
            if let value = source[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
               value.doubleValue.isFinite, value.doubleValue >= 0 { result[key] = value.doubleValue }
        }
        if let value = source["audioValidationDurationSeconds"] as? NSNumber,
           CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue == Double(value.intValue),
           (0...300).contains(value.intValue) { result["audioValidationDurationSeconds"] = value.intValue }
        if let value = source["maximumSeconds"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
           value.doubleValue.isFinite, value.doubleValue == Double(value.intValue), (1...300).contains(value.intValue) {
            result["maximumSeconds"] = value.intValue
        }
        for key in ["bluetoothCallControlReady", "audioValidationPrepared", "audioValidationReady", "validationPromptSent", "connected", "busy", "phoneStateUnknown", "callActive", "callPending", "voiceActive", "voiceServiceChecking",
                    "cloudConsent", "keyConfigured", "pluginSessionActive", "builtinVoiceConfirmed",
                    "builtinRouteActive", "builtinRouteReady", "permissionRequestPending", "phoneConfigured", "phoneSelectionPending",
                    "pairingModeActive", "pairingRoleMatches", "continuousVoiceInstalled", "continuousVoiceActive", "continuousVoiceReady"] {
            if let value = source[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { result[key] = value.boolValue }
        }
        if let phones = source["pairedPhones"] as? [[String: Any]] {
            result["pairedPhones"] = phones.prefix(64).compactMap { phone -> [String: String]? in
                guard let address = phone["address"] as? String, let name = phone["name"] as? String else { return nil }
                return ["address": String(address.prefix(64)), "name": String(name.prefix(128))]
            }
        }
        for key in ["call", "voice", "preflight"] {
            if let value = source[key] as? String { result[key] = String(value.prefix(256)) }
            else if let object = source[key] as? [String: Any] {
                var state: [String: Any] = [:]
                for field in ["active", "pending", "checking", "completed", "ok", "connectionClosed"] {
                    if let value = object[field] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { state[field] = value.boolValue }
                }
                if let status = object["status"] as? String { state["status"] = String(status.prefix(512)) }
                result[key] = state
            }
        }
        let lines = (source["transcript"] as? [[String: Any]] ?? []).suffix(100)
        result["transcript"] = lines.compactMap { line -> [String: Any]? in
            guard let text = line["text"] as? String, let role = line["role"] as? String else { return nil }
            let isFinal = (line["final"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            var result: [String: Any] = ["role": String(role.prefix(40)), "text": String(text.prefix(8192)), "final": isFinal]
            if let id = line["id"] as? String { result["id"] = String(id.prefix(256)) }
            return result
        }
        return result
    }

    private func loadPath() throws -> String {
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
        let runtime = directory.appendingPathComponent("caption-web.json")
        let fd = open(runtime.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), info.st_size <= 4096, fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileReadNoPermission) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &bytes, bytes.count)
            if count >= 0, let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any],
               let path = object["path"] as? String, path.range(of: "\\A/[a-f0-9]{64}\\z", options: .regularExpression) != nil { return path }
            throw CocoaError(.fileReadCorruptFile)
        }
        guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
        return "/" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
    private func saveRuntime(_ address: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["url": address.absoluteString, "path": secretPath,
            "port": boundPort, "pid": ProcessInfo.processInfo.processIdentifier], options: [.sortedKeys])
        let temporary = directory.appendingPathComponent(".caption-web-\(UUID().uuidString).json")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd); unlink(temporary.path) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(fd) == 0,
              rename(temporary.path, directory.appendingPathComponent("caption-web.json").path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

}
