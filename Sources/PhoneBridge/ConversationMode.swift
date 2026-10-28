import Foundation

enum ConversationMode: String, CaseIterable, Identifiable {
    case builtinVoice = "builtin_voice"
    case openaiRealtime = "openai_realtime"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builtinVoice: return "ChatGPT / Codex 内置语音"
        case .openaiRealtime: return "OpenAI Realtime API"
        }
    }
}
