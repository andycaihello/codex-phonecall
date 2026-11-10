#!/usr/bin/python3
"""Invoke one installed PhoneBridge MCP tool when Codex omits its tool namespace.

Read a JSON object with ``name`` and ``arguments`` from stdin. The request
still passes through the plugin adapter's validation and authenticated local
backend; this helper does not control Bluetooth or audio itself.
"""

import importlib.util
import json
import sys
import threading
from pathlib import Path


SERVER = Path(__file__).resolve().parents[1] / "mcp" / "server.py"


def main():
    raw = sys.stdin.buffer.read(65_537)
    if len(raw) > 65_536:
        raise ValueError("request exceeds 65536 bytes")
    spec = importlib.util.spec_from_file_location("phonebridge_adapter", SERVER)
    adapter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(adapter)
    request = adapter.strict_json(raw.decode("utf-8"))
    if not isinstance(request, dict) or set(request) != {"name", "arguments"}:
        raise ValueError("expected name and arguments")
    server = adapter.MCPServer()
    try:
        name = request["name"]
        arguments = adapter.validate_tool(name, request["arguments"])
        result = server.invoke_tool(name, arguments, threading.Event())
        response = {"result": server.backend.sanitize(result), "isError": False}
    except adapter.SafeError as error:
        response = {"error": server.backend.sanitize(str(error)), "isError": True}
    print(json.dumps(response, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        print(json.dumps({"error": str(error), "isError": True}, ensure_ascii=False))
        sys.exit(2)
