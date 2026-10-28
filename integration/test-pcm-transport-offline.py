#!/usr/bin/env python3
"""Exercise PCM JSONL using socketpair only. Never launch the App or audio IO."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

CHECKS = r'''
extension PCMTransport {
    static func offlineChecks() async throws -> [String] {
        var names: [String] = []
        let unconfigured = PCMTransport()
        do {
            try await unconfigured.prepare(helperURL: URL(fileURLWithPath: "/nonexistent-offline-fixture.app"))
            preconditionFailure("unconfigured transport accepted prepare")
        } catch { precondition(unconfigured.cleanupVerified && unconfigured.directory == nil && unconfigured.pendingLaunches == 0) }
        names.append("unconfigured prepare rejects before private IPC or LaunchServices")
        let firstPhone = try PhonePeerConfiguration(address: "A1:B2:C3:D4:E5:F6", name: "Fixture Phone A")
        let secondPhone = try PhonePeerConfiguration(address: "12:34:56:78:90:AB", name: "另一个模拟手机")
        try unconfigured.configure(phone: firstPhone)
        precondition(PCMTransport.phoneArguments(firstPhone) == ["--phone-address", firstPhone.address, "--phone-name", firstPhone.name])
        try unconfigured.configure(phone: secondPhone)
        precondition(unconfigured.phone == secondPhone && PCMTransport.phoneArguments(secondPhone)[3] == secondPhone.name)
        names.append("explicit phone identity becomes structured native arguments without shell interpolation")
        func refuses(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        unconfigured.pendingLaunches = 1
        precondition(refuses { try unconfigured.configure(phone: firstPhone) } && refuses { try unconfigured.clearPhoneConfiguration() })
        unconfigured.pendingLaunches = 0; unconfigured.running = true
        precondition(refuses { try unconfigured.configure(phone: firstPhone) } && refuses { try unconfigured.clearPhoneConfiguration() })
        unconfigured.running = false
        names.append("pending launch and active IO reject changing or clearing phone identity")
        try unconfigured.clearPhoneConfiguration()
        precondition(unconfigured.phone == nil && unconfigured.cleanupVerified)
        names.append("forgetting phone clears previous native launch identity")
        var descriptors: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let bridge = PCMTransport()
        bridge.client = descriptors[0]; bridge.authenticated = true; bridge.helloVerified = true
        _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
        defer { bridge.stop(); Darwin.close(descriptors[1]) }
        func messages() throws -> [[String: Any]] {
            var received = Data(), bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.recv(descriptors[1], &bytes, bytes.count, 0)
                if count <= 0 { break }
                received.append(contentsOf: bytes.prefix(count))
            }
            return try received.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        }
        precondition(bridge.interrupt() == nil && bridge.generation == 0)
        let beforeReady = try messages(); precondition(beforeReady.isEmpty)
        names.append("authenticated but pre-ready interruption emits no clear command")
        bridge.running = true
        let first = RealtimeAudioChunk(responseID: "r1", itemID: "item1", contentIndex: 0, pcm16: Data([0, 0]))
        let second = RealtimeAudioChunk(responseID: "r1", itemID: "item1", contentIndex: 1, pcm16: Data([1, 0]))
        bridge.play(first)
        bridge.endPart(responseID: "r1", itemID: "item1", contentIndex: 0)
        bridge.endPart(responseID: "r1", itemID: "item1", contentIndex: 0)
        bridge.play(second)
        bridge.endResponse("r1"); bridge.endResponse("r1")
        let parts = try messages()
        precondition(parts.map { $0["op"] as! String } == ["output_audio", "output_end", "output_audio", "output_end"])
        precondition(parts[1]["content_index"] as? Int == 0 && parts[3]["content_index"] as? Int == 1)
        precondition(bridge.responseItems.isEmpty)
        names.append("multi-content parts end before next part with idempotent explicit and response fallback ends")
        bridge.lastPosition = .init(itemID: "heard", contentIndex: 1, playedMilliseconds: 37)
        let position = bridge.interrupt()
        precondition(position?.playedMilliseconds == 37 && bridge.generation == 1)
        bridge.play(.init(responseID: "r2", itemID: "new", contentIndex: 0, pcm16: Data([0, 0])))
        let beforeAck = try messages()
        precondition(beforeAck.count == 1 && beforeAck[0]["op"] as? String == "clear_output")
        bridge.handle(["type": "clear_ack", "generation": 0])
        let staleAck = try messages(); precondition(staleAck.isEmpty)
        bridge.handle(["type": "clear_ack", "generation": 1])
        let afterAck = try messages()
        precondition(afterAck.count == 1 && afterAck[0]["op"] as? String == "output_audio" && afterAck[0]["generation"] as? Int == 1)
        names.append("new generation audio waits for matching clear acknowledgement")
        precondition(bridge.lastPosition?.itemID == "heard")
        names.append("last consumed position is retained without growing per-item playback history")
        var failures = 0
        bridge.onFailure = { _ in failures += 1; bridge.stop(); _ = bridge.interrupt() }
        bridge.output = Data(repeating: 0, count: 1024 * 1024)
        bridge.send(["op": "start"])
        precondition(failures == 1 && !bridge.authenticated && bridge.client == -1)
        names.append("send backlog failure remains nonrecursive when cleanup interrupts playback")
        return names
    }
}
@main @MainActor struct PCMOfflineMain {
    static func main() async throws {
        let names = try await PCMTransport.offlineChecks()
        let report: [String: Any] = ["passed": true, "count": names.count, "checks": names,
                                    "appLaunches": 0, "audioDeviceOperations": 0, "apiRequests": 0]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        print(String(data: data, encoding: .utf8)!)
    }
}
'''


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required")
    with tempfile.TemporaryDirectory(prefix="phonebridge-pcm-offline-") as temporary:
        build = Path(temporary)
        # A temporary same-file extension can exercise private IPC state without
        # weakening production visibility or adding a production test command.
        source = build / "PCMTransportChecks.swift"
        source.write_text((root / "Sources/PhoneBridge/PCMTransport.swift").read_text() + CHECKS)
        subprocess.run([
            compiler, "-emit-library", "-emit-module", "-module-name", "BridgeCore",
            str(root / "Sources/BridgeCore/Protocol.swift"), str(root / "Sources/BridgeCore/RealtimeProtocol.swift"),
            str(root / "Sources/BridgeCore/PhonePeerConfiguration.swift"),
            "-emit-module-path", str(build / "BridgeCore.swiftmodule"), "-o", str(build / "libBridgeCore.dylib"),
        ], check=True, timeout=60)
        executable = build / "check"
        subprocess.run([
            compiler, "-parse-as-library", "-I", str(build), "-L", str(build), "-lBridgeCore",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path", str(source), "-o", str(executable),
        ], check=True, timeout=60)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise SystemExit(result.stderr)
        report = json.loads(result.stdout)
        (root / "integration/pcm-transport-offline-validation-20260908.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(result.stdout, end="")


if __name__ == "__main__":
    main()
