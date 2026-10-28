import Foundation
import CoreAudio
import BridgeCore

@main @MainActor struct BuiltinCaptionChecks {
    static var checks: [String] = []
    nonisolated static let phoneConfiguration = try! PhonePeerConfiguration(address: "A1:B2:C3:D4:E5:F6", name: "Fixture Phone A")
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw NSError(domain: name, code: 1) }; checks.append(name)
    }
    static func rejected(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks.append(name); return }; throw NSError(domain: name, code: 1)
    }
    static func device(id: UInt32 = 22, name: String = "Fixture Phone A", uid: String = "A1-B2-C3-D4-E5-F6:input", channels: Int = 1, outputs: Int = 0, bluetooth: Bool = true) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, name: name, uid: uid, inputChannels: channels, outputChannels: outputs, bluetooth: bluetooth, transport: bluetooth ? .bluetooth : .other)
    }
    static func main() throws {
        for (microphone, speech) in [(false,false), (true,false), (false,true)] {
            try rejected("permission gate \(microphone)/\(speech)") { try BuiltinVoiceCaptions.validatePermissions(microphone: microphone, speech: speech) }
        }
        try BuiltinVoiceCaptions.validatePermissions(microphone: true, speech: true)
        checks.append("authorized permission policy accepted without requesting permission")
        let selected = try BuiltinVoiceCaptions.selectDevice([device()], phone: phoneConfiguration)
        try check(selected.id == 22, "only exact paired mono Bluetooth input selected")
        for candidate in [device(id:0), device(name:"MacBook microphone"), device(uid:"A1-B2-C3-D4-E5-F6:output"), device(channels:2), device(outputs:1), device(bluetooth:false)] {
            try rejected("wrong device rejected \(checks.count)") { _ = try BuiltinVoiceCaptions.selectDevice([candidate], phone: phoneConfiguration) }
        }
        try rejected("duplicate matching identity rejected") { _ = try BuiltinVoiceCaptions.selectDevice([device(), device(id:23)], phone: phoneConfiguration) }
        try rejected("missing phone never falls back") { _ = try BuiltinVoiceCaptions.selectDevice([], phone: phoneConfiguration) }
        let cable = device(id:59, name:"PhoneBridge Voice Output", uid:"cn.andy.phonebridge.audio.output.device", channels:2, outputs:2, bluetooth:false)
        let output = try BuiltinVoiceCaptions.selectOutgoingDevice([device(),cable])
        try check(output.id == 59, "outgoing captions choose only exact stable output cable")
        for invalid in [device(),device(name:cable.name, uid:cable.uid, channels:1,outputs:2,bluetooth:false),device(name:cable.name,uid:cable.uid,channels:2,outputs:2,bluetooth:true),device(name:"Unrelated virtual input",uid:cable.uid,channels:2,outputs:2,bluetooth:false)] {
            try rejected("outgoing source rejects wrong identity or channels \(checks.count)") { _ = try BuiltinVoiceCaptions.selectOutgoingDevice([invalid]) }
        }
        try rejected("duplicate outgoing cables cannot choose arbitrarily") { _ = try BuiltinVoiceCaptions.selectOutgoingDevice([cable,cable]) }
        try rejected("missing outgoing cable never captures owner microphone") { _ = try BuiltinVoiceCaptions.selectOutgoingDevice([device()]) }
        let outgoing = BuiltinVoiceCaptions()
        try outgoing.configureOutgoingVoice()
        try check(outgoing.diagnosticSnapshot["outgoingVoice"] as? Bool == true && !outgoing.running && !outgoing.prepared, "explicit outgoing setup starts no audio or recognition")
        let storage = BuiltinCaptionSamples(capacity: 7)
        let values: [Float] = [1,2,3,4]
        values.withUnsafeBufferPointer { storage.append($0.baseAddress!, count: 4) }
        try check(storage.publishedFrames == 4 && storage.samples[3] == 4, "copy completes before published prefix advances")
        values.withUnsafeBufferPointer { storage.append($0.baseAddress!, count: 4) }
        try check(storage.failureCode != 0 && storage.publishedFrames == 4, "capacity overflow fails without overwriting prefix")
        values.withUnsafeBufferPointer { storage.append($0.baseAddress!, count: 1) }
        try check(storage.publishedFrames == 4 && storage.samples[0] == 1, "failed writer cannot resume or overwrite data")
        let empty = BuiltinCaptionSamples(capacity: 10)
        values.withUnsafeBufferPointer { empty.append($0.baseAddress!, count: 0) }
        try check(empty.failureCode != 0 && empty.publishedFrames == 0, "invalid slice rejected before copy")
        let stopped = BuiltinCaptionSamples(capacity: 10)
        values.withUnsafeBufferPointer { stopped.append($0.baseAddress!, count: 4) }
        stopped.markFailure(-5)
        values.withUnsafeBufferPointer { stopped.append($0.baseAddress!, count: 4) }
        try check(stopped.failureCode == -5 && stopped.publishedFrames == 4 && stopped.samples[3] == 4,
                  "stop revokes sample copying even if HAL cleanup fails")
        stopped.markFailure(-9)
        try check(stopped.failureCode == -5, "late cleanup failure cannot reset stop revocation")
        let count = 60000
        let concurrent = BuiltinCaptionSamples(capacity: count)
        let finished = DispatchGroup(); finished.enter()
        DispatchQueue.global().async {
            let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 257)
            defer { scratch.deallocate(); finished.leave() }
            var offset = 0
            while offset < count {
                let chunk = min(257, count - offset)
                for n in 0..<chunk { scratch[n] = Float((offset + n) % 1000) }
                concurrent.append(scratch, count: chunk); offset += chunk
            }
        }
        let deadline = Date().addingTimeInterval(5)
        var observed = 0
        while observed < count && Date() < deadline {
            let prefix = concurrent.publishedFrames
            guard prefix >= observed && prefix <= count else { throw NSError(domain:"nonmonotonic prefix",code:1) }
            while observed < prefix {
                guard concurrent.samples[observed] == Float(observed % 1000) else { throw NSError(domain:"unpublished/torn sample",code:1) }
                observed += 1
            }
        }
        try check(finished.wait(timeout: .now()+1) == .success && observed == count && concurrent.failureCode == 0,
                  "concurrent reader observes only complete immutable published prefix")
        let untouched = BuiltinVoiceCaptions()
        try check(!untouched.running && !untouched.prepared && untouched.cleanupVerified, "construction starts no audio or recognition")
        try rejected("unconfigured prepare rejects before permission or HAL access") { try untouched.prepare() }
        try untouched.configure(phone: phoneConfiguration)
        try check(untouched.diagnosticSnapshot["phoneConfigured"] as? Bool == true, "explicit phone configuration accepted without IO")
        try untouched.clearPhoneConfiguration()
        try rejected("forgotten configuration cannot prepare old device") { try untouched.prepare() }
        let second = try PhonePeerConfiguration(address: "12:34:56:78:90:AB", name: "另一个模拟手机")
        try rejected("old phone cannot satisfy new configured identity") { _ = try BuiltinVoiceCaptions.selectDevice([device()], phone: second) }
        let secondDevice = try BuiltinVoiceCaptions.selectDevice([device(), device(id:28, name:second.name, uid:second.inputUID)], phone: second)
        try check(secondDevice.id == 28, "different explicitly selected phone is supported")
        let lifetimeCheck = try BuiltinVoiceCaptions.offlineConfigurationLifetimeCheck()
        try check(lifetimeCheck, "running cleanup-pending and permission-pending states reject identity changes")
        untouched.stop()
        let report: [String: Any] = ["passed":true,"count":checks.count,"checks":checks,
            "deviceOperations":0,"permissionRequests":0,"recognitionTasks":0,"networkRequests":0]
        let data = try JSONSerialization.data(withJSONObject: report, options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count == 2 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        print(String(data:data,encoding:.utf8)!)
    }
}
