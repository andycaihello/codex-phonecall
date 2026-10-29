#!/usr/bin/env python3
"""Build Coordinator against fakes; never link real Keychain/device/API classes."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='phonebridge-service-preflight-offline-') as temporary:
    build = Path(temporary)
    subprocess.run(['swiftc', '-emit-library', '-emit-module', '-module-name', 'BridgeCore',
                    str(root / 'Sources/BridgeCore/Protocol.swift'), str(root / 'Sources/BridgeCore/RealtimeProtocol.swift'), str(root / 'Sources/BridgeCore/PhoneNumber.swift'),
                    str(root / 'Sources/BridgeCore/PhonePeerConfiguration.swift'),
                    '-emit-module-path', str(build / 'BridgeCore.swiftmodule'), '-o', str(build / 'libBridgeCore.dylib')], check=True, timeout=60)
    exe = build / 'preflight-check'
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(build), '-L', str(build), '-lBridgeCore',
                    '-Xlinker', '-rpath', '-Xlinker', '@executable_path',
                    str(root / 'Sources/PhoneBridge/CallSessionCoordinator.swift'),
                    str(root / 'Sources/PhoneBridge/CodexVoiceCaptions.swift'),
                    str(root / 'Sources/PhoneBridge/ConversationMode.swift'),
                    str(root / 'integration/test-voice-service-preflight.swift'), '-o', str(exe)], check=True, timeout=60)
    subprocess.run([str(exe), str(root / 'integration/voice-service-preflight-validation.json')], check=True, timeout=30)
