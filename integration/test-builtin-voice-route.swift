import Foundation
import CoreAudio
import BridgeCore

@MainActor
private final class FakeRouteHardware: BuiltinVoiceRouteHardware {
    nonisolated static let configuration = try! PhonePeerConfiguration(address: "A1:B2:C3:D4:E5:F6", name: "Fixture Phone A")
    var inventory: [BuiltinVoiceRouteDevice]
    var defaults: [BuiltinVoiceRouteDirection: AudioDeviceID] = [.input: 10, .output: 11]
    var settable = true
    var reads = 0
    var writes: [(BuiltinVoiceRouteDirection, AudioDeviceID)] = []
    var hook: ((AudioDeviceID, BuiltinVoiceRouteDirection) throws -> Void)?
    init() { inventory = [Self.device(10, "prior-input"), Self.device(11, "prior-output"),
                          Self.device(12, "foreign"), Self.phone(true), Self.phone(false)] }
    static func device(_ id: UInt32, _ uid: String, alive: Bool = true) -> BuiltinVoiceRouteDevice {
        BuiltinVoiceRouteDevice(id: id, uid: uid, name: "fixture", alive: alive, bluetooth: false,
            inputChannels: 2, outputChannels: 2, phoneFormat: false, canBeDefaultInput: true, canBeDefaultOutput: true)
    }
    static func phone(_ input: Bool, id: UInt32? = nil, name: String = FakeRouteHardware.configuration.name,
                      alive: Bool = true, bluetooth: Bool = true, channels: Int = 1,
                      format: Bool = true, selectable: Bool = true) -> BuiltinVoiceRouteDevice {
        BuiltinVoiceRouteDevice(id: id ?? (input ? 20 : 21),
            uid: input ? FakeRouteHardware.configuration.inputUID : FakeRouteHardware.configuration.outputUID,
            name: name, alive: alive, bluetooth: bluetooth,
            inputChannels: input ? channels : 0, outputChannels: input ? 0 : channels,
            phoneFormat: format, canBeDefaultInput: selectable, canBeDefaultOutput: selectable)
    }
    func devices() throws -> [BuiltinVoiceRouteDevice] { reads += 1; return inventory }
    func defaultDevice(_ direction: BuiltinVoiceRouteDirection) throws -> AudioDeviceID { defaults[direction]! }
    func defaultIsSettable(_ direction: BuiltinVoiceRouteDirection) throws -> Bool { settable }
    func setDefaultDevice(_ id: AudioDeviceID, direction: BuiltinVoiceRouteDirection) throws {
        writes.append((direction, id)); try hook?(id, direction); defaults[direction] = id
    }
}

