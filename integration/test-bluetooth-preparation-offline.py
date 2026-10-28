#!/usr/bin/env python3
"""Fake subprocess/JSON tests only; never executes prepare-phone-acl or Bluetooth."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

SWIFT = r'''
import Foundation
import Darwin
import BridgeCore
@main @MainActor struct PreparationChecks {
    static var checks: [String] = []
    static let phone = try! PhonePeerConfiguration(address: "AA:BB:CC:DD:EE:FF", name: "Offline Test Phone")
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name); checks.append(name)
    }
    static func path(_ mode: String) -> URL {
        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(mode)
    }
    static func failed(_ mode: String, timeout: Double = 16) async {
        let prep = BluetoothConnectionPreparation(timeout: timeout)
        do { _ = try await prep.prepare(path(mode), phone: phone); preconditionFailure("accepted " + mode) }
        catch {
            check(prep.cleanupVerified, "reject and reap " + mode)
            if mode == "bad-exit" {
                check(prep.lastResult["exitStatus"] as? Int == 7 && prep.lastResult["extra"] == nil,
                      "retain sanitized failed-exit diagnostics only")
            } else { check(prep.lastResult.isEmpty, "invalid result not retained " + mode) }
        }
    }
    static func main() async throws {
        for mode in ["fresh", "existing", "post-reset", "stderr"] {
            let prep = BluetoothConnectionPreparation()
            let result = try await prep.prepare(path(mode), phone: phone)
            check(prep.cleanupVerified && result["ok"] as? Bool == true, "accept validated exit and JSON " + mode)
            check(result.count == 10, "only known result fields retained " + mode)
        }
        for mode in ["no-callback", "no-disconnect", "numeric-bool", "double-json", "bad-exit", "oversize", "missing"] {
            await failed(mode)
        }
        await failed("timeout", timeout: 1)
        let timeoutPID = try String(contentsOf: path("timeout.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        errno = 0
        check(kill(Int32(timeoutPID)!, 0) == -1 && errno == ESRCH, "timeout ignoring TERM is killed and reaped")

        let cancelPrep = BluetoothConnectionPreparation()
        let operation = Task { try await cancelPrep.prepare(path("cancel"), phone: phone) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path("cancel.pid").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        operation.cancel()
        do { _ = try await operation.value; preconditionFailure("cancelled prepare succeeded") }
        catch { check(error is CancellationError, "running cancellation preserves cancellation outcome") }
        check(cancelPrep.cleanupVerified, "running cancellation awaits owned child exit")
        let cancelPID = try String(contentsOf: path("cancel.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        errno = 0
        check(kill(Int32(cancelPID)!, 0) == -1 && errno == ESRCH, "cancelled child has no surviving PID")

        let beforePrep = BluetoothConnectionPreparation()
        let before = Task { try await beforePrep.prepare(path("never-start"), phone: phone) }
        before.cancel()
        do { _ = try await before.value; preconditionFailure("pre-cancel succeeded") }
        catch { check(error is CancellationError, "pre-start cancellation stays cancelled") }
        check(beforePrep.cleanupVerified && !FileManager.default.fileExists(atPath: path("never-start.pid").path), "pre-start cancellation never launches child")
        check(await beforePrep.stopAndWait(), "idle cleanup is idempotent")
        let data = try JSONSerialization.data(withJSONObject: ["passed": true, "count": checks.count,
            "checks": checks, "bluetoothOperations": 0, "appLaunches": 0, "apiRequests": 0], options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
'''

FAKE = r'''
import sys,json,os,signal,time
from pathlib import Path
assert sys.argv[1:]==['--prepare-paired-phone','--phone-address','AA:BB:CC:DD:EE:FF','--phone-name','Offline Test Phone']
p=Path(sys.argv[0]); mode=p.name
if mode=='timeout': signal.signal(signal.SIGTERM, signal.SIG_IGN)
p.with_name(mode+'.pid').write_text(str(os.getpid()))
if mode in ('timeout','cancel'):
 while True: time.sleep(1)
r={'ok':True,'connectedObserved':True,'connectedBefore':False,'freshACLRequested':True,
   'callbackSeen':True,'status':0,'disconnectedObserved':True,'connectionPreserved':True,'extra':'not-retained'}
if mode=='existing': r.update(connectedBefore=True)
if mode=='post-reset': r.update(connectedBefore=True,freshACLRequested=False,callbackSeen=False,postResetConnectionObserved=True)
if mode=='no-callback': r['callbackSeen']=False
if mode=='no-disconnect': r['disconnectedObserved']=False
if mode=='numeric-bool': r['ok']=1
if mode=='stderr': print('private diagnostic which must never be surfaced',file=sys.stderr)
if mode=='oversize': print('x'*17000); sys.exit(0)
print(json.dumps(r),flush=True)
if mode=='double-json': print(json.dumps(r),flush=True)
sys.exit(7 if mode=='bad-exit' else 0)
'''


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required")
    with tempfile.TemporaryDirectory(prefix="phonebridge-preparation-offline-") as directory:
        build = Path(directory)
        for mode in ["fresh", "existing", "post-reset", "stderr", "no-callback", "no-disconnect", "numeric-bool", "double-json",
                     "bad-exit", "oversize", "timeout", "cancel", "never-start"]:
            fake = build / mode
            fake.write_text("#!" + sys.executable + "\n" + FAKE)
            fake.chmod(0o700)
        source = build / "check.swift"
        source.write_text(SWIFT)
        subprocess.run([compiler, "-emit-library", "-emit-module", "-module-name", "BridgeCore",
                        str(root / "Sources/BridgeCore/Protocol.swift"), str(root / "Sources/BridgeCore/PhonePeerConfiguration.swift"),
                        "-emit-module-path", str(build / "BridgeCore.swiftmodule"),
                        "-o", str(build / "libBridgeCore.dylib")], check=True, timeout=60)
        executable = build / "check"
        subprocess.run([compiler, "-parse-as-library", "-I", str(build), "-L", str(build), "-lBridgeCore",
                        "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                        str(root / "Sources/PhoneBridge/BluetoothConnectionPreparation.swift"), str(source),
                        "-o", str(executable)], check=True, timeout=60)
        result = subprocess.run([str(executable), str(build)], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise SystemExit(result.stderr)
        report = json.loads(result.stdout)
        (root / "integration/bluetooth-preparation-offline-validation-20260908.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(result.stdout, end="")


if __name__ == "__main__":
    main()
