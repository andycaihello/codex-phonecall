#!/usr/bin/env python3
"""Install this personal plugin's immutable stdio service and set its launch path.

The Mac app is a separate signed application. No app launch, permissions, voice,
dialing, credentials, or plugin-marketplace changes occur here.
"""
from pathlib import Path
import hashlib
import json
import os
import argparse
import plistlib

parser = argparse.ArgumentParser(description="Configure PhoneBridge for this Mac user")
parser.add_argument("--app-path", type=Path, default=Path.home() / "Applications/PhoneBridge.app")
options = parser.parse_args()
app = options.app_path.expanduser().resolve()
if app.suffix != ".app" or not app.is_dir():
    raise SystemExit("Install PhoneBridge.app first, or specify --app-path")
with (app / "Contents/Info.plist").open("rb") as stream:
    if plistlib.load(stream).get("CFBundleIdentifier") != "cn.andy.phonebridge":
        raise SystemExit("The selected app is not PhoneBridge")

plugin = Path(__file__).resolve().parents[1]
source = (plugin / "mcp/server.py").read_bytes()
digest = hashlib.sha256(source).hexdigest()
directory = Path.home() / "Library/Application Support/PhoneBridge/mcp" / digest
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
target = directory / "server.py"
if target.exists():
    if target.is_symlink() or target.read_bytes() != source:
        raise SystemExit("Existing runtime does not match its content hash")
else:
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o700)
    with os.fdopen(fd, "wb") as stream:
        stream.write(source)
configuration = {"mcpServers": {"phonebridge": {
    "command": "/usr/bin/python3", "args": [str(target)], "startup_timeout_sec": 15, "tool_timeout_sec": 30,
    "env": {"PHONEBRIDGE_APP_PATH": str(app)}
}}}
(plugin / ".mcp.json").write_text(json.dumps(configuration, indent=2) + "\n")
print(json.dumps({"runtime": str(target), "sha256": digest, "appLaunched": False}))
