#!/usr/bin/env python3
"""Experimental, receive-only Codex voice caption mirror/subscriber.

Uses the public app-server proxy. Never starts an app-server, thread, turn or
voice session. Tail mode only reads new canonical voice records from one
identity-verified conversation log. Never reads credentials or recordings.
"""
import argparse
from collections import OrderedDict
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import secrets
import stat
import subprocess
import sys
import threading
import time

MAX_WIRE = 2 * 1024 * 1024
MAX_TEXT = 32768
MAX_LINES = 100
ROLES = {"user": "对方／输入", "assistant": "AI"}
PREFIX = "thread/realtime/"


class ProbeError(Exception):
    pass


class Captions:
    """Per-thread bounded projection; synthetic replay is always labelled."""
    def __init__(self, thread_id, synthetic=False, source="codex_voice"):
        self.thread_id = thread_id
        self.synthetic = synthetic
        self.source = "synthetic" if synthetic else source
        self.last_source_lag_ms = None
        self.status = "replay" if synthetic else "disconnected"
        self.lines = OrderedDict()
        self.pending = {}
        self.item_keys = {}
        self.sequence = 0
        self.keyed = False
        self.lock = threading.RLock()
        self.events = 0

    def reset(self):
        self.lines.clear()
        self.pending.clear()
        self.item_keys.clear()
        self.keyed = False
        self.last_source_lag_ms = None

    def put(self, key, role, text, final, session=None):
        if role not in ROLES or not isinstance(text, str):
            return
        if len(text) > MAX_TEXT:
            raise ProbeError("字幕段超过大小上限，已停止订阅。")
        if key not in self.lines and not text and final:
            return
        self.lines[key] = {"id": key, "role": role, "label": ROLES[role],
                           "text": text, "final": final,
                           "source": self.source,
                           "session": session}
        while len(self.lines) > MAX_LINES:
            removed, _ = self.lines.popitem(last=False)
            self.pending = {r: k for r, k in self.pending.items() if k != removed}
            self.item_keys = {i: k for i, k in self.item_keys.items() if k != removed}

    def feed(self, message):
        if not isinstance(message, dict):
            return
        method = message.get("method", "")
        p = message.get("params")
        if not isinstance(method, str) or not method.startswith(PREFIX):
            return
        if not isinstance(p, dict) or p.get("threadId") != self.thread_id:
            return
        with self.lock:
            self.events += 1
            if method == PREFIX + "started":
                self.reset()
                self.status = "voice_started"
            elif method in (PREFIX + "closed", PREFIX + "error"):
                self.status = "voice_ended" if method.endswith("closed") else "voice_error"
                self.pending.clear()  # Never silently finalize interrupted text.
            elif method in (PREFIX + "item/started", PREFIX + "item/completed"):
                item = p.get("item")
                if not isinstance(item, dict) or item.get("type") != "transcriptSegment":
                    return
                key, role, text = item.get("id"), item.get("role"), item.get("text")
                session = item.get("realtimeSessionId")
                if not isinstance(key, str) or not key or len(key) > 256 or role not in ROLES:
                    return
                if not isinstance(session, str) or not session or len(session) > 256:
                    return
                if not isinstance(text, str):
                    return
                if not self.keyed:
                    # Flat and canonical notifications can describe the same words.
                    # Switch to IDs once available; do not display both projections.
                    self.reset()
                    self.keyed = True
                canonical = session + ":" + key
                if method.endswith("started") and self.lines.get(canonical, {}).get("final"):
                    return
                self.item_keys[key] = canonical
                self.put(canonical, role, text,
                         method.endswith("completed"), session)
            elif method == PREFIX + "item/transcript/delta":
                item_id, delta = p.get("itemId"), p.get("delta")
                if not isinstance(item_id, str) or not isinstance(delta, str):
                    return
                key = self.item_keys.get(item_id)
                if key not in self.lines:
                    return  # Missing start: cannot infer role/session safely.
                line = self.lines[key]
                if not line["final"]:
                    self.put(key, line["role"], line["text"] + delta, False, line["session"])
            elif method in (PREFIX + "transcript/delta", PREFIX + "transcript/done") and not self.keyed:
                role = p.get("role")
                text = p.get("delta" if method.endswith("delta") else "text")
                if role not in ROLES or not isinstance(text, str):
                    return
                key = self.pending.get(role)
                if key is None:
                    self.sequence += 1
                    key = "flat-" + str(self.sequence)
                    self.pending[role] = key
                final = method.endswith("done")
                previous = self.lines.get(key, {}).get("text", "")
                self.put(key, role, text if final else previous + text, final)
                if final:
                    self.pending.pop(role, None)

    def snapshot(self):
        with self.lock:
            return {"status": self.status, "synthetic": self.synthetic,
                    "source": self.source, "lastSourceLagMs": self.last_source_lag_ms,
                    "events": self.events, "keyed": self.keyed,
                    "transcript": [dict(v) for v in self.lines.values()]}


