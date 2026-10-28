#!/usr/bin/env python3
"""Compile native caption adapter against synthetic child processes only."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="codex-caption-adapter-") as d:
    work = Path(d)
    (work / "good.py").write_text('''import json,time
print(json.dumps({'type':'watching','watching':True,'source':'codex_transcript'}),flush=True)
time.sleep(.1)
for n,text in enumerate(['Hello, this is a caption test.','Это проверка субтитров.']):
 print(json.dumps({'type':'voice_transcript','id':'synthetic:'+str(n),'role':'assistant','text':text,'final':True,'source':'codex_transcript','lastSourceLagMs':5}),flush=True)
time.sleep(60)
''')
    (work / "bad.py").write_text('''import json,time
print(json.dumps({'ok':False,'error':'PRIVATE_SYNTHETIC_TOKEN'}),flush=True)
time.sleep(60)
''')
    (work / "conversation.jsonl").write_text(json.dumps({"type": "session_meta", "payload": {"id": "00000000-0000-0000-0000-000000000001"}}) + "\n")
    (work / "real-worker.py").write_text("import runpy,sys\n" +
        "sys.argv += ['--transcript-path', " + repr(str(work / "conversation.jsonl")) + "]\n" +
        "runpy.run_path(" + repr(str(root / "scripts/codex_voice_captions.py")) + ",run_name='__main__')\n")
    (work / "Checks.swift").write_text('''import Foundation
import BridgeCore
@main struct Checks {
 @MainActor static func main() async throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1])
  let good=CodexVoiceCaptions(scriptURL:base.appendingPathComponent("good.py"))
  var rows:[String]=[];var errors:[String]=[]
  good.onTranscript={ _,role,text in precondition(role=="assistant");rows.append(text) }
  good.onFailure={errors.append($0)}
  try await good.prepare(threadID:"00000000-0000-0000-0000-000000000001")
  for _ in 0..<100 { if rows.count==2 {break};try await Task.sleep(nanoseconds:20_000_000) }
  precondition(good.ready && rows.count==2 && rows[1].contains("Это"))
  good.stop();try await Task.sleep(nanoseconds:100_000_000)
  precondition(!good.ready && errors.isEmpty)
  let bad=CodexVoiceCaptions(scriptURL:base.appendingPathComponent("bad.py"))
  var rejected=false;var safe=true
  bad.onFailure={ safe = safe && !$0.contains("PRIVATE_SYNTHETIC_TOKEN") }
  do {try await bad.prepare(threadID:"00000000-0000-0000-0000-000000000001")}catch{rejected=true}
  precondition(rejected && safe && !bad.ready)
  var invalid=false
  do {try await bad.prepare(threadID:"../other-thread")}catch{invalid=true}
  precondition(invalid)
  let actual=CodexVoiceCaptions(scriptURL:base.appendingPathComponent("real-worker.py"))
  var actualRows:[String]=[]
  actual.onTranscript={_,role,text in precondition(role=="user");actualRows.append(text)}
  try await actual.prepare(threadID:"00000000-0000-0000-0000-000000000001")
  let event:[String:Any] = ["type":"realtime_item","payload":["type":"transcript_segment","id":"real-pipe-test","realtime_session_id":"fixture","role":"user","text":"Привет, 字幕测试"]]
  var bytes=try JSONSerialization.data(withJSONObject:event);bytes.append(10)
  let file=try FileHandle(forWritingTo:base.appendingPathComponent("conversation.jsonl"));try file.seekToEnd();try file.write(contentsOf:bytes);try file.close()
  for _ in 0..<100 {if !actualRows.isEmpty{break};try await Task.sleep(nanoseconds:20_000_000)}
  precondition(actualRows==["Привет, 字幕测试"])
  actual.stop()
  print("PASS: native adapter readiness, English/Russian, cleanup, sanitized failure and thread validation; no audio or APIs")
 }
}
''')
    subprocess.run(["swiftc", "-emit-library", "-emit-module", "-module-name", "BridgeCore",
                    str(root / "Sources/BridgeCore/Protocol.swift"), "-emit-module-path", str(work / "BridgeCore.swiftmodule"),
                    "-o", str(work / "libBridgeCore.dylib")], check=True, timeout=45)
    exe = work / "checks"
    subprocess.run(["swiftc", "-parse-as-library", "-I", d, "-L", d, "-lBridgeCore", "-Xlinker", "-rpath", "-Xlinker", d,
                    str(root / "Sources/PhoneBridge/CodexVoiceCaptions.swift"), str(work / "Checks.swift"), "-o", str(exe)], check=True, timeout=45)
    subprocess.run([str(exe), d], check=True, timeout=15)
