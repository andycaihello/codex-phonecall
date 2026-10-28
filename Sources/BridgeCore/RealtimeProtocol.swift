import Foundation

// GA protocol references (reviewed 2026-09-08):
// https://developers.openai.com/api/docs/guides/realtime-conversations
// https://developers.openai.com/api/docs/guides/realtime-websocket
public enum RealtimeVoice: String, CaseIterable, Sendable { case marin, cedar }

public struct RealtimeAudioChunk: Equatable, Sendable {
    public let responseID: String
    public let itemID: String
    public let contentIndex: Int
    public let pcm16: Data // Signed little-endian, mono, 24,000 Hz.
    public init(responseID: String, itemID: String, contentIndex: Int, pcm16: Data) {
        self.responseID = responseID; self.itemID = itemID
        self.contentIndex = contentIndex; self.pcm16 = pcm16
    }
}

public struct RealtimePlaybackPosition: Equatable, Sendable {
    public let itemID: String
    public let contentIndex: Int
    public let playedMilliseconds: Int
    public init(itemID: String, contentIndex: Int = 0, playedMilliseconds: Int) {
        self.itemID = itemID; self.contentIndex = contentIndex; self.playedMilliseconds = playedMilliseconds
    }
}

public enum RealtimeFailure: String, Error, LocalizedError, Sendable {
    case consentRequired, invalidKey, alreadyStarted, invalidConfiguration, invalidAudio
    case invalidServerEvent, configurationMismatch, authenticationFailed, rateLimited
    case serviceUnavailable, connectionFailed, queueOverflow, sessionExpired, transcriptionFailed
    public var errorDescription: String? {
        switch self {
        case .consentRequired: return "请先同意将通话音频发送至 OpenAI 并使用付费 API。"
        case .invalidKey: return "请输入有效的 OpenAI API Key。"
        case .alreadyStarted: return "实时语音会话已启动。"
        case .invalidConfiguration: return "实时语音配置无效。"
        case .invalidAudio: return "音频必须为 24 kHz 单声道 PCM16。"
        case .invalidServerEvent: return "实时语音服务返回了无法处理的数据。"
        case .configurationMismatch: return "实时语音服务未确认所需音频配置。"
        case .authenticationFailed: return "API 身份验证失败，请检查密钥和项目权限。"
        case .rateLimited: return "API 配额或速率限制已达到。"
        case .serviceUnavailable: return "实时语音服务暂时不可用，请稍后重试。"
        case .connectionFailed: return "实时语音连接中断。"
        case .queueOverflow: return "音频发送积压，实时语音已停止。"
        case .sessionExpired: return "本次实时语音已达到五分钟上限。"
        case .transcriptionFailed: return "通话字幕识别失败，实时语音已停止。"
        }
    }
    public static func httpStatus(_ status: Int?) -> Self {
        switch status { case 401, 403: return .authenticationFailed
        case 429: return .rateLimited
        case 500, 502, 503, 504: return .serviceUnavailable
        default: return .connectionFailed }
    }
}

public enum RealtimeConversationEvent: Equatable, Sendable {
    case connecting, configuring, ready, speechStarted, speechStopped
    case inputTranscript(itemID: String, text: String, isFinal: Bool)
    case outputTranscript(itemID: String, text: String, isFinal: Bool)
    case audio(RealtimeAudioChunk)
    case audioFinished(responseID: String, itemID: String, contentIndex: Int)
    case responseFinished(responseID: String, cancelled: Bool)
    case playbackInterrupted
    case stopped
    case failed(RealtimeFailure)
}

public enum RealtimeEffect: Equatable, Sendable {
    case event(RealtimeConversationEvent)
    case send(Data)
    case interruptPlayback
}

