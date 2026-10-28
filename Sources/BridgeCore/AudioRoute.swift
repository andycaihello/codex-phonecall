import Foundation

public enum AudioRouteMode: String, Codable, CaseIterable, Sendable {
    case usb = "usb"
    case bluetooth = "bluetooth"
}

public enum AudioTransport: String, Codable {
    case usb, bluetooth, other
}

public struct AudioEndpoint {
    public let id: UInt32
    public let uid: String
    public let transport: AudioTransport
    public let inputs: Int
    public let outputs: Int

    public init(id: UInt32, uid: String, transport: AudioTransport, inputs: Int, outputs: Int) {
        self.id = id; self.uid = uid; self.transport = transport
        self.inputs = inputs; self.outputs = outputs
    }
}

public enum AudioRoutePolicy {
    public static func validate(mode: AudioRouteMode, input: AudioEndpoint, output: AudioEndpoint) throws {
        guard input.id != 0, output.id != 0, !input.uid.isEmpty, !output.uid.isEmpty,
              input.inputs > 0, output.outputs > 0 else {
            throw BridgeError("所选设备没有可用的双向音频通道。")
        }
        switch mode {
        case .usb:
            guard input.transport == .usb, output.transport == .usb,
                  input.id == output.id, input.uid == output.uid else {
                throw BridgeError("USB 模式需要选择同一台具备输入和输出的外置 USB 音频接口。")
            }
        case .bluetooth:
            guard input.transport == .bluetooth, output.transport == .bluetooth else {
                throw BridgeError("蓝牙模式需要选择手机对应的蓝牙输入和输出。")
            }
        }
    }
}
