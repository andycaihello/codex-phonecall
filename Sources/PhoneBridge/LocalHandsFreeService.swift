import Foundation
import IOBluetooth
import BridgeCore

/// Advertise the Mac's HF role while testing the selected phone. The SDP entry
/// is transient, so macOS also removes it when this process exits.
final class LocalHandsFreeService {
    private var record: IOBluetoothSDPServiceRecord?
    private var lastPublished: [String: Any] = [:]
    private var ownsRecord = false
    private var publishedFeatures: UInt16?

    private func matchesHandsFreeRole(_ record: IOBluetoothSDPServiceRecord) -> Bool {
        let classes = record.getAttributeDataElement(0x0001)?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
        let expected = IOBluetoothSDPUUID(uuid16: 0x111e)
        return classes.contains { $0.getUUIDValue()?.isEqual(to: expected) == true }
    }

    var diagnostic: [String: Any] {
        guard let record else { return ["published": false, "lastPublication": lastPublished] }
        return ["published": true, "handsFreeRoleMatches": matchesHandsFreeRole(record), "name": record.getServiceName() ?? "",
            "requestedFeatures": publishedFeatures.map { Int($0) as Any } ?? NSNull(),
            "returnedFeatures": record.getAttributeDataElement(0x0311)?.getNumberValue() as Any? ?? NSNull(),
            "serviceClasses": record.getAttributeDataElement(0x0001)?.description ?? "",
            "protocols": record.getAttributeDataElement(0x0004)?.description ?? "",
            "profile": record.getAttributeDataElement(0x0009)?.description ?? "",
            "features": record.getAttributeDataElement(0x0311)?.description ?? ""]
    }

