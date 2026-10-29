import Foundation
import AVFoundation
import Speech
import CoreFoundation
import BridgeCore

private struct ConsoleSettings: Codable {
    var schema = 2
    var phone: PhonePeerConfiguration?
    var number: String
    var instructions: String
    var mode: String
    var maximumSeconds: Int
    var voice: String
}

@MainActor extension BridgeModel {
    func webSnapshot() -> [String: Any] {
        func microphone() -> String {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "notDetermined"
            }
        }
        func speech() -> String {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "notDetermined"
            }
        }
        // A separate projection avoids exposing native logs, credentials, call
        // lease IDs, audio data or private diagnostic paths to the page.
        return ["version": "0.7.9", "backendRunning": true,
            "status": session.status, "captionWarning": session.captionWarning, "error": lastError.isEmpty ? session.error : lastError,
            "captionSource": session.usesCodexCaptions ? "codex_transcript" : "apple_speech",
            "codexCaptions": session.codexCaptions.snapshot,
            "modeID": session.mode.rawValue, "mode": session.mode.title,
            "connected": session.connected, "busy": session.busy || webDialTask != nil || webPermissionPending,
            "audioValidationPrepared": session.audioValidationPrepared, "audioValidationReady": session.audioValidationReady, "validationPromptSent": session.validationPromptSent,
            "audioValidationStartedAt": session.audioValidationStartedAt, "audioValidationStoppedAt": session.audioValidationStoppedAt,
            "audioValidationDurationSeconds": session.audioValidationDurationSeconds,
            "audioValidationVoiceConfirmedAt": session.audioValidationVoiceConfirmedAt,
            "audioValidationStopReason": session.audioValidationStopReason,
            "incomingMode": session.incomingMode, "incomingAvailable": pluginCalls.currentIncomingSelected,
            "phoneStateUnknown": session.phoneStateUnknown, "dialerStage": session.dialerStage,
            "bluetoothCallControlReady": session.bluetoothCallControlReady, "dialTransport": "bluetooth_hfp",
            "callActive": session.callActive, "callPending": session.callPending, "voiceActive": session.voiceActive,
            "number": session.number, "instructions": session.instructions,
            "maximumSeconds": session.maximumSeconds, "voice": session.voice.rawValue,
            "cloudConsent": session.cloudConsent, "keyConfigured": session.keyConfigured,
            "pluginSessionActive": session.pluginSessionActive, "pluginPhase": pluginCalls.phase,
            "builtinVoiceConfirmed": session.builtinVoiceConfirmed, "builtinRouteActive": session.builtinAudioPrepared,
            "builtinRouteReady": session.builtinAudioReady,
            "continuousVoiceInstalled": session.continuousVoice.installed,
            "continuousVoiceActive": session.continuousVoice.active,
            "continuousVoiceReady": session.continuousVoice.ready,
            "continuousVoiceTarget": session.continuousVoice.target,
            "microphonePermission": microphone(), "speechPermission": speech(),
            "permissionRequestPending": webPermissionPending,
            "voiceServiceChecking": session.voiceServiceChecking, "voiceServiceStatus": session.voiceServiceStatus,
            "phoneConfigured": session.phone != nil, "phoneName": session.phone?.name ?? "",
            "phoneAddress": session.phone?.address ?? "", "phoneSelectionPending": bluetooth.refreshing,
            "pairingModeActive": bluetooth.waitingForPhone && bluetooth.localServiceDiagnostic["published"] as? Bool == true,
            "pairingRoleMatches": bluetooth.localServiceDiagnostic["handsFreeRoleMatches"] as? Bool == true,
            "pairedPhones": bluetooth.devices.filter { $0.paired }.compactMap { device -> [String: String]? in
                guard let peer = try? PhonePeerConfiguration(address: device.id, name: device.name) else { return nil }
                return ["address": peer.address, "name": peer.name]
            },
            "transcript": session.transcript.suffix(100).map { ["id": $0.id, "role": $0.role, "text": $0.text, "final": $0.final] },
            "diagnosticSummary": "蓝牙：\(bluetooth.radioState)\n手机配置：\(session.phone == nil ? "未选择" : "已保存")\n插件阶段：\(pluginCalls.phase)\n控制台：仅本机访问\n内置语音端到端验证：待完成\nRealtime 端到端验证：待完成"]
    }

    func webCommand(_ value: [String: Any]) -> [String: Any] {
        do {
            guard let action = value["action"] as? String else { throw BridgeError("缺少操作名称。") }
            func string(_ key: String) throws -> String {
                guard let text = value[key] as? String else { throw BridgeError("操作参数不完整。") }; return text
            }
            func boolean(_ key: String) throws -> Bool {
                guard let number = value[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw BridgeError("确认参数无效。")
                }
                return number.boolValue
            }
            func idle(allowLease: Bool = false, allowRinging: Bool = false) throws {
                guard !session.busy, !session.callActive, (!session.callPending || (allowRinging && session.incomingMode)), !session.voiceActive,
                      webDialTask == nil, !webPermissionPending,
                      allowLease || !session.pluginSessionActive else {
                    throw BridgeError("当前任务正在使用通话桥，请先结束或取消该任务。")
                }
            }
            lastError = ""
            switch action {
            case "configure":
                try idle()
                guard !session.builtinRoute.active else { throw BridgeError("请先停止内置语音并恢复音频。") }
                let number = try string("number"), instructions = try string("instructions")
                guard PhoneNumber.valid(number), !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      instructions.utf8.count <= 6000, let mode = ConversationMode(rawValue: try string("modeID")),
                      let voice = RealtimeVoice(rawValue: try string("voice")),
                      let duration = value["maximumSeconds"] as? NSNumber, CFGetTypeID(duration) != CFBooleanGetTypeID(),
                      duration.doubleValue == Double(duration.intValue), (0...Int(Int32.max)).contains(duration.intValue) else {
                    throw BridgeError("请填写有效号码和通话任务；通话时限为非负整数秒，0 表示不限时。")
                }
                guard !session.connected || session.number == number else { throw BridgeError("号码已改变，请先断开手机再保存。") }
                guard !session.continuousVoice.active || mode == .builtinVoice else {
                    throw BridgeError("连续 Codex 语音仍在运行，请先结束并恢复音频，再切换 API 语音模式。")
                }
                session.incomingMode = false; session.beginIncomingSelection()
                session.number = number; session.instructions = instructions; session.mode = mode
                session.voice = voice; session.maximumSeconds = duration.intValue
                session.builtinVoiceConfirmed = false
                if mode != .openaiRealtime { session.cloudConsent = false }
                try saveConsoleSettings()
            case "refresh_phones":
                try idle(); bluetooth.refresh()
            case "start_audio_pairing":
                try idle()
                guard !session.connected, !session.builtinRoute.active else {
                    throw BridgeError("请先断开手机并恢复原音频设备，再准备通话音频配对。")
                }
                try bluetooth.advertiseForPairing()
                guard bluetooth.localServiceDiagnostic["published"] as? Bool == true,
                      bluetooth.localServiceDiagnostic["handsFreeRoleMatches"] as? Bool == true else {
                    bluetooth.disconnect()
                    throw BridgeError("Mac 免提服务发布后未通过角色校验，已安全停止。")
                }
            case "stop_audio_pairing":
                try idle()
                guard !session.connected else { throw BridgeError("请先断开当前手机连接。") }
                bluetooth.disconnect()
            case "select_phone":
                try idle()
                let address = try string("address").uppercased().replacingOccurrences(of: "-", with: ":")
                guard !bluetooth.refreshing,
                      let device = bluetooth.devices.first(where: {
                          $0.paired && $0.id.uppercased().replacingOccurrences(of: "-", with: ":") == address
                      }) else { throw BridgeError("请先读取已配对设备，再选择列表中的手机。") }
                try session.configurePhone(PhonePeerConfiguration(address: device.id, name: device.name))
                try saveConsoleSettings()
            case "forget_phone":
                try idle(); try session.forgetPhone(); try saveConsoleSettings()
            case "connect":
                try idle(); session.connect()
                if !session.error.isEmpty { throw BridgeError(session.error) }
            case "diagnose_control_link":
                try idle()
                guard !session.connected, !session.builtinRoute.active,
                      let interval = value["intervalSeconds"] as? NSNumber,
                      CFGetTypeID(interval) != CFBooleanGetTypeID(), interval.doubleValue.isFinite,
                      (0.25...10).contains(interval.doubleValue) else {
                    throw BridgeError("请先断开手机，再指定 0.25 到 10 秒的只读查询间隔。")
                }
                session.connect(readOnlyProbeInterval: interval.doubleValue)
                if !session.error.isEmpty { throw BridgeError(session.error) }
            case "disconnect", "hangup":
                cancelWebDial()
                if session.pluginSessionActive { try pluginCalls.endFromConsole(disconnect: action == "disconnect") }
                else if action == "disconnect" {
                    guard !session.builtinRoute.active else { session.hangup(); throw BridgeError("电话已请求结束。请停止内置语音、恢复音频后再断开手机。") }
                    session.disconnect()
                } else { session.hangup() }
            case "prepare_audio_validation":
                try idle()
                try session.prepareAudioValidation()
            case "send_validation_prompt":
                try session.sendValidationPrompt()
            case "mark_validation_voice":
                guard try boolean("confirmed") else { throw BridgeError("需要机主确认当前语音已启动。") }
                try session.markAudioValidationVoiceStarted()
            case "validate_bluetooth_audio":
                try idle()
                session.dial(useAI: false, localValidation: true)
                if !session.error.isEmpty { throw BridgeError(session.error) }
            case "inspect_dialer":
                try idle()
                guard session.connectedForCurrentNumber, !session.builtinRoute.active else {
                    throw BridgeError("请在空闲状态连接手机，再检查拨号页面。")
                }
                session.dial(useAI: false, systemDialerDiagnostic: true)
                if !session.error.isEmpty { throw BridgeError(session.error) }
            case "answer_incoming":
                try pluginCalls.answerFromConsole()
            case "dial":
                try idle()
                guard session.connectedForCurrentNumber else { throw BridgeError("请先保存本次号码并连接手机。") }
                if session.mode == .openaiRealtime { try startWebRealtimeDial() }
                else { session.dial(useAI: true); if !session.error.isEmpty { throw BridgeError(session.error) } }
            case "interrupt": session.interruptSpeech()
            case "request_permissions":
                try idle(allowLease: true, allowRinging: true)
                webPermissionPending = true
                Task { [weak self] in
                    guard let self else { return }
                    if self.session.usesCodexCaptions || self.session.mode == .openaiRealtime {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                    } else {
                        await self.session.builtinCaptions.requestPermissions()
                    }
                    self.webPermissionPending = false
                }
            case "start_caption_check":
                try idle()
                webDialTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.webDialTask = nil }
                    do { try await self.session.startOutgoingCaptionCheck() }
                    catch { self.lastError = error.localizedDescription }
                }
            case "stop_caption_check":
                session.stopOutgoingCaptionCheck()
            case "prepare_builtin":
                if session.pluginSessionActive { try pluginCalls.prepareBuiltinFromConsole() }
                else { try idle(); try session.prepareBuiltinVoice() }
            case "confirm_builtin":
                guard try boolean("confirmed") else { session.builtinVoiceConfirmed = false; break }
                if session.pluginSessionActive { try pluginCalls.confirmBuiltinFromConsole() }
                else {
                    try idle()
                    guard session.mode == .builtinVoice, session.builtinAudioPrepared, session.builtinAudioReady else {
                        throw BridgeError("请先准备电话音频，再确认已经启动当前任务的内置语音。")
                    }
                    session.builtinVoiceConfirmed = true
                }
            case "restore_audio":
                guard try boolean("voiceStopped") else { throw BridgeError("请先在 Codex 停止语音聊天。") }
                try idle(allowLease: true)
                if session.pluginSessionActive { try pluginCalls.restoreFromConsole() }
                else { try session.restoreBuiltinAudio() }
            case "api_consent":
                try idle(allowLease: true)
                guard session.mode == .openaiRealtime else { throw BridgeError("请先选择 Realtime API 模式。") }
                session.cloudConsent = try boolean("allowed")
            case "save_key":
                try idle(allowLease: true)
                session.saveKey(try string("apiKey"))
                if !session.error.isEmpty { throw BridgeError("密钥未保存，请检查输入格式和钥匙串访问权限。") }
            case "remove_key":
                try idle(allowLease: true); session.removeKey()
                if !session.error.isEmpty { throw BridgeError("未能移除钥匙串中的密钥。") }
            case "check_service":
                try idle(allowLease: true)
                guard session.canCheckVoiceService else { throw BridgeError("请先选择 Realtime 并允许本轮 API 使用。") }
                session.checkVoiceService()
            case "cancel_service": cancelWebDial(); session.cancelVoiceServiceCheck()
            default: throw BridgeError("不支持此控制台操作。")
            }
            return ["ok": true, "state": webSnapshot()]
        } catch {
            lastError = (error as? BridgeError)?.localizedDescription ?? "操作未完成，请检查设备与配置后重试。"
            return ["ok": false, "error": lastError, "state": webSnapshot()]
        }
    }

    private func startWebRealtimeDial() throws {
        guard session.canCheckVoiceService else { throw BridgeError("请先允许本轮 API 使用，并完成密钥配置。") }
        session.checkVoiceService() // Sets busy synchronously, before any async gap.
        let generation = UUID(); webDialGeneration = generation
        webDialTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.webDialGeneration == generation { self.webDialTask = nil } }
            do {
                while self.session.voiceServiceChecking {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try Task.checkCancellation()
                    guard self.webDialGeneration == generation else { return }
                }
                try Task.checkCancellation()
                guard self.webDialGeneration == generation else { return }
                let checked = self.session.snapshot()["voiceServiceCheck"] as? [String: Any] ?? [:]
                guard checked["ok"] as? Bool == true, !self.session.pluginSessionActive,
                      self.session.connectedForCurrentNumber, self.session.cloudConsent else { return }
                self.session.dial(useAI: true)
            } catch { /* Cancellation never resumes a delayed dial. */ }
        }
    }
    private func cancelWebDial() {
        webDialGeneration = UUID(); webDialTask?.cancel(); webDialTask = nil
        session.cancelVoiceServiceCheck()
    }

    func saveConsoleSettings() throws {
        let settings = ConsoleSettings(phone: session.phone, number: session.number, instructions: session.instructions,
            mode: session.mode.rawValue, maximumSeconds: session.maximumSeconds, voice: session.voice.rawValue)
        let url = directory.appendingPathComponent("console-settings.json")
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func loadConsoleSettings() {
        let url = directory.appendingPathComponent("console-settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 32_768 else { throw PhonePeerError.invalidIdentity }
            let settings = try JSONDecoder().decode(ConsoleSettings.self, from: Data(contentsOf: url))
            guard (1...2).contains(settings.schema), settings.number.isEmpty || PhoneNumber.valid(settings.number),
                  settings.instructions.utf8.count <= 6000, (0...Int(Int32.max)).contains(settings.maximumSeconds),
                  let mode = ConversationMode(rawValue: settings.mode), let voice = RealtimeVoice(rawValue: settings.voice) else { throw PhonePeerError.invalidIdentity }
            if let phone = settings.phone { try session.configurePhone(phone) }
            session.number = settings.number; session.instructions = settings.instructions; session.mode = mode
            session.maximumSeconds = settings.schema < 2 ? 0 : settings.maximumSeconds; session.voice = voice
            // Consent, user voice attestation, calls and connections are never restored.
        } catch { lastError = "本机配置无法读取，请在控制台重新选择手机并保存设置。" }
    }
}
