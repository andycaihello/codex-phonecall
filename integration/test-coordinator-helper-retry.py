#!/usr/bin/env python3
"""Exercise bounded helper-open retry with fake Bluetooth and no phone access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fakes = (root / 'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
fakes = fakes.replace(
    '    var onEvent: (([String: Any]) -> Void)?, onExit:',
    '    static var latest: BluetoothControlProcess?\n'
    '    init() { Self.latest = self }\n'
    '    var requests: [String] = [], openFailure = ""\n'
    '    var onEvent: (([String: Any]) -> Void)?, onExit:', 1)
fakes = fakes.replace(
    'FakeCounts.bluetooth += 1; return [:] }',
    '''FakeCounts.bluetooth += 1; requests.append(op)
        if op == "helper_connect" && requests.filter({ $0 == op }).count == 1 && !openFailure.isEmpty {
            throw BridgeError(openFailure)
        }
        if op == "helper_status" { throw BridgeError("offline-stop-after-helper-open") }
        return [:] }''', 1)

checks = '''
@main struct HelperRetryChecks {
 @MainActor static func main() async throws {
  for (failure, expectedOpens) in [
   ("蓝牙操作未完成：RFCOMM_open_callback_without_channel; status=0; channelID=8", 2),
   ("蓝牙操作未完成：RFCOMM_socket_identity_rejected", 1)
  ] {
   let c = CallSessionCoordinator(), bt = BluetoothControlProcess.latest!
   try c.configurePhone(PhonePeerConfiguration(address:"AA:BB:CC:DD:EE:FF",name:"Offline Phone"))
   c.number = "12345"; bt.openFailure = failure
   c.connect()
   let deadline = ProcessInfo.processInfo.systemUptime + 8
   while c.busy && ProcessInfo.processInfo.systemUptime < deadline {
    try await Task.sleep(nanoseconds: 20_000_000)
   }
   precondition(!c.busy && !c.connected)
   precondition(bt.requests.filter { $0 == "helper_connect" }.count == expectedOpens)
   precondition(!bt.requests.contains("dial") && !bt.requests.contains("answer"))
  }
  print("PASS: nil RFCOMM callback retries once; unrelated errors do not retry or dial")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-helper-retry-offline-') as temporary:
    build = Path(temporary)
    (build / 'Checks.swift').write_text(fakes + checks)
    subprocess.run(['swiftc', '-emit-library', '-emit-module', '-module-name', 'BridgeCore',
                    *[str(root / 'Sources/BridgeCore' / name) for name in
                      ['Protocol.swift', 'RealtimeProtocol.swift', 'PhoneNumber.swift',
                       'PhonePeerConfiguration.swift', 'ManagedAudioSegmenter.swift']],
                    '-emit-module-path', str(build / 'BridgeCore.swiftmodule'),
                    '-o', str(build / 'libBridgeCore.dylib')], check=True, timeout=60)
    subprocess.run(['swiftc', '-parse-as-library', '-I', temporary, '-L', temporary, '-lBridgeCore',
                    '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
                    str(root / 'Sources/PhoneBridge/CallSessionCoordinator.swift'),
                    str(root / 'Sources/PhoneBridge/CodexVoiceCaptions.swift'),
                    str(root / 'Sources/PhoneBridge/ConversationMode.swift'),
                    str(build / 'Checks.swift'), '-o', str(build / 'checks')], check=True, timeout=60)
    subprocess.run([str(build / 'checks')], check=True, timeout=20)
