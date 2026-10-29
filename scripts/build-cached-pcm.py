#!/usr/bin/env python3
"""Keep the PCM helper's signing identity unchanged across unrelated App builds."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
audio = root / "integration/audio"
cache = audio / "pcm-build-cache.json"
inputs = [audio / x for x in ["build-pcm-bridge.sh", "phonebridge-pcm.mm", "pcm-dsp.hpp", "pcm-rings.hpp", "private-ipc.hpp"]]
inputs.append(root / "integration/phone-identity-arguments.h")
digest = hashlib.sha256(b"".join(p.name.encode() + p.read_bytes() for p in inputs)).hexdigest()
binary = audio / "PhoneBridgePCM.app/Contents/MacOS/phonebridge-pcm"
plist = audio / "PhoneBridgePCM.app/Contents/Info.plist"


def output_hash():
    return hashlib.sha256(binary.read_bytes() + plist.read_bytes()).hexdigest()


try:
    old = json.loads(cache.read_text())
    reuse = old.get("inputs") == digest and old.get("output") == output_hash()
    if reuse:
        subprocess.run(["codesign", "--verify", "--strict", str(audio / "PhoneBridgePCM.app")], check=True, capture_output=True)
except (OSError, ValueError, subprocess.CalledProcessError):
    reuse = False
if reuse:
    print("PCM source unchanged; reusing the verified, signed audio helper.")
else:
    subprocess.run(["sh", str(audio / "build-pcm-bridge.sh")], check=True)
    cache.write_text(json.dumps({"inputs": digest, "output": output_hash()}))
