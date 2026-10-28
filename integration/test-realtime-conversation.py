#!/usr/bin/env python3
"""Compile/run only fake-transport Realtime checks; no app, device, or API access."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path,
                        default=root / "integration/realtime-offline-validation-20260908.json")
    args = parser.parse_args()
    compiler = shutil.which("swiftc")
    if compiler is None:
        parser.error("swiftc is required")
    report = args.report.expanduser().resolve()
    if not report.parent.is_dir():
        parser.error("report parent must already exist")
    with tempfile.TemporaryDirectory(prefix="phonebridge-realtime-offline-") as temporary:
        build = Path(temporary)
        subprocess.run([
            compiler, "-emit-library", "-emit-module", "-module-name", "BridgeCore",
            str(root / "Sources/BridgeCore/RealtimeProtocol.swift"),
            "-emit-module-path", str(build / "BridgeCore.swiftmodule"),
            "-o", str(build / "libBridgeCore.dylib"),
        ], cwd=root, check=True, timeout=60)
        executable = build / "realtime-checks"
        subprocess.run([
            compiler, "-parse-as-library", "-I", str(build), "-L", str(build),
            "-lBridgeCore", "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
            str(root / "Sources/PhoneBridge/RealtimeConversation.swift"),
            str(root / "integration/test-realtime-conversation.swift"),
            "-o", str(executable),
        ], cwd=root, check=True, timeout=60)
        subprocess.run([str(executable), str(report)], cwd=root, check=True, timeout=15)


if __name__ == "__main__":
    main()
