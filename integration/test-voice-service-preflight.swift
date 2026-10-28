// Coordinator control-flow tests using fakes only. No Keychain, API, App,
// Bluetooth process, CoreAudio or phone action is reachable from this executable.
import Foundation
import BridgeCore

enum FakeKeyState {
    static let lock = NSLock()
    static var delay: TimeInterval = 0
    static var loads = 0
    static var presence = false
    static var presenceChecks = 0
    static func setPresence(_ value: Bool) { lock.lock(); presence = value; lock.unlock() }
    static func presenceCount() -> Int { lock.lock(); defer { lock.unlock() }; return presenceChecks }
    static func isPresentWithoutPrompt() -> Bool {
        lock.lock(); defer { lock.unlock() }; presenceChecks += 1; return presence
    }
    static func setDelay(_ value: TimeInterval) { lock.lock(); delay = value; lock.unlock() }
    static func count() -> Int { lock.lock(); defer { lock.unlock() }; return loads }
    static func load() -> String {
        lock.lock(); let wait = delay; loads += 1; lock.unlock()
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return "offline-placeholder-not-a-real-key"
    }
}
enum VoiceAPIKeychain {
    static func isPresentWithoutPrompt() -> Bool { FakeKeyState.isPresentWithoutPrompt() }
    static func load() throws -> String? { FakeKeyState.load() }
    static func save(_ key: String) throws { fatalError("Unexpected key save") }
    static func delete() throws { fatalError("Unexpected key delete") }
}
@MainActor enum FakeCounts { static var bluetooth = 0, pcm = 0, audioDevice = 0, starts = 0, stops = 0, greeting = 0, input = 0 }
@MainActor final class BluetoothControlProcess {
    var onEvent: (([String: Any]) -> Void)?, onExit: ((Int32) -> Void)?
    var cleanupVerified = true, resourcesReleased = true, isRunning = false
    var diagnosticEvents: [[String: Any]] = [], cleanupSnapshot: [String: Any] = [:]
    func launch(_ url: URL, allowedNumber: String, phone: PhonePeerConfiguration) throws { FakeCounts.bluetooth += 1 }
    func request(_ op: String, fields: [String: Any] = [:], timeout: TimeInterval = 12) async throws -> [String: Any] { FakeCounts.bluetooth += 1; return [:] }
    func shutdown() { FakeCounts.bluetooth += 1 }
    func shutdownAndWait() async -> Bool { FakeCounts.bluetooth += 1; return true }
}
@MainActor final class BluetoothConnectionPreparation {
    var cleanupVerified = true
    var lastResult: [String: Any] = [:]
    func prepare(_ url: URL, phone: PhonePeerConfiguration) async throws -> [String: Any] { FakeCounts.bluetooth += 1; return [:] }
    func stopAndWait() async -> Bool { FakeCounts.bluetooth += 1; return true }
}
@MainActor final class PCMTransport {
    var onEvent: (([String: Any]) -> Void)?, onFailure: ((String) -> Void)?
    var cleanupVerified = true
    var running = false
    var diagnosticSnapshot: [String: Any] = [:]
    func configure(phone: PhonePeerConfiguration) throws {}
    func clearPhoneConfiguration() throws {}
    func prepare(helperURL: URL) async throws { FakeCounts.pcm += 1 }
    func start() { FakeCounts.pcm += 1 }
    func play(_ chunk: RealtimeAudioChunk) { FakeCounts.pcm += 1 }
    func endPart(responseID: String, itemID: String, contentIndex: Int) { FakeCounts.pcm += 1 }
    func endResponse(_ id: String) { FakeCounts.pcm += 1 }
    func interrupt() -> RealtimePlaybackPosition? { FakeCounts.pcm += 1; return nil }
    func stop() { FakeCounts.pcm += 1 }
    func waitForStop() async -> Bool { true }
}
struct AudioDeviceInfo {
    let uid: String, name: String
    let bluetooth: Bool
    let inputChannels: Int, outputChannels: Int
    @MainActor static func enumerate() -> [AudioDeviceInfo] { FakeCounts.audioDevice += 1; return [] }
}
@MainActor final class RealtimeConversation {
    static var latest: RealtimeConversation?
    var onEvent: ((RealtimeConversationEvent) -> Void)?
    var onInterruptPlayback: (() -> RealtimePlaybackPosition?)?
    var isRunning = false
    var diagnosticSnapshot: [String: Any] = [:]
    var lastMaximum: TimeInterval = 0
    init() { Self.latest = self }
    func start(apiKey: String, consentGranted: Bool, voice: RealtimeVoice, instructions: String, maximumDuration: TimeInterval) throws {
        guard consentGranted, !apiKey.isEmpty else { throw RealtimeFailure.consentRequired }
        FakeCounts.starts += 1; isRunning = true; lastMaximum = maximumDuration
        diagnosticSnapshot = ["eventTypes": ["connecting"]]; onEvent?(.connecting)
    }
    func emit(_ event: RealtimeConversationEvent) {
        if case .failed = event { isRunning = false; _ = onInterruptPlayback?() }
        diagnosticSnapshot = ["eventTypes": [event == .ready ? "session.updated" : "fake-event"]]
        onEvent?(event)
    }
    func stop() {
        guard isRunning else { return }; isRunning = false; FakeCounts.stops += 1
        _ = onInterruptPlayback?(); onEvent?(.stopped)
    }
    func appendInputAudio(_ data: Data) -> Bool { FakeCounts.input += 1; return true }
    func requestGreeting() -> Bool { FakeCounts.greeting += 1; return true }
    func interrupt() { FakeCounts.pcm += 1 }
    func updateTask(_ text: String) -> Bool { true }
}
@MainActor final class LocalHandsFreeService {
    var diagnostic: [String: Any] = [:]
    func start(supportedFeatures: UInt16 = 0) throws -> UInt8 { return 2 }
    func stop() -> Int32 { return 0 }
}
@MainActor final class BuiltinVoiceRoute {
    struct Status { var ready = true }
    var active = false
    var onFailure: ((String) -> Void)?
    var diagnosticSnapshot: [String: Any] = [:]
    func configure(phone: PhonePeerConfiguration) throws {}
    func clearPhoneConfiguration() throws {}
    func inspect() -> Status { Status() }
    func activate(changeInput: Bool, changeOutput: Bool) throws { active = true }
    func stop() { active = false }
}
@MainActor final class ContinuousVoiceAudio {
    var active = false, installed = false
    var ready: Bool { active && error.isEmpty }
    var target = "stopped", error = ""
    var onFailure: ((String) -> Void)?
    var snapshot: [String: Any] { ["active": active, "ready": ready, "target": target] }
    var starts = 0, suspends = 0, phoneSwitches = 0, ownerSwitches = 0, stops = 0
    func start() throws { if !active { starts += 1 }; active = true; target = "owner" }
    func suspendForDial() { suspends += 1; target = "waiting_for_phone" }
    func prepareForDial() throws { suspends += 1; target = "owner_dialing" }
    func switchToPhone(_ phone: PhonePeerConfiguration) throws { phoneSwitches += 1; target = "phone" }
    func switchToOwner() throws { ownerSwitches += 1; if active { target = "owner" } }
    func stopAfterVoiceEnded() { stops += 1; active = false; target = "stopped" }
}
@MainActor final class BuiltinVoiceCaptions {
    var onTranscript: ((String, String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    var diagnosticSnapshot: [String: Any] = [:]
    func configure(phone: PhonePeerConfiguration) throws {}
    func clearPhoneConfiguration() throws {}
    func configureOutgoingVoice() throws {}
    func prepareRecognitionBackend() async throws {}
    func prepare() throws { FakeCounts.pcm += 1 }
    func start() throws { FakeCounts.pcm += 1 }
    func stop() { FakeCounts.pcm += 1 }
}
@main struct Check {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ reason: String) {
        checks += 1; if !condition() { fatalError("FAIL: " + reason) }
    }
    @MainActor static func waitFor(_ condition: () -> Bool, seconds: Double = 2) async {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() && ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(nanoseconds: 5_000_000) }
        expect(condition(), "timed condition")
    }
    @MainActor static func main() async throws {
        let absent = CallSessionCoordinator()
        expect(!absent.keyConfigured && FakeKeyState.presenceCount() == 1 && FakeKeyState.count() == 0,
               "initial absent metadata leaves key unconfigured without reading secret data")
        FakeKeyState.setPresence(true)
        let c = CallSessionCoordinator(); c.mode = .openaiRealtime; let rt = RealtimeConversation.latest!
        expect(c.keyConfigured && FakeKeyState.presenceCount() == 2 && FakeKeyState.count() == 0,
               "initial present metadata restores configured status without loading the key")
        c.checkVoiceService(); expect(FakeKeyState.count() == 0 && !c.busy, "consent guard precedes key loading")
        c.cloudConsent = true; c.callPending = true; c.checkVoiceService()
        expect(FakeKeyState.count() == 0 && !c.busy, "pending phone call blocks preflight")
        c.callPending = false; c.checkVoiceService()
        await waitFor { rt.isRunning }
        expect(c.busy && c.voiceServiceChecking && !c.voiceActive && rt.lastMaximum == 20, "configuration-only run is bounded and separate")
        rt.emit(.configuring); rt.emit(.ready)
        let first = c.snapshot()["voiceServiceCheck"] as! [String: Any]
        expect(!c.busy && !c.voiceServiceChecking && !rt.isRunning, "ready closes immediately")
        expect(first["ok"] as? Bool == true && first["connectionClosed"] as? Bool == true, "success records acceptance and close")
        expect(c.transcript.isEmpty && FakeCounts.greeting == 0 && FakeCounts.input == 0, "no response/transcript/audio request")
        c.checkVoiceService(); await waitFor { rt.isRunning }; rt.emit(.failed(.invalidServerEvent))
        expect(!c.busy && !c.voiceServiceChecking && !c.error.isEmpty, "failure completes without hangup")
        expect((c.snapshot()["voiceServiceCheck"] as! [String: Any])["ok"] as? Bool == false, "failure remains diagnostic")
        FakeKeyState.setDelay(0.2); let starts = FakeCounts.starts
        c.checkVoiceService(); try await Task.sleep(nanoseconds: 25_000_000); c.cancelVoiceServiceCheck()
        expect(!c.busy && c.error.isEmpty, "cancel returns idle promptly during key load")
        FakeKeyState.setDelay(0); c.checkVoiceService(); await waitFor { rt.isRunning }
        try await Task.sleep(nanoseconds: 250_000_000)
        expect(c.voiceServiceChecking && rt.isRunning && FakeCounts.starts == starts + 1, "late cancelled key result cannot replace or close newer check")
        rt.emit(.ready)
        FakeKeyState.setDelay(0.15); let beforeRevocation = FakeCounts.starts
        c.checkVoiceService(); try await Task.sleep(nanoseconds: 25_000_000); c.cloudConsent = false
        await waitFor { !c.voiceServiceChecking }
        expect(FakeCounts.starts == beforeRevocation, "consent rechecked after background key load")
        FakeKeyState.setDelay(0); c.cloudConsent = true; c.checkVoiceService(); await waitFor { rt.isRunning }
        await waitFor({ !c.voiceServiceChecking }, seconds: 22)
        let timed = c.snapshot()["voiceServiceCheck"] as! [String: Any]
        expect(timed["ok"] as? Bool == false && !rt.isRunning && !c.busy, "twenty-second total deadline closes check")
        let elapsed = timed["elapsedSeconds"] as! Double
        expect(elapsed >= 19.8 && elapsed < 21.5, "deadline bounded from before key load")
        expect(FakeCounts.bluetooth == 0 && FakeCounts.pcm == 0 && FakeCounts.audioDevice == 0, "all check outcomes avoid Bluetooth and PCM entirely")
        FakeKeyState.setDelay(0.15); let beforeQuit = FakeCounts.starts
        c.checkVoiceService(); try await Task.sleep(nanoseconds: 20_000_000)
        let quit = await c.shutdownForQuit(); try await Task.sleep(nanoseconds: 200_000_000)
        expect(quit && !c.voiceServiceChecking && !rt.isRunning && FakeCounts.starts == beforeQuit, "quit invalidates pending key load and closes check")
        let result: [String: Any] = ["passed": true, "checks": checks, "scope": "Coordinator with fake key/service/Bluetooth/PCM only; no actual Keychain/API/App/device calls", "deadlineElapsedSeconds": elapsed]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])); print(String(decoding: data, as: UTF8.self))
    }
}
