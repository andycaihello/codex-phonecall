#!/usr/bin/env python3
"""Exercise real async dialer orchestration with fake OS and radio dependencies."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
f=(root/'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
f=f.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '    static var latest: BluetoothControlProcess?\n    init() { Self.latest = self }\n    var scenario = "failed", requests: [String] = []\n    var onEvent: (([String: Any]) -> Void)?, onExit:',1)
f=f.replace('FakeCounts.bluetooth += 1; return [:] }','''FakeCounts.bluetooth += 1; requests.append(op)
        onEvent?(["state": ["helperCallState": scenario == "offhook" && op == "helper_status" ? 2 : 0, "idleVerified": false, "ownDial": false]])
        if op == "helper_dial_ui" { return ["helper": ["dialerStage": scenario == "bad-receipt" ? "idle" : "requested", "dialerRequestId": "owned"]] }
        if op == "helper_status" { return ["helper": ["dialerStage": scenario == "failed" ? "failed" : "submitted", "dialerRequestId": scenario == "stale" ? "other" : "owned", "dialerError": "offline-dialer-error"]] }
        return [:] }''',1)
source=(root/'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text()+'''
@MainActor extension CallSessionCoordinator {
 func offlineDialSetup() {
  number = "12345"; connectionNumber = number; connected = true
  state = ["helperCallState": 0]
 }
}
'''
main='''
@main struct DialerChecks {
 @MainActor static func main() async throws {
  var checks=0
  for scenario in ["bad-receipt", "failed", "stale", "submitted", "offhook"] {
   let c=CallSessionCoordinator(); let bt=BluetoothControlProcess.latest!
   bt.isRunning=true; bt.scenario=scenario; c.offlineDialSetup()
   let pcmBefore = FakeCounts.pcm
   c.dial(useAI:false,systemDialerDiagnostic:true)
   try await Task.sleep(nanoseconds:250_000_000)
   precondition(bt.requests.filter{$0 == "helper_dial_ui"}.count == 1)
   precondition(!c.voiceActive)
   if scenario == "offhook" {
    precondition(c.callActive && !c.busy && FakeCounts.pcm == pcmBefore)
    bt.scenario = "submitted"
    bt.onEvent?(["state": ["helperCallState": 0, "idleVerified": false, "ownDial": false]])
    c.disconnect();try await Task.sleep(nanoseconds:150_000_000)
   } else if scenario == "submitted" {
    precondition(c.callPending && c.busy && c.dialerStage == "submitted")
    precondition(c.status.contains("核对手机页面"))
    c.disconnect();try await Task.sleep(nanoseconds:150_000_000)
   } else { precondition(!c.connected && !c.busy && !c.error.isEmpty) }
   precondition(!c.callPending && !c.callActive)
   precondition(bt.requests.contains("helper_stop") && bt.requests.contains("disconnect"))
   checks += 5
  }
  let c=CallSessionCoordinator();let bt=BluetoothControlProcess.latest!
  c.offlineDialSetup();c.phoneStateUnknown=true;c.dial(useAI:false,systemDialerDiagnostic:true)
  try await Task.sleep(nanoseconds:50_000_000)
  precondition(bt.requests.isEmpty);checks += 1
  print("PASS \\(checks) system dialer orchestration checks; no device calls")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-dialer-offline-') as d:
 b=Path(d);(b/'Coordinator.swift').write_text(source);(b/'Checks.swift').write_text(f+main)
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*[str(root/'Sources/BridgeCore'/n) for n in ['Protocol.swift','RealtimeProtocol.swift','PhoneNumber.swift','PhonePeerConfiguration.swift']],'-emit-module-path',str(b/'BridgeCore.swiftmodule'),'-o',str(b/'libBridgeCore.dylib')],check=True,timeout=60)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker','@executable_path',str(b/'Coordinator.swift'),str(root/'Sources/PhoneBridge/ConversationMode.swift'),str(b/'Checks.swift'),'-o',str(b/'checks')],check=True,timeout=60)
 subprocess.run([str(b/'checks')],check=True,timeout=15)
