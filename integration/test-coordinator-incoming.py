#!/usr/bin/env python3
"""Actual coordinator against fake phone/audio; never connects a physical device."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
fake = (root / 'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
fake = fake.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '''    static var latest: BluetoothControlProcess?
    init() { Self.latest = self }
    var requests: [String] = [], rejectAnswer = false
    var observed: [String: Any] = [:]
    var onEvent: (([String: Any]) -> Void)?, onExit:''', 1)
fake = fake.replace('FakeCounts.bluetooth += 1; return [:] }', '''FakeCounts.bluetooth += 1; requests.append(op)
        if op == "refresh" { onEvent?(["state":observed]) }
        if op == "answer" {
            precondition(fields["incoming_id"] as? String == "1")
            if rejectAnswer { throw BridgeError("synthetic changed caller; ATA not sent") }
            observed=["hfpAnchorMode":true,"hfpReady":true,"call":1,"setup":0,"held":0,
                      "ownIncoming":true,"ownDial":false,"idleVerified":false,"incomingAvailable":false,"incomingID":"0"]
            onEvent?(["state":observed])
        }
        if op == "hangup" {
            observed=["hfpAnchorMode":true,"hfpReady":true,"call":0,"setup":0,"held":0,
                      "ownIncoming":false,"ownDial":false,"idleVerified":true,"incomingAvailable":false,"incomingID":"0"]
            onEvent?(["state":observed])
        }
        return [:] }''', 1)
fake = fake.replace('func start() { FakeCounts.pcm += 1 }', 'func start() { FakeCounts.pcm += 1; running = true }', 1)
source = (root / 'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text() + '''
@MainActor extension CallSessionCoordinator {
    func incomingFixture(connectionIncoming: Bool = true) {
        incomingMode=true; self.connectionIncoming=connectionIncoming; connected=true; mode = .builtinVoice
        phone=try! PhonePeerConfiguration(address:"AA:BB:CC:DD:EE:FF",name:"Offline Phone")
        state=["hfpAnchorMode":true,"hfpReady":true,"call":0,"setup":1,"held":0,
               "ownDial":false,"ownIncoming":false,"incomingAvailable":true,"incomingID":"1"]
        callPending=true; pluginSessionActive=true
    }
}
'''
main = '''
@main struct IncomingChecks {
    @MainActor static func main() async throws {
        var checks=0
        for reject in [false,true] {
            let c=CallSessionCoordinator(), bt=BluetoothControlProcess.latest!
            c.incomingFixture();bt.isRunning=true;bt.rejectAnswer=reject
            bt.observed=c.snapshot()["bluetoothState"] as! [String:Any]
            c.continuousVoice.installed=true
            try c.prepareBuiltinVoice()
            precondition(c.continuousVoice.active && !c.callActive && bt.requests.isEmpty);checks += 1
            do { try c.answerIncoming(id:"1"); preconditionFailure("requires voice confirmation") } catch {}
            c.builtinVoiceConfirmed=true
            do { try c.answerIncoming(id:"2"); preconditionFailure("must bind original call") } catch {}
            precondition(bt.requests.isEmpty);checks += 2
            c.dial(useAI:true,fromPlugin:true)
            precondition(!c.error.isEmpty && bt.requests.isEmpty);checks += 1
            try c.answerIncoming(id:"1")
            try await Task.sleep(nanoseconds:150_000_000)
            precondition(bt.requests.filter{$0 == "answer"}.count == 1 && !bt.requests.contains("dial"));checks += 1
            if reject {
                precondition(!c.callActive && !c.voiceActive && !bt.requests.contains("hangup"));checks += 1
            } else {
                precondition(c.callActive && c.ownsActiveCall && c.voiceActive && c.continuousVoice.target == "phone");checks += 1
                do { try c.answerIncoming(id:"1"); preconditionFailure("cannot re-answer") } catch {}
                c.outgoingCaptions.onTranscript?("ai","你好，我是 AI 助手",true)
                c.builtinCaptions.onTranscript?("caller","你好",true)
                precondition(c.transcript.count == 2);checks += 2
                c.hangup();try await Task.sleep(nanoseconds:150_000_000)
                precondition(!c.callActive && !c.callPending && !c.voiceActive && c.continuousVoice.target == "owner");checks += 1
                precondition(bt.requests.filter{$0 == "hangup"}.count == 1 && c.continuousVoice.active);checks += 1
            }
        }
        let monitored=CallSessionCoordinator()
        monitored.incomingFixture(connectionIncoming:false) // The same HFP link may have been opened for a scoped outgoing task.
        precondition(monitored.connectedForCurrentNumber && monitored.bluetoothCallControlReady && monitored.incomingCallID == "1")
        checks += 1
        precondition(FakeCounts.starts == 0 && FakeKeyState.count() == 0);checks += 1
        print("PASS: \\(checks) incoming coordinator checks; fake phone/audio, no USB or API")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-incoming-offline-') as temporary:
    build = Path(temporary)
    (build / 'Coordinator.swift').write_text(source)
    (build / 'Checks.swift').write_text(fake + main)
    subprocess.run(['swiftc', '-emit-library', '-emit-module', '-module-name', 'BridgeCore',
                    *[str(root / 'Sources/BridgeCore' / n) for n in
                      ['Protocol.swift', 'RealtimeProtocol.swift', 'PhoneNumber.swift', 'PhonePeerConfiguration.swift']],
                    '-emit-module-path', str(build / 'BridgeCore.swiftmodule'),
                    '-o', str(build / 'libBridgeCore.dylib')], check=True, timeout=60)
    subprocess.run(['swiftc', '-parse-as-library', '-I', temporary, '-L', temporary, '-lBridgeCore',
                    '-Xlinker', '-rpath', '-Xlinker', temporary, str(build / 'Coordinator.swift'),
                    str(root / 'Sources/PhoneBridge/CodexVoiceCaptions.swift'),
                    str(root / 'Sources/PhoneBridge/ConversationMode.swift'), str(build / 'Checks.swift'),
                    '-o', str(build / 'checks')], check=True, timeout=60)
    subprocess.run([str(build / 'checks')], check=True, timeout=15)