/// Pure GA event reducer. It never performs IO, reads a key, or executes model tools.
public struct RealtimeProtocolReducer {
    public static let model = "gpt-realtime-2.1"
    public static let maximumMessageBytes = 2 * 1024 * 1024
    public private(set) var isReady = false
    private var configured = false
    private var stopped = false
    private let voice: RealtimeVoice
    private let instructions: String
    private var activeResponseID: String?
    private var greetingRequested = false
    private struct AudioPart {
        let responseID: String, itemID: String
        let contentIndex: Int
        var bytes: Int
        var ended = false
    }
    private var outputParts: [AudioPart] = []
    private var suppressedResponses: [String] = []
    private var transcripts: [String: String] = [:]
    private var finalTranscripts: Set<String> = []
    private var diagnosticEventTypes: [String] = []
    private var diagnosticError: [String: String] = [:]
    private var validationFailureFields: [String] = []
    /// Privacy-safe protocol evidence only; deliberately retained by stop().
    /// No event IDs, field values, server messages, transcripts, or audio payloads.
    public var diagnosticSnapshot: [String: Any] {
        ["eventTypes": diagnosticEventTypes, "error": diagnosticError,
         "validationFailureFields": validationFailureFields]
    }
    private static func diagnosticAtom(_ value: Any?) -> String? {
        guard let value = value as? String, !value.lowercased().hasPrefix("sk-"),
              !value.lowercased().hasPrefix("sk_"),
              value.range(of: "\\A[A-Za-z][A-Za-z0-9_.\\[\\]-]{0,95}\\z", options: .regularExpression) != nil else { return nil }
        return value
    }

    public init(voice: RealtimeVoice = .marin, instructions: String = "用自然、简洁的普通话回应对方。你是 AI 语音助手。") {
        self.voice = voice; self.instructions = instructions
    }