@main
private struct RouteChecks {
    @MainActor static func main() throws {
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: " + name) }; checks.append(name)
        }
        func fixture() -> (FakeRouteHardware, BuiltinVoiceRoute) {
            let h = FakeRouteHardware(); let r = BuiltinVoiceRoute(hardware: h, automaticallyMonitor: false)
            try! r.configure(phone: FakeRouteHardware.configuration); return (h, r)
        }
        func mustFail(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let simulated = BuiltinVoiceRouteError(message: "simulated")
        do {
            let (h, r) = fixture()
            check(h.reads == 0 && h.writes.isEmpty, "initialization performs no HAL calls")
            check(r.inspect().ready && h.writes.isEmpty, "inspection is read-only")
            try r.activate(changeInput: false, changeOutput: true)
            check(r.active && h.defaults[.input] == 10 && h.defaults[.output] == 21 && h.writes.count == 1,
                  "default activation changes output only")
            try r.activate(changeInput: false, changeOutput: true)
            check(h.writes.count == 1, "repeated matching activation is idempotent")
            r.stop()
            check(!r.active && h.defaults[.input] == 10 && h.defaults[.output] == 11, "explicit stop restores owned output")
        }
        do {
            let (h, r) = fixture()
            h.hook = { id, direction in if direction == .output && id == 21 { throw simulated } }
            check(mustFail { try r.activate(changeInput: true, changeOutput: true) }, "second-field failure is surfaced")
            check(!r.active && h.defaults[.input] == 10 && h.defaults[.output] == 11,
                  "activation failure rolls back first field")
        }
        do {
            let (h, r) = fixture()
            h.hook = { [weak h] id, direction in
                if direction == .output && id == 21 { h?.defaults[.output] = 21; throw simulated }
            }
            check(mustFail { try r.activate(changeInput: true, changeOutput: true) }, "partially applied write error is surfaced")
            check(!r.active && h.defaults[.input] == 10 && h.defaults[.output] == 11,
                  "rollback owns partial write even when setter throws")
        }
        do {
            let (h, r) = fixture()
            try r.activate(changeInput: true, changeOutput: true)
            h.defaults[.input] = 12; r.stop()
            check(!r.active && h.defaults[.input] == 12 && h.defaults[.output] == 11,
                  "foreign input choice preserved while owned output restored")
        }
        do {
            let (h, r) = fixture(); var failures = 0
            r.onFailure = { _ in failures += 1 }; try r.activate()
            h.defaults[.output] = 12; let before = h.writes.count
            r.checkForChanges(); r.checkForChanges()
            check(failures == 1 && r.active && !r.inspect().ready && h.writes.count == before,
                  "default-change fault latches once without restoring")
            r.stop()
            check(!r.active && h.defaults[.output] == 12 && h.writes.count == before,
                  "explicit stop preserves foreign output")
        }
        do {
            let (h, r) = fixture(); var failures = 0
            r.onFailure = { _ in failures += 1 }; try r.activate()
            h.inventory.removeAll { $0.uid == FakeRouteHardware.configuration.inputUID }
            let before = h.writes.count; r.checkForChanges()
            check(failures == 1 && r.active && !r.status.available && h.writes.count == before && h.defaults[.output] == 21,
                  "endpoint disappearance never auto-restores speakers")
        }
        for (name, replacement) in [
            ("name", FakeRouteHardware.phone(true, name: "different")),
            ("alive", FakeRouteHardware.phone(true, alive: false)),
            ("transport", FakeRouteHardware.phone(true, bluetooth: false)),
            ("channels", FakeRouteHardware.phone(true, channels: 2)),
            ("format", FakeRouteHardware.phone(true, format: false))] {
            let (h, r) = fixture(); try r.activate()
            h.inventory.removeAll { $0.uid == FakeRouteHardware.configuration.inputUID }; h.inventory.append(replacement)
            let before = h.writes.count; r.checkForChanges()
            check(!r.inspect().ready && r.active && h.writes.count == before, "identity monitor rejects changed " + name)
        }
        do {
            let (h, r) = fixture(); h.inventory.append(FakeRouteHardware.phone(true, id: 22))
            check(!r.inspect().ready && mustFail { try r.activate() } && h.writes.isEmpty,
                  "duplicate fixed UID is rejected before mutation")
        }
        do {
            let (h, r) = fixture(); try r.activate(); let before = h.writes.count
            r.stop(restore: false)
            check(r.active && !r.inspect().ready && h.defaults[.output] == 21 && h.writes.count == before,
                  "stop without restoration holds route and responsibility")
            check(mustFail { try r.activate() }, "held unready route cannot be silently reactivated")
            r.stop(); check(!r.active && h.defaults[.output] == 11, "later explicit restore still has original UID")
        }
        do {
            let (h, r) = fixture(); try r.activate()
            h.inventory.removeAll { $0.uid == "prior-output" }; let before = h.writes.count; r.stop()
            check(r.active && h.writes.count == before && h.defaults[.output] == 21,
                  "missing prior device retains pending restore without substitute")
            h.inventory.append(FakeRouteHardware.device(41, "prior-output")); r.stop()
            check(!r.active && h.defaults[.output] == 41, "restoration resolves stable UID to fresh device ID")
        }
        do {
            let (h, r) = fixture(); try r.activate()
            h.hook = { id, _ in if id == 11 { throw simulated } }; r.stop()
            check(r.active && h.defaults[.output] == 21, "failed restore keeps ownership")
            h.hook = nil; r.stop(); check(!r.active && h.defaults[.output] == 11, "explicit restore retry succeeds")
        }
        do {
            let (h, r) = fixture(); h.defaults[.output] = 21; try r.activate(); r.stop()
            check(!r.active && h.defaults[.output] == 21 && h.writes.isEmpty, "preexisting phone default is never owned or undone")
        }
        do {
            let (h, r) = fixture(); h.settable = false
            check(r.inspect().ready && !r.status.canRouteOutput, "per-app inspection does not require writable system defaults")
            check(mustFail { try r.activate() } && h.writes.isEmpty, "read-only default property rejects activation")
            try r.activate(changeInput: false, changeOutput: false)
            check(r.active && r.inspect().ready && h.writes.isEmpty, "per-app monitoring mode changes neither default")
            r.stop(); check(!r.active && h.writes.isEmpty, "per-app monitoring stop has nothing to restore")
        }
        do {
            let (h, r) = fixture()
            h.hook = { [weak h] id, direction in
                if direction == .output && id == 21 { h?.defaults[.input] = 12; throw simulated }
            }
            _ = mustFail { try r.activate(changeInput: true, changeOutput: true) }
            check(!r.active && h.defaults[.input] == 12 && h.defaults[.output] == 11,
                  "rollback preserves a foreign choice made during activation")
        }
        do {
            let h = FakeRouteHardware()
            let r = BuiltinVoiceRoute(hardware: h, automaticallyMonitor: false)
            check(!r.inspect().ready && mustFail { try r.activate() }, "unconfigured route rejects inspect and activation")
            check(h.reads == 0 && h.writes.isEmpty, "no implicit legacy phone selection")
            try r.configure(phone: FakeRouteHardware.configuration)
            try r.clearPhoneConfiguration()
            check(!r.inspect().ready, "forgetting phone removes route identity")
        }
        do {
            let (h, r) = fixture()
            let other = try PhonePeerConfiguration(address: "12:34:56:78:90:AB", name: "另一个模拟手机")
            try r.activate()
            check(mustFail { try r.configure(phone: other) } && mustFail { try r.clearPhoneConfiguration() },
                  "active route rejects switching or clearing phone")
            r.stop(); try r.configure(phone: other)
            check(!r.inspect().ready && h.writes.count == 2, "new identity never falls back to old phone")
            for input in [true, false] {
                h.inventory.append(BuiltinVoiceRouteDevice(id: input ? 30 : 31,
                    uid: input ? other.inputUID : other.outputUID, name: other.name, alive: true,
                    bluetooth: true, inputChannels: input ? 1 : 0, outputChannels: input ? 0 : 1,
                    phoneFormat: true, canBeDefaultInput: true, canBeDefaultOutput: true))
            }
            try r.activate()
            check(h.defaults[.output] == 31 && r.inspect().ready, "only explicitly configured second phone is routed")
            r.stop()
        }
        let report: [String: Any] = ["passed": checks.count, "checks": checks,
            "hardware": "injected fake only", "realHALQueries": false, "realRouteChanges": false,
            "audioIO": false, "appsLaunched": false, "network": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
