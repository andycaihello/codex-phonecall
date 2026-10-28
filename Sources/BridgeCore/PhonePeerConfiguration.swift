import Foundation

/// A user-selected paired device. Exact audio identities remain bound to this
/// address; selecting a different device never permits a microphone fallback.
public struct PhonePeerConfiguration: Codable, Equatable, Sendable {
    public let address: String
    public let name: String
    public var inputUID: String { address.replacingOccurrences(of: ":", with: "-") + ":input" }
    public var outputUID: String { address.replacingOccurrences(of: ":", with: "-") + ":output" }

    public init(address: String, name: String) throws {
        let normalized = address.uppercased().replacingOccurrences(of: "-", with: ":")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        let hex = Set("0123456789ABCDEF".utf8)
        guard parts.count == 6, parts.allSatisfy({ $0.utf8.count == 2 && $0.utf8.allSatisfy { hex.contains($0) } }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128, !name.hasPrefix("--"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PhonePeerError.invalidIdentity
        }
        self.address = normalized; self.name = name
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(address: values.decode(String.self, forKey: .address), name: values.decode(String.self, forKey: .name))
    }
    private enum CodingKeys: String, CodingKey { case address, name }
}

public enum PhonePeerError: LocalizedError {
    case invalidIdentity
    public var errorDescription: String? { "所选手机的蓝牙身份无效，请重新读取已配对设备。" }
}
