import Foundation

enum ConversationMode: String, CaseIterable, Identifiable {
    case codexManaged = "codex_voice"
    case builtinVoice = "builtin_voice"
    case openaiRealtime = "openai_realtime"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codexManaged: return "Codex 自动语音（实验）"
        case .builtinVoice: return "ChatGPT / Codex 内置语音"
        case .openaiRealtime: return "OpenAI Realtime API"
        }
    }
}