class TranscriptTail:
    """Read only newly appended canonical voice records from one selected log.

    Codex documents transcript files, but not a stable format. Check the thread
    identity before seeking to EOF; ignore tool output and ordinary chat text.
    Never scrape the desktop UI or read auth/configuration files.
    """
    def __init__(self, path, captions):
        self.path = Path(path)
        self.captions = captions
        self.file = None
        self.pending = b""
        self.identity = None
        self.on_record = lambda _: None

    def __enter__(self):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(self.path, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ProbeError("语音会话记录不是当前用户拥有的普通文件。")
            self.file = os.fdopen(fd, "rb")
            fd = None
            first = self.file.readline(MAX_WIRE + 1)
            if len(first) > MAX_WIRE:
                raise ProbeError("会话记录标识超过大小上限。")
            meta = json.loads(first)
            payload = meta.get("payload") if isinstance(meta, dict) else None
            if meta.get("type") != "session_meta" or not isinstance(payload, dict) or payload.get("id") != self.captions.thread_id:
                raise ProbeError("会话记录的线程标识不匹配，拒绝读取。")
            self.identity = (info.st_dev, info.st_ino)
            self.file.seek(0, os.SEEK_END)  # No past calls or typed messages replayed.
            self.captions.status = "watching_current_voice_transcript"
            return self
        except (ValueError, AttributeError):
            self.__exit__()
            raise ProbeError("当前会话记录格式无法识别。") from None
        except BaseException:
            self.__exit__()
            raise
        finally:
            if fd is not None:
                os.close(fd)

    def poll(self):
        try:
            info = self.path.lstat()
        except OSError:
            raise ProbeError("会话记录已不可用；没有切换到其他文件。") from None
        if (info.st_dev, info.st_ino) != self.identity or not stat.S_ISREG(info.st_mode):
            raise ProbeError("会话记录已被替换；请重新验证线程后再连接。")
        if info.st_size < self.file.tell():
            raise ProbeError("会话记录已截断；没有回放旧通话。")
        chunk = self.file.read(262144)
        if not chunk:
            return 0
        self.pending += chunk
        count = 0
        while b"\n" in self.pending:
            raw, self.pending = self.pending.split(b"\n", 1)
            if len(raw) > MAX_WIRE:
                raise ProbeError("会话记录单条过大，字幕读取已停止。")
            try:
                value = json.loads(raw)
            except (ValueError, UnicodeError):
                raise ProbeError("会话记录存在无法解析的完整条目，字幕读取已停止。") from None
            if self.feed(value):
                count += 1
        if len(self.pending) > MAX_WIRE:
            raise ProbeError("会话记录未完成条目超过上限。")
        return count

    def feed(self, record):
        if not isinstance(record, dict) or record.get("type") != "realtime_item":
            return False
        p = record.get("payload")
        if not isinstance(p, dict):
            raise ProbeError("语音记录格式变化，已停止读取。")
        kind = p.get("type")
        if kind == "transcript_segment":
            session, identifier, role, text = [p.get(k) for k in ("realtime_session_id", "id", "role", "text")]
            if (not isinstance(session, str) or not session or len(session) > 256 or
                    not isinstance(identifier, str) or not identifier or len(identifier) > 256 or
                    role not in ROLES or not isinstance(text, str)):
                raise ProbeError("语音字幕字段不兼容，已停止读取。")
            self.captions.feed({"method": PREFIX + "item/completed", "params": {
                "threadId": self.captions.thread_id, "item": {"type": "transcriptSegment",
                "id": identifier, "realtimeSessionId": session, "role": role, "text": text}}})
            with self.captions.lock:
                self.captions.status = "receiving_committed_voice_transcript"
                try:
                    timestamp = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
                    lag = int((datetime.now(timezone.utc) - timestamp).total_seconds() * 1000)
                    self.captions.last_source_lag_ms = max(0, lag) if timestamp.tzinfo is not None else None
                except (KeyError, TypeError, ValueError, AttributeError):
                    self.captions.last_source_lag_ms = None
            self.on_record({"type": "voice_transcript", "id": session + ":" + identifier,
                            "role": role, "text": text, "final": True,
                            "source": "codex_transcript", "lastSourceLagMs": self.captions.last_source_lag_ms})
            return True
        if kind in ("realtime_session_started", "realtime_session_closed"):
            self.captions.feed({"method": PREFIX + ("started" if kind.endswith("started") else "closed"),
                                "params": {"threadId": self.captions.thread_id}})
            self.on_record({"type": "voice_started" if kind.endswith("started") else "voice_ended"})
            return True
        if kind != "bem_item_promoted":
            raise ProbeError("出现未知语音记录类型；需要更新版本适配。")
        return False

    def __exit__(self, *_):
        if self.file is not None:
            self.file.close()
            self.file = None


def discover_transcript(thread_id):
    # Only the selected thread, never all transcripts or credential files.
    if not isinstance(thread_id, str) or len(thread_id) > 128 or any(x not in "0123456789abcdef-" for x in thread_id):
        raise ProbeError("会话标识格式无效。")
    root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions"
    paths = list(root.glob("**/*" + thread_id + ".jsonl"))
    if len(paths) != 1:
        raise ProbeError("找不到唯一的当前会话记录，请明确指定对应的 --transcript-path。")
    return paths[0]


class ProxyClient:
    """JSONL transport via Codex's own public Unix-socket proxy."""
    ALLOWED = {"initialize", "initialized", "thread/loaded/list", "thread/resume"}

    def __init__(self, codex, socket_path=None):
        self.command = [codex, "app-server", "proxy"]
        if socket_path is not None:
            self.command += ["--sock", str(socket_path)]
        self.process = None
        self.messages = queue.Queue(maxsize=512)
        self.counter = 0
        self.on_event = lambda _: None
        self.stopping = threading.Event()

    def __enter__(self):
        self.process = subprocess.Popen(self.command, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._read, daemon=True).start()
        return self

    def _read(self):
        try:
            while not self.stopping.is_set():
                raw = self.process.stdout.readline(MAX_WIRE + 1)
                if not raw:
                    break
                if len(raw) > MAX_WIRE or not raw.endswith(b"\n"):
                    self.messages.put_nowait(ProbeError("协议消息过大或不完整。"))
                    return
                message = json.loads(raw)
                if not isinstance(message, dict):
                    raise ValueError()
                self.messages.put_nowait(message)
        except (ValueError, queue.Full):
            # Exit rather than dropping transcript deltas or printing raw payloads.
            try:
                self.messages.put_nowait(ProbeError("协议格式错误或事件消费过慢。"))
            except queue.Full:
                pass
        finally:
            self.stopping.set()

    def send(self, method, params, request_id=None):
        if method not in self.ALLOWED:
            raise ProbeError("订阅器不允许执行该操作。")
        value = {"method": method, "params": params}
        if request_id is not None:
            value["id"] = request_id
        try:
            self.process.stdin.write(json.dumps(value).encode() + b"\n")
            self.process.stdin.flush()
        except (OSError, ValueError):
            raise ProbeError("控制通道已关闭。") from None

    def receive(self, timeout):
        if self.stopping.is_set() and self.messages.empty():
            raise ProbeError("控制通道已断开；未启动替代会话。")
        try:
            message = self.messages.get(timeout=timeout)
        except queue.Empty:
            return None
        if isinstance(message, Exception):
            raise message
        return message

    def rpc(self, method, params, timeout=5):
        self.counter += 1
        identifier = self.counter
        self.send(method, params, identifier)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self.receive(min(.2, max(.001, deadline - time.monotonic())))
            if message is None:
                continue
            if message.get("id") == identifier:
                if "error" in message:
                    raise ProbeError("Codex 拒绝了 " + method + "；未读取历史或启动语音。")
                result = message.get("result")
                if not isinstance(result, dict):
                    raise ProbeError("Codex 响应结构不兼容。")
                return result
            if "method" in message:
                self.on_event(message)
        raise ProbeError("Codex 控制请求超时。")

    def initialize(self):
        self.rpc("initialize", {"clientInfo": {"name": "phonebridge_caption_probe", "version": "0.1.0"},
                                "capabilities": {"experimentalApi": True}})
        self.send("initialized", {})

    def loaded(self, thread_id):
        cursor = None
        seen = set()
        for _ in range(100):
            result = self.rpc("thread/loaded/list", {"limit": 100, "cursor": cursor})
            data = result.get("data")
            if not isinstance(data, list):
                raise ProbeError("无法验证目标会话已在当前运行实例中加载。")
            if thread_id in data:
                return True
            cursor = result.get("nextCursor")
            if cursor is None:
                return False
            if not isinstance(cursor, str) or cursor in seen:
                raise ProbeError("已加载会话分页异常。")
            seen.add(cursor)
        raise ProbeError("已加载会话列表超过检查上限。")

    def attach(self, thread_id):
        # Prevent disk-only resume into another Codex process. No history, model,
        # config, prompt, tool or instruction overrides are passed.
        if not self.loaded(thread_id):
            raise ProbeError("目标会话未在这个运行实例中加载；拒绝从磁盘恢复或创建副本。")
        self.rpc("thread/resume", {"threadId": thread_id, "excludeTurns": True})

    def __exit__(self, *_):
        self.stopping.set()
        if self.process is not None:
            if self.process.poll() is None:
                self.process.terminate()  # Only our proxy, never the daemon.
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)
            for pipe in (self.process.stdin, self.process.stdout):
                pipe.close()


