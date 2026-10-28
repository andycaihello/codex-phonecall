#!/usr/bin/env python3
"""Read-only documentation preview of the real console with synthetic data.

No runtime tokens, phone, Bluetooth, microphone, permissions or API access.
POST is deliberately unsupported. Stop with Ctrl+C after capturing screenshots.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
STATE = {
    "backendRunning": True, "version": "0.7.7", "modeID": "builtin_voice",
    "connected": True, "callActive": False, "busy": False,
    "status": "文档演示 · 以下设备、号码及字幕均为示例数据，不代表真实通话。",
    "phoneConfigured": True, "phoneName": "HarmonyOS 测试手机",
    "phoneAddress": "AA:BB:CC:DD:EE:FF",
    "pairedPhones": [{"name": "HarmonyOS 测试手机", "address": "AA:BB:CC:DD:EE:FF"}],
    "number": "13800000000", "maximumSeconds": 60,
    "instructions": "说明你是机主委托的 AI 助手，进行简短的电话语音测试。确认双方能否听清，结束后挂断并总结。",
    "voice": "marin", "microphonePermission": "authorized", "speechPermission": "authorized",
    "continuousVoiceInstalled": True, "continuousVoiceActive": True,
    "continuousVoiceReady": True, "continuousVoiceTarget": "owner",
    "builtinRouteActive": True, "builtinRouteReady": True, "builtinVoiceConfirmed": True,
    "bluetoothCallControlReady": True,
    "diagnosticSummary": "文档预览：未连接真实手机，未调用生产后端。",
    "captionWarning": "双方字幕演示 · 本页不采集音频、不拨号。",
    "transcript": [
        {"id": "example-1", "role": "AI", "final": True, "text": "你好，我是机主委托的 AI 助手。这是一次电话语音测试，你能听清吗？"},
        {"id": "example-2", "role": "对方", "final": True, "text": "能听清，声音很清楚。"},
        {"id": "example-3", "role": "AI", "final": True, "text": "收到，谢谢配合。我会结束测试，并把结果整理到当前对话。"},
    ],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/state":
            data = json.dumps(STATE, ensure_ascii=False).encode()
            kind = "application/json; charset=utf-8"
        elif self.path == "/":
            data = (ROOT / "Sources/PhoneBridge/Resources/Web/console.html").read_bytes()
            kind = "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"Documentation preview only: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
