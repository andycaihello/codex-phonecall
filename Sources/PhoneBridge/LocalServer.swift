import Foundation
import Network
import BridgeCore

final class LocalServer {
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var connections: [UUID: NWConnection] = [:]
    private let runtime: URL
    var handler: ([String: Any]) throws -> [String: Any] = { _ in [:] }
    var log: (String) -> Void = { _ in }

    init(directory: URL) { runtime = directory.appendingPathComponent("runtime.json") }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener?.port else { return }
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["port": port.rawValue, "token": self.token,
                        "pid": ProcessInfo.processInfo.processIdentifier, "version": "0.3.0"])
                    try? FileManager.default.removeItem(at: self.runtime)
                    guard FileManager.default.createFile(atPath: self.runtime.path, contents: data,
                        attributes: [.posixPermissions: 0o600]) else { throw BridgeError("无法写入本机控制凭据。") }
                    self.log("本机控制接口已就绪（仅监听 127.0.0.1）。")
                } catch { self.log(error.localizedDescription); self.stop() }
            case .failed(let error): self.log("控制接口启动失败：\(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 8 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: .main)
            self.receive(connection, id: id, data: Data())
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.connections.removeValue(forKey: id)?.cancel()
            }
        }
        listener.start(queue: .main)
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] next, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = data
            if let next { accumulated.append(next) }
            do {
                if let request = try HTTPRequest.parse(accumulated) {
                    guard request.headers["authorization"] == "Bearer \(self.token)" else {
                        self.respond(connection, id: id, status: 401, body: ["error": "认证失败"]); return
                    }
                    guard request.headers["origin"] == nil,
                          request.method == "POST", request.path == "/command",
                          request.headers["content-type"] == "application/json" else {
                        self.respond(connection, id: id, status: 400, body: ["error": "仅接受本机工具的 JSON 指令"]); return
                    }
                    guard let command = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                        throw BridgeError("指令必须是 JSON 对象")
                    }
                    let result = try self.handler(command)
                    self.respond(connection, id: id, status: 200, body: ["ok": true, "result": result])
                } else if complete || error != nil {
                    self.connections.removeValue(forKey: id)?.cancel()
                } else { self.receive(connection, id: id, data: accumulated) }
            } catch {
                self.respond(connection, id: id, status: 400, body: ["ok": false, "error": error.localizedDescription])
            }
        }
    }
    private func respond(_ connection: NWConnection, id: UUID, status: Int, body: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : "Bad Request"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(json)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: id)
        })
    }
    func stop() {
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        if let data = try? Data(contentsOf: runtime),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: runtime)
        }
    }
}
