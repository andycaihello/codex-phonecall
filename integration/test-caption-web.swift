import Foundation
import Darwin

@main @MainActor struct CaptionWebChecks {
    static var checks: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw NSError(domain: name, code: 1) }; checks.append(name)
    }
    static func request(_ target: String = "/secret/state", method: String = "GET", headers: String = "Host: 127.0.0.1:53063\r\n", tail: String = "") -> Data {
        Data("\(method) \(target) HTTP/1.1\r\n\(headers)\r\n\(tail)".utf8)
    }
    static func route(_ data: Data) -> CaptionWebServer.Route { CaptionWebServer.route(data, port: 53063, secretPath: "/secret") }
    static func ready(_ server: CaptionWebServer) async throws -> URL {
        for _ in 0..<150 { if let url = server.url { return url }; if !server.error.isEmpty { throw NSError(domain: server.error, code: 1) }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NSError(domain: "stub readiness timeout", code: 1)
    }
    static func main() async throws {
        let incomingProjection = CaptionWebServer.safeSnapshot(["incomingMode":true,"incomingAvailable":true,"manualAnswerQueued":true,"incomingID":"private-ring-token"])
        try check(incomingProjection["incomingMode"] as? Bool == true && incomingProjection["incomingAvailable"] as? Bool == true && incomingProjection["manualAnswerQueued"] as? Bool == true && incomingProjection["incomingID"] == nil,
                  "incoming controls expose readiness but not the private ring token")
        let automatic = CaptionWebServer.safeSnapshot(["managedVoice":["ready":true,"installed":true,"token":"private"],
            "autoAnswer":["enabled":false,"delaySeconds":2,"task":"fixture","session_id":"private"]])
        let managed = automatic["managedVoice"] as! [String:Any], auto = automatic["autoAnswer"] as! [String:Any]
        try check(managed["ready"] as? Bool == true && managed["token"] == nil && auto["session_id"] == nil && auto["enabled"] as? Bool == false,
            "automatic voice state never exposes credentials or call capabilities")
        let voiceHealth = CaptionWebServer.safeSnapshot(["managedVoice": ["health": [
            "inputPCMBytes": 48000, "assistantFinals": 2, "problem": "user_turn_unfinalized", "rawAudio": "secret"]]])
        let projectedHealth = (voiceHealth["managedVoice"] as? [String: Any])?["health"] as? [String: Any] ?? [:]
        try check(projectedHealth["inputPCMBytes"] as? Int64 == 48000 && projectedHealth["problem"] as? String == "user_turn_unfinalized" && projectedHealth["rawAudio"] == nil,
            "voice health exposes bounded counters without audio")
        try check((CaptionWebServer.safeSnapshot(["autoAnswer":["delaySeconds":true]])["autoAnswer"] as? [String:Any])?["delaySeconds"] == nil,
            "boolean cannot masquerade as autoanswer delay")
        try check(route(request()) == .state, "exact GET state accepted")
        try check(route(request("/secret/")) == .page, "exact page accepted")
        try check(route(request(method: "POST")) == .methodNotAllowed, "POST to read-only route rejected")
        try check(route(request(headers: "Host: evil.example\r\n")) == .forbidden, "DNS rebinding Host rejected")
        try check(route(request(headers: "Host: 127.0.0.1:53063\r\nOrigin: https://evil.example\r\n")) == .forbidden, "cross-origin request rejected")
        try check(route(request(headers: "Host: 127.0.0.1:53063\r\nSec-Fetch-Site: cross-site\r\n")) == .forbidden, "cross-site fetch rejected")
        try check(route(request(headers: "Host: 127.0.0.1:53063\r\nOrigin: http://127.0.0.1:53063\r\n")) == .state, "same-origin fetch accepted")
        try check(route(request(headers: "Host: 127.0.0.1:53063\r\nHost: evil.example\r\n")) == .badRequest, "duplicate Host rejected")
        try check(route(request(headers: "Host: 127.0.0.1:53063\r\nTransfer-Encoding: chunked\r\n")) == .badRequest, "transfer encoding rejected")
        try check(route(request(tail: "body")) == .badRequest, "body and pipelining rejected")
        try check(route(request("/secret/state?file=/etc/passwd")) == .notFound, "query and arbitrary file access rejected")
        try check(route(request("/secret/../state")) == .notFound, "traversal rejected")
        try check(route(Data(repeating: 65, count: 8193)) == .badRequest, "oversize request rejected")
        let body = "{\"action\":\"offline-check\"}"
        let commandHeaders = "Host: 127.0.0.1:53063\r\nOrigin: http://127.0.0.1:53063\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
        let full = request("/secret/command", method: "POST", headers: commandHeaders, tail: body)
        try check(route(full) == .command, "exact same-origin bounded JSON POST accepted")
        try check(CaptionWebServer.parse(full, port: 53063, secretPath: "/secret").body == Data(body.utf8), "parser returns only exact body")
        for prefix in 0..<full.count {
            guard route(Data(full.prefix(prefix))) == .incomplete else { throw NSError(domain: "fragment refused before completion", code: prefix) }
        }
        checks.append("every header and body fragmentation boundary waits for completion")
        var trailing = full; trailing.append(0x78)
        try check(route(trailing) == .badRequest, "extra trailing byte never becomes a second command")
        for length in ["0", "01", "+2", "-1", "20481", "99999999999999", "2,2"] {
            let headers = "Host: 127.0.0.1:53063\r\nOrigin: http://127.0.0.1:53063\r\nContent-Type: application/json\r\nContent-Length: \(length)\r\n"
            try check(route(request("/secret/command", method: "POST", headers: headers, tail: "{}")) == .badRequest, "invalid command length rejected \(length)")
        }
        try check(route(request("/secret/command", method: "POST", headers: commandHeaders + "Content-Length: 2\r\n", tail: body)) == .badRequest, "duplicate command Content-Length rejected")
        try check(route(request("/secret/command", method: "POST", headers: commandHeaders + "Transfer-Encoding: chunked\r\n", tail: body)) == .badRequest, "command transfer encoding rejected")
        try check(route(request("/secret/command?x=1", method: "POST", headers: commandHeaders, tail: body)) == .methodNotAllowed, "command query rejected")
        let source: [String: Any] = ["status": "等待语音", "apiKey": "synthetic-secret", "nativeEvents": ["secret"], "pcm": "secret", "connected": true,
            "transcript": [["role": "对方", "text": "<script>synthetic text</script>", "final": true, "token": "secret"]],
            "preflight": ["ok": true, "token": "secret"]]
        let filtered = CaptionWebServer.safeSnapshot(source)
        let encoded = try JSONSerialization.data(withJSONObject: filtered)
        let encodedText = String(data: encoded, encoding: .utf8)!
        try check(!encodedText.contains("secret") && (filtered["connected"] as? Bool) == true, "snapshot only includes selected fields")
        try check((filtered["transcript"] as? [[String: Any]])?.first?["final"] as? Bool == true, "final caption state preserved")
        let logProjection = CaptionWebServer.safeSnapshot(["consoleEvents": ["连接设备 02:00:00:00:00:01", "号码 15500001111 已结束"],
            "nativeEvents": ["never expose native data"]])
        let visibleLog = logProjection["consoleEvents"] as? [String] ?? []
        try check(visibleLog.count == 2 && visibleLog[0].contains("[设备]") && visibleLog[1].contains("[号码]") &&
                  logProjection["nativeEvents"] == nil, "console log projection redacts identifiers and excludes native diagnostics")
        let console: [String: Any] = ["version":"0.4.0", "modeID":"builtin_voice", "number":"123456789", "instructions":"离线任务",
            "maximumSeconds":60, "voice":"marin", "cloudConsent":false, "keyConfigured":true, "pluginSessionActive":true,
            "pluginPhase":"prepared", "builtinVoiceConfirmed":true, "builtinRouteActive":true, "builtinRouteReady":true,
            "microphonePermission":"authorized", "speechPermission":"authorized", "permissionRequestPending":false,
            "busy":false, "diagnosticSummary":"离线摘要", "apiKey":"synthetic-secret", "bluetoothEvents":["synthetic-secret"],
            "phoneConfigured":true, "phoneName":"离线设备", "phoneAddress":"00:11:22:33:44:55", "phoneSelectionPending":false,
            "incomingMode":true, "incomingAvailable":true, "incomingID":"private-ring-token",
            "pairedPhones":[["address":"00:11:22:33:44:55", "name":"离线设备", "privateField":"synthetic-secret"]],
            "transcript":[["id":"local-1", "role":"对方", "text":"离线文字", "final":false]]]
        let consoleState = CaptionWebServer.safeSnapshot(console)
        try check(console.keys.filter { !["apiKey", "bluetoothEvents", "incomingID"].contains($0) }.allSatisfy { consoleState[$0] != nil }
                  && consoleState["backendRunning"] as? Bool == true && consoleState["apiKey"] == nil && consoleState["bluetoothEvents"] == nil && consoleState["incomingID"] == nil,
                  "console contract survives whitelist without keys or native events")
        try check((consoleState["transcript"] as? [[String:Any]])?.first?["id"] as? String == "local-1",
                  "console transcript identity retained for partial replacement")
        try check((consoleState["pairedPhones"] as? [[String:String]])?.first?.count == 2,
                  "paired phone list exposes only address and name")
        try check(CaptionWebServer.safeSnapshot(["maximumSeconds":true])["maximumSeconds"] == nil,
                  "boolean cannot masquerade as console duration")
        try check(CaptionWebServer.safeSnapshot(["maximumSeconds":0])["maximumSeconds"] as? Int == 0 &&
                  CaptionWebServer.safeSnapshot(["maximumSeconds":1800])["maximumSeconds"] as? Int == 1800,
                  "unlimited and explicit longer duration survive web projection")
        let validation = CaptionWebServer.safeSnapshot(["audioValidationStartedAt": 12.5,
            "audioValidationStoppedAt": 0, "audioValidationVoiceConfirmedAt": 14,
            "audioValidationDurationSeconds": 180, "audioValidationStopReason": "duration_limit"])
        try check(validation["audioValidationDurationSeconds"] as? Int == 180 &&
                  validation["audioValidationStartedAt"] as? Double == 12.5 &&
                  validation["audioValidationVoiceConfirmedAt"] as? Double == 14,
                  "validation timing survives privacy projection")
        try check(CaptionWebServer.safeSnapshot(["audioValidationStartedAt": Double.infinity,
            "audioValidationDurationSeconds": true])["audioValidationStartedAt"] == nil &&
            CaptionWebServer.safeSnapshot(["audioValidationDurationSeconds": true])["audioValidationDurationSeconds"] == nil,
                  "invalid validation clock and boolean duration rejected")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caption-web-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("Console.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources/Web")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let bundleInfo: [String: Any] = ["CFBundleIdentifier": "local.phonebridge.offline.console", "CFBundlePackageType": "BNDL"]
        let infoData = try PropertyListSerialization.data(fromPropertyList: bundleInfo, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try Data("<!doctype html><title>Offline console fixture</title><p>等待语音</p>".utf8).write(to: resources.appendingPathComponent("console.html"))
        guard let bundle = Bundle(url: bundleURL) else { throw NSError(domain: "test bundle unavailable", code: 1) }
        var commands = 0
        let server = CaptionWebServer(directory: directory, port: 0, snapshot: { source }, command: { object in
            commands += 1
            if object["action"] as? String == "fail" { throw NSError(domain: "synthetic-private-error-token", code: 1) }
            return ["ok": true, "received": object["action"] as? String ?? ""]
        }, resourceBundle: bundle)
        defer { server.stop() }
        server.start(); let address = try await ready(server)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (page, response) = try await session.data(from: address)
        let http = response as! HTTPURLResponse
        let html = String(data: page, encoding: .utf8)!
        try check(http.statusCode == 200 && html.contains("Offline console fixture"), "offline GET serves bundled Web console resource")
        try check(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == nil && http.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true, "no CORS and restrictive CSP")
        let (state, stateResponse) = try await session.data(from: address.appendingPathComponent("state"))
        try check((stateResponse as! HTTPURLResponse).statusCode == 200 && !String(data: state, encoding: .utf8)!.contains("secret"), "offline HTTP state remains privacy filtered")
        func post(_ body: Data, origin: String?) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: address.appendingPathComponent("command"))
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let origin = "http://127.0.0.1:\(address.port!)"
        let commandData = try JSONSerialization.data(withJSONObject: ["action": "offline-check", "padding": String(repeating: "x", count: 19000)])
        let (reply, commandResponse) = try await post(commandData, origin: origin)
        try check(commandResponse.statusCode == 200 && commands == 1 && String(data: reply, encoding: .utf8)!.contains("offline-check"),
                  "fragmented nineteen-kilobyte JSON command executes exactly once")
        let (_, denied) = try await post(Data("{}".utf8), origin: nil)
        try check(denied.statusCode == 403 && commands == 1, "HTTP POST without Origin never invokes command")
        let (_, evil) = try await post(Data("{}".utf8), origin: "https://evil.example")
        try check(evil.statusCode == 403 && commands == 1, "HTTP POST foreign Origin never invokes command")
        let (_, invalidJSON) = try await post(Data("[1,2]".utf8), origin: origin)
        try check(invalidJSON.statusCode == 400 && commands == 1, "non-object JSON rejected before command")
        let (errorBody, failed) = try await post(Data("{\"action\":\"fail\"}".utf8), origin: origin)
        let errorText = String(data: errorBody, encoding: .utf8)!
        try check(failed.statusCode == 400 && commands == 2 && !errorText.contains("synthetic-private") && errorText.contains("操作未能完成"),
                  "command exception response never contains raw error or request")
        let runtime = directory.appendingPathComponent("caption-web.json")
        var info = stat(); try check(lstat(runtime.path, &info) == 0 && (info.st_mode & 0o777) == 0o600, "runtime stored with mode 0600")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
        let firstPath = saved["path"] as? String
        server.stop(); try check(server.url == nil && FileManager.default.fileExists(atPath: runtime.path), "stop clears live address and preserves bookmark path")
        server.start(); _ = try await ready(server)
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime)) as! [String: Any]
        try check(firstPath == second["path"] as? String, "restart preserves independent random path")
        server.stop()
        let report: [String: Any] = ["passed": true, "count": checks.count, "checks": checks, "externalNetworkRequests": 0, "deviceOperations": 0, "audioOperations": 0, "localHTTPStubOnly": true]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print(String(data: data, encoding: .utf8)!)
    }
}
