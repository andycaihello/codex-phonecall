import AppKit
import SwiftUI
import BridgeCore

// Explicit wrapper alias avoids resolving the SDK 27 State macro, whose
// compiler plugin is not bundled with the standalone Command Line Tools.
private typealias FormState<Value> = SwiftUI.State<Value>

struct IntegratedSessionView: View {
    @ObservedObject var session: CallSessionCoordinator
    @ObservedObject var model: BridgeModel
    @FormState private var apiKey = ""
    @FormState private var showConfiguration = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("通话桥").font(.system(size: 32, weight: .bold))
                        Text("蓝牙电话 · 自然语音对话").foregroundStyle(.secondary)
                    }
                    Spacer()
                        Text("0.5.7 · Codex 插件版").font(.caption).padding(8)
                        .background(.blue.opacity(0.09), in: Capsule())
                }
                HStack(spacing: 9) {
                    Circle().fill(session.connected ? .green : .secondary.opacity(0.4)).frame(width: 9, height: 9)
                    Text(session.status).font(.headline)
                    Spacer()
                    if session.busy { ProgressView().controlSize(.small) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("连接手机").font(.headline)
                        Text("先在手机打开通话桥并启动会话，再在这里连接。通话桥通过蓝牙准备电话音频，并在手机系统拨号界面填入本次号码。")
                            .foregroundStyle(.secondary)
                        HStack {
                            Label(session.phone?.name ?? "尚未选择手机", systemImage: "iphone")
                            Spacer()
                            Button("连接手机") { session.connect() }.disabled(session.busy || session.connected)
                            Button("断开") { session.disconnect() }.disabled(!session.connected && !session.busy)
                        }
                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("开始通话").font(.headline)
                        HStack {
                            TextField("电话号码", text: $session.number).textFieldStyle(.roundedBorder).frame(width: 200)
                                .disabled(session.pluginSessionActive || session.busy || session.callActive || session.callPending)
                            Button("仅拨号") { session.dial(useAI: false) }
                                .disabled(session.pluginSessionActive || !session.connected || session.busy || session.callActive || session.callPending)
                            Button("拨打并开始 AI 对话") { session.dial(useAI: true) }
                                .buttonStyle(.borderedProminent)
                                .disabled(session.pluginSessionActive || !session.connected || session.busy || session.callActive || session.callPending ||
                                    (session.mode == .openaiRealtime ? !session.cloudConsent : !session.builtinVoiceConfirmed))
                            Spacer()
                            Button("挂断", role: .destructive) { session.hangup() }
                                .disabled(!session.callActive && !session.callPending && !session.busy)
                        }
                        HStack {
                            Text("使用手机的默认拨号 SIM。本次连接只允许配置的一个号码；首次验证需在手机系统界面提交拨号和挂断。").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("立即停止 AI 发声") { session.interruptSpeech() }.disabled(!session.voiceActive)
                        }
                    }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox {
                    DisclosureGroup("自然语音设置", isExpanded: $showConfiguration) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("语音模式", selection: $session.mode) {
                                ForEach(ConversationMode.allCases) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                                .disabled(session.voiceActive || session.busy || session.pluginSessionActive || session.builtinRoute.active)
                            if session.mode == .openaiRealtime {
                            HStack {
                                Picker("声音", selection: $session.voice) {
                                    Text("Marin").tag(RealtimeVoice.marin)
                                    Text("Cedar").tag(RealtimeVoice.cedar)
                                }.frame(width: 240)
                                Picker("本次最长", selection: $session.maximumSeconds) {
                                    Text("1 分钟").tag(60); Text("3 分钟").tag(180); Text("5 分钟").tag(300)
                                }.frame(width: 200)
                            }.disabled(session.voiceActive || session.busy)
                            Text("使用 OpenAI 实时语音服务生成自然的回答声音。通话期间可以直接插话，AI 会停止发声并听你说。").foregroundStyle(.secondary)
                            HStack {
                                SecureField("OpenAI API 密钥", text: $apiKey).textFieldStyle(.roundedBorder)
                                Button("保存到钥匙串") {
                                    session.saveKey(apiKey)
                                    if session.keyConfigured { apiKey = "" }
                                }.disabled(apiKey.isEmpty || session.voiceActive || session.busy)
                                if session.keyConfigured {
                                    Label("已保存", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                    Button("移除密钥") { session.removeKey() }.disabled(session.voiceActive || session.busy)
                                }
                            }
                            HStack {
                                Button("创建 API 密钥") { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!) }
                                Button("查看 API 余额") { NSWorkspace.shared.open(URL(string: "https://platform.openai.com/settings/organization/billing/overview")!) }
                                Text("API 费用单独结算。").font(.caption).foregroundStyle(.secondary)
                            }.buttonStyle(.link)
                            Toggle("本轮允许将通话音频发送至 OpenAI，并使用 API 余额", isOn: $session.cloudConsent)
                                .disabled(session.voiceActive || session.busy)
                            HStack {
                                Button("检查语音服务") { session.checkVoiceService() }
                                    .disabled(!session.canCheckVoiceService)
                                if session.voiceServiceChecking {
                                    Button("取消检查") { session.cancelVoiceServiceCheck() }
                                }
                                Text("验证连接与会话配置，最长 20 秒。").font(.caption).foregroundStyle(.secondary)
                            }
                            if !session.voiceServiceStatus.isEmpty {
                                Text(session.voiceServiceStatus).font(.caption).foregroundStyle(.secondary)
                            }
                            } else {
                                Text("使用当前 Codex 对话的内置语音与对方连续交流，消耗订阅语音额度，无需 API 充值。电话对方的字幕在本机识别；AI 回答保留在 Codex 语音对话中。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("配置本机字幕权限") { Task { await session.builtinCaptions.requestPermissions() } }
                                        .disabled(session.busy || session.callActive || session.callPending)
                                    Button("准备内置语音音频") { model.run { try session.prepareBuiltinVoice() } }
                                        .disabled(!session.connected || session.busy || session.callActive || session.callPending)
                                    Button("语音已停止，恢复音频") { model.run { try session.restoreBuiltinAudio() } }
                                        .disabled(session.busy || session.callActive || session.callPending)
                                }
                                Text("准备音频会暂时将 Mac 的默认声音输出设为手机蓝牙通话接口。请在 Codex 的 Voice → Microphone 选择控制台配置的手机蓝牙输入，再启动当前对话的语音聊天。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Toggle("我已在当前 Codex 对话启动语音，并选择手机麦克风", isOn: $session.builtinVoiceConfirmed)
                                    .disabled(!session.connected || session.busy || session.callActive || session.callPending)
                                Text("挂断后先停止 Codex 语音聊天，再恢复音频。内置语音能否双向通话仍待实测。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            TextField("对话任务", text: $session.instructions, axis: .vertical)
                                .lineLimit(3...5).textFieldStyle(.roundedBorder).disabled(session.voiceActive || session.busy || session.pluginSessionActive)
                        }.padding(.top, 12)
                    }.padding(9)
                }
                if !session.error.isEmpty {
                    Label(session.error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)
                }
                HStack {
                    Text("实时对话").font(.headline)
                    CaptionWebLink(server: model.captionWeb)
                    Spacer()
                    Text("字幕可能修订，AI 字幕表示生成内容。").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 15) {
                    if session.transcript.isEmpty {
                        Text(session.mode == .builtinVoice ? "通话开始后显示对方的话。AI 回答请看当前 Codex 语音对话。" : "通话开始后，这里会显示对方的话和 AI 的回答。")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(session.transcript) { line in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(line.role + (line.final ? "" : " · 转写中")).font(.caption).foregroundStyle(.secondary)
                            Text(line.text).font(.system(size: 19)).textSelection(.enabled)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.role == "AI" ? Color.blue.opacity(0.07) : Color.gray.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup("运行记录") {
                    Text(session.events.suffix(20).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    HStack {
                        Button("导出诊断") { model.run { _ = try model.report() } }
                        Button("打开本机目录") { NSWorkspace.shared.open(model.directory) }
                    }
                }
            }.padding(28)
        }
    }
}

private struct CaptionWebLink: View {
    @ObservedObject var server: CaptionWebServer
    var body: some View {
        HStack(spacing: 8) {
            Button("打开实时字幕网页") {
                if let url = server.url { NSWorkspace.shared.open(url) }
            }.disabled(server.url == nil)
            if !server.error.isEmpty {
                Text(server.error).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
