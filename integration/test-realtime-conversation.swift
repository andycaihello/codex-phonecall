import Foundation
import BridgeCore

private enum CheckError: Error { case failed(String), fakeTransportFailure }

@MainActor
private final class FakeSocket: RealtimeSocketTransport {
    var httpStatus: Int?
    var resumes = 0, closes = 0
    var sent: [Data] = []
    var blockSends = false, ignoreClose = false
    private var waitingReceive: CheckedContinuation<Data, Error>?
    private var waitingSend: CheckedContinuation<Void, Error>?
    private var incoming: [Result<Data, Error>] = []
    func resume() { resumes += 1 }
    func send(_ data: Data) async throws {
        sent.append(data)
        if blockSends { try await withCheckedThrowingContinuation { waitingSend = $0 } }
    }
    func receive() async throws -> Data {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waitingReceive = $0 }
    }
    func emit(_ data: Data) {
        if let continuation = waitingReceive { waitingReceive = nil; continuation.resume(returning: data) }
        else { incoming.append(.success(data)) }
    }
    func failReceive() {
        if let continuation = waitingReceive { waitingReceive = nil; continuation.resume(throwing: CheckError.fakeTransportFailure) }
        else { incoming.append(.failure(CheckError.fakeTransportFailure)) }
    }
    func releaseSend() { let continuation = waitingSend; waitingSend = nil; continuation?.resume() }
    func close() {
        closes += 1
        guard !ignoreClose else { return }
        if let continuation = waitingReceive { waitingReceive = nil; continuation.resume(throwing: CancellationError()) }
        if let continuation = waitingSend { waitingSend = nil; continuation.resume(throwing: CancellationError()) }
    }
}

