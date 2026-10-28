#!/usr/bin/env python3
"""Pure identity init/Codable validation, never links Bluetooth or app services."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'Sources/BridgeCore/PhonePeerConfiguration.swift'
with tempfile.TemporaryDirectory(prefix='phonebridge-phone-configuration-offline-') as temporary:
    exe = Path(temporary) / 'configuration-check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source),
                    str(root / 'integration/test-phone-peer-configuration.swift'), '-o', str(exe)], check=True, timeout=30)
    result = subprocess.run([str(exe)], capture_output=True, text=True, check=True, timeout=3)
    report = json.loads(result.stdout)
    report['sourceSHA256'] = hashlib.sha256(source.read_bytes()).hexdigest()
    (root / 'integration/phone-peer-configuration-validation-20260909.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
