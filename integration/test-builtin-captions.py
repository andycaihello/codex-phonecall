#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="builtin-caption-checks-") as directory:
    build = Path(directory)
    core = [str(p) for p in (root / "Sources/BridgeCore").glob("*.swift")]
    subprocess.run(["swiftc", "-emit-library", "-emit-module", "-module-name", "BridgeCore", *core,
        "-emit-module-path", str(build / "BridgeCore.swiftmodule"), "-o", str(build / "libBridgeCore.dylib")], check=True, timeout=45)
    source = build / "BuiltinVoiceCaptionsChecks.swift"
    extra = r'''
extension BuiltinVoiceCaptions {
    static func offlineConfigurationLifetimeCheck() throws -> Bool {
        let c = BuiltinVoiceCaptions()
        let a = try PhonePeerConfiguration(address: "A1:B2:C3:D4:E5:F6", name: "Fixture A")
        let b = try PhonePeerConfiguration(address: "12:34:56:78:90:AB", name: "Fixture B")
        try c.configure(phone: a)
        func refuses(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        c.running = true
        guard refuses({ try c.configure(phone: b) }), refuses({ try c.clearPhoneConfiguration() }) else { return false }
        c.running = false; c.cleanupVerified = false
        guard refuses({ try c.configure(phone: b) }), refuses({ try c.clearPhoneConfiguration() }) else { return false }
        c.cleanupVerified = true; c.permissionRequest = UUID()
        guard refuses({ try c.configure(phone: b) }), refuses({ try c.clearPhoneConfiguration() }) else { return false }
        c.permissionRequest = nil; c.prepared = true
        try c.configure(phone: b)
        return c.phone == b && !c.prepared && c.cleanupVerified
    }
}
'''
    source.write_text((root / "Sources/PhoneBridge/BuiltinVoiceCaptions.swift").read_text() + extra)
    subprocess.run(["swiftc", "-parse-as-library", "-I", directory, "-L", directory, "-lBridgeCore",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
        str(root / "Sources/PhoneBridge/AudioDevices.swift"), str(root / "Sources/PhoneBridge/ModernCaptionRecognition.swift"), str(source),
        str(root / "integration/test-builtin-captions.swift"), "-o", str(build / "checks")], check=True, timeout=45)
    subprocess.run([str(build / "checks"), str(root / "integration/builtin-captions-offline-validation-20260909.json")], check=True, timeout=12)