@main
@MainActor
private struct RealtimeChecks {
    static var names: [String] = []
    static let key = "sk-offline-test-never-sent"
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw CheckError.failed(name) }
        names.append(name)
    }
    static func expect(_ expected: RealtimeFailure, _ name: String, _ action: () throws -> Void) throws {
        do { try action(); throw CheckError.failed(name + " did not fail") }
        catch let failure as RealtimeFailure { try check(failure == expected, name) }
    }
    static func json(_ value: [String: Any]) throws -> Data { try RealtimeProtocolReducer.encode(value) }
    static func object(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
    static func packets(_ effects: [RealtimeEffect]) throws -> [[String: Any]] {
        try effects.compactMap { if case .send(let data) = $0 { return try object(data) }; return nil }
    }
    static func readyReducer() throws -> RealtimeProtocolReducer {
        var reducer = RealtimeProtocolReducer()
        _ = try reducer.receive(json(["type": "session.created"]))
        var update = try object(reducer.sessionUpdate()); update["type"] = "session.updated"
        _ = try reducer.receive(json(update))
        return reducer
    }
    static func created(_ id: String) throws -> Data { try json(["type": "response.created", "response": ["id": id]]) }
    static func audio(_ response: String = "r1", _ item: String = "i1", count: Int = 4800) throws -> Data {
        try json(["type": "response.output_audio.delta", "response_id": response, "item_id": item,
                  "content_index": 0, "delta": Data(repeating: 0, count: count).base64EncodedString()])
    }
    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
        throw CheckError.failed("asynchronous condition timed out")
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 10_000_000) }
    static func makeReady(_ client: RealtimeConversation, _ socket: FakeSocket, duration: Double = 300) async throws {
        try client.start(apiKey: key, consentGranted: true, maximumDuration: duration)
        socket.emit(try json(["type": "session.created"]))
        try await eventually { socket.sent.count == 1 }
        var update = try object(socket.sent[0]); update["type"] = "session.updated"
        socket.emit(try json(update))
        try await eventually { client.isReady }
    }

    static func reducerChecks() throws {
        var greeting = RealtimeProtocolReducer()
        try check(try greeting.requestGreeting().isEmpty, "no greeting before cloud readiness")
        greeting = try readyReducer()
        let greetingPackets = try packets(greeting.requestGreeting())
        try check(greetingPackets.count == 1 && greetingPackets[0]["type"] as? String == "response.create" &&
                  ((greetingPackets[0]["response"] as? [String: Any])?["instructions"] as? String)?.contains("AI") == true,
                  "explicit greeting creates one natural AI-identified response")
        try check(try greeting.requestGreeting().isEmpty, "duplicate PCM ready cannot create duplicate greeting")
        var alreadySpeaking = try readyReducer(); _ = try alreadySpeaking.receive(created("peer-turn"))
        try check(try alreadySpeaking.requestGreeting().isEmpty, "greeting does not collide with already active peer turn")
        let initial = RealtimeProtocolReducer()
        let update = try object(initial.sessionUpdate())
        let session = update["session"] as! [String: Any]
        let audioConfig = session["audio"] as! [String: Any]
        let input = audioConfig["input"] as! [String: Any]
        let vad = input["turn_detection"] as! [String: Any]
        try check(session["model"] as? String == "gpt-realtime-2.1" && session["output_modalities"] as? [String] == ["audio"], "GA model and output schema")
        try check(vad["type"] as? String == "semantic_vad" && vad["interrupt_response"] as? Bool == true && vad["create_response"] as? Bool == true, "natural VAD and automatic server interruption")
        try check((input["transcription"] as? [String: Any])?["language"] as? String == "zh", "Chinese input transcription")
        try check((session["tools"] as? [Any])?.isEmpty == true && session["tool_choice"] as? String == "none", "no tools configured")
        let pcm = Data([0, 0, 255, 127])
        try check(try object(RealtimeProtocolReducer.inputAudio(pcm))["audio"] as? String == pcm.base64EncodedString(), "PCM16 exact byte encoding")
        for invalid in [Data(), Data([0]), Data(repeating: 0, count: 48002)] {
            try expect(.invalidAudio, "reject invalid PCM length \(invalid.count)") { _ = try RealtimeProtocolReducer.inputAudio(invalid) }
        }
        var reducer = try readyReducer()
        try check(reducer.isReady, "ready only after configuration echo")
        var wrong = update; wrong["type"] = "session.updated"
        var wrongSession = session; wrongSession["model"] = "other-model"; wrong["session"] = wrongSession
        try expect(.configurationMismatch, "reject mismatched echo") { _ = try reducer.receive(json(wrong)) }
        _ = try reducer.receive(created("r1"))
        let effects = try reducer.receive(audio())
        try check(effects == [.event(.audio(.init(responseID: "r1", itemID: "i1", contentIndex: 0, pcm16: Data(repeating: 0, count: 4800))))], "output PCM accepts numeric zero content index")
        let truncated = try packets(reducer.interrupt(at: .init(itemID: "i1", playedMilliseconds: 37)))
        try check(truncated.count == 2 && truncated[0]["type"] as? String == "response.cancel" && truncated[1]["audio_end_ms"] as? Int == 37, "cancel precedes truncate at observed playback time")
        try check(try reducer.receive(audio()).isEmpty, "late interrupted response audio discarded")
        var parts = try readyReducer(); _ = try parts.receive(created("r1"))
        _ = try parts.receive(audio("r1", "part1"))
        let partDone = try json(["type": "response.output_audio.done", "response_id": "r1", "item_id": "part1", "content_index": 0])
        try check(try parts.receive(partDone) == [.event(.audioFinished(responseID: "r1", itemID: "part1", contentIndex: 0))], "individual part ends before the next part begins")
        try check(try parts.receive(partDone).isEmpty, "duplicate audio part done is idempotent")
        _ = try parts.receive(audio("r1", "part2"))
        let fallback = try parts.receive(json(["type": "response.done", "response": ["id": "r1", "status": "completed"]]))
        try check(fallback == [.event(.audioFinished(responseID: "r1", itemID: "part2", contentIndex: 0)), .event(.responseFinished(responseID: "r1", cancelled: false))], "response done ends only still-open parts as fallback")
        var finished = try readyReducer()
        _ = try finished.receive(created("r1")); _ = try finished.receive(audio())
        _ = try finished.receive(json(["type": "response.done", "response": ["id": "r1", "status": "completed"]]))
        let afterDone = try packets(finished.interrupt(at: .init(itemID: "i1", playedMilliseconds: 999)))
        try check(afterDone.count == 1 && afterDone[0]["audio_end_ms"] as? Int == 100, "generation done still truncates queued playback and clamps time")
        var multiple = try readyReducer()
        _ = try multiple.receive(created("r1")); _ = try multiple.receive(audio("r1", "old"))
        _ = try multiple.receive(created("r2")); _ = try multiple.receive(audio("r2", "current")); _ = try multiple.receive(audio("r2", "future"))
        let many = try packets(multiple.interrupt(at: .init(itemID: "current", playedMilliseconds: 25), cancelResponse: false))
        try check(many.count == 2 && many[0]["item_id"] as? String == "current" && many[0]["audio_end_ms"] as? Int == 25 && many[1]["audio_end_ms"] as? Int == 0, "server VAD avoids duplicate cancel and truncates only current and future parts")
        var captions = try readyReducer()
        _ = try captions.receive(json(["type": "conversation.item.input_audio_transcription.delta", "item_id": "in", "delta": "你"]))
        let caption = try captions.receive(json(["type": "conversation.item.input_audio_transcription.delta", "item_id": "in", "delta": "好"]))
        try check(caption == [.event(.inputTranscript(itemID: "in", text: "你好", isFinal: false))], "input deltas accumulated per item")
        _ = try captions.receive(json(["type": "conversation.item.input_audio_transcription.completed", "item_id": "in", "transcript": "你好。 "]))
        try check(try captions.receive(json(["type": "conversation.item.input_audio_transcription.delta", "item_id": "in", "delta": "迟到"])).isEmpty, "final transcript cannot become partial")
        try expect(.transcriptionFailed, "transcription failure stops visibly") { _ = try captions.receive(json(["type": "conversation.item.input_audio_transcription.failed"])) }
        try expect(.authenticationFailed, "raw server secret not exposed") { _ = try captions.receive(json(["type": "error", "error": ["code": "invalid_api_key", "message": "secret API key raw detail"]])) }
        try expect(.invalidServerEvent, "function calls rejected") { _ = try captions.receive(json(["type": "response.output_item.added", "item": ["type": "function_call"]])) }
        var invalidIndex = try readyReducer(); _ = try invalidIndex.receive(created("r1"))
        var invalidPacket = try object(audio()); invalidPacket["content_index"] = true
        try expect(.invalidServerEvent, "boolean content index rejected") { _ = try invalidIndex.receive(json(invalidPacket)) }
        captions.stop()
        try check(try captions.receive(Data("invalid late message".utf8)).isEmpty, "stopped reducer ignores even malformed late events")
    }

    static func diagnosticChecks() throws {
        var reducer = RealtimeProtocolReducer()
        let secret = "sk-" + String(repeating: "synthetic-only-", count: 4)
        _ = try? reducer.receive(json(["type": "error", "error": [
            "code": "unknown_parameter", "type": "invalid_request_error", "param": "session.max_output_tokens",
            "message": secret, "audio": "synthetic-audio", "instructions": "synthetic-instructions"
        ], "event_id": "synthetic-event-id"]))
        try check(reducer.diagnosticSnapshot["error"] as? [String: String] == [
            "code": "unknown_parameter", "type": "invalid_request_error", "param": "session.max_output_tokens"
        ], "diagnostics retain only three sanitized machine error fields")
        let serialized = String(data: try json(reducer.diagnosticSnapshot), encoding: .utf8)!
        try check(![secret, "synthetic-audio", "synthetic-instructions", "synthetic-event-id", "message"].contains { serialized.contains($0) },
                  "diagnostics omit raw messages secrets payloads instructions and event ids")
        let retained = try json(reducer.diagnosticSnapshot)
        reducer.stop(); _ = try reducer.receive(json(["type": "late.event"]))
        try check(try json(reducer.diagnosticSnapshot) == retained, "stop retains diagnostic evidence and ignores stale packets")
        for unsafe in [secret, "sk_fake", "Bearer secret", "valid_code\n", "a/b", "{\"secret\":1}", String(repeating: "a", count: 97)] {
            var filtered = RealtimeProtocolReducer()
            _ = try? filtered.receive(json(["type": "error", "error": ["code": unsafe, "type": unsafe, "param": unsafe, "message": unsafe]]))
            try check((filtered.diagnosticSnapshot["error"] as? [String: String])?.isEmpty == true,
                      "unsafe diagnostic atom rejected \(names.count)")
        }
        var mismatch = try readyReducer()
        var update = try object(mismatch.sessionUpdate()); update["type"] = "session.updated"
        var session = update["session"] as! [String: Any]; session["model"] = secret; update["session"] = session
        _ = try? mismatch.receive(json(update))
        try check(mismatch.diagnosticSnapshot["validationFailureFields"] as? [String] == ["session.model"] &&
                  !String(data: try json(mismatch.diagnosticSnapshot), encoding: .utf8)!.contains(secret),
                  "session mismatch reports fixed field name without server value")
        var bounded = RealtimeProtocolReducer()
        for _ in 0..<20 { _ = try bounded.receive(json(["type": "safe.future_event", "delta": secret])) }
        _ = try bounded.receive(json(["type": secret]))
        let types = bounded.diagnosticSnapshot["eventTypes"] as? [String]
        try check(types?.count == 12 && types?.last == "redacted", "event type history is bounded and unsafe types redacted")
        var malformed = RealtimeProtocolReducer(); _ = try? malformed.receive(Data("not JSON".utf8))
        try check(malformed.diagnosticSnapshot["validationFailureFields"] as? [String] == ["event.json_or_type"],
                  "malformed packet reports only fixed parser failure field")
    }

    static func clientChecks() async throws {
        var factoryCalls = 0
        let unused = FakeSocket()
        let gated = RealtimeConversation(transportFactory: { _ in factoryCalls += 1; return unused })
        try expect(.consentRequired, "missing consent rejects before transport") { try gated.start(apiKey: key, consentGranted: false) }
        try expect(.invalidKey, "header injection key rejects before transport") { try gated.start(apiKey: key + "\r\n", consentGranted: true) }
        try expect(.invalidConfiguration, "negative duration rejects before transport") { try gated.start(apiKey: key, consentGranted: true, maximumDuration: -1) }
        try check(factoryCalls == 0 && unused.resumes == 0, "all invalid starts avoid transport creation")

        let unlimitedSocket = FakeSocket()
        let unlimited = RealtimeConversation(transportFactory: { _ in unlimitedSocket })
        try unlimited.start(apiKey: key, consentGranted: true, maximumDuration: 0)
        try check(unlimited.isRunning && unlimitedSocket.resumes == 1, "zero duration enables session without a fixed call deadline")
        unlimited.stop()
        try unlimited.start(apiKey: key, consentGranted: true, maximumDuration: 1800)
        try check(unlimited.isRunning, "explicit duration beyond five minutes is accepted")
        unlimited.stop()

        let socket = FakeSocket()
        let client = RealtimeConversation(transportFactory: { _ in socket })
        var events: [RealtimeConversationEvent] = []
        var flushes = 0
        client.onEvent = { events.append($0) }
        client.onInterruptPlayback = { flushes += 1; return .init(itemID: "i1", playedMilliseconds: 41) }
        try check(!client.appendInputAudio(Data([0, 0])), "input refused before ready")
        try await makeReady(client, socket)
        try check(socket.sent.count == 1, "cloud ready alone does not request early audio greeting")
        socket.emit(try created("r1")); socket.emit(try audio())
        try await eventually { events.contains { if case .audio = $0 { return true }; return false } }
        socket.blockSends = true
        try check(client.appendInputAudio(Data([1, 0])), "ready accepts audio")
        try await eventually { socket.sent.count == 2 }
        _ = client.appendInputAudio(Data([2, 0]))
        client.interrupt()
        socket.blockSends = false; socket.releaseSend()
        try await eventually { socket.sent.count == 5 }
        let sendTypes = try socket.sent.map { try object($0)["type"] as! String }
        try check(sendTypes == ["session.update", "input_audio_buffer.append", "response.cancel", "conversation.item.truncate", "input_audio_buffer.append"], "control FIFO overtakes queued audio after one in-flight packet")
        try check(try object(socket.sent[3])["audio_end_ms"] as? Int == 41 && flushes == 1, "client truncation uses synchronous playback acknowledgement")
        client.stop(); let countAfterStop = events.count
        socket.emit(try audio()); try await settle()
        try check(!client.isRunning && socket.closes == 1 && events.count == countAfterStop && events.last == .stopped && flushes == 2, "stop closes once flushes audio and suppresses stale receive")

        let overloaded = FakeSocket()
        let overflowing = RealtimeConversation(transportFactory: { _ in overloaded })
        var overflowEvents: [RealtimeConversationEvent] = []
        overflowing.onEvent = { overflowEvents.append($0) }
        try await makeReady(overflowing, overloaded)
        overloaded.blockSends = true
        _ = overflowing.appendInputAudio(Data([0, 0]))
        try await eventually { overloaded.sent.count == 2 }
        for _ in 0..<100 { _ = overflowing.appendInputAudio(Data(repeating: 0, count: 48000)) }
        try check(!overflowing.isRunning && overloaded.closes == 1 && overflowEvents.last == .failed(.queueOverflow), "bounded outbound backlog fails and closes instead of retaining unlimited PCM")

        let old = FakeSocket(); old.ignoreClose = true
        let next = FakeSocket()
        var generation = 0
        let restarting = RealtimeConversation(transportFactory: { _ in generation += 1; return generation == 1 ? old : next })
        var restartEvents: [RealtimeConversationEvent] = []
        restarting.onEvent = { restartEvents.append($0) }
        try await makeReady(restarting, old)
        restarting.stop()

        let greetingSocket = FakeSocket()
        let greetingClient = RealtimeConversation(transportFactory: { _ in greetingSocket })
        try await makeReady(greetingClient, greetingSocket)
        try check(greetingClient.requestGreeting() && greetingClient.requestGreeting(), "explicit PCM ready greeting requests accepted idempotently")
        try await eventually { greetingSocket.sent.count == 2 }
        try check(try object(greetingSocket.sent[1])["type"] as? String == "response.create", "client emits one greeting only on explicit coordinator request")
        greetingClient.stop()
        try await makeReady(restarting, next)
        let restartCount = restartEvents.count
        old.emit(try created("stale")); try await settle()
        try check(restarting.isReady && restartEvents.count == restartCount, "old receive continuation cannot affect new generation")
        restarting.stop()

        for (status, failure) in [(401, RealtimeFailure.authenticationFailed), (502, .serviceUnavailable)] {
            let failingSocket = FakeSocket(); failingSocket.httpStatus = status
            let failing = RealtimeConversation(transportFactory: { _ in failingSocket })
            var terminal: RealtimeConversationEvent?
            failing.onEvent = { terminal = $0 }
            try failing.start(apiKey: key, consentGranted: true)
            failingSocket.failReceive()
            try await eventually { !failing.isRunning }
            try check(terminal == .failed(failure) && failingSocket.closes == 1, "HTTP \(status) mapped to sanitized terminal failure")
        }
        let diagnosticSocket = FakeSocket()
        let diagnosticClient = RealtimeConversation(transportFactory: { _ in diagnosticSocket })
        try diagnosticClient.start(apiKey: key, consentGranted: true)
        diagnosticSocket.emit(try json(["type": "error", "error": ["code": "unknown_parameter", "param": "session.audio", "message": key]]))
        try await eventually { !diagnosticClient.isRunning }
        try check((diagnosticClient.diagnosticSnapshot["error"] as? [String: String])?["code"] == "unknown_parameter",
                  "client fail teardown preserves sanitized protocol evidence")
        try diagnosticClient.start(apiKey: key, consentGranted: true)
        try check((diagnosticClient.diagnosticSnapshot["eventTypes"] as? [String])?.isEmpty == true &&
                  (diagnosticClient.diagnosticSnapshot["error"] as? [String: String])?.isEmpty == true,
                  "new client start resets previous diagnostic evidence")
        diagnosticClient.stop()

        let expiringSocket = FakeSocket()
        let expiring = RealtimeConversation(transportFactory: { _ in expiringSocket })
        var expired: RealtimeConversationEvent?
        expiring.onEvent = { expired = $0 }
        try expiring.start(apiKey: key, consentGranted: true, maximumDuration: 1)
        try await Task.sleep(nanoseconds: 1_080_000_000)
        try check(!expiring.isRunning && expiringSocket.closes == 1 && expired == .failed(.sessionExpired), "deadline stops an unready session with no transport response")

        let reentrantSocket = FakeSocket()
        let reentrant = RealtimeConversation(transportFactory: { _ in reentrantSocket })
        reentrant.onEvent = { if $0 == .connecting { reentrant.stop() } }
        try reentrant.start(apiKey: key, consentGranted: true)
        try check(!reentrant.isRunning && reentrantSocket.resumes == 0 && reentrantSocket.closes == 1, "synchronous connecting callback stop prevents socket resume")
    }

    static func main() async throws {
        try reducerChecks()
        try diagnosticChecks()
        try await clientChecks()
        let report: [String: Any] = ["passed": true, "count": names.count, "checks": names,
                                    "networkRequests": 0, "audioDeviceOperations": 0, "apiCharges": 0]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count == 2 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic) }
        print(String(data: data, encoding: .utf8)!)
    }
}
