import Foundation
import Security
import LocalAuthentication
import BridgeCore

enum VoiceAPIKeychain {
    private static let service = "cn.andy.phonebridge.openai-realtime"
    private static let account = "api-key"
    /// Metadata only; never returns the key or opens a Keychain permission prompt.
    static func isPresentWithoutPrompt() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
    static func load() throws -> String? {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw BridgeError("无法读取钥匙串中的 API 密钥。")
        }
        return key
    }
    static func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-"), trimmed.utf8.count >= 20, trimmed.utf8.count <= 1024,
              !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw BridgeError("API 密钥格式不正确。")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = Data(trimmed.utf8)
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw BridgeError("API 密钥未能保存到钥匙串。") }
        } else if status != errSecSuccess { throw BridgeError("API 密钥未能更新。") }
    }
    static func delete() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError("API 密钥未能移除。") }
    }
}
