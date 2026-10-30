#!/usr/bin/python3
"""Offline only: fake backend/HTTP objects; no App, phone, audio, API or install."""
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest import mock

import server

SID = "3a3bb52c-43ef-47c8-834c-d36bde6b2c44"
TOKEN = "fake-private-runtime-credential-0000000000"
CONSOLE = {"consoleURL": "http://127.0.0.1:12345/console", "backendRunning": True, "version": "fake"}


class LockedOutput:
    def __init__(self):
        self.parts = []
        self.lock = threading.Lock()
    def write(self, raw):
        with self.lock:
            self.parts.append(raw)
    def flush(self):
        pass
    def rows(self):
        with self.lock:
            return [json.loads(row) for row in self.parts]


class FakeBackend(server.LocalBackend):
    def __init__(self):
        super().__init__("/unused/no-runtime-reads-in-fake")
        self.calls = []
        self.open_count = 0
        self.open_options = []
        self.terminal = False
        self.cursor = 0
        self.lock = threading.Lock()
        self.first_read = threading.Event()
        self.bad_identity = False
    def request(self, payload, timeout=2):
        with self.lock:
            self.calls.append(dict(payload))
            action = payload["action"]
            if action == "plugin_read":
                self.first_read.set()
            if action == "plugin_end":
                self.terminal = True
                self.cursor = 1
            if action == "plugin_status":
                return {"appRunning": True, "sessionReserved": False}
            if action == "plugin_console":
                return dict(CONSOLE)
            return {"session_id": str(__import__('uuid').uuid4()) if self.bad_identity else SID,
                    "cursor": self.cursor, "events": [], "phase": "ended" if self.terminal else "prepared",
                    "terminal": self.terminal}
    def open_app(self, timeout=5, background=False):
        self.open_count += 1
        self.open_options.append({"timeout": timeout, "background": background})
        return {"openRequested": True, "appRunningVerified": False}


