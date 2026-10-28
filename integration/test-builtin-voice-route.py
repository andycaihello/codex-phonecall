#!/usr/bin/env python3
"""Run route policy against injected fake HAL; never enumerate/open real devices."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="phonebridge-route-offline-") as temporary:
    build = Path(temporary)
    subprocess.run(["xcrun", "swiftc", "-emit-library", "-emit-module", "-module-name", "BridgeCore",
                    str(root / "Sources/BridgeCore/PhonePeerConfiguration.swift"),
                    "-emit-module-path", str(build / "BridgeCore.swiftmodule"),
                    "-o", str(build / "libBridgeCore.dylib")], check=True, timeout=30)
    exe = build / "route-check"
    subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", "-I", temporary, "-L", temporary, "-lBridgeCore",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    str(root / "Sources/PhoneBridge/BuiltinVoiceRoute.swift"),
                    str(root / "integration/test-builtin-voice-route.swift"), "-framework", "CoreAudio", "-o", str(exe)],
                   check=True, timeout=30)
    result = subprocess.run([str(exe)], capture_output=True, text=True, check=True, timeout=10)
    (root / "integration/builtin-voice-route-validation.json").write_text(result.stdout)
    print(result.stdout)
