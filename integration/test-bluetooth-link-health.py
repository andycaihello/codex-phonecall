#!/usr/bin/env python3
"""Real coordinator monitor with fake radio/OS: helper health alone is insufficient."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
f=(root/'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
f=f.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '    static var latest: BluetoothControlProcess?\n    init() { Self.latest = self }\n    var requests: [String] = []\n    var onEvent: (([String: Any]) -> Void)?, onExit:',1)
f=f.replace('FakeCounts.bluetooth += 1; return [:] }','FakeCounts.bluetooth += 1; requests.append(op); return [:] }',1)
src=(root/'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text()+'''
@MainActor extension CallSessionCoordinator {
 func offlineHealthSetup() {
  number="12345";connectionNumber=number;connected=true
  state=["hfpAnchorMode":true,"hfpReady":true,"call":0,"setup":0,"held":0]
  beginMonitoring()
 }
}
'''
main='''
@main struct LinkHealthChecks {
 @MainActor static func main() async throws {
  let c=CallSessionCoordinator(), bt=BluetoothControlProcess.latest!
  bt.isRunning=true;c.offlineHealthSetup()
  try await Task.sleep(nanoseconds:2_150_000_000)
  precondition(c.connected && c.bluetoothCallControlReady && c.error.isEmpty)
  precondition(bt.requests.contains("helper_status"))
  bt.onEvent?(["state":["hfpAnchorMode":false,"hfpReady":false,"call":0,"setup":0,"held":0,"ownDial":false,"idleVerified":false]])
  precondition(!c.bluetoothCallControlReady)
  try await Task.sleep(nanoseconds:2_150_000_000)
  precondition(!c.connected && !c.busy && !c.phoneStateUnknown)
  precondition(c.error.contains("电话控制通道"))
  precondition(bt.requests.contains("helper_stop") && bt.requests.contains("disconnect"))
  precondition(!bt.requests.contains("dial") && !bt.requests.contains("helper_dial_ui"))
  precondition(FakeCounts.starts == 0 && FakeKeyState.count() == 0)
  print("PASS 8 Bluetooth link-health checks; fake transports, no calls or API")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-health-offline-') as d:
 b=Path(d);(b/'Coordinator.swift').write_text(src);(b/'Checks.swift').write_text(f+main)
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*[str(root/'Sources/BridgeCore'/n) for n in ['Protocol.swift','RealtimeProtocol.swift','PhoneNumber.swift','PhonePeerConfiguration.swift']],'-emit-module-path',str(b/'BridgeCore.swiftmodule'),'-o',str(b/'libBridgeCore.dylib')],check=True,timeout=60)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker',d,str(b/'Coordinator.swift'),str(root/'Sources/PhoneBridge/ConversationMode.swift'),str(b/'Checks.swift'),'-o',str(b/'checks')],check=True,timeout=60)
 subprocess.run([str(b/'checks')],check=True,timeout=15)
