#!/usr/bin/env python3
"""Exercise HFP dialing/cleanup with fake radio, audio, Speech and Keychain."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
f=(root/'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
f=f.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '    static var latest: BluetoothControlProcess?\n    init() { Self.latest = self }\n    var requests: [String] = [], failDial = false\n    var onEvent: (([String: Any]) -> Void)?, onExit:',1)
f=f.replace('FakeCounts.bluetooth += 1; return [:] }','''FakeCounts.bluetooth += 1; requests.append(op)
        if op == "helper_status" { return ["helper": ["remainingSeconds":900]] }
        if op == "dial" {
            if failDial { throw BridgeError("synthetic dial rejected") }
            onEvent?(["state": ["call": 0, "setup": 2, "held": 0, "ownDial": true, "idleVerified": false]])
            try await Task.sleep(nanoseconds:20_000_000)
            onEvent?(["state": ["call": 1, "setup": 0, "held": 0, "ownDial": true, "idleVerified": false]])
        }
        if op == "hangup" {
            onEvent?(["state": ["call": 0, "setup": 0, "held": 0, "ownDial": false, "idleVerified": true]])
        }
        return [:] }''',1)
f=f.replace('func start() { FakeCounts.pcm += 1 }', 'func start() { FakeCounts.pcm += 1; running = true }', 1)
src=(root/'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text()+'''
@MainActor extension CallSessionCoordinator {
 func offlineBluetoothSetup(ready:Bool, callNumber:String="12345") {
  number=callNumber;connectionNumber=number;connected=true;mode = .builtinVoice
  phone=try! PhonePeerConfiguration(address:"AA:BB:CC:DD:EE:FF",name:"Offline Phone")
  state=["hfpAnchorMode":ready,"hfpReady":ready,"call":0,"setup":0,"held":0]
 }
 func offlineReadOnlyProbeSetup() { offlineBluetoothSetup(ready:true); readOnlyProbeInterval=0.25 }
}
'''
main='''
@main struct BluetoothDialChecks {
 @MainActor static func main() async throws {
  var checks=0
  let missing=CallSessionCoordinator(), mb=BluetoothControlProcess.latest!
  missing.offlineBluetoothSetup(ready:false);mb.isRunning=true
  missing.dial(useAI:false);try await Task.sleep(nanoseconds:40_000_000)
  precondition(mb.requests.isEmpty && !missing.error.isEmpty);checks += 1
  let probe=CallSessionCoordinator(), pb=BluetoothControlProcess.latest!
  probe.offlineReadOnlyProbeSetup();pb.isRunning=true
  precondition(!probe.bluetoothCallControlReady)
  for flags in [(false,false,false),(true,false,false),(false,true,false),(false,false,true)] {
   probe.dial(useAI:flags.0, systemDialerDiagnostic:flags.1, localValidation:flags.2)
   precondition(!probe.error.isEmpty && pb.requests.isEmpty && !probe.callPending)
  }
  do { try probe.prepareBuiltinVoice(); preconditionFailure("probe must not route voice") } catch {}
  do { try probe.prepareAudioValidation(); preconditionFailure("probe must not capture") } catch {}
  checks += 7
  for rejected in [false,true] {
   let c=CallSessionCoordinator(), bt=BluetoothControlProcess.latest!
   c.offlineBluetoothSetup(ready:true);bt.isRunning=true;bt.failDial=rejected
   let pcmBefore=FakeCounts.pcm
   c.dial(useAI:false)
   try await Task.sleep(nanoseconds:150_000_000)
   precondition(bt.requests.filter{$0 == "dial"}.count == 1)
   precondition(!bt.requests.contains("helper_dial_ui") && !bt.requests.contains("open_hsp"))
   checks += 2
   if !rejected {
    precondition(c.callActive && c.ownsActiveCall && !c.busy)
    precondition(!c.voiceActive && FakeCounts.pcm == pcmBefore)
    precondition(c.dialerStage == "bluetooth_submitted")
    checks += 3
    c.hangup();try await Task.sleep(nanoseconds:120_000_000)
    precondition(!c.callActive && !c.callPending && !c.busy)
    checks += 1
   } else { precondition(!c.connected && !c.busy && !c.error.isEmpty);checks += 1 }
   precondition(bt.requests.filter{$0 == "hangup"}.count == 1)
   precondition(!bt.requests.contains("helper_dial_ui"));checks += 2
   if !rejected { c.disconnect();try await Task.sleep(nanoseconds:120_000_000) }
  }
  let stalled=CallSessionCoordinator(), sb=BluetoothControlProcess.latest!
  stalled.offlineBluetoothSetup(ready:true); sb.isRunning=true
  stalled.continuousVoice.installed=true;try stalled.continuousVoice.start()
  stalled.continuousVoice.error="synthetic missing input frames"
  stalled.builtinVoiceConfirmed=true;stalled.dial(useAI:true)
  try await Task.sleep(nanoseconds:160_000_000)
  precondition(!sb.requests.contains("dial") && !sb.requests.contains("helper_dial_ui"))
  precondition(!stalled.callActive && !stalled.error.isEmpty);checks += 2
  let continuous=CallSessionCoordinator(), cb=BluetoothControlProcess.latest!
  continuous.offlineBluetoothSetup(ready:true); cb.isRunning=true
  continuous.continuousVoice.installed=true
  continuous.connected=false
  try continuous.prepareBuiltinVoice()
  precondition(continuous.continuousVoice.starts == 1 && continuous.builtinAudioReady && !continuous.builtinRoute.active && cb.requests.isEmpty)
  checks += 1
  for recipient in ["12345","67890"] {
   continuous.offlineBluetoothSetup(ready:true,callNumber:recipient)
   continuous.builtinVoiceConfirmed=true
   continuous.dial(useAI:true)
   try await Task.sleep(nanoseconds:180_000_000)
   precondition(continuous.callActive && continuous.continuousVoice.target == "phone")
   precondition(continuous.continuousVoice.active && continuous.continuousVoice.starts == 1)
   continuous.outgoingCaptions.onTranscript?("test-output", "你好", false)
   continuous.outgoingCaptions.onTranscript?("test-output", "你好，记得吃药", true)
   continuous.builtinCaptions.onTranscript?("test-remote", "好的", true)
   precondition(continuous.transcript.filter{$0.role == "AI"}.count == 1)
   precondition(continuous.transcript.first{$0.role == "AI"}?.text == "你好，记得吃药")
   precondition(continuous.transcript.first{$0.role == "AI"}?.final == true)
   precondition(continuous.transcript.contains{$0.role == "对方" && $0.text == "好的"})
   checks += 4
   let hangupsBefore=cb.requests.filter{$0 == "hangup"}.count
   continuous.builtinCaptions.onFailure?("synthetic decoder failure")
   continuous.outgoingCaptions.onFailure?("synthetic output decoder failure")
   precondition(continuous.callActive && continuous.voiceActive)
   precondition(cb.requests.filter{$0 == "hangup"}.count == hangupsBefore)
   precondition(!continuous.captionWarning.isEmpty && continuous.error.isEmpty)
   checks += 3
   continuous.hangup();try await Task.sleep(nanoseconds:140_000_000)
   precondition(!continuous.callActive && continuous.continuousVoice.target == "owner" && continuous.continuousVoice.active)
   precondition(continuous.continuousVoice.stops == 0)
   let captionCount=continuous.transcript.count
   continuous.outgoingCaptions.onTranscript?("late-output", "不得出现在下一通", true)
   precondition(continuous.transcript.count == captionCount)
   checks += 5
  }
  precondition(continuous.continuousVoice.suspends == 2 && continuous.continuousVoice.phoneSwitches == 2)
  try continuous.restoreBuiltinAudio()
  precondition(!continuous.continuousVoice.active && continuous.continuousVoice.stops == 1)
  checks += 2
  precondition(FakeCounts.starts == 0 && FakeKeyState.count() == 0);checks += 1
  print("PASS \\(checks) Bluetooth-only call checks; fake devices, no USB, no API")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-bt-dial-offline-') as d:
 b=Path(d);(b/'Coordinator.swift').write_text(src);(b/'Checks.swift').write_text(f+main)
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*[str(root/'Sources/BridgeCore'/n) for n in ['Protocol.swift','RealtimeProtocol.swift','PhoneNumber.swift','PhonePeerConfiguration.swift']],'-emit-module-path',str(b/'BridgeCore.swiftmodule'),'-o',str(b/'libBridgeCore.dylib')],check=True,timeout=60)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker',d,str(b/'Coordinator.swift'),str(root/'Sources/PhoneBridge/ConversationMode.swift'),str(b/'Checks.swift'),'-o',str(b/'checks')],check=True,timeout=60)
 subprocess.run([str(b/'checks')],check=True,timeout=15)
