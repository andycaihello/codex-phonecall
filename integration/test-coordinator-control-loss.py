#!/usr/bin/env python3
"""Run the production connection-loss flow against fake transports, never devices."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
fakes=(root/'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
fakes=fakes.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '    static var latest: BluetoothControlProcess?\n    init() { Self.latest = self }\n    var requests: [String] = []\n    var onEvent: (([String: Any]) -> Void)?, onExit:',1)
fakes=fakes.replace('FakeCounts.bluetooth += 1; return [:] }', 'FakeCounts.bluetooth += 1; requests.append(op); if op == "helper_status" { throw BridgeError("offline-link-lost") }; return [:] }',1)
source=(root/'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text()+'''
@MainActor extension CallSessionCoordinator {
    func offlineStartMonitor(submitted: Bool) {
        connected = true; systemDialInFlight = submitted; callPending = submitted
        state = ["helperCallState": 0]
        beginMonitoring()
    }
    func offlineFailedDial() {
        connected = false; ownDial = true; callPending = true
        phoneStateUnknown = true; state = [:]
    }
    func offlineRetiredRingingLink() {
        incomingMode = true; connected = true; callPending = true
        state = ["call": 0, "setup": 1, "ownIncoming": false, "incomingAvailable": true, "incomingID": "1"]
        bluetooth.onExit?(1)
        bluetooth.onEvent?(["event": "cleanup_finished", "state": ["shutdown": true,
            "call": 0, "setup": 1, "ownIncoming": false, "incomingAvailable": true, "incomingID": "1"]])
    }
}
'''
main='''
@main struct ControlLossChecks {
 @MainActor static func main() async throws {
  var checks = 0
  for submitted in [false, true] {
   let c = CallSessionCoordinator()
   let bt = BluetoothControlProcess.latest!
   bt.isRunning = true
   c.offlineStartMonitor(submitted: submitted)
   try await Task.sleep(nanoseconds: 2_700_000_000)
   precondition(!c.connected && !c.busy && !c.callPending && !c.callActive)
   precondition(c.phoneStateUnknown == submitted)
   precondition(!c.builtinVoiceConfirmed)
   precondition(bt.requests.contains("helper_stop") && bt.requests.contains("disconnect"))
   precondition(!bt.requests.contains("helper_dial_ui") && !bt.requests.contains("dial"))
   checks += 5
   let count = bt.requests.count
   try await Task.sleep(nanoseconds: 250_000_000)
   precondition(count == bt.requests.count)
   checks += 1
  }
  let failedDial = CallSessionCoordinator()
  failedDial.offlineFailedDial()
  failedDial.hangup()
  try await Task.sleep(nanoseconds: 250_000_000)
  precondition(!failedDial.busy && !failedDial.callActive && !failedDial.callPending)
  precondition(failedDial.phoneStateUnknown)
  precondition(failedDial.error.contains("挂断尚未确认"))
  checks += 3
  let retiredRing = CallSessionCoordinator()
  let serviceStops = FakeCounts.localServiceStops
  retiredRing.offlineRetiredRingingLink()
  precondition(!retiredRing.connected && !retiredRing.callPending && !retiredRing.callActive)
  precondition(!retiredRing.phoneStateUnknown && retiredRing.incomingCallID == nil)
  precondition(FakeCounts.localServiceStops == serviceStops + 1)
  checks += 3
  print("PASS \\(checks) coordinator control-loss checks; no device calls")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-control-loss-offline-') as d:
 b=Path(d);(b/'Coordinator.swift').write_text(source);(b/'Checks.swift').write_text(fakes+main)
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*[str(root/'Sources/BridgeCore'/n) for n in ['Protocol.swift','RealtimeProtocol.swift','PhoneNumber.swift','PhonePeerConfiguration.swift']],'-emit-module-path',str(b/'BridgeCore.swiftmodule'),'-o',str(b/'libBridgeCore.dylib')],check=True,timeout=60)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker','@executable_path',str(b/'Coordinator.swift'),str(root/'Sources/PhoneBridge/CodexVoiceCaptions.swift'),str(root/'Sources/PhoneBridge/ConversationMode.swift'),str(b/'Checks.swift'),'-o',str(b/'checks')],check=True,timeout=60)
 subprocess.run([str(b/'checks')],check=True,timeout=15)
