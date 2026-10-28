#!/usr/bin/env python3
"""Build and run a temporary local HTTP stub, without launching the App."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="caption-web-checks-") as temporary:
    binary = str(Path(temporary) / "caption-checks")
    subprocess.run(["swiftc", str(root / "Sources/PhoneBridge/CaptionWebServer.swift"),
                    str(root / "integration/test-caption-web.swift"), "-o", binary], check=True, timeout=45)
    subprocess.run([binary, str(root / "integration/caption-web-offline-validation-20260909.json")], check=True, timeout=15)
