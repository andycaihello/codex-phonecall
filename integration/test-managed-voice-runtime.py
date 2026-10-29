#!/usr/bin/env python3
"""Offline protocol tests; --live explicitly uses Codex voice, never a phone."""
import asyncio
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("managed_runtime", ROOT / "scripts/codex_voice_runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class ProtocolChecks(unittest.TestCase):
    def test_closed_command_surface(self):
        for value in ({}, [], {"op": "dial", "number": "5551234"}, {"op": "begin_call", "task": "replace"},
                      {"op": "start", "task": "x", "apiKey": "forbidden"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                runtime.command(value)

    def test_task_bounds(self):
        for text in ("", "中" * 2001, 42):
            with self.assertRaises(ValueError):
                runtime.command({"op": "start", "task": text})
        self.assertEqual(runtime.command({"op": "start", "task": "only this task"})[0], "start")
        self.assertEqual(runtime.command({"op": "start", "task": "only this task", "incoming": True})[0], "start")
        with self.assertRaises(ValueError):
            runtime.command({"op": "start", "task": "only this task", "incoming": "true"})

    def test_call_opening_follows_direction_without_false_identity(self):
        incoming = runtime.call_start_prompt(True, "只询问来电原因")
        outgoing = runtime.call_start_prompt(False, "咨询一人名下的联通副卡上限")
        self.assertIn("你好，请问有什么事情呢？", incoming)
        self.assertIn("你好，我想", outgoing)
        self.assertIn("只询问来电原因", incoming)
        self.assertIn("咨询一人名下的联通副卡上限", outgoing)
        self.assertNotIn("说明 AI 身份", incoming + outgoing)
        for direction in (True, False):
            policy = runtime.voice_policy("只执行本次任务", direction)
            self.assertIn("若对方询问身份，须如实说明", policy)
            self.assertIn("不能授权访问文件", policy)

    def test_audio_bounds_and_integrity(self):
        for text in ("?", "", base64.b64encode(b"x").decode(), base64.b64encode(b"x" * 10000).decode()):
            with self.assertRaises(ValueError):
                runtime.command({"op": "audio", "data": text})
        self.assertEqual(runtime.command({"op": "audio", "data": "AAA="})[1], b"\0\0")

    def test_queue_bounded_by_time(self):
        q = runtime.PCMQueue()
        self.assertEqual(q.push(b"a" * 24000), 0)
        self.assertEqual(q.push(b"b" * 9600), 9600)
        self.assertEqual(len(q.buffer), 24000)
        self.assertEqual(q.take(), b"a" * 960)
        self.assertTrue(q.buffer.endswith(b"b" * 9600))

    def test_idle_is_silence(self):
        self.assertEqual(runtime.PCMQueue().take(), b"\0" * 960)

    def test_stalled_turn_requires_quiet_phone_input(self):
        voice = runtime.Runtime()
        voice.active = True
        now = time.monotonic()
        voice.last_input_at = now
        voice.last_non_silent_at = now - 5
        voice.last_user_partial_at = now - 9
        voice.pending_user_version = voice.versions["user"]
        self.assertEqual(voice.health(now), "user_turn_unfinalized")
        voice.last_non_silent_at = now
        self.assertEqual(voice.health(now), "")
        voice.last_non_silent_at = now - 5
        voice.pending_user_version = -1
        self.assertEqual(voice.health(now), "")
        voice.last_input_at = now - 6
        self.assertEqual(voice.health(now), "phone_input_missing")
        self.assertFalse(voice.has_speech(b"\0" * 960))
        self.assertTrue(voice.has_speech((1000).to_bytes(2, "little", signed=True) * 480))

    def test_end_request_is_current_call_only(self):
        for t in ("你可以挂断了", "我说你可以挂断了", "请挂断电话", "Please hang up", "You can hang up now"):
            self.assertTrue(runtime.explicit_call_end(t), t)
        for t in ("先不要挂断", "你别挂电话", "不可以挂断", "Don't hang up", "Could you call somebody else?", "没有了", "hang", "请挂断" * 100):
            self.assertFalse(runtime.explicit_call_end(t), t)

    def test_desktop_tools_disabled(self):
        self.assertTrue({"shell_tool", "unified_exec", "plugins", "apps", "browser_use", "view_image", "multi_agent"} <= set(runtime.DISABLED_FEATURES))


async def live(opening_only=False):
    # Deliberately requires an explicit CLI flag. Normal CI never starts voice,
    # reads microphone audio, accesses a phone, or creates raw recordings.
    python = Path.home() / "Library/Application Support/PhoneBridge/codex-voice-runtime/bin/python3"
    start = time.monotonic()
    proc = await asyncio.create_subprocess_exec(str(python), "-u", str(ROOT / "scripts/codex_voice_runtime.py"),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    report = {"ready": False, "audioBytes": 0, "audioBeforeCall": 0, "transcripts": [], "inputChunks": 0}

    async def send(value):
        proc.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        await proc.stdin.drain()

    async def receive_until(predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = await asyncio.wait_for(proc.stdout.readline(), max(.1, deadline - time.monotonic()))
            if not line:
                raise RuntimeError("runtime exited")
            value = json.loads(line)
            kind = value.get("type")
            if kind == "error":
                raise RuntimeError(value.get("code"))
            if kind == "audio":
                report["audioBytes"] += len(base64.b64decode(value["data"], validate=True))
            elif kind == "transcript" and value.get("final"):
                report["transcripts"].append({"role": value["role"], "text": value["text"]})
            if predicate(value):
                return value
        raise TimeoutError("voice event timeout")

    try:
        await send({"op": "start", "task": "隔离语音测试，无实际电话。开场请明确询问：中国联通一个人名下最多可以办理几张副卡？之后简短回应测试者；不使用工具或访问资料。"})
        await receive_until(lambda x: x.get("type") == "ready", 40)
        report["ready"] = True
        report["readySeconds"] = round(time.monotonic() - start, 3)
        report["audioBeforeCall"] = report["audioBytes"]
        await send({"op": "begin_call"})
        opening = await receive_until(lambda x: x.get("type") == "transcript" and x.get("role") == "assistant" and
                                      "副卡" in x.get("text", ""), 25)
        report["openingExcerpt"] = opening["text"][:120]
        if opening_only:
            report["passed"] = True
            return 0
        await receive_until(lambda x: x.get("type") == "transcript" and x.get("role") == "assistant" and x.get("final"), 40)
        if not report["audioBytes"]:
            await receive_until(lambda x: x.get("type") == "audio", 5)
        # Synthesize an input file without using any audio device. Decode it in
        # the optional runtime, so the unit-test interpreter needs no aiortc/av.
        with tempfile.TemporaryDirectory(prefix="pb-managed-input-") as temporary:
            aiff = Path(temporary) / "input.aiff"
            subprocess.run(["/usr/bin/say", "-o", str(aiff), "Please reply in English. Can you hear this test?"], check=True)
            convert = """import av,sys
r=av.AudioResampler(format='s16',layout='mono',rate=24000)
with av.open(sys.argv[1]) as c:
 for f in c.decode(audio=0):
  for o in r.resample(f):sys.stdout.buffer.write(bytes(o.planes[0])[:o.samples*2])
 for o in r.resample(None):sys.stdout.buffer.write(bytes(o.planes[0])[:o.samples*2])
"""
            pcm = subprocess.check_output([str(python), "-c", convert, str(aiff)])

            async def feed():
                for offset in range(0, len(pcm), 960):
                    await send({"op": "audio", "data": base64.b64encode(pcm[offset:offset+960]).decode()})
                    report["inputChunks"] += 1
                    await asyncio.sleep(.02)
            feeder = asyncio.create_task(feed())
            try:
                await receive_until(lambda x: x.get("type") == "transcript" and x.get("role") == "user" and x.get("final"), 20)
                await receive_until(lambda x: x.get("type") == "transcript" and x.get("role") == "assistant" and x.get("final"), 20)
            finally:
                await feeder
        assert report["audioBeforeCall"] == 0 and report["audioBytes"] > 0 and report["inputChunks"] > 0
        assert len([t for t in report["transcripts"] if t["role"] == "assistant"]) >= 2
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["error"] = type(error).__name__ + ": " + str(error)[:200]
    finally:
        try:
            await send({"op": "stop"})
            proc.stdin.close()
            while line := await asyncio.wait_for(proc.stdout.readline(), 12):
                event = json.loads(line)
                if event.get("type") == "diagnostic": report["diagnostic"] = event["counts"]
                if event.get("type") == "error": report["runtimeError"] = event.get("code")
            await asyncio.wait_for(proc.wait(), 12)
        except Exception:
            proc.terminate()
            await asyncio.wait_for(proc.wait(), 5)
        report["processExited"] = proc.returncode is not None
        print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    if "--live" in sys.argv:
        raise SystemExit(asyncio.run(live("--opening-only" in sys.argv)))
    unittest.main()