class ToolTests(unittest.TestCase):
    def test_menu_key_scope_and_validation(self):
        self.assertEqual(server.ACTIONS["phonebridge_press_key"], "plugin_press_key")
        for key in "0123456789*#":
            self.assertEqual(server.validate_tool("phonebridge_press_key", {"session_id": SID, "key": key}), {"session_id": SID, "key": key})
        for key in ("", "12", "A", "１", "\r", 1, True):
            with self.subTest(key=key), self.assertRaises(server.InvalidParams):
                server.validate_tool("phonebridge_press_key", {"session_id": SID, "key": key})
        for fields in ({"key": "1"}, {"session_id": SID, "key": "1", "number": "10010"}):
            with self.assertRaises(server.InvalidParams):
                server.validate_tool("phonebridge_press_key", fields)
    def test_prepare_defaults_and_number_scope(self):
        for number in ["13800000000", "10010", "+8613800000000", "123", "1" * 15]:
            with self.subTest(number=number):
                args = server.validate_tool("phonebridge_prepare_call", {"number": number, "task": "咨询副卡实名"})
                self.assertEqual(args["mode"], "builtin_voice")
                self.assertEqual(args["max_seconds"], 0)
        for number in ["12", "1" * 16, "++123", "123;", "123\rATD", "１２３", "12 34", 123, True]:
            with self.subTest(number=number), self.assertRaises(server.InvalidParams):
                server.validate_tool("phonebridge_prepare_call", {"number": number, "task": "test"})

    def test_automatic_voice_is_explicit_and_scoped(self):
        self.assertEqual(server.validate_tool("phonebridge_prepare_call", {"number":"5551234","task":"fixture","mode":"codex_voice"})["mode"],"codex_voice")
        self.assertEqual(server.validate_tool("phonebridge_prepare_incoming", {"task":"fixture","mode":"codex_voice"})["mode"],"codex_voice")
        self.assertEqual(server.validate_tool("phonebridge_prepare_codex_voice", {"session_id":SID}),{"session_id":SID})
        with self.assertRaises(server.InvalidParams):
            server.validate_tool("phonebridge_prepare_codex_voice", {"session_id":SID,"auto_answer":True})
        self.assertNotIn("phonebridge_auto_answer",server.BY_NAME)

    def test_incoming_receive_only_contract(self):
        args = server.validate_tool("phonebridge_prepare_incoming", {"task": "代接当前来电", "codex_thread_id": SID})
        self.assertEqual(args["max_seconds"], 0)
        self.assertNotIn("number", args)
        self.assertEqual(args["mode"], "builtin_voice")
        for extra in ({"number": "5551234"}, {"mode": "openai_realtime"}, {"max_seconds": True}, {"codex_thread_id": "../other"}):
            with self.assertRaises(server.InvalidParams):
                server.validate_tool("phonebridge_prepare_incoming", {"task": "current call", **extra})
        self.assertEqual(server.validate_tool("phonebridge_answer_call", {"session_id": SID}), {"session_id": SID})
        for extra in ({"number": "5551234"}, {"incoming_id": "1"}):
            with self.assertRaises(server.InvalidParams):
                server.validate_tool("phonebridge_answer_call", {"session_id": SID, **extra})

    def test_strict_bounded_fields(self):
        bad = [
            ("phonebridge_prepare_call", {"number": "10010", "task": "x", "codex_thread_id": "../another"}),
            ("phonebridge_status", {"session_id": SID}),
            ("phonebridge_open_console", {"url": "https://example.com"}),
            ("phonebridge_start_call", {}),
            ("phonebridge_start_call", {"session_id": "../other"}),
            ("phonebridge_start_call", {"session_id": SID.upper()}),
            ("phonebridge_start_call", {"session_id": SID, "number": "10010"}),
            ("phonebridge_prepare_call", {"number": "10010", "task": " "}),
            ("phonebridge_prepare_call", {"number": "10010", "task": "字" * 2001}),
            ("phonebridge_prepare_call", {"number": "10010", "task": "x", "max_seconds": True}),
            ("phonebridge_prepare_call", {"number": "10010", "task": "x", "max_seconds": -1}),
            ("phonebridge_prepare_call", {"number": "10010", "task": "x", "max_seconds": 2147483648}),
            ("phonebridge_prepare_call", {"number": "10010", "task": "x", "mode": "shell"}),
            ("phonebridge_steer_call", {"session_id": SID, "instruction": "字" * 1334}),
            ("phonebridge_read_call", {"session_id": SID, "cursor": True}),
            ("phonebridge_read_call", {"session_id": SID, "cursor": -1}),
            ("phonebridge_read_call", {"session_id": SID, "cursor": 1 << 54}),
            ("phonebridge_read_call", {"session_id": SID, "wait_seconds": float("inf")}),
            ("phonebridge_read_call", {"session_id": SID, "wait_seconds": float("nan")}),
            ("phonebridge_read_call", {"session_id": SID, "wait_seconds": True}),
            ("phonebridge_read_call", {"session_id": SID, "wait_seconds": 21}),
            ("phonebridge_unknown", {}),
        ]
        for name, args in bad:
            with self.subTest(name=name, args=args), self.assertRaises(server.InvalidParams):
                server.validate_tool(name, args)
        for seconds in [0, 0.5, 20]:
            self.assertEqual(server.validate_tool("phonebridge_read_call", {"session_id": SID, "wait_seconds": seconds})["wait_seconds"], seconds)

    def test_all_exact_app_mappings_and_no_implicit_open(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput())
        self.addCleanup(mcp.stop)
        for name, action in server.ACTIONS.items():
            arguments = {"session_id": SID}
            if name in ("phonebridge_status", "phonebridge_open_console"):
                arguments = {}
            elif name == "phonebridge_prepare_incoming":
                arguments = {"task": "owner authorized current incoming call"}
            elif name == "phonebridge_prepare_call":
                arguments = {"number": "10010", "task": "test"}
            elif name == "phonebridge_steer_call":
                arguments["instruction"] = "owner requested clarification"
            elif name == "phonebridge_press_key":
                arguments["key"] = "1"
            args = server.validate_tool(name, arguments)
            mcp.invoke_tool(name, args, threading.Event())
            self.assertEqual(backend.calls[-1]["action"], action)
            self.assertNotIn("wait_seconds", backend.calls[-1])
            self.assertEqual(set(backend.calls[-1]), {"action"} | (set(args) - {"wait_seconds"}))
        self.assertEqual(backend.open_count, 0)
        mcp.invoke_tool("phonebridge_open_app", {}, threading.Event())
        self.assertEqual(backend.open_count, 1)

    def test_session_mismatch_never_returns_transcript(self):
        backend = FakeBackend(); backend.bad_identity = True
        mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        with self.assertRaisesRegex(server.SafeError, "identity mismatch"):
            mcp.invoke_tool("phonebridge_read_call", {"session_id": SID, "cursor": 0, "wait_seconds": 0}, threading.Event())

    def test_read_wait_cursor_terminal_and_cancel(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        before = time.monotonic()
        result = mcp.invoke_tool("phonebridge_read_call", {"session_id": SID, "cursor": 0, "wait_seconds": 0.45}, threading.Event())
        self.assertGreaterEqual(time.monotonic() - before, 0.44)
        self.assertLess(time.monotonic() - before, 0.9)
        self.assertEqual(result["cursor"], 0)
        self.assertLessEqual(len(backend.calls), 3)
        backend.cursor = 2
        before = time.monotonic()
        result = mcp.invoke_tool("phonebridge_read_call", {"session_id": SID, "cursor": 0, "wait_seconds": 20}, threading.Event())
        self.assertLess(time.monotonic() - before, 0.1)
        self.assertEqual(result["cursor"], 2)
        backend.terminal = True
        self.assertTrue(mcp.invoke_tool("phonebridge_read_call", {"session_id": SID, "cursor": 2, "wait_seconds": 20}, threading.Event())["terminal"])
        event = threading.Event(); event.set(); count = len(backend.calls)
        with self.assertRaises(server.SafeError):
            mcp.invoke_tool("phonebridge_start_call", {"session_id": SID}, event)
        self.assertEqual(len(backend.calls), count)

    def test_annotations_and_user_attestation(self):
        self.assertEqual(len(server.TOOLS), 15)
        self.assertTrue(server.BY_NAME["phonebridge_read_call"]["annotations"]["readOnlyHint"])
        self.assertTrue(server.BY_NAME["phonebridge_start_call"]["annotations"]["openWorldHint"])
        self.assertIn("spoken greeting", server.BY_NAME["phonebridge_start_call"]["description"])
        self.assertIn("progress-only update is insufficient", server.BY_NAME["phonebridge_start_call"]["description"])
        self.assertIn("hearing remains unverified", server.BY_NAME["phonebridge_start_call"]["description"])
        self.assertFalse(server.BY_NAME["phonebridge_prepare_call"]["annotations"]["readOnlyHint"])
        self.assertIn("ONLY after the owner", server.BY_NAME["phonebridge_confirm_builtin_voice"]["description"])
        backend, out = FakeBackend(), LockedOutput(); mcp = server.MCPServer(backend, out); self.addCleanup(mcp.stop)
        mcp.initialized = True
        mcp.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "phonebridge_confirm_builtin_voice", "arguments": {"session_id": SID}}})
        wait_row(out, 1)
        payload = json.loads(out.rows()[-1]["result"]["content"][0]["text"])
        self.assertEqual(payload["confirmationBasis"], "user_attested")
        self.assertFalse(payload["voiceStartedVerified"])
        self.assertIn("untrusted", payload["evidenceTrust"])

    def test_console_existing_backend_no_app_or_browser_launch(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        result = mcp.invoke_tool("phonebridge_open_console", {}, threading.Event())
        self.assertEqual(result, CONSOLE)
        self.assertEqual(backend.calls, [{"action": "plugin_console"}])
        self.assertEqual(backend.open_count, 0)
        self.assertFalse(server.BY_NAME["phonebridge_open_console"]["annotations"]["readOnlyHint"])

    def test_console_launches_only_fixed_backend_once_then_polls(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        with mock.patch.object(backend, "request", side_effect=[server.SafeError("not running"), server.SafeError("starting"), dict(CONSOLE)]) as request:
            result = mcp.invoke_tool("phonebridge_open_console", {}, threading.Event())
        self.assertEqual(result, CONSOLE)
        self.assertEqual(backend.open_count, 1)
        self.assertEqual(backend.open_options, [{"timeout": 5, "background": True}])
        self.assertEqual(request.call_count, 3)
        self.assertTrue(all(call.args == ({"action": "plugin_console"},) for call in request.call_args_list))
        self.assertTrue(all(0 < call.kwargs["timeout"] <= 2 for call in request.call_args_list))

    def test_console_total_deadline_includes_launch_and_requests(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        clock = [100.0]
        def unavailable(payload, timeout):
            clock[0] += timeout
            raise server.SafeError("still unavailable")
        def opening(timeout=5, background=False):
            clock[0] += timeout
        with mock.patch.object(server.time, "monotonic", side_effect=lambda: clock[0]), mock.patch.object(backend, "request", side_effect=unavailable) as request, mock.patch.object(backend, "open_app", side_effect=opening) as opened:
            with self.assertRaisesRegex(server.SafeError, "8 seconds"):
                mcp.invoke_tool("phonebridge_open_console", {}, threading.Event())
        self.assertEqual(clock[0], 108.0)
        self.assertEqual(opened.call_count, 1)
        self.assertEqual([call.kwargs["timeout"] for call in request.call_args_list], [2.0, 1.0])

    def test_console_cancel_does_not_launch_or_poll_after_cancellation(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        cancelled = threading.Event(); cancelled.set()
        with self.assertRaisesRegex(server.SafeError, "cancelled"):
            mcp.invoke_tool("phonebridge_open_console", {}, cancelled)
        self.assertEqual(backend.calls, []); self.assertEqual(backend.open_count, 0)
        cancelled.clear()
        def cancel_request(*args, **kwargs):
            cancelled.set()
            raise server.SafeError("unavailable")
        with mock.patch.object(backend, "request", side_effect=cancel_request) as request, self.assertRaisesRegex(server.SafeError, "cancelled"):
            mcp.invoke_tool("phonebridge_open_console", {}, cancelled)
        self.assertEqual(request.call_count, 1); self.assertEqual(backend.open_count, 0)
        cancelled.clear()
        with mock.patch.object(backend, "request", side_effect=server.SafeError("unavailable")) as request, mock.patch.object(backend, "open_app", side_effect=lambda **_: cancelled.set()), self.assertRaisesRegex(server.SafeError, "cancelled"):
            mcp.invoke_tool("phonebridge_open_console", {}, cancelled)
        self.assertEqual(request.call_count, 1)

    def test_console_rejects_nonlocal_or_malformed_backend_urls(self):
        backend = FakeBackend(); mcp = server.MCPServer(backend, LockedOutput()); self.addCleanup(mcp.stop)
        bad_urls = ["https://127.0.0.1:12345/console", "http://example.com:12345/console", "http://127.0.0.1.example.com:12345/", "http://127.0.0.1/console", "http://u@127.0.0.1:12345/", "http://127.0.0.1:65536/", "http://127.0.0.1:0/", "http://127.0.0.1:012345/", "http://127.0.0.1:12345/\n", "http://127.0.0.1:12345/\\other", "file:///tmp/console", None]
        bad_results = [dict(CONSOLE, consoleURL=url) for url in bad_urls] + [dict(CONSOLE, backendRunning=False), dict(CONSOLE, backendRunning=1), dict(CONSOLE, version=""), dict(CONSOLE, version="x" * 101)]
        for data in bad_results:
            with self.subTest(data=data), mock.patch.object(backend, "request", return_value=data), self.assertRaisesRegex(server.SafeError, "invalid local console"):
                mcp.invoke_tool("phonebridge_open_console", {}, threading.Event())
        self.assertEqual(backend.open_count, 0)


def wait_row(output, rid, timeout=1.5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for row in output.rows():
            if row.get("id") == rid:
                return row
        time.sleep(0.005)
    raise AssertionError("No response for id " + str(rid))


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.backend, self.out = FakeBackend(), LockedOutput()
        self.mcp = server.MCPServer(self.backend, self.out)
        self.addCleanup(self.mcp.stop)
    def request(self, rid, method, params=None):
        self.mcp.handle({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
    def init(self):
        self.request("init", "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "offline-test", "version": "1"}})

    def test_initialize_list_ping_and_unknown(self):
        self.request(0, "tools/list")
        self.assertEqual(self.out.rows()[-1]["error"]["code"], -32002)
        self.init(); self.request(1, "tools/list"); self.request(2, "ping"); self.request(3, "execute_shell")
        rows = self.out.rows()
        self.assertEqual(rows[1]["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(len(rows[2]["result"]["tools"]), 15)
        self.assertEqual(rows[3]["result"], {})
        self.assertEqual(rows[4]["error"]["code"], -32601)
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(self.backend.open_count, 0)

    def test_full_read_lane_does_not_block_hangup(self):
        self.init()
        for rid in range(4):
            self.request(rid, "tools/call", {"name": "phonebridge_read_call", "arguments": {"session_id": SID, "wait_seconds": 20}})
        self.assertTrue(self.backend.first_read.wait(0.5))
        self.request(10, "tools/call", {"name": "phonebridge_read_call", "arguments": {"session_id": SID, "wait_seconds": 20}})
        self.assertEqual(wait_row(self.out, 10)["error"]["code"], -32001)
        before = time.monotonic()
        self.request("end", "tools/call", {"name": "phonebridge_end_call", "arguments": {"session_id": SID}})
        self.assertFalse(wait_row(self.out, "end")["result"]["isError"])
        self.assertLess(time.monotonic() - before, 0.3)
        for rid in range(4):
            self.assertFalse(wait_row(self.out, rid)["result"]["isError"])
        self.assertEqual(sum(call["action"] == "plugin_end" for call in self.backend.calls), 1)

    def test_notification_cancels_only_pending_read(self):
        self.init()
        self.request("read", "tools/call", {"name": "phonebridge_read_call", "arguments": {"session_id": SID, "wait_seconds": 20}})
        self.assertTrue(self.backend.first_read.wait(0.5))
        self.mcp.handle({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "read", "reason": "user typed"}})
        row = wait_row(self.out, "read")
        self.assertTrue(row["result"]["isError"])
        self.assertTrue(all(call["action"] == "plugin_read" for call in self.backend.calls))

    def test_malformed_oversize_depth_and_duplicate_json(self):
        cases = [b'{"id":1,"id":2}\n', b'{"jsonrpc":"2.0","id":NaN}\n', b'\xff\n', b'[' * 40 + b'0' + b']' * 40 + b'\n', b' ' * (server.MAX_LINE + 1) + b'\n']
        stream = io.BytesIO(b''.join(cases) + b'{"jsonrpc":"2.0","id":"ping","method":"ping"}\n')
        self.mcp.serve(stream)
        self.assertEqual(sum("error" in row for row in self.out.rows()), len(cases))
        self.assertEqual(self.out.rows()[-1]["result"], {})
        self.assertEqual(self.backend.calls, [])

    def test_unknown_tool_and_args_do_not_submit(self):
        self.init()
        for rid, params in enumerate([{"name": "shell", "arguments": {}}, {"name": "phonebridge_open_app", "arguments": {"path": "/tmp/other"}}, {"name": "phonebridge_end_call", "arguments": {"session_id": SID, "force": True}}]):
            self.request(rid, "tools/call", params)
            self.assertEqual(wait_row(self.out, rid)["error"]["code"], -32602)
        self.assertFalse(self.backend.calls)
        self.assertEqual(self.backend.open_count, 0)


class FakeHTTPResponse:
    def __init__(self, status=200, value=None, raw=None):
        self.status = status
        self.raw = raw if raw is not None else json.dumps(value).encode()
    def read(self, limit):
        return self.raw[:limit]


class FakeHTTPConnection:
    response = None
    instances = []
    def __init__(self, host, port, timeout):
        self.host, self.port, self.timeout = host, port, timeout
        self.closed = False; self.sent = None
        self.instances.append(self)
    def request(self, method, path, body, headers):
        self.sent = (method, path, body, headers)
    def getresponse(self):
        return self.response
    def close(self):
        self.closed = True


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "runtime.json"
        self.path.write_text(json.dumps({"port": 12345, "token": TOKEN, "pid": 123, "version": "fake"}))
        self.path.chmod(0o600)
        self.backend = server.LocalBackend(self.path)
        FakeHTTPConnection.instances = []

    def test_private_runtime_and_fixed_authenticated_loopback(self):
        FakeHTTPConnection.response = FakeHTTPResponse(value={"ok": True, "result": {"appRunning": True}})
        with mock.patch.object(server.http.client, "HTTPConnection", FakeHTTPConnection):
            data = self.backend.request({"action": "plugin_status"})
        conn = FakeHTTPConnection.instances[-1]
        self.assertEqual((conn.host, conn.port), ("127.0.0.1", 12345))
        self.assertEqual(conn.sent[:2], ("POST", "/command"))
        self.assertEqual(conn.sent[3]["Authorization"], "Bearer " + TOKEN)
        self.assertNotIn("Origin", conn.sent[3])
        self.assertTrue(conn.closed)
        self.assertTrue(data["appRunning"])

    def test_runtime_missing_symlink_permissions_and_bad_values(self):
        self.path.unlink()
        with self.assertRaises(server.SafeError): self.backend.credentials()
        other = Path(self.tmp.name) / "other"; other.write_text("{}"); self.path.symlink_to(other)
        with self.assertRaises(server.SafeError): self.backend.credentials()
        self.path.unlink(); self.path.write_text("{}"); self.path.chmod(0o644)
        with self.assertRaises(server.SafeError): self.backend.credentials()
        self.path.chmod(0o600)
        for values in [{"port": True, "token": TOKEN}, {"port": 99999, "token": TOKEN}, {"port": 12345, "token": "bad\r\nHeader: injected"}]:
            self.path.write_text(json.dumps(values))
            with self.assertRaises(server.SafeError): self.backend.credentials()

    def test_secrets_redacted_in_results_errors_and_stdout(self):
        FakeHTTPConnection.response = FakeHTTPResponse(value={"ok": True, "result": {"token": TOKEN, "message": "Bearer " + TOKEN, "api_key": "never-echo", "nested": ["sk-fakeSecretValue0123456789"]}})
        with mock.patch.object(server.http.client, "HTTPConnection", FakeHTTPConnection):
            result = self.backend.request({"action": "plugin_status"})
        serialized = json.dumps(result)
        self.assertNotIn(TOKEN, serialized); self.assertNotIn("never-echo", serialized); self.assertNotIn("sk-fake", serialized)
        out = LockedOutput(); mcp = server.MCPServer(self.backend, out); self.addCleanup(mcp.stop)
        mcp.send({"jsonrpc": "2.0", "id": 1, "result": {"message": TOKEN}})
        self.assertNotIn(TOKEN, json.dumps(out.rows()))
        FakeHTTPConnection.response = FakeHTTPResponse(status=400, value={"ok": False, "error": TOKEN})
        with mock.patch.object(server.http.client, "HTTPConnection", FakeHTTPConnection), self.assertRaises(server.SafeError) as caught:
            self.backend.request({"action": "plugin_start"})
        self.assertNotIn(TOKEN, str(caught.exception))

    def test_response_limits_redirects_and_no_mutation_retry(self):
        for response in [FakeHTTPResponse(status=302, value={}), FakeHTTPResponse(raw=b'{}' * (server.MAX_HTTP_BODY // 2 + 1)), FakeHTTPResponse(raw=b'{"ok":true,"ok":false}'), FakeHTTPResponse(value={"ok": True, "result": []})]:
            FakeHTTPConnection.instances = []; FakeHTTPConnection.response = response
            with mock.patch.object(server.http.client, "HTTPConnection", FakeHTTPConnection), self.assertRaises(server.SafeError):
                self.backend.request({"action": "plugin_start", "session_id": SID})
            self.assertEqual(len(FakeHTTPConnection.instances), 1)
            self.assertTrue(FakeHTTPConnection.instances[0].closed)
        with mock.patch.object(server.http.client.HTTPConnection, "request", side_effect=TimeoutError), self.assertRaisesRegex(server.SafeError, "outcome is unknown"):
            self.backend.request({"action": "plugin_start", "session_id": SID})

    def test_explicit_open_uses_only_fixed_application(self):
        with mock.patch.object(server.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            result = self.backend.open_app()
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", server.APP_PATH])
        self.assertFalse(result["appRunningVerified"])
        self.assertTrue(result["openRequested"])
        with mock.patch.object(server.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            self.backend.open_app(timeout=0.75, background=True)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/open", "-g", server.APP_PATH])
        self.assertEqual(run.call_args.kwargs["timeout"], 0.75)


if __name__ == "__main__":
    unittest.main(verbosity=2)