def default_socket():
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "app-server-control/app-server-control.sock"


def check_socket(path):
    try:
        value = path.lstat()
    except FileNotFoundError:
        raise ProbeError("没有可订阅的 app-server 控制端口。当前桌面 stdio 会话不能由第二个进程直接订阅；未创建替代会话。") from None
    if not stat.S_ISSOCK(value.st_mode) or value.st_uid != os.getuid():
        raise ProbeError("控制端口不是当前用户拥有的 Unix socket。")


class Viewer:
    def __init__(self, captions):
        self.token = secrets.token_urlsafe(32)
        self.captions = captions
        self.server = None

    def __enter__(self):
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.headers.get("Host") != "127.0.0.1:" + str(owner.server.server_port):
                    self.send_error(403)
                    return
                base = "/" + owner.token + "/"
                if self.path == base:
                    content = (Path(__file__).parent / "codex-voice-captions.html").read_bytes()
                    kind = "text/html; charset=utf-8"
                elif self.path == base + "state":
                    content = json.dumps(owner.captions.snapshot(), ensure_ascii=False).encode()
                    kind = "application/json; charset=utf-8"
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
                self.end_headers()
                self.wfile.write(content)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/{self.token}/"
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["probe", "listen", "tail", "replay"])
    parser.add_argument("--codex", default="codex", help="Codex 可执行文件；不需要 API 密钥")
    parser.add_argument("--socket", type=Path, default=default_socket())
    parser.add_argument("--thread-id", default=os.environ.get("CODEX_THREAD_ID"))
    parser.add_argument("--transcript-path", type=Path, help="仅限选定线程的 Codex 会话记录；默认自动定位")
    parser.add_argument("--events-only", action="store_true", help="供通话桥后台读取的小型 JSONL 消息")
    parser.add_argument("--parent-pid", type=int, help="后台宿主退出时自动结束文字同步")
    parser.add_argument("--seconds", type=int, default=90)
    parser.add_argument("--serve", action="store_true", help="显示只读本地验证页")
    args = parser.parse_args(argv)
    maximum_seconds = 3600 if args.mode == "tail" else 300
    if not (args.mode == "tail" and args.seconds == 0) and not 1 <= args.seconds <= maximum_seconds:
        parser.error("--seconds 超出范围；tail 的 0 表示随宿主运行，不设总时长")
    if args.parent_pid is not None and (args.parent_pid <= 1 or os.getppid() != args.parent_pid):
        parser.error("后台宿主标识不匹配")
    if args.events_only and args.mode != "tail":
        parser.error("--events-only 仅用于 tail")
    if args.mode != "replay" and not args.thread_id:
        parser.error("需要明确指定 --thread-id，或从当前 Codex 会话环境读取")
    captions = Captions("synthetic-demo" if args.mode == "replay" else args.thread_id,
                        synthetic=args.mode == "replay",
                        source="codex_transcript" if args.mode == "tail" else "codex_voice")
    viewer = None
    try:
        if args.mode not in ("replay", "tail"):
            check_socket(args.socket)
        if args.mode == "tail":
            path = args.transcript_path or discover_transcript(args.thread_id)
            with TranscriptTail(path, captions) as reader:
                if args.events_only:
                    reader.on_record = emit
                if args.serve:
                    viewer = Viewer(captions).__enter__()
                    emit({"viewerURL": viewer.url, "synthetic": False, "source": "codex_transcript"})
                emit({"type": "watching", "watching": True, "pastTranscriptReplayed": False,
                      "voiceStartedByProbe": False, "source": "codex_transcript", "seconds": args.seconds})
                deadline = time.monotonic() + args.seconds if args.seconds else None
                while deadline is None or time.monotonic() < deadline:
                    if args.parent_pid is not None and os.getppid() != args.parent_pid:
                        break
                    if reader.poll() and not args.events_only:
                        emit(captions.snapshot())
                    time.sleep(.2)
                captions.status = "finished"
                if not args.events_only:
                    emit(captions.snapshot())
            return 0
        if args.serve:
            viewer = Viewer(captions).__enter__()
            emit({"viewerURL": viewer.url, "synthetic": captions.synthetic})
        if args.mode == "replay":
            # Deliberately synthetic protocol data. No microphone, network API,
            # production backend, phone or Codex process is accessed.
            messages = [
                {"method": PREFIX + "item/started", "params": {"threadId": captions.thread_id, "item": {
                    "type": "transcriptSegment", "id": "ru", "realtimeSessionId": "demo", "role": "user", "text": ""}}},
                {"method": PREFIX + "item/transcript/delta", "params": {"threadId": captions.thread_id, "itemId": "ru", "delta": "Здравствуйте! "}},
                {"method": PREFIX + "item/completed", "params": {"threadId": captions.thread_id, "item": {
                    "type": "transcriptSegment", "id": "ru", "realtimeSessionId": "demo", "role": "user", "text": "Здравствуйте! Вы меня слышите?"}}},
                {"method": PREFIX + "item/completed", "params": {"threadId": captions.thread_id, "item": {
                    "type": "transcriptSegment", "id": "ai", "realtimeSessionId": "demo", "role": "assistant", "text": "能听到。这是模拟字幕，不代表俄语识别已验证。"}}},
            ]
            for message in messages:
                captions.feed(message)
                if viewer:
                    time.sleep(.4)
            emit(captions.snapshot())
            if viewer:
                time.sleep(args.seconds)
            return 0
        with ProxyClient(args.codex, args.socket) as client:
            client.initialize()
            if args.mode == "probe":
                emit({"connected": True, "targetLoaded": client.loaded(args.thread_id),
                      "voiceStartedByProbe": False, "transcriptVerified": False})
                return 0
            client.on_event = captions.feed
            client.attach(args.thread_id)
            if captions.status == "disconnected":
                captions.status = "subscribed_waiting_for_voice_events"
            emit({"subscribed": True, "transcriptVerified": False, "seconds": args.seconds})
            deadline = time.monotonic() + args.seconds
            old = None
            while time.monotonic() < deadline:
                message = client.receive(.2)
                if message is not None:
                    captions.feed(message)
                    snap = captions.snapshot()
                    if snap != old:
                        emit(snap)
                        old = snap
            captions.status = "finished"
            emit(captions.snapshot())
            return 0
    except (ProbeError, OSError) as error:
        captions.status = "disconnected"
        # Never print arbitrary transport stderr, RPC payloads or credentials.
        emit({"ok": False, "error": str(error) if isinstance(error, ProbeError) else "本机订阅器无法连接或启动。",
              "voiceStartedByProbe": False, "transcriptVerified": False})
        return 2
    except KeyboardInterrupt:
        return 130
    finally:
        if viewer:
            viewer.__exit__()


if __name__ == "__main__":
    sys.exit(main())
