import Foundation
import BridgeCore

struct CheckFailure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CheckFailure(message: message) }
}
func rejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckFailure(message: "Invalid input was accepted")
}

do {
    try check(try CallInput.number("+86 185-1234-5678") == "+8618512345678", "Dial normalization")
    for input in ["", "10010;ATD112", "10010\r\nATH", "10010\n", "10010\r", "*100#", "10010,1", "１００１０", "+", "123456789012345678901"] {
        try rejects { _ = try CallInput.number(input) }
    }
    try check(try CallInput.dtmf("#") == "#", "DTMF #")
    try rejects { _ = try CallInput.dtmf("12") }
    print("PASS: dial validation and AT injection rejection")

    let raw = Data("POST /command HTTP/1.1\r\nAuthorization: Bearer example\r\nContent-Length: 2\r\n\r\n{}".utf8)
    for count in 0..<raw.count { try check(try HTTPRequest.parse(raw.prefix(count)) == nil, "Partial request \(count)") }
    let request = try HTTPRequest.parse(raw)
    try check(request?.headers["authorization"] == "Bearer example", "Authorization header")
    try check(request?.body == Data("{}".utf8), "Body boundary")
    print("PASS: all HTTP fragmentation boundaries")

    for raw in [
        "POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\nx",
        "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
        "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n"
    ] { try rejects { _ = try HTTPRequest.parse(Data(raw.utf8)) } }
    try rejects { _ = try HTTPRequest.parse(Data(repeating: 65, count: 65_537)) }
    print("PASS: ambiguous framing, request smuggling and oversize rejection")

    var state = CallState(); state.connected = true; state.setup = 2
    try check(!state.active && state.label == "正在拨号", "Dialing is not active call")
    state.active = true
    try check(state.label.contains("不代表已接通人工客服"), "Active call is not proof of human answer")
    print("PASS: call state evidence boundaries")

    let usb = AudioEndpoint(id: 10, uid: "phone-interface", transport: .usb, inputs: 2, outputs: 2)
    try AudioRoutePolicy.validate(mode: .usb, input: usb, output: usb)
    let builtInMic = AudioEndpoint(id: 11, uid: "internal-mic", transport: .other, inputs: 1, outputs: 0)
    let builtInSpeaker = AudioEndpoint(id: 12, uid: "internal-speaker", transport: .other, inputs: 0, outputs: 2)
    let otherUSB = AudioEndpoint(id: 13, uid: "unrelated-interface", transport: .usb, inputs: 2, outputs: 2)
    let outputOnly = AudioEndpoint(id: 14, uid: "usb-speaker", transport: .usb, inputs: 0, outputs: 2)
    let inputOnly = AudioEndpoint(id: 15, uid: "usb-mic", transport: .usb, inputs: 1, outputs: 0)
    let recycledID = AudioEndpoint(id: 10, uid: "different-physical-device", transport: .usb, inputs: 2, outputs: 2)
    let anonymous = AudioEndpoint(id: 10, uid: "", transport: .usb, inputs: 2, outputs: 2)
    for (input, output) in [(builtInMic, builtInSpeaker), (builtInMic, usb), (usb, builtInSpeaker),
                            (usb, otherUSB), (outputOnly, outputOnly), (inputOnly, inputOnly),
                            (usb, recycledID), (anonymous, anonymous)] {
        try rejects { try AudioRoutePolicy.validate(mode: .usb, input: input, output: output) }
    }
    let bt = AudioEndpoint(id: 16, uid: "phone-bluetooth", transport: .bluetooth, inputs: 1, outputs: 1)
    try AudioRoutePolicy.validate(mode: .bluetooth, input: bt, output: bt)
    try rejects { try AudioRoutePolicy.validate(mode: .usb, input: bt, output: bt) }
    try rejects { try AudioRoutePolicy.validate(mode: .bluetooth, input: usb, output: usb) }
    print("PASS: USB duplex routing rejects built-ins, unrelated devices, missing channels and unstable identities")

    var segments = ManagedAudioSegmenter()
    try rejects { _ = try segments.append(Data(repeating: 1, count: 1)) }
    let nearlyFull = try segments.append(Data(repeating: 1, count: ManagedAudioSegmenter.maxSegmentBytes - 2))
    try check(nearlyFull.count == 1, "Managed audio starts one bounded output item")
    guard case let .play(firstID, firstPCM) = nearlyFull[0] else { throw CheckFailure(message: "Missing first output item") }
    try check(firstID == "codex-webrtc-0" && firstPCM.count == ManagedAudioSegmenter.maxSegmentBytes - 2,
              "Managed audio first segment identity and length")
    let boundary = try segments.append(Data(repeating: 2, count: 6))
    try check(boundary.count == 3, "Boundary emits play, end and next play")
    guard case let .play(lastID, lastPCM) = boundary[0], case let .end(endedID) = boundary[1],
          case let .play(nextID, nextPCM) = boundary[2] else { throw CheckFailure(message: "Invalid output boundary sequence") }
    try check(lastID == firstID && lastPCM.count == 2 && endedID == firstID &&
              nextID == "codex-webrtc-1" && nextPCM.count == 4,
              "Output item rotates before native per-item duration limit")
    segments.interrupt()
    let resumed = try segments.append(Data(repeating: 3, count: 2))
    guard case let .play(resumedID, _) = resumed[0] else { throw CheckFailure(message: "Missing resumed output") }
    try check(resumedID == "codex-webrtc-2", "Interrupted output never reuses the cleared item")
    print("PASS: managed audio segments roll over and reset after interruption")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
