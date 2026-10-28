#!/usr/bin/env python3
"""Local control client. No network listener; credentials never printed."""
import argparse
import json
import pathlib
import sys
import urllib.request
import urllib.error

RUNTIME = pathlib.Path.home() / "Library/Application Support/PhoneBridge/runtime.json"

def request(command):
    runtime = json.loads(RUNTIME.read_text())
    req = urllib.request.Request(
        f"http://127.0.0.1:{int(runtime['port'])}/command",
        data=json.dumps(command).encode(),
        headers={"Authorization": "Bearer " + runtime["token"], "Content-Type": "application/json"},
        method="POST",
    )
    # This is a loopback service; never send its credentials through a configured proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=8) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        result = json.load(exc)
    if not result.get("ok"):
        raise RuntimeError(result.get("error", "Unknown bridge error"))
    return result["result"]

def main():
    parser = argparse.ArgumentParser(description="控制运行中的 PhoneBridge Mac 应用")
    parser.add_argument("action", choices=["status", "devices", "advertise_hf", "sdp_probe", "raw_hfp_probe", "reset_phone_link", "connect", "disconnect", "dial", "hangup",
        "dtmf", "audio_to_mac", "takeover", "audio_start", "audio_stop", "speak", "stop_speech", "record_test", "report",
        "session_connect", "session_dial", "session_start_ai", "session_hangup", "session_disconnect", "session_interrupt"])
    parser.add_argument("--address")
    parser.add_argument("--number")
    parser.add_argument("--key")
    parser.add_argument("--text")
    parser.add_argument("--input-id", type=int, dest="inputID")
    parser.add_argument("--output-id", type=int, dest="outputID")
    command = {k: v for k, v in vars(parser.parse_args()).items() if v is not None}
    try:
        print(json.dumps(request(command), ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"PhoneBridge: {exc}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
