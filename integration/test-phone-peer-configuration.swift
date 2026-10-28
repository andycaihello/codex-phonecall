import Foundation

@main struct ConfigurationChecks {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            count += 1; precondition(value(), label)
        }
        func fails(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let canonical = try PhonePeerConfiguration(address: "AA:BB:CC:DD:EE:FF", name: "Offline Phone")
        let normalized = try PhonePeerConfiguration(address: "aa-bb-cc-dd-ee-ff", name: "Offline Phone")
        check(canonical == normalized, "UI accepts paired-device notation and normalizes native arguments")
        check(canonical.inputUID == "AA-BB-CC-DD-EE-FF:input" && canonical.outputUID == "AA-BB-CC-DD-EE-FF:output",
              "both audio directions are derived from the same selected address")
        let unicode = try PhonePeerConfiguration(address: "01:23:45:67:89:AB", name: String(repeating: "é", count: 64))
        check(unicode.name.utf8.count == 128, "name limit counts UTF-8 bytes")
        let encoded = try JSONEncoder().encode(canonical)
        let decoded = try JSONDecoder().decode(PhonePeerConfiguration.self, from: encoded)
        check(decoded == canonical, "valid selected identity round-trips")
        for address in ["", " AA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:FF\n", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:FF:00",
                        "AA::BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:FG", "AA:BB:CC:DD:EE:F", "ＡＡ:BB:CC:DD:EE:FF", "AA BB CC DD EE FF"] {
            check(fails { _ = try PhonePeerConfiguration(address: address, name: "Offline Phone") }, "invalid address initializer")
            let bytes = try JSONSerialization.data(withJSONObject: ["address": address, "name": "Offline Phone"])
            check(fails { _ = try JSONDecoder().decode(PhonePeerConfiguration.self, from: bytes) }, "codec cannot bypass address validation")
        }
        for name in ["", "   ", "\n", "name\tother", "name\u{0000}other", "name\u{007F}", "--validate-args", String(repeating: "é", count: 65)] {
            check(fails { _ = try PhonePeerConfiguration(address: canonical.address, name: name) }, "invalid name initializer")
            let bytes = try JSONSerialization.data(withJSONObject: ["address": canonical.address, "name": name])
            check(fails { _ = try JSONDecoder().decode(PhonePeerConfiguration.self, from: bytes) }, "codec cannot bypass name validation")
        }
        for data in ["{}", "{\"address\":\"AA:BB:CC:DD:EE:FF\"}", "{\"name\":\"Offline Phone\"}",
                     "{\"address\":null,\"name\":\"Offline Phone\"}", "{\"address\":\"AA:BB:CC:DD:EE:FF\",\"name\":123}", "[]"] {
            check(fails { _ = try JSONDecoder().decode(PhonePeerConfiguration.self, from: Data(data.utf8)) },
                  "missing or wrong-typed fields have no implicit personal defaults")
        }
        let result: [String: Any] = ["passed": true, "checks": count, "deviceQueries": false, "permissionQueries": false, "appLaunches": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
