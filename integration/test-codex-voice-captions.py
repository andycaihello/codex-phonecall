#!/usr/bin/env python3
"""Offline protocol/transport/web isolation tests; all speech is synthetic."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("captions", ROOT / "scripts/codex_voice_captions.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def event(method, thread="chosen", **params):
    return {"method": c.PREFIX + method, "params": {"threadId": thread, **params}}


def item(identifier="one", role="user", text="", session="voice1"):
    return {"type": "transcriptSegment", "id": identifier, "role": role,
            "text": text, "realtimeSessionId": session}


class ProjectionTests(unittest.TestCase):
    def setUp(self):
        self.s = c.Captions("chosen")

    def lines(self):
        return self.s.snapshot()["transcript"]

    def test_flat_partial_correction_and_interleaved_roles(self):
        self.s.feed(event("transcript/delta", role="user", delta="你号"))
        self.s.feed(event("transcript/delta", role="assistant", delta="Здравствуйте"))
        self.s.feed(event("transcript/done", role="user", text="你好"))
        self.s.feed(event("transcript/done", role="assistant", text="Здравствуйте!"))
        self.assertEqual([x["text"] for x in self.lines()], ["你好", "Здравствуйте!"])
        self.assertTrue(all(x["final"] for x in self.lines()))

    def test_ignores_other_threads_and_unknown_roles(self):
        for thread, role in [("private-other", "user"), ("chosen", "system")]:
            self.s.feed(event("transcript/done", thread=thread, role=role, text="do not disclose"))
        self.assertEqual(self.lines(), [])

    def test_keyed_ids_preserve_repeated_sentences(self):
        for n in ["one", "two"]:
            self.s.feed(event("item/completed", item=item(n, text="Да.")))
        self.s.feed(event("item/completed", item=item("one", text="Да.")))
        self.assertEqual(len(self.lines()), 2)

    def test_canonical_partial_final_replaces_and_ignores_late_delta(self):
        self.s.feed(event("item/started", item=item(text="Зд")))
        self.s.feed(event("item/transcript/delta", itemId="one", delta="равствуйте"))
        self.assertEqual(self.lines()[0]["text"], "Здравствуйте")
        self.s.feed(event("item/completed", item=item(text="Здравствуйте!")))
        self.s.feed(event("item/transcript/delta", itemId="one", delta="duplicate"))
        self.s.feed(event("item/started", item=item(text="old")))
        self.assertEqual(self.lines()[0]["text"], "Здравствуйте!")
        self.assertTrue(self.lines()[0]["final"])

    def test_missing_start_not_guessed(self):
        self.s.feed(event("item/transcript/delta", itemId="unknown", delta="text"))
        self.assertEqual(self.lines(), [])

    def test_same_item_id_different_sessions_does_not_mix_text(self):
        self.s.feed(event("item/completed", item=item(text="old", session="old")))
        self.s.feed(event("item/started", item=item(text="new", session="new")))
        self.s.feed(event("item/transcript/delta", itemId="one", delta=" text"))
        self.assertEqual([x["text"] for x in self.lines()], ["old", "new text"])

    def test_prefer_canonical_over_duplicate_flat_notifications(self):
        self.s.feed(event("transcript/done", role="assistant", text="你好"))
        self.s.feed(event("item/completed", item=item(role="assistant", text="你好")))
        self.s.feed(event("transcript/done", role="assistant", text="你好"))
        self.assertEqual(len(self.lines()), 1)
        self.assertTrue(self.s.snapshot()["keyed"])

    def test_disconnect_does_not_finalize_and_restart_clears_old_voice(self):
        self.s.feed(event("transcript/delta", role="user", delta="unfinished"))
        self.s.feed(event("closed", reason="ended"))
        self.assertFalse(self.lines()[0]["final"])
        self.s.feed(event("started"))
        self.assertEqual(self.lines(), [])

    def test_invalid_objects_and_raw_audio_ignored(self):
        for obj in [None, [], "x", {"method": 1}, {"method": c.PREFIX + "started", "params": []},
                    event("outputAudio/delta", audio={"data": "private-audio"}),
                    event("item/completed", item=item(text=None))]:
            self.s.feed(obj)
        self.assertEqual(self.lines(), [])

    def test_text_and_history_bounds(self):
        with self.assertRaises(c.ProbeError):
            self.s.feed(event("transcript/delta", role="user", delta="x" * (c.MAX_TEXT + 1)))
        for i in range(120):
            self.s.feed(event("item/completed", item=item(str(i), text="line")))
        self.assertEqual(len(self.lines()), c.MAX_LINES)

    def test_synthetic_explicit_and_no_html_execution(self):
        s = c.Captions("chosen", synthetic=True)
        s.feed(event("transcript/done", role="user", text="<script>alert(1)</script>"))
        self.assertTrue(s.snapshot()["synthetic"])
        self.assertEqual(s.snapshot()["transcript"][0]["source"], "synthetic")
        html = (ROOT / "scripts/codex-voice-captions.html").read_text()
        self.assertIn("t.textContent=line.text", html)
        self.assertNotIn("innerHTML", html)


class TransportTests(unittest.TestCase):
    def fake(self, directory, loaded=True):
        # This executable implements only the four allowed JSONL messages.
        p = Path(directory) / "fake-codex"
        p.write_text("#!/usr/bin/env python3\n" + '''import json,sys
for raw in sys.stdin:
 m=json.loads(raw); method=m['method']
 if method not in ['initialize','initialized','thread/loaded/list','thread/resume']:sys.exit(20)
 if method=='initialized':continue
 if method=='initialize':r={'userAgent':'fake'}
 if method=='thread/loaded/list':r={'data': LOADED, 'nextCursor':None}
 if method=='thread/resume':
  if m['params']!={'threadId':'chosen','excludeTurns':True}:sys.exit(21)
  r={'thread':{'id':'chosen'}}
 print(json.dumps({'id':m['id'],'result':r}),flush=True)
 if method=='thread/resume':
  print(json.dumps({'method':'thread/realtime/transcript/done','params':{'threadId':'chosen','role':'assistant','text':'synthetic answer'}}),flush=True)
'''.replace("LOADED", "['chosen']" if loaded else "[]"))
        p.chmod(0o700)
        return str(p)

    def test_real_jsonl_handshake_attach_and_caption(self):
        with tempfile.TemporaryDirectory() as d:
            with c.ProxyClient(self.fake(d)) as client:
                client.initialize()
                client.attach("chosen")
                e = client.receive(2)
                self.assertEqual(e["params"]["text"], "synthetic answer")

    def test_no_disk_resume_when_target_not_loaded(self):
        with tempfile.TemporaryDirectory() as d:
            with c.ProxyClient(self.fake(d, loaded=False)) as client:
                client.initialize()
                with self.assertRaisesRegex(c.ProbeError, "拒绝从磁盘"):
                    client.attach("chosen")

    def test_mutating_rpc_not_allowed(self):
        client = c.ProxyClient("unused")
        for method in ["thread/start", "turn/start", "thread/realtime/start", "thread/realtime/appendAudio", "thread/realtime/stop"]:
            with self.assertRaises(c.ProbeError):
                client.send(method, {})

    def test_missing_and_regular_file_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sock"
            with self.assertRaises(c.ProbeError):
                c.check_socket(p)
            p.write_text("not socket")
            with self.assertRaises(c.ProbeError):
                c.check_socket(p)

    def test_missing_socket_never_spawns_alternate_process(self):
        with tempfile.TemporaryDirectory() as d, patch.object(c.subprocess, "Popen") as spawn:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = c.main(["probe", "--socket", str(Path(d) / "absent"), "--thread-id", "chosen"])
            self.assertEqual(result, 2)
            self.assertFalse(json.loads(output.getvalue())["transcriptVerified"])
            spawn.assert_not_called()

    @unittest.skipUnless(hasattr(socket, "AF_UNIX"), "requires Unix sockets")
    def test_owned_socket_accepted_without_connecting(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "sock"
            with socket.socket(socket.AF_UNIX) as sock:
                sock.bind(str(p))
                c.check_socket(p)


class WebTests(unittest.TestCase):
    def test_private_viewer_no_write_and_no_cross_host(self):
        captions = c.Captions("chosen", synthetic=True)
        with c.Viewer(captions) as web:
            with urlopen(web.url + "state") as r:
                self.assertTrue(json.load(r)["synthetic"])
                self.assertEqual(r.headers["Cache-Control"], "no-store")
            base = web.url.split("/", 3)[:3]
            with self.assertRaises(HTTPError) as err:
                urlopen("/".join(base) + "/wrong/state")
            self.assertEqual(err.exception.code, 404)
            err.exception.close()
            with self.assertRaises(HTTPError) as err:
                urlopen(Request(web.url, headers={"Host": "attacker.invalid"}))
            self.assertEqual(err.exception.code, 403)
            err.exception.close()
            with self.assertRaises(HTTPError) as err:
                urlopen(Request(web.url, data=b"{}", method="POST"))
            self.assertEqual(err.exception.code, 501)
            err.exception.close()


class TailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "thread.jsonl"
        self.path.write_text(json.dumps({"type": "session_meta", "payload": {"id": "chosen"}}) + "\n")
        self.state = c.Captions("chosen", source="codex_transcript")

    def tearDown(self):
        self.temp.cleanup()

    def append(self, obj):
        with self.path.open("a") as f:
            f.write(json.dumps(obj, ensure_ascii=False) + "\n")

    def segment(self, identifier="one", role="user", text="你好", **extra):
        return {"type": "realtime_item", "timestamp": "2026-10-28T00:00:00Z", "payload": {
            "type": "transcript_segment", "id": identifier, "realtime_session_id": "voice", "role": role, "text": text, **extra}}

    def test_new_final_text_and_roles_without_old_replay(self):
        self.append(self.segment("old", text="do not replay"))
        with c.TranscriptTail(self.path, self.state) as tail:
            self.assertEqual(tail.poll(), 0)
            self.append(self.segment(text="Здравствуйте!"))
            self.append(self.segment("ai", "assistant", "你好"))
            self.assertEqual(tail.poll(), 2)
        rows = self.state.snapshot()["transcript"]
        self.assertEqual([x["text"] for x in rows], ["Здравствуйте!", "你好"])
        self.assertTrue(all(x["final"] and x["source"] == "codex_transcript" for x in rows))

    def test_thread_identity_mismatch(self):
        with self.assertRaises(c.ProbeError):
            with c.TranscriptTail(self.path, c.Captions("another")):
                self.fail("must not open wrong thread")

    def test_partial_json_is_only_processed_after_newline(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            raw = json.dumps(self.segment()).encode()
            with self.path.open("ab") as f:
                f.write(raw[:21])
            self.assertEqual(tail.poll(), 0)
            with self.path.open("ab") as f:
                f.write(raw[21:] + b"\n")
            self.assertEqual(tail.poll(), 1)

    def test_ordinary_chat_tools_and_forged_payload_not_consumed(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            self.append({"type": "response_item", "payload": {"type": "function_call_output", "output": self.segment()}})
            self.append({"type": "response_item", "payload": {"type": "message", "role": "user", "text": "ordinary chat"}})
            self.assertEqual(tail.poll(), 0)
        self.assertEqual(self.state.snapshot()["transcript"], [])

    def test_rotation_stops_instead_of_reading_other_file(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            other = self.path.with_suffix(".replacement")
            other.write_text(self.path.read_text())
            other.replace(self.path)
            with self.assertRaises(c.ProbeError):
                tail.poll()

    def test_truncation_and_malformed_record_stop(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            self.path.write_text("")
            with self.assertRaises(c.ProbeError):
                tail.poll()

    def test_unknown_voice_schema_stops(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            self.append({"type": "realtime_item", "payload": {"type": "new_unsupported_type"}})
            with self.assertRaises(c.ProbeError):
                tail.poll()

    def test_start_and_stop_are_real_status_not_fabricated_text(self):
        with c.TranscriptTail(self.path, self.state) as tail:
            self.append({"type": "realtime_item", "payload": {"type": "realtime_session_started"}})
            self.append(self.segment())
            self.append({"type": "realtime_item", "payload": {"type": "realtime_session_closed"}})
            self.assertEqual(tail.poll(), 3)
            self.assertEqual(self.state.status, "voice_ended")
            self.assertEqual(len(self.state.snapshot()["transcript"]), 1)


if __name__ == "__main__":
    unittest.main()
