import Foundation
import BridgeCore

// Injectable only inside this module, so offline tests never create a real socket.
@MainActor
protocol RealtimeSocketTransport: AnyObject {
    var httpStatus: Int? { get }
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

private final class RealtimeRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward an Authorization header to another endpoint.
    }
}

@MainActor
private final class URLSessionRealtimeTransport: RealtimeSocketTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var closed = false
    var httpStatus: Int? { (socket.response as? HTTPURLResponse)?.statusCode }

    init(apiKey: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 305
        session = URLSession(configuration: configuration, delegate: RealtimeRedirectBlocker(), delegateQueue: nil)
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")!)
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = RealtimeProtocolReducer.maximumMessageBytes
    }
    func resume() { if !closed { socket.resume() } }
    func send(_ data: Data) async throws {
        guard !closed, let text = String(data: data, encoding: .utf8) else { throw RealtimeFailure.connectionFailed }
        try await socket.send(.string(text))
    }
    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw RealtimeFailure.invalidServerEvent
        }
    }
    func close() {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Explicitly started, five-minute, speech-to-speech API session. No key storage,
/// logging, dialing, model tools, automatic reconnection, or audio-device access.
@MainActor
final class RealtimeConversation {
    typealias TransportFactory = (String) -> any RealtimeSocketTransport
    var onEvent: ((RealtimeConversationEvent) -> Void)?
    /// Flush/invalidate playback synchronously, then return its last conservatively
    /// observed consumed position (even if the queue has already drained).
    var onInterruptPlayback: (() -> RealtimePlaybackPosition?)?
    private(set) var isRunning = false
    private(set) var isReady = false
    /// Retained after failure/stop; reset with the reducer on the next start.
    /// Contains machine field names only, never NSError/server text or payloads.
    var diagnosticSnapshot: [String: Any] { reducer.diagnosticSnapshot }
    private let transportFactory: TransportFactory
    private var transport: (any RealtimeSocketTransport)?
    private var reducer = RealtimeProtocolReducer()
    private var runID: UUID?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var outboundAudio: [Data] = []
    private var outboundControl: [Data] = []
    private var queuedBytes = 0
    private let maximumQueuedBytes = 256 * 1024
    private let maximumQueuedMessages = 96

    init() { transportFactory = { URLSessionRealtimeTransport(apiKey: $0) } }
    init(transportFactory: @escaping TransportFactory) { self.transportFactory = transportFactory }

    func start(apiKey: String, consentGranted: Bool, voice: RealtimeVoice = .marin,
               instructions: String = "用自然、简洁的普通话回应对方。你是 AI 语音助手。",
               maximumDuration: TimeInterval = 0) throws {
        guard consentGranted else { throw RealtimeFailure.consentRequired }
        guard !isRunning else { throw RealtimeFailure.alreadyStarted }
        guard (20...4096).contains(apiKey.utf8.count), apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw RealtimeFailure.invalidKey
        }
        guard maximumDuration.isFinite, (0...TimeInterval(Int32.max)).contains(maximumDuration) else { throw RealtimeFailure.invalidConfiguration }
        let nextReducer = RealtimeProtocolReducer(voice: voice, instructions: instructions)
        _ = try nextReducer.sessionUpdate() // Validate before constructing/resuming a transport.
        let id = UUID()
        reducer = nextReducer; runID = id; isRunning = true; isReady = false
        let socket = transportFactory(apiKey)
        transport = socket
        onEvent?(.connecting)
        guard current(id) else { return }
        socket.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let socket = self?.transport, self?.current(id) == true else { return }
                do {
                    let data = try await socket.receive()
                    guard let self, self.current(id), !Task.isCancelled else { return }
                    do { try self.apply(self.reducer.receive(data), id: id) }
                    catch { self.fail((error as? RealtimeFailure) ?? .invalidServerEvent, id: id); return }
                } catch {
                    guard let self, self.current(id), !Task.isCancelled else { return }
                    self.fail(RealtimeFailure.httpStatus(socket.httpStatus), id: id)
                    return
                }
            }
        }
        deadlineTask = maximumDuration > 0 ? Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(maximumDuration * 1_000_000_000)) }
            catch { return }
            self?.fail(.sessionExpired, id: id)
        } : nil
        handshakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            guard let self, self.current(id), !self.isReady else { return }
            self.fail(.connectionFailed, id: id)
        }
    }

    /// Call on the main actor, outside any realtime audio callback. False means the
    /// session is not ready or has stopped; no audio is retained before readiness.
    @discardableResult
    func appendInputAudio(_ pcm16: Data) -> Bool {
        guard let id = runID, isReady else { return false }
        do { return enqueue(try RealtimeProtocolReducer.inputAudio(pcm16), id: id) }
        catch { fail((error as? RealtimeFailure) ?? .invalidAudio, id: id); return false }
    }
    /// The coordinator calls this after BOTH cloud configuration and native PCM
    /// readiness, so the first greeting cannot be discarded during audio startup.
    @discardableResult
    func requestGreeting() -> Bool {
        guard let id = runID, isReady else { return false }
        do { try apply(reducer.requestGreeting(), id: id); return current(id) }
        catch { fail((error as? RealtimeFailure) ?? .invalidServerEvent, id: id); return false }
    }

    /// Optional user/local interruption. Server VAD calls the same truncation path
    /// with automatic server cancellation, avoiding a duplicate cancel race.
    func interrupt() {
        guard let id = runID, isReady else { return }
        let position = onInterruptPlayback?()
        guard current(id) else { return }
        do { try apply(reducer.interrupt(at: position, cancelResponse: true), id: id) }
        catch { fail((error as? RealtimeFailure) ?? .invalidServerEvent, id: id) }
    }

    /// Update the voice agent's task through its existing session. No model tools
    /// are enabled and no reply/audio is requested by this configuration change.
    @discardableResult
    func updateTask(_ instructions: String) -> Bool {
        guard let id = runID, isReady, !instructions.isEmpty, instructions.utf8.count <= 12_000 else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "type": "session.update", "session": ["type": "realtime", "instructions": instructions]
        ]) else { return false }
        return enqueue(data, id: id, priority: true)
    }

    func stop() {
        guard isRunning else { return }
        tearDown()
        onEvent?(.stopped)
    }

    private func current(_ id: UUID) -> Bool { isRunning && runID == id }
    private func apply(_ effects: [RealtimeEffect], id: UUID) throws {
        for effect in effects {
            guard current(id) else { return }
            switch effect {
            case .event(let event):
                if event == .ready { isReady = true; handshakeTask?.cancel(); handshakeTask = nil }
                onEvent?(event)
            case .send(let data):
                _ = enqueue(data, id: id, priority: true)
            case .interruptPlayback:
                let position = onInterruptPlayback?()
                guard current(id) else { return }
                // interrupt_response=true already cancels generation on server VAD.
                try apply(reducer.interrupt(at: position, cancelResponse: false), id: id)
            }
        }
    }
    private func enqueue(_ data: Data, id: UUID, priority: Bool = false) -> Bool {
        guard current(id) else { return false }
        guard data.count <= maximumQueuedBytes, queuedBytes + data.count <= maximumQueuedBytes,
              outboundAudio.count + outboundControl.count < maximumQueuedMessages else { fail(.queueOverflow, id: id); return false }
        // Controls overtake unsent audio, but preserve cancel-before-truncate order.
        // Exactly one send is in flight; input chunks retain their own FIFO order.
        if priority { outboundControl.append(data) } else { outboundAudio.append(data) }
        queuedBytes += data.count
        if sendTask == nil {
            sendTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.current(id), let socket = self.transport else { return }
                    guard !self.outboundControl.isEmpty || !self.outboundAudio.isEmpty else { self.sendTask = nil; return }
                    let packet = !self.outboundControl.isEmpty ? self.outboundControl.removeFirst() : self.outboundAudio.removeFirst()
                    self.queuedBytes -= packet.count
                    do { try await socket.send(packet) }
                    catch {
                        if self.current(id), !Task.isCancelled { self.fail(RealtimeFailure.httpStatus(socket.httpStatus), id: id) }
                        return
                    }
                }
            }
        }
        return true
    }
    private func fail(_ error: RealtimeFailure, id: UUID) {
        guard current(id) else { return }
        tearDown()
        onEvent?(.failed(error)) // Deliberately never exposes NSError/server text/key.
    }
    private func tearDown() {
        runID = nil; isRunning = false; isReady = false
        reducer.stop()
        receiveTask?.cancel(); receiveTask = nil
        sendTask?.cancel(); sendTask = nil
        deadlineTask?.cancel(); deadlineTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        outboundAudio.removeAll(); outboundControl.removeAll(); queuedBytes = 0
        transport?.close(); transport = nil
        _ = onInterruptPlayback?()
    }
}