    // Both incoming and outgoing HF implementations negotiate AT+BRSF=0.
    // Keep discovery's capability declaration consistent with that baseline.
    func start(supportedFeatures: UInt16 = 0) throws -> UInt8 {
        if let record {
            guard publishedFeatures == supportedFeatures else { throw BridgeError("本机免提服务已有不同能力声明，请先断开。") }
            return try channel(of: record)
        }
        func uuid(_ value: UInt16) -> Data {
            Data([UInt8(value >> 8), UInt8(value & 0xff)])
        }
        func bluetoothBaseUUID(_ value: UInt16) -> Data {
            Data([0x00, 0x00, UInt8(value >> 8), UInt8(value & 0xff),
                  0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb])
        }
        func uint(_ value: Int, bytes: Int) -> [String: Any] {
            ["DataElementType": 1, "DataElementSize": bytes, "DataElementValue": value]
        }
        // macOS 26.6.2 rewrites the compact 16-bit 0x111E service into its
        // built-in 0x111F Audio Gateway record. The equivalent 128-bit
        // Bluetooth Base UUID is preserved and is equal across UUID widths.
        let handsFree = bluetoothBaseUUID(0x111e)
        let attributes: [AnyHashable: Any] = [
            // Keep the full UUID first so macOS does not substitute its built-in
            // Audio Gateway record. A compact HF UUID in the second slot lets
            // phones whose profile matcher only recognizes assigned-number
            // encodings discover the same role.
            "0001 - ServiceClassIDList": [handsFree, uuid(0x111e), uuid(0x1203)],
            "0003 - ServiceID": bluetoothBaseUUID(0x4306),
            "0004 - ProtocolDescriptorList": [
                [uuid(0x0100)],
                [uuid(0x0003), uint(2, bytes: 1)]
            ],
            "0005 - BrowseGroupList": [uuid(0x1002)],
            "0009 - BluetoothProfileDescriptorList": [[handsFree, uint(0x0105, bytes: 2)]],
            "0100 - ServiceName": "PhoneBridge Hands-Free",
            "0311 - Supported Features": uint(Int(supportedFeatures), bytes: 2),
            "LocalAttributes": ["Persistent": false]
        ]
        guard let created = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: attributes) else {
            throw BridgeError("macOS 未能发布本机免提服务。")
        }
        record = created
        publishedFeatures = supportedFeatures
        ownsRecord = created.getServiceName() == "PhoneBridge Hands-Free" && matchesHandsFreeRole(created)
        lastPublished = diagnostic
        guard matchesHandsFreeRole(created) else {
            let classes = created.getAttributeDataElement(0x0001)?.description ?? "missing"
            stop()
            throw BridgeError("本机服务角色读回不匹配：请求 Hands-Free 0x111E，返回 \(classes)。已停止本次连接，不能把发布成功当作免提就绪。")
        }
        guard created.getAttributeDataElement(0x0311)?.getNumberValue()?.intValue == Int(supportedFeatures) else {
            stop()
            throw BridgeError("本机免提能力声明读回不匹配，已停止本次连接。")
        }
        do { return try channel(of: created) }
        catch { stop(); throw error }
    }

    private func channel(of record: IOBluetoothSDPServiceRecord) throws -> UInt8 {
        var channel: BluetoothRFCOMMChannelID = 0
        let status = record.getRFCOMMChannelID(&channel)
        guard status == kIOReturnSuccess, (1...30).contains(channel) else {
            throw BridgeError("本机免提服务未取得有效 RFCOMM 通道（\(status)）。")
        }
        return channel
    }

    static func probePublication() -> [[String: Any]] {
        func uuid(_ value: UInt16) -> Data { Data([UInt8(value >> 8), UInt8(value & 0xff)]) }
        func uuid32(_ value: UInt16) -> Data { Data([0, 0, UInt8(value >> 8), UInt8(value & 0xff)]) }
        func bluetoothBaseUUID(_ value: UInt16) -> Data {
            Data([0x00, 0x00, UInt8(value >> 8), UInt8(value & 0xff),
                  0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5f, 0x9b, 0x34, 0xfb])
        }
        func uint(_ value: Int, bytes: Int) -> [String: Any] {
            ["DataElementType": 1, "DataElementSize": bytes, "DataElementValue": value]
        }
        func inspect(_ created: IOBluetoothSDPServiceRecord, requestedName: String,
                     result seed: [String: Any]) -> [String: Any] {
            var result = seed
            var handle: BluetoothSDPServiceRecordHandle = 0
            var channel: BluetoothRFCOMMChannelID = 0
            let handleStatus = created.getHandle(&handle)
            let channelStatus = created.getRFCOMMChannelID(&channel)
            result["returnedName"] = created.getServiceName() ?? ""
            result["returnedClasses"] = created.getAttributeDataElement(0x0001)?.description ?? ""
            result["returnedServiceID"] = created.getAttributeDataElement(0x0003)?.description ?? ""
            result["returnedProfile"] = created.getAttributeDataElement(0x0009)?.description ?? ""
            result["returnedFeatures"] = created.getAttributeDataElement(0x0311)?.description ?? ""
            result["handle"] = handleStatus == kIOReturnSuccess ? String(format: "%08X", handle) : "unavailable"
            result["channel"] = channelStatus == kIOReturnSuccess ? Int(channel) : -1
            if created.getServiceName() == requestedName {
                result["cleanupStatus"] = created.remove()
            } else {
                result["cleanup"] = "Returned record identity does not match; not removing an unrelated record."
            }
            return result
        }
        var results: [[String: Any]] = []
        for variant in 0..<3 {
            let service: UInt16 = variant == 2 ? 0x1101 : 0x111e
            let name = "PhoneBridge Probe \(variant)"
            let classKey = variant == 1 ? "0001" : "0001 - ServiceClassIDList"
            let protocolKey = variant == 1 ? "0004" : "0004 - ProtocolDescriptorList"
            let profileKey = variant == 1 ? "0009" : "0009 - BluetoothProfileDescriptorList"
            let nameKey = variant == 1 ? "0100" : "0100 - ServiceName"
            var attributes: [AnyHashable: Any] = [
                classKey: [uuid(service)],
                protocolKey: [[uuid(0x0100)], [uuid(0x0003), uint(1, bytes: 1)]],
                profileKey: [[uuid(service), uint(variant == 2 ? 0x0100 : 0x0105, bytes: 2)]],
                nameKey: name, "LocalAttributes": ["Persistent": false]
            ]
            if variant != 2 { attributes["0311 - SupportedFeatures"] = uint(0, bytes: 2) }
            let parsed = IOBluetoothSDPDataElement(elementValue: [uuid(service)] as NSArray)
            var result: [String: Any] = ["variant": variant, "source": "PhoneBridge",
                "requestedClass": String(format: "%04X", service),
                "requestedName": name, "localParserClass": parsed?.description ?? "parse_failed"]
            if let created = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: attributes) {
                results.append(inspect(created, requestedName: name, result: result))
            } else {
                result["error"] = "publication returned nil"
                results.append(result)
            }
        }

        // Phone Amego 1.5.08 is a notarized, universal Mac application whose
        // bundled plist historically published the Mac as the HFP Hands-Free
        // role. Reproduce that plist exactly before blaming the phone or pairing.
        let legacyName = "Hands-Free Phone Amego PhoneBridge Probe"
        let serviceID = Data([0xf2, 0x7b, 0x65, 0x33, 0xdf, 0x7d, 0x4d, 0x0f,
                              0xb9, 0xac, 0x9f, 0x3f, 0x2b, 0xf7, 0x7f, 0xf3])
        let legacyAttributes: [AnyHashable: Any] = [
            "0000 - ServiceRecordHandle*": 5140,
            "0001 - ServiceClassIDList": [uuid(0x111e), uuid(0x1203)],
            "0003 - ServiceID": serviceID,
            "0004 - ProtocolDescriptorList": [
                [uuid(0x0100)],
                [uuid(0x0003), uint(2, bytes: 1)]
            ],
            "0005 - BrowseGroupList*": [uuid(0x1002)],
            "0009 - BluetoothProfileDescriptorList": [[uuid(0x111e), uint(0x0105, bytes: 2)]],
            "0100 - ServiceName*": legacyName,
            "0311 - Supported Features": uint(6, bytes: 2)
        ]
        let legacySeed: [String: Any] = [
            "variant": 3,
            "source": "Phone Amego 1.5.08 HandsFreeHFDictionary.plist",
            "requestedClass": "111E",
            "requestedName": legacyName,
            "requestedChannel": 2,
            "requestedFeatures": 6,
            "requestedHandle": "00001414"
        ]
        if let created = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: legacyAttributes) {
            results.append(inspect(created, requestedName: legacyName, result: legacySeed))
        } else {
            var result = legacySeed
            result["error"] = "publication returned nil"
            results.append(result)
        }

        for (variant, encodedHF, encoding) in [
            (4, uuid32(0x111e), "uuid32"),
            (5, bluetoothBaseUUID(0x111e), "uuid128")
        ] {
            let name = "PhoneBridge HFP \(encoding) Probe"
            let attributes: [AnyHashable: Any] = [
                "0001 - ServiceClassIDList": [encodedHF, uuid(0x1203)],
                "0003 - ServiceID": bluetoothBaseUUID(UInt16(0x4300 + variant)),
                "0004 - ProtocolDescriptorList": [
                    [uuid(0x0100)],
                    [uuid(0x0003), uint(2, bytes: 1)]
                ],
                "0005 - BrowseGroupList": [uuid(0x1002)],
                "0009 - BluetoothProfileDescriptorList": [[encodedHF, uint(0x0105, bytes: 2)]],
                "0100 - ServiceName": name,
                "0311 - Supported Features": uint(6, bytes: 2)
            ]
            let seed: [String: Any] = [
                "variant": variant,
                "source": "PhoneBridge alternate UUID-width probe",
                "uuidEncoding": encoding,
                "requestedClass": "111E",
                "requestedName": name
            ]
            if let created = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: attributes) {
                results.append(inspect(created, requestedName: name, result: seed))
            } else {
                var result = seed
                result["error"] = "publication returned nil"
                results.append(result)
            }
        }
        return results
    }

    @discardableResult
    func stop() -> IOReturn {
        guard let record else { return kIOReturnSuccess }
        // The API can return an existing system AG record instead of our request.
        // Never remove an unrelated record merely because it was returned.
        guard ownsRecord else { self.record = nil; self.publishedFeatures = nil; return kIOReturnSuccess }
        let status = record.remove()
        if status == kIOReturnSuccess { self.record = nil; self.publishedFeatures = nil }
        return status
    }
}
