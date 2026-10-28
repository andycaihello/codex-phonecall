import Foundation

public struct BridgeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum CallInput {
    public static func number(_ value: String) throws -> String {
        // Never pass arbitrary AT commands, dial pauses, USSD, or redial through.
        let number = value.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        let digits = number.hasPrefix("+") ? number.dropFirst() : number[...]
        guard (3...20).contains(digits.count), digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            throw BridgeError("号码只能包含 3–20 位数字，可带国际区号 +。")
        }
        return number
    }
    public static func dtmf(_ value: String) throws -> String {
        guard value.count == 1, value.range(of: "^[0-9*#A-D]$", options: .regularExpression) != nil else {
            throw BridgeError("每次发送一个电话按键：0–9、*、# 或 A–D。")
        }
        return value
    }
}

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public static let maximumSize = 65_536
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= maximumSize else { throw BridgeError("请求过大") }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw BridgeError("无效请求头")
        }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/") else {
            throw BridgeError("无效 HTTP 请求")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw BridgeError("无效请求头")
            }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw BridgeError("重复请求头") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw BridgeError("不支持分块请求") }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int(lengthText), count <= maximumSize - separator.upperBound else {
            throw BridgeError("无效请求长度")
        }
        guard data.count >= separator.upperBound + count else { return nil }
        guard data.count == separator.upperBound + count else { throw BridgeError("不支持流水线请求") }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: Data(data[separator.upperBound...]))
    }
}

public struct CallState: Codable {
    public var connected = false
    public var scoConnected = false
    public var active = false
    public var setup = 0
    public var held = 0
    public init() {}
    public var label: String {
        if !connected { return "未连接免提服务" }
        if held > 0 { return "通话保持" }
        if active { return "通话已建立（不代表已接通人工客服）" }
        switch setup {
        case 1: return "来电响铃"
        case 2: return "正在拨号"
        case 3: return "对方振铃"
        default: return "免提服务已连接，空闲"
        }
    }
}
