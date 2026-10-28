#!/usr/bin/env python3
"""Local transport validation with fake radios/audio/Speech; no system IO."""
from pathlib import Path
import subprocess,tempfile,plistlib,shutil
root=Path(__file__).resolve().parents[1]
f=(root/'integration/test-voice-service-preflight.swift').read_text().split('@main')[0]
f=f.replace('    var onEvent: (([String: Any]) -> Void)?, onExit:', '    static var latest: BluetoothControlProcess?\n    init() { Self.latest = self }\n    var onEvent: (([String: Any]) -> Void)?, onExit:',1)
f=f.replace('FakeCounts.bluetooth += 1; return [:] }','FakeCounts.bluetooth += 1; onEvent?(["state": ["helperCallState": 0, "idleVerified": false, "ownDial": false]]); return ["helper": ["callState": 0]] }',1)
f=f.replace('@MainActor final class PCMTransport {','@MainActor final class PCMTransport {\n    static var latest: PCMTransport?\n    var startCount=0, playCount=0\n    init() { Self.latest = self }')
f=f.replace('func start() { FakeCounts.pcm += 1 }','func start() { FakeCounts.pcm += 1; startCount += 1; running = true; onEvent?(["type": "ready"]) }',1)
f=f.replace('func play(_ chunk: RealtimeAudioChunk) { FakeCounts.pcm += 1 }','func play(_ chunk: RealtimeAudioChunk) { FakeCounts.pcm += 1; playCount += 1 }',1)
f=f.replace('func stop() { FakeCounts.pcm += 1 }','func stop() { FakeCounts.pcm += 1; running = false }',1)
src=(root/'Sources/PhoneBridge/CallSessionCoordinator.swift').read_text()+'''
@MainActor extension CallSessionCoordinator {
 func offlineLocalValidationSetup() {
  number = "12345"; connectionNumber = number; connected = true
  dialerStage = "submitted"; mode = .builtinVoice
  state = ["helperCallState": 0]
 }
}
'''
main='''
@main struct LocalValidationChecks {
 @MainActor static func main() async throws {
  var checks=0
  let c = CallSessionCoordinator(), bt=BluetoothControlProcess.latest!, pcm=PCMTransport.latest!
  do { try c.prepareAudioValidation(); preconditionFailure("unconnected validation accepted") } catch { checks += 1 }
  c.offlineLocalValidationSetup();bt.isRunning=true
  c.maximumSeconds = 0
  do { try c.prepareAudioValidation(); preconditionFailure("unbounded duration accepted") } catch { checks += 1 }
  c.maximumSeconds = 180
  try c.prepareAudioValidation()
  try await Task.sleep(nanoseconds:100_000_000)
  precondition(c.audioValidationPrepared && c.callPending && !c.callActive)
  precondition(!c.voiceActive && pcm.startCount == 0 && pcm.playCount == 0)
  precondition(FakeCounts.starts == 0 && FakeKeyState.count() == 0)
  precondition(c.audioValidationDurationSeconds == 180 && c.audioValidationStartedAt == 0)
  checks += 3
  checks += 1
  do { try c.markAudioValidationVoiceStarted(); preconditionFailure("voice marker accepted before audio") } catch { checks += 1 }
  do { try c.sendValidationPrompt(); preconditionFailure("pre-call playback accepted") } catch { checks += 1 }
  bt.onEvent?(["state": ["helperCallState":2,"idleVerified":false,"ownDial":false]])
  try await Task.sleep(nanoseconds:600_000_000)
  precondition(c.audioValidationReady && c.callActive && c.voiceActive && !c.busy)
  precondition(pcm.startCount == 1 && pcm.playCount == 0)
  precondition(c.audioValidationStartedAt > 0 && c.audioValidationStoppedAt == 0)
  checks += 2
  checks += 1
  try c.markAudioValidationVoiceStarted()
  let marker = c.audioValidationVoiceConfirmedAt
  try c.markAudioValidationVoiceStarted()
  precondition(marker >= c.audioValidationStartedAt && marker == c.audioValidationVoiceConfirmedAt)
  checks += 1
  c.builtinCaptions.onTranscript?("local", "本机字幕测试", true)
  precondition(c.transcript.contains { $0.text == "本机字幕测试" && $0.role == "对方" })
  checks += 1
  try c.sendValidationPrompt()
  precondition(pcm.playCount == 1 && c.validationPromptSent)
  precondition(c.transcript.contains { $0.role.contains("待确认听见") })
  checks += 2
  do { try c.sendValidationPrompt();preconditionFailure("duplicate greeting accepted") } catch { checks += 1 }
  bt.onEvent?(["state": ["helperCallState":0,"idleVerified":false,"ownDial":false]])
  precondition(!c.audioValidationReady && !c.audioValidationPrepared && !c.voiceActive && !c.callActive)
  precondition(c.audioValidationStopReason == "phone_idle" && c.audioValidationStoppedAt >= marker)
  checks += 1
  checks += 1
  do { try c.markAudioValidationVoiceStarted(); preconditionFailure("voice marker accepted after stop") } catch { checks += 1 }
  c.disconnect();try await Task.sleep(nanoseconds:100_000_000)
  precondition(!c.busy && !c.connected && !pcm.running)
  precondition(FakeCounts.starts == 0 && FakeKeyState.count() == 0)
  checks += 2
  let timed = CallSessionCoordinator(), timedBT = BluetoothControlProcess.latest!
  timed.offlineLocalValidationSetup();timedBT.isRunning = true;timed.maximumSeconds = 1
  try timed.prepareAudioValidation()
  try await Task.sleep(nanoseconds:100_000_000)
  timedBT.onEvent?(["state": ["helperCallState":2,"idleVerified":false,"ownDial":false]])
  try await Task.sleep(nanoseconds:1_800_000_000)
  precondition(timed.audioValidationStopReason == "duration_limit")
  precondition(timed.audioValidationStoppedAt >= timed.audioValidationStartedAt && !timed.voiceActive)
  precondition(timed.audioValidationDurationSeconds == 1)
  checks += 3
  timed.disconnect();try await Task.sleep(nanoseconds:100_000_000)
  print("PASS \\(checks) local audio validation checks; all transports fake, no API or device calls")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='phonebridge-local-audio-offline-') as d:
 b=Path(d);app=b/'checks.app/Contents';exe=app/'MacOS/checks';exe.parent.mkdir(parents=True);resources=app/'Resources/Audio';resources.mkdir(parents=True)
 (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'checks','CFBundleIdentifier':'offline.phonebridge.validation','CFBundlePackageType':'APPL'}))
 shutil.copy2(root/'Sources/PhoneBridge/Resources/Audio/bluetooth-test.pcm',resources)
 (b/'Coordinator.swift').write_text(src);(b/'Checks.swift').write_text(f+main)
 subprocess.run(['swiftc','-emit-library','-emit-module','-module-name','BridgeCore',*[str(root/'Sources/BridgeCore'/n) for n in ['Protocol.swift','RealtimeProtocol.swift','PhoneNumber.swift','PhonePeerConfiguration.swift']],'-emit-module-path',str(b/'BridgeCore.swiftmodule'),'-o',str(b/'libBridgeCore.dylib')],check=True,timeout=60)
 subprocess.run(['swiftc','-parse-as-library','-I',d,'-L',d,'-lBridgeCore','-Xlinker','-rpath','-Xlinker',d,str(b/'Coordinator.swift'),str(root/'Sources/PhoneBridge/ConversationMode.swift'),str(b/'Checks.swift'),'-o',str(exe)],check=True,timeout=60)
 subprocess.run([str(exe)],check=True,timeout=15)