    public static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw RealtimeFailure.invalidConfiguration }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public func sessionUpdate() throws -> Data {
        guard !instructions.isEmpty, instructions.utf8.count <= 12_000 else { throw RealtimeFailure.invalidConfiguration }
        return try Self.encode(["type": "session.update", "session": [
            "type": "realtime", "model": Self.model, "output_modalities": ["audio"],
            "instructions": instructions, "tools": [], "tool_choice": "none", "max_output_tokens": 1024,
            "audio": [
                "input": ["format": ["type": "audio/pcm", "rate": 24000],
                          "transcription": ["model": "gpt-4o-mini-transcribe", "language": "zh"],
                          "turn_detection": ["type": "semantic_vad", "eagerness": "auto",
                                             "create_response": true, "interrupt_response": true]],
                "output": ["format": ["type": "audio/pcm", "rate": 24000], "voice": voice.rawValue]
            ]
        ]])
    }

    public static func inputAudio(_ pcm16: Data) throws -> Data {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2), pcm16.count <= 48_000 else { throw RealtimeFailure.invalidAudio }
        return try encode(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }
    /// Call once after the authenticated local playback endpoint reports ready.
    public mutating func requestGreeting() throws -> [RealtimeEffect] {
        guard isReady, !stopped, !greetingRequested else { return [] }
        greetingRequested = true
        // Never collide with a turn already started by the peer's voice.
        guard activeResponseID == nil else { return [] }
        return [.send(try Self.encode(["type": "response.create", "response": [
            "output_modalities": ["audio"],
            "instructions": "请主动简短问候，说明你是机主委托的 AI 语音助手，然后让对方说话。用自然普通话，最多一到两句话。"
        ]]))]
    }

    private static func identifier(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256 else { throw RealtimeFailure.invalidServerEvent }
        return value
    }
    private static func index(_ value: Any?) throws -> Int {
        guard let n = value as? NSNumber, String(cString: n.objCType) != "c",
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              (0...16).contains(n.intValue) else { throw RealtimeFailure.invalidServerEvent }
        return n.intValue
    }
    private mutating func validateSession(_ object: [String: Any]) throws {
        let session = object["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any], output = audio?["output"] as? [String: Any]
        let inFormat = input?["format"] as? [String: Any], outFormat = output?["format"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any], vad = input?["turn_detection"] as? [String: Any]
        // Field names are constants; never retain the differing server values.
        let checks: [(String, Bool)] = [
            ("session", session != nil), ("session.type", session?["type"] as? String == "realtime"),
            ("session.model", session?["model"] as? String == Self.model),
            ("session.output_modalities", session?["output_modalities"] as? [String] == ["audio"]),
            ("session.audio.input.format.type", inFormat?["type"] as? String == "audio/pcm"),
            ("session.audio.input.format.rate", inFormat?["rate"] as? Int == 24000),
            ("session.audio.output.format.type", outFormat?["type"] as? String == "audio/pcm"),
            ("session.audio.output.format.rate", outFormat?["rate"] as? Int == 24000),
            ("session.audio.output.voice", output?["voice"] as? String == voice.rawValue),
            ("session.audio.input.transcription.language", transcription?["language"] as? String == "zh"),
            ("session.audio.input.transcription.model", transcription?["model"] as? String == "gpt-4o-mini-transcribe"),
            ("session.audio.input.turn_detection.type", vad?["type"] as? String == "semantic_vad"),
            ("session.audio.input.turn_detection.create_response", vad?["create_response"] as? Bool == true),
            ("session.audio.input.turn_detection.interrupt_response", vad?["interrupt_response"] as? Bool == true),
            ("session.tools", (session?["tools"] as? [Any])?.isEmpty == true)
        ]
        validationFailureFields = checks.filter { !$0.1 }.map { $0.0 }
        guard validationFailureFields.isEmpty else { throw RealtimeFailure.configurationMismatch }
    }

    public mutating func receive(_ data: Data) throws -> [RealtimeEffect] {
        guard !stopped else { return [] }
        validationFailureFields = []
        do { return try process(data) }
        catch {
            if validationFailureFields.isEmpty && diagnosticEventTypes.last != "error" {
                validationFailureFields = ["event.payload"]
            }
            throw error
        }
    }
    private mutating func process(_ data: Data) throws -> [RealtimeEffect] {
        guard data.count <= Self.maximumMessageBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            validationFailureFields = ["event.json_or_type"]
            throw RealtimeFailure.invalidServerEvent
        }
        diagnosticEventTypes.append(Self.diagnosticAtom(type) ?? "redacted")
        if diagnosticEventTypes.count > 12 { diagnosticEventTypes.removeFirst(diagnosticEventTypes.count - 12) }
        if type == "error" {
            let error = object["error"] as? [String: Any] ?? [:]
            diagnosticError = [:]
            for field in ["code", "type", "param"] {
                if let value = Self.diagnosticAtom(error[field]) { diagnosticError[field] = value }
            }
            switch error["code"] as? String {
            case "invalid_api_key", "authentication_error": throw RealtimeFailure.authenticationFailed
            case "rate_limit_exceeded", "insufficient_quota": throw RealtimeFailure.rateLimited
            case "server_error": throw RealtimeFailure.serviceUnavailable
            default: throw RealtimeFailure.invalidServerEvent
            }
        }
        if type == "session.created" {
            guard !configured else { return [] }
            configured = true
            return [.event(.configuring), .send(try sessionUpdate())]
        }
        if type == "session.updated" {
            guard configured else { validationFailureFields = ["session.created"]; throw RealtimeFailure.configurationMismatch }
            try validateSession(object)
            if isReady { return [] }
            isReady = true
            return [.event(.ready)]
        }
        guard isReady else { return [] }
        switch type {
        case "input_audio_buffer.speech_started":
            return [.event(.speechStarted), .interruptPlayback]
        case "input_audio_buffer.speech_stopped": return [.event(.speechStopped)]
        case "response.created":
            let response = object["response"] as? [String: Any] ?? [:]
            activeResponseID = try Self.identifier(response["id"])
            return []
        case "response.output_audio.delta":
            let responseID = try Self.identifier(object["response_id"])
            guard !suppressedResponses.contains(responseID), responseID == activeResponseID else { return [] }
            let itemID = try Self.identifier(object["item_id"]), index = try Self.index(object["content_index"])
            guard let base64 = object["delta"] as? String, let pcm = Data(base64Encoded: base64),
                  !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= 192_000 else { throw RealtimeFailure.invalidServerEvent }
            if let n = outputParts.firstIndex(where: { $0.itemID == itemID && $0.contentIndex == index }) {
                guard outputParts[n].responseID == responseID, !outputParts[n].ended else { throw RealtimeFailure.invalidServerEvent }
                outputParts[n].bytes += pcm.count
                guard outputParts[n].bytes <= 14_400_000 else { throw RealtimeFailure.queueOverflow }
            } else {
                guard outputParts.count < 128 else { throw RealtimeFailure.queueOverflow }
                outputParts.append(AudioPart(responseID: responseID, itemID: itemID, contentIndex: index, bytes: pcm.count))
            }
            return [.event(.audio(RealtimeAudioChunk(responseID: responseID, itemID: itemID, contentIndex: index, pcm16: pcm)))]
        case "response.output_audio.done":
            let responseID = try Self.identifier(object["response_id"])
            guard !suppressedResponses.contains(responseID) else { return [] }
            let itemID = try Self.identifier(object["item_id"]), index = try Self.index(object["content_index"])
            guard let part = outputParts.firstIndex(where: { $0.responseID == responseID && $0.itemID == itemID && $0.contentIndex == index }),
                  !outputParts[part].ended else { return [] }
            outputParts[part].ended = true
            return [.event(.audioFinished(responseID: responseID, itemID: itemID, contentIndex: index))]
        case "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed",
             "response.output_audio_transcript.delta", "response.output_audio_transcript.done":
            let input = type.hasPrefix("conversation.item.")
            if !input {
                let responseID = try Self.identifier(object["response_id"])
                if suppressedResponses.contains(responseID) { return [] }
            }
            let id = try Self.identifier(object["item_id"])
            let key = (input ? "in:" : "out:") + id
            let final = type.hasSuffix(".completed") || type.hasSuffix(".done")
            if !final && finalTranscripts.contains(key) { return [] }
            guard let value = object[final ? "transcript" : "delta"] as? String else { throw RealtimeFailure.invalidServerEvent }
            let text = final ? value : (transcripts[key] ?? "") + value
            guard text.utf8.count <= 32_768, transcripts[key] != nil || transcripts.count < 256 else { throw RealtimeFailure.queueOverflow }
            transcripts[key] = text
            if final { finalTranscripts.insert(key) }
            return [.event(input ? .inputTranscript(itemID: id, text: text, isFinal: final) : .outputTranscript(itemID: id, text: text, isFinal: final))]
        case "conversation.item.input_audio_transcription.failed": throw RealtimeFailure.transcriptionFailed
        case "response.done":
            let response = object["response"] as? [String: Any] ?? [:]
            let id = try Self.identifier(response["id"])
            let status = response["status"] as? String
            if id == activeResponseID { activeResponseID = nil }
            if status == "failed" { throw RealtimeFailure.serviceUnavailable }
            var effects: [RealtimeEffect] = []
            if status != "cancelled", !suppressedResponses.contains(id) {
                for index in outputParts.indices where outputParts[index].responseID == id && !outputParts[index].ended {
                    outputParts[index].ended = true
                    let part = outputParts[index]
                    effects.append(.event(.audioFinished(responseID: id, itemID: part.itemID, contentIndex: part.contentIndex)))
                }
            }
            effects.append(.event(.responseFinished(responseID: id, cancelled: status == "cancelled")))
            return effects
        case "response.output_item.added":
            if let item = object["item"] as? [String: Any], item["type"] as? String == "function_call" { throw RealtimeFailure.invalidServerEvent }
            return []
        default: return []
        }
    }

    /// `position` must describe audio consumed by playback, never bytes merely queued.
    /// The caller flushes playback first, and keeps its last confirmed position even
    /// when the queue is empty. A nil/older position means new output is unheard.
    /// Server VAD already cancels automatically; local interruption sends cancel.
    public mutating func interrupt(at position: RealtimePlaybackPosition?, cancelResponse: Bool = true) throws -> [RealtimeEffect] {
        guard isReady, !stopped else { return [] }
        var effects: [RealtimeEffect] = []
        if let activeResponseID {
            if cancelResponse { effects.append(.send(try Self.encode(["type": "response.cancel", "response_id": activeResponseID]))) }
            suppressedResponses.append(activeResponseID)
        }
        let positionIndex = position.flatMap { p in outputParts.firstIndex { $0.itemID == p.itemID && $0.contentIndex == p.contentIndex } }
        for (index, part) in outputParts.enumerated() {
            suppressedResponses.append(part.responseID)
            if let positionIndex, index < positionIndex { continue }
            let heard = index == positionIndex ? max(0, position?.playedMilliseconds ?? 0) : 0
            let end = min(heard, part.bytes / 48) // 24,000 samples/s * 2 bytes/sample.
            effects.append(.send(try Self.encode(["type": "conversation.item.truncate", "item_id": part.itemID,
                                                 "content_index": part.contentIndex, "audio_end_ms": end])))
        }
        if suppressedResponses.count > 256 { suppressedResponses.removeFirst(suppressedResponses.count - 256) }
        activeResponseID = nil; outputParts.removeAll(keepingCapacity: false)
        effects.append(.event(.playbackInterrupted))
        return effects
    }

    public mutating func stop() {
        stopped = true; isReady = false; activeResponseID = nil
        outputParts.removeAll(); transcripts.removeAll(); finalTranscripts.removeAll(); suppressedResponses.removeAll()
    }
}
