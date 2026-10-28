#!/usr/bin/env python3
"""Compile only PluginCallSession against fake dependencies; no live app/services."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "Sources/PhoneBridge/PluginCallSession.swift"
report = root / "integration/plugin-call-session-validation.json"
with tempfile.TemporaryDirectory(prefix="phonebridge-plugin-session-offline-") as temporary:
    build = Path(temporary)
    subprocess.run([
        "xcrun", "swiftc", "-emit-library", "-emit-module", "-module-name", "BridgeCore",
        str(root / "Sources/BridgeCore/Protocol.swift"), str(root / "Sources/BridgeCore/PhoneNumber.swift"),
        str(root / "Sources/BridgeCore/PhonePeerConfiguration.swift"),
        "-emit-module-path", str(build / "BridgeCore.swiftmodule"), "-o", str(build / "libBridgeCore.dylib"),
    ], check=True, timeout=30)
    exe = build / "plugin-session-check"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-I", str(build), "-L", str(build), "-lBridgeCore",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path", str(source),
        str(root / "Sources/PhoneBridge/ConversationMode.swift"),
        str(root / "integration/test-plugin-call-session.swift"), "-o", str(exe),
    ], check=True, timeout=30)
    result = subprocess.run([str(exe), str(build / "fixtures"), str(report)], timeout=15)
    data = json.loads(report.read_text())
    data["sourceSHA256"] = hashlib.sha256(source.read_bytes()).hexdigest()
    report.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    raise SystemExit(result.returncode)
