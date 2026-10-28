import Foundation
import Combine
import BridgeCore

struct ConversationLine: Identifiable {
    let id: String
    let role: String
    var text: String
    var final: Bool
}
@MainActor final class FakeBuiltinRoute {
    var active = false
    var ready = true
    struct Status { let ready: Bool }
    func inspect() -> Status { Status(ready: ready) }
}
@MainActor final class FakeBuiltinCaptions {
    var diagnosticSnapshot: [String: Any] { ["fake": true] }
}
/// Deliberately contains no real Bluetooth, CoreAudio, Keychain, Speech or API class.
@MainActor final class CallSessionCoordinator {
    var connected = true, connectedForCurrentNumber = true, busy = false
    var bluetoothCallControlReady: Bool { connected && connectedForCurrentNumber }
    var callActive = false, callPending = false, voiceActive = false
    var ownsActiveCall = false
    var mode: ConversationMode = .builtinVoice
    var phone: PhonePeerConfiguration?
    var number = "", instructions = "", status = "fixture", error = ""
    var maximumSeconds = 60
    var builtinVoiceConfirmed = false, pluginSessionActive = false, cloudConsent = true
    var canCheckVoiceService = true, voiceServiceChecking = false, voiceServiceStatus = "fixture check"
    var voiceCheckOK = true, deferVoiceCheck = false, deferConnect = false, failBuiltinPrepare = false
    var transcript: [ConversationLine] = []
    let builtinRoute = FakeBuiltinRoute(), builtinCaptions = FakeBuiltinCaptions()
    let continuousVoice = FakeBuiltinRoute()
    var builtinAudioPrepared: Bool { builtinRoute.active || continuousVoice.active }
    var builtinAudioReady: Bool { continuousVoice.active ? continuousVoice.ready : builtinRoute.active && builtinRoute.ready }
    var connects = 0, disconnects = 0, dials = 0, hangups = 0, checks = 0, prepares = 0, restores = 0
    var steers: [String] = []
    func connect() { connects += 1; if deferConnect { busy = true } else { connected = true } }
    func disconnect() {
        disconnects += 1; busy = false; connected = false; callActive = false; callPending = false
        voiceServiceChecking = false; voiceActive = false; ownsActiveCall = false
    }
    func hangup() { hangups += 1; callActive = false; callPending = false; busy = false; voiceActive = false; ownsActiveCall = false }
    func dial(useAI: Bool, fromPlugin: Bool = false) { dials += 1; callActive = true; voiceActive = useAI; ownsActiveCall = true }
    func prepareBuiltinVoice() throws {
        prepares += 1
        if failBuiltinPrepare { throw BridgeError("simulated route prepare failure") }
        builtinRoute.active = true
    }
    func restoreBuiltinAudio() throws {
        guard !callActive, !callPending, !busy else { throw BridgeError("fixture call not ended") }
        restores += 1; builtinRoute.active = false; builtinVoiceConfirmed = false
    }
    func steerConversation(_ instruction: String) throws { steers.append(instruction) }
    func checkVoiceService() { checks += 1; voiceServiceChecking = deferVoiceCheck }
    func snapshot() -> [String: Any] { ["voiceServiceCheck": ["ok": voiceCheckOK]] }
    func log(_ message: String) {}
}

@main
private struct PluginChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks: [[String: Any]] = []
        var retained: [PluginCallSession] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks.append(["name": label, "passed": condition()])
        }
        func fixture(_ name: String) -> (CallSessionCoordinator, PluginCallSession, URL) {
            let s = CallSessionCoordinator(), root = directory.appendingPathComponent(name)
            s.phone = try! PhonePeerConfiguration(address: "AA:BB:CC:DD:EE:FF", name: "Offline Test Phone")
            let p = PluginCallSession(session: s, directory: root); retained.append(p)
            return (s, p, root)
        }
        func prepare(_ p: PluginCallSession, mode: String = "builtin_voice") throws -> String {
            try p.prepare(number: "5551234", task: "OFFLINE fixture only", mode: mode, maximumSeconds: 60)["session_id"] as! String
        }
        func fails(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        func pump() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        func transcripts(_ value: [String: Any]) -> [[String: Any]] {
            (value["events"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "transcript" }
        }
        do {
            let (s, p, _) = fixture("no-default-phone"); s.phone = nil
            check(fails { _ = try prepare(p) }, "no selected phone means no prepared call or personal-device default")
            check(s.dials == 0 && s.connects == 0 && s.prepares == 0 && !s.pluginSessionActive,
                  "missing phone rejection has no connection, route or lease side effects")
        }
        do {
            let (s, p, _) = fixture("continuous-two-recipients")
            s.continuousVoice.active = true
            for number in ["5551234", "5555678"] {
                let id = try p.prepare(number: number, task: "OFFLINE continuous voice fixture", mode: "builtin_voice", maximumSeconds: 60)["session_id"] as! String
                _ = try p.prepareBuiltin(id: id)
                check(p.phase == "awaiting_user_voice_start" && s.prepares == 0 && s.continuousVoice.active,
                      "existing continuous interface is retained without preparing or restarting frontend voice")
                _ = try p.confirmBuiltin(id: id); _ = try p.start(id: id); await pump()
                _ = try p.end(id: id); await pump(); _ = try p.read(id: id, after: 0)
                check(s.continuousVoice.active && !s.pluginSessionActive,
                      "call lease ends while continuous voice remains available for next recipient")
            }
            check(s.dials == 2 && s.restores == 0, "two recipients use one retained voice interface without audio restore")
        }
        do {
            let (s, p, _) = fixture("ownership"); let id = try prepare(p)
            check(s.dials == 0 && s.connects == 0 && s.prepares == 0 && !s.builtinRoute.active,
                  "prepare reserves lease with zero dial, connection or route actions")
            check(fails { _ = try prepare(p) }, "second conversation cannot replace active lease")
            let other = UUID().uuidString.lowercased()
            check(fails { _ = try p.start(id: other) } && fails { _ = try p.end(id: other) } &&
                  fails { _ = try p.steer(id: other, instruction: "x") }, "foreign session ID cannot control lease")
            check(fails { _ = try p.read(id: other, after: 0) } && p.status()["session_id"] == nil,
                  "status does not expose lease ID and unknown ID cannot read captions")
            check(fails { _ = try p.start(id: id) } && s.dials == 0, "builtin start needs user attestation")
            _ = try p.prepareBuiltin(id: id); await pump()
            check(p.phase == "awaiting_user_voice_start" && s.prepares == 1 && s.dials == 0,
                  "builtin prepare routes but never starts voice or dials")
            s.builtinRoute.ready = false
            check(fails { _ = try p.confirmBuiltin(id: id) }, "invalid route cannot receive new voice attestation")
            s.builtinRoute.ready = true; _ = try p.confirmBuiltin(id: id)
            _ = try p.start(id: id); _ = try p.start(id: id); await pump(); _ = try p.start(id: id)
            check(s.dials == 1, "start retries before and after task execution dial exactly once")
            check(fails { _ = try p.restoreAudio(id: id) } && s.restores == 0, "active call cannot restore audio")
            _ = try p.end(id: id); let ended = try p.read(id: id, after: 0)
            check(ended["terminal"] as? Bool == true && s.hangups == 1 && s.builtinRoute.active && s.restores == 0,
                  "builtin hangup retains audio until explicit voice-stop acknowledgement")
            check(fails { _ = try prepare(p) }, "held audio keeps cross-conversation lease reserved")
            _ = try p.restoreAudio(id: id)
            check(!s.builtinRoute.active && s.restores == 1 && !s.pluginSessionActive,
                  "explicit restore after voice stop releases held audio")
            check(s.connected && s.disconnects == 0,
                  "ending and restoring voice retains a ready Bluetooth link for the next call")
        }
        do {
            let (s, p, _) = fixture("explicit-disconnect"); _ = try prepare(p, mode: "openai_realtime")
            try p.endFromConsole(disconnect: true)
            check(!s.connected && s.disconnects == 1, "explicit console disconnect still releases the retained Bluetooth link")
        }
        do {
            let (s, p, _) = fixture("disconnect-held-route"); let id = try prepare(p)
            _ = try p.prepareBuiltin(id: id); await pump()
            try p.endFromConsole(disconnect: true); _ = try p.read(id: id, after: 0)
            check(s.builtinRoute.active && s.disconnects == 0, "explicit disconnect waits for active voice route restoration")
            _ = try p.restoreAudio(id: id)
            check(!s.connected && s.disconnects == 1, "deferred explicit disconnect runs after voice stop and route restore")
        }
        do {
            let (s, p, _) = fixture("cancel-not-yet-running"); s.connected = false
            let id = try prepare(p, mode: "openai_realtime")
            _ = try p.start(id: id); _ = try p.end(id: id); await pump()
            check(s.dials == 0 && s.checks == 0, "end cancels start before task can preflight or dial")
            check(s.connects == 0, "cancelled task does not initiate a late Bluetooth connection")
        }
        do {
            let (s, p, _) = fixture("end-then-start"); let id = try prepare(p, mode: "openai_realtime")
            _ = try p.end(id: id)
            let rejected = fails { _ = try p.start(id: id) }; await pump()
            check(rejected && s.dials == 0, "end of prepared lease rejects immediate start before observer tick")
        }
        do {
            let (s, p, _) = fixture("preflight-failure"); s.voiceCheckOK = false
            let id = try prepare(p, mode: "openai_realtime"); _ = try p.start(id: id); await pump()
            let result = try p.read(id: id, after: 0)
            check(s.checks == 1 && s.dials == 0 && result["terminal"] as? Bool == true,
                  "failed voice preflight terminates without dial")
        }
        do {
            let (s, p, _) = fixture("preflight-cancel"); s.deferVoiceCheck = true
            let id = try prepare(p, mode: "openai_realtime"); _ = try p.start(id: id); await pump()
            _ = try p.end(id: id); s.voiceCheckOK = true; s.voiceServiceChecking = false; await pump()
            check(s.checks == 1 && s.dials == 0, "late successful preflight after cancellation never dials")
        }
        do {
            let (s, p, base) = fixture("transcripts"); let first = try prepare(p, mode: "openai_realtime")
            _ = try p.start(id: first); await pump()
            s.transcript = [ConversationLine(id: "p1", role: "对方", text: "OFFLINE partial", final: false)]
            let partial = try p.read(id: first, after: 0), cursor = partial["cursor"] as! Int
            check(transcripts(partial).count == 1 && transcripts(partial)[0]["final"] as? Bool == false,
                  "partial caption emits one revision with external-content trust")
            s.transcript[0].text = "OFFLINE final"; s.transcript[0].final = true
            let final = try p.read(id: first, after: cursor), finalCursor = final["cursor"] as! Int
            check(transcripts(final).count == 1 && transcripts(final)[0]["final"] as? Bool == true &&
                  transcripts(final)[0]["trust"] as? String == "external_call_content",
                  "same caption ID sends final revision after prior cursor")
            let unchanged = try p.read(id: first, after: finalCursor)
            check(transcripts(unchanged).isEmpty,
                  "unchanged caption is not re-emitted")
            check(fails { _ = try p.read(id: first, after: -1) }, "negative cursor rejected")
            _ = try p.end(id: first); _ = try p.read(id: first, after: 0)
            let originalContext = (try p.read(id: first, after: 0))["voice_context"] as? String
            s.instructions = "FOREIGN INSTRUCTIONS"; s.callActive = true
            s.transcript = [ConversationLine(id: "foreign-call", role: "对方", text: "FOREIGN CALL TEXT", final: true)]
            let sealed = try p.read(id: first, after: 0)
            check(!(sealed["transcript"] as? [[String: Any]] ?? []).contains { $0["text"] as? String == "FOREIGN CALL TEXT" } &&
                  !transcripts(sealed).contains { $0["text"] as? String == "FOREIGN CALL TEXT" },
                  "terminal lease does not capture a later unrelated call transcript")
            check(sealed["phoneCallActive"] as? Bool == false,
                  "terminal lease does not claim a later unrelated active call")
            check(sealed["voice_context"] as? String == originalContext && sealed["captionPageURL"] as? String == "",
                  "terminal lease freezes instructions and removes live caption link")
            s.callActive = false
            let calls = base.appendingPathComponent("calls"), archive = calls.appendingPathComponent(first + ".json")
            let fileMode = (try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as! NSNumber).intValue
            let dirMode = (try FileManager.default.attributesOfItem(atPath: calls.path)[.posixPermissions] as! NSNumber).intValue
            check(fileMode == 0o600 && dirMode == 0o700, "saved call archive is 0600 inside 0700 directory")
            _ = try prepare(p, mode: "openai_realtime")
            let historical = try p.read(id: first, after: cursor)
            check(historical["historical"] as? Bool == true && historical["liveStateVerified"] as? Bool == false &&
                  (historical["transcript"] as? [[String: Any]])?.first?["text"] as? String == "OFFLINE final",
                  "prior lease archive preserves captions without claiming live state")
            let linkID = UUID().uuidString.lowercased()
            try FileManager.default.createSymbolicLink(at: calls.appendingPathComponent(linkID + ".json"), withDestinationURL: archive)
            check(fails { _ = try p.read(id: linkID, after: 0) }, "symbolic-link archive is rejected")
            check(fails { _ = try p.read(id: "../outside", after: 0) }, "non-UUID archive traversal is rejected")
        }
        do {
            let (s, p, _) = fixture("unclaimed-held-audio"); s.builtinRoute.active = true
            check(fails { _ = try prepare(p) } && s.dials == 0,
                  "new lease cannot claim audio held outside that lease")
        }
        do {
            let (s, p, _) = fixture("unstarted-foreign-call"); let id = try prepare(p)
            s.callActive = true
            s.transcript = [ConversationLine(id: "foreign", role: "对方", text: "UNOWNED LIVE TEXT", final: false)]
            let state = try p.read(id: id, after: 0)
            check(state["phase"] as? String != "in_call" && transcripts(state).isEmpty,
                  "prepared unstarted lease does not adopt unrelated active call")
        }
        do {
            let (s, p, base) = fixture("interrupted-archive"); let id = try prepare(p)
            let another = PluginCallSession(session: s, directory: base); retained.append(another)
            let historical = try another.read(id: id, after: 0)
            check(historical["terminal"] as? Bool == true && historical["phase"] as? String == "interrupted_unknown_phone_state",
                  "nonterminal disk snapshot is not treated as a still-live call")
        }
        let failed = checks.filter { $0["passed"] as? Bool != true }
        let report: [String: Any] = ["passed": checks.count - failed.count, "failed": failed.count,
            "checks": checks, "productionSource": "PluginCallSession.swift", "dependencies": "fully fake coordinator and hardware",
            "deviceActions": false, "routeChanges": false, "Keychain": false, "API": false,
            "archiveContents": "synthetic fixture only"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        print("PluginCallSession fake checks: \(checks.count - failed.count) passed, \(failed.count) failed")
        for failure in failed { print("FAIL: \(failure["name"]!)") }
        if !failed.isEmpty { exit(1) }
    }
}
