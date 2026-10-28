import Foundation
import IOBluetooth
import BridgeCore
import BluetoothShim

/// Minimal HFP Hands-Free control plane implemented directly on RFCOMM.
/// macOS 26.6.2 crashes inside IOBluetoothHandsFreeDevice while starting the
/// AT handshake, so this class uses only the public RFCOMM channel API.
final class IncomingHfpSession: NSObject, IOBluetoothRFCOMMChannelDelegate,
                                IOBluetoothDeviceAsyncCallbacks, PBRFCOMMListenerDelegate {
    enum Stage: String {
        case stopped, listening, openingBaseband, queryingSDP, openingRFCOMM, brsf, cindTest, cindRead, cmer, connected
    }

    private(set) var stage: Stage = .stopped
    private(set) var connected = false
    private(set) var address = ""
    private(set) var diagnostic: [String: Any] = ["stage": Stage.stopped.rawValue]
    var log: (String) -> Void = { _ in }
    var stateChanged: (CallState) -> Void = { _ in }
    var connectedChanged: (Bool, String) -> Void = { _, _ in }

    /// A separate delegate identifies each open attempt even when IOBluetooth
    /// supplies a nil callback channel or reuses a channel object after a retry.
    private final class OutboundRFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
        weak var owner: IncomingHfpSession?

        init(owner: IncomingHfpSession) {
            self.owner = owner
            super.init()
        }

        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
            owner?.completeOutboundOpen(channel, status: error, from: self)
        }

        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!,
                               data pointer: UnsafeMutableRawPointer!, length: Int) {
            owner?.receiveChannelData(channel, data: pointer, length: length, from: self)
        }

        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
            owner?.handleChannelClosed(channel, from: self)
        }
    }

    private let listener = PBRFCOMMListener()
    private var channel: IOBluetoothRFCOMMChannel?
    // IOBluetooth does not retain its delegate. Keep it until it is detached
    // from the channel, and use its identity to reject callbacks from retries.
    private var outboundDelegate: OutboundRFCOMMDelegate?
    private var outboundDevice: IOBluetoothDevice?
    private var expectedChannel: BluetoothRFCOMMChannelID = 0
    private var expectedAddress: String?
    private var listeningForIncoming = false
    private var received = Data()
    private var state = CallState()
    private var indicatorNames: [String] = []

    var audioDriverChannel: IOBluetoothRFCOMMChannel? {
        connected && channel?.isOpen() == true ? channel : nil
    }

    func start(channelID: BluetoothRFCOMMChannelID, expectedAddress: String?,
               outboundDevice: IOBluetoothDevice? = nil,
               listenForIncoming: Bool = true) throws {
        stop()
        expectedChannel = channelID
        self.expectedAddress = expectedAddress?.lowercased()
        listeningForIncoming = listenForIncoming
        if listenForIncoming {
            listener.delegate = self
            guard listener.start(withChannelID: channelID) else {
                throw BridgeError("macOS 未能注册 RFCOMM 入站监听。")
            }
        }
        stage = listenForIncoming ? .listening : .stopped
        diagnostic = ["stage": stage.rawValue, "channelID": Int(channelID),
                      "expectedAddress": self.expectedAddress ?? "any",
                      "listener": listenForIncoming ? "objective_c_channel_specific_incoming" : "disabled_during_outbound_open"]
        if let outboundDevice {
            self.outboundDevice = outboundDevice
            if let cachedChannel = cachedHfpAGChannel(on: outboundDevice) {
                // A paired phone can change its RFCOMM server channel across
                // Bluetooth restarts. Keep the cached value as evidence, but
                // never use it for a new HFP connection.
                diagnostic["cachedOutboundChannelID"] = Int(cachedChannel)
            }
            if outboundDevice.isConnected() {
                try startSDP(on: outboundDevice)
            } else {
                stage = .openingBaseband
                diagnostic["stage"] = stage.rawValue
                let status = outboundDevice.openConnection(self)
                diagnostic["basebandOpenStartStatus"] = status
                guard status == kIOReturnSuccess else {
                    self.outboundDevice = nil
                    stage = listeningForIncoming ? .listening : .stopped
                    diagnostic["stage"] = stage.rawValue
                    throw BridgeError("手机基础蓝牙连接启动失败：\(status)")
                }
            }
        }
    }

    func stop() {
        listener.stop()
        listener.delegate = nil
        listeningForIncoming = false
        _ = closeCurrentChannel()
        outboundDevice = nil
        expectedAddress = nil
        expectedChannel = 0
        received.removeAll()
        indicatorNames.removeAll()
        address = ""
        connected = false
        state = CallState()
        stage = .stopped
        diagnostic = ["stage": stage.rawValue]
    }

    func rfcommListenerDidOpen(_ newChannel: IOBluetoothRFCOMMChannel) {
        let observedID = newChannel.getID()
        guard let remoteAddress = newChannel.getDevice()?.addressString?.lowercased() else { return }
        diagnostic["lastObservedChannel"] = Int(observedID)
        diagnostic["lastObservedAddress"] = remoteAddress
        diagnostic["lastObservedIncoming"] = newChannel.isIncoming()
        guard observedID == expectedChannel else { return }
        if let expectedAddress, expectedAddress != remoteAddress {
            _ = newChannel.close()
            log("拒绝了非目标设备的免提连接。")
            return
        }
        beginHandshake(on: newChannel, direction: "incoming")
    }

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let device, device === self.outboundDevice,
                  self.channel == nil else { return }
            self.diagnostic["sdpStatus"] = status
            guard status == kIOReturnSuccess else {
                self.stage = self.listeningForIncoming ? .listening : .stopped
                self.diagnostic["stage"] = self.stage.rawValue
                self.log("手机未返回可用的 HFP Audio Gateway 服务；继续等待入站连接。")
                return
            }
            let agUUID = IOBluetoothSDPUUID(uuid32: 0x0000111f)
            let rfcommUUID = IOBluetoothSDPUUID(uuid32: 0x00000003)
            let records = device.services as? [IOBluetoothSDPServiceRecord] ?? []
            var observed: [[String: Any]] = []
            var exactAGChannel: BluetoothRFCOMMChannelID?
            for record in records {
                let classElement = record.getAttributeDataElement(0x0001)
                var classes = classElement?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
                if classes.isEmpty, let classElement, classElement.getUUIDValue() != nil {
                    classes = [classElement]
                }
                let protocols = record.getAttributeDataElement(0x0004)?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
                var parsedChannel: BluetoothRFCOMMChannelID?
                for descriptor in protocols {
                    let fields = descriptor.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
                    guard fields.first?.getUUIDValue()?.isEqual(to: rfcommUUID) == true,
                          fields.count > 1, let number = fields[1].getNumberValue() else { continue }
                    let value = number.intValue
                    if (1...30).contains(value) { parsedChannel = BluetoothRFCOMMChannelID(value) }
                }
                let matchesAG = classes.contains { $0.getUUIDValue()?.isEqual(to: agUUID) == true }
                observed.append([
                    "name": record.getServiceName() ?? "",
                    "classes": classElement?.description ?? "",
                    "protocols": record.getAttributeDataElement(0x0004)?.description ?? "",
                    "channel": parsedChannel.map(Int.init) ?? -1,
                    "matches111F": matchesAG
                ])
                if matchesAG, let parsedChannel { exactAGChannel = parsedChannel }
            }
            self.diagnostic["remoteServices"] = observed
            guard let remoteChannel = exactAGChannel else {
                self.stage = self.listeningForIncoming ? .listening : .stopped
                self.diagnostic["stage"] = self.stage.rawValue
                self.log("手机 SDP 中没有 HFP Audio Gateway 0x111F 服务；继续等待入站连接。")
                return
            }
            self.diagnostic["outboundChannelID"] = Int(remoteChannel)
            self.diagnostic["outboundChannelSource"] = "parsed_protocol_descriptor"
            self.stage = .openingRFCOMM
            self.diagnostic["stage"] = self.stage.rawValue
            let delegate = OutboundRFCOMMDelegate(owner: self)
            self.outboundDelegate = delegate
            let openStatus = device.openRFCOMMChannelAsync(&self.channel,
                                                            withChannelID: remoteChannel,
                                                            delegate: delegate)
            self.diagnostic["outboundOpenStartStatus"] = openStatus
            if openStatus != kIOReturnSuccess {
                if let closeStatus = self.closeCurrentChannel() {
                    self.diagnostic["failedOpenStartCloseStatus"] = closeStatus
                }
                self.stage = self.listeningForIncoming ? .listening : .stopped
                self.diagnostic["stage"] = self.stage.rawValue
                self.log("主动打开手机 HFP 控制通道失败：\(openStatus)；继续等待入站连接。")
            } else {
                self.log("已发现手机 HFP AG 通道 \(remoteChannel)，正在主动建立控制链路。")
            }
        }
    }

    func rfcommChannelOpenComplete(_ newChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        // Incoming channels emit this callback when setDelegate is called.
        // Their handshake is started by rfcommListenerDidOpen. Outbound opens
        // use an attempt-specific delegate and completeOutboundOpen instead.
    }

    private func completeOutboundOpen(_ newChannel: IOBluetoothRFCOMMChannel?, status error: IOReturn,
                                      from delegate: OutboundRFCOMMDelegate) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stage == .openingRFCOMM,
                  self.outboundDelegate === delegate, let pendingChannel = self.channel else { return }
            // An unrelated channel must not clear the current pending open.
            if let newChannel, newChannel !== pendingChannel { return }
            self.diagnostic["outboundOpenCompletionStatus"] = error
            guard error == kIOReturnSuccess, let newChannel else {
                // A nil failure channel is safe to clean up only after the
                // originating attempt has been matched on the main queue.
                if let closeStatus = self.closeCurrentChannel() {
                    self.diagnostic["failedOpenEagerCloseStatus"] = closeStatus
                }
                self.stage = self.listeningForIncoming ? .listening : .stopped
                self.diagnostic["stage"] = self.stage.rawValue
                self.log("手机 HFP 控制通道未打开：\(error)；已清理当前待定通道。")
                return
            }
            self.beginHandshake(on: newChannel, direction: "outgoing")
        }
    }

    @discardableResult
    private func closeCurrentChannel() -> IOReturn? {
        let oldChannel = channel
        let oldDelegate = outboundDelegate
        // Detach before releasing the retained delegate or closing the channel.
        // Callbacks already queued with it will fail the attempt identity guard.
        if let oldChannel { _ = oldChannel.setDelegate(nil) }
        channel = nil
        outboundDelegate = nil
        let status = oldChannel?.close()
        withExtendedLifetime(oldDelegate) {}
        return status
    }

    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let device, device === self.outboundDevice,
                  self.stage == .openingBaseband else { return }
            self.diagnostic["basebandOpenCompletionStatus"] = status
            guard status == kIOReturnSuccess else {
                self.stage = self.listeningForIncoming ? .listening : .stopped
                self.diagnostic["stage"] = self.stage.rawValue
                self.log("手机基础蓝牙连接未完成：\(status)。")
                return
            }
            do { try self.startSDP(on: device) }
            catch { self.log("手机服务查询未启动：\(error.localizedDescription)") }
        }
    }

    private func startSDP(on device: IOBluetoothDevice) throws {
        stage = .queryingSDP
        diagnostic["stage"] = stage.rawValue
        diagnostic["outboundSDP"] = "forced_refresh_after_baseband"
        let status = device.performSDPQuery(self)
        diagnostic["sdpStartStatus"] = status
        guard status == kIOReturnSuccess else {
            outboundDevice = nil
            stage = listeningForIncoming ? .listening : .stopped
            diagnostic["stage"] = stage.rawValue
            throw BridgeError("手机 HFP 服务查询启动失败：\(status)")
        }
    }

    private func cachedHfpAGChannel(on device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let agUUID = IOBluetoothSDPUUID(uuid32: 0x0000111f)
        let rfcommUUID = IOBluetoothSDPUUID(uuid32: 0x00000003)
        for record in device.services as? [IOBluetoothSDPServiceRecord] ?? [] {
            let classElement = record.getAttributeDataElement(0x0001)
            var classes = classElement?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
            if classes.isEmpty, let classElement, classElement.getUUIDValue() != nil { classes = [classElement] }
            guard classes.contains(where: { $0.getUUIDValue()?.isEqual(to: agUUID) == true }) else { continue }
            let protocols = record.getAttributeDataElement(0x0004)?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
            for descriptor in protocols {
                let fields = descriptor.getArrayValue() as? [IOBluetoothSDPDataElement] ?? []
                guard fields.first?.getUUIDValue()?.isEqual(to: rfcommUUID) == true,
                      fields.count > 1, let number = fields[1].getNumberValue(),
                      (1...30).contains(number.intValue) else { continue }
                return BluetoothRFCOMMChannelID(number.intValue)
            }
        }
        return nil
    }

    private func beginHandshake(on newChannel: IOBluetoothRFCOMMChannel, direction: String) {
        guard let remoteAddress = newChannel.getDevice()?.addressString?.lowercased() else { return }
        if let channel, channel !== newChannel { _ = closeCurrentChannel() }
        channel = newChannel
        outboundDevice = nil
        address = remoteAddress
        received.removeAll()
        indicatorNames.removeAll()
        state = CallState()
        // openRFCOMMChannelAsync already installed this delegate. Calling
        // setDelegate again on an open outgoing channel synchronously repeats
        // rfcommChannelOpenComplete in current IOBluetooth.
        let delegateStatus = direction == "outgoing" ? kIOReturnSuccess : newChannel.setDelegate(self)
        diagnostic["incomingAddress"] = remoteAddress
        diagnostic["connectionDirection"] = direction
        diagnostic["delegateStatus"] = delegateStatus
        guard delegateStatus == kIOReturnSuccess else {
            log("RFCOMM 通道已到达，但设置数据接收器失败：\(delegateStatus)")
            _ = closeCurrentChannel()
            return
        }
        if direction == "incoming" { outboundDelegate = nil }
        log("RFCOMM 免提通道已打开（\(direction)），开始 HFP 握手。")
        // Advertise only the mandatory HF baseline. Setting the three-way-call
        // bit requires a later AT+CHLD=? step before SLC is complete; this
        // bridge intentionally exposes basic dial, hang-up and DTMF only.
        send("AT+BRSF=0\r", next: .brsf)
    }

    private func send(_ text: String, next: Stage? = nil) {
        guard let channel else { return }
        var bytes = Array(text.utf8)
        let status = bytes.withUnsafeMutableBytes {
            channel.writeSync($0.baseAddress, length: UInt16($0.count))
        }
        if let next { stage = next }
        diagnostic["stage"] = stage.rawValue
        diagnostic["lastWriteStatus"] = status
        diagnostic["lastCommand"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if status != kIOReturnSuccess { log("HFP 指令写入失败：\(status)") }
    }

    private func advanceAfterOK(response: String) {
        switch stage {
        case .brsf:
            if let match = response.range(of: #"\+BRSF:\s*([0-9]+)"#, options: .regularExpression) {
                diagnostic["gatewayFeatures"] = String(response[match])
            }
            send("AT+CIND=?\r", next: .cindTest)
        case .cindTest:
            parseIndicatorNames(response)
            send("AT+CIND?\r", next: .cindRead)
        case .cindRead:
            parseInitialIndicators(response)
            send("AT+CMER=3,0,0,1\r", next: .cmer)
        case .cmer:
            stage = .connected
            connected = true
            state.connected = true
            diagnostic["stage"] = stage.rawValue
            diagnostic["slcConnected"] = true
            connectedChanged(true, address)
            stateChanged(state)
            log("HFP 服务级连接已由原始 RFCOMM 实现并完成。")
        default: break
        }
    }

    private func parseIndicatorNames(_ response: String) {
        guard let line = response.components(separatedBy: .newlines).first(where: { $0.contains("+CIND:") }) else { return }
        let pattern = #"\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        indicatorNames = regex.matches(in: line, range: range).compactMap {
            guard let r = Range($0.range(at: 1), in: line) else { return nil }
            return String(line[r]).lowercased()
        }
        diagnostic["indicators"] = indicatorNames
    }

    private func parseInitialIndicators(_ response: String) {
        guard let line = response.components(separatedBy: .newlines).first(where: { $0.contains("+CIND:") }),
              let colon = line.firstIndex(of: ":") else { return }
        let values = line[line.index(after: colon)...].split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        for (offset, value) in values.enumerated() { applyIndicator(index: offset + 1, value: value) }
    }

    private func applyIndicator(index: Int, value: Int) {
        guard index > 0, index <= indicatorNames.count else { return }
        switch indicatorNames[index - 1] {
        case "call": state.active = value == 1
        case "callsetup": state.setup = value
        case "callheld": state.held = value
        default: break
        }
        if connected { stateChanged(state) }
    }

    private func processUnsolicited(_ text: String) {
        let pattern = #"\+CIEV:\s*([0-9]+)\s*,\s*([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let ir = Range(match.range(at: 1), in: text),
                  let vr = Range(match.range(at: 2), in: text),
                  let index = Int(text[ir]), let value = Int(text[vr]) else { continue }
            applyIndicator(index: index, value: value)
        }
    }

    func rfcommChannelData(_ source: IOBluetoothRFCOMMChannel!,
                           data pointer: UnsafeMutableRawPointer!, length: Int) {
        receiveChannelData(source, data: pointer, length: length, from: nil)
    }

    private func receiveChannelData(_ source: IOBluetoothRFCOMMChannel?,
                                    data pointer: UnsafeMutableRawPointer?, length: Int,
                                    from delegate: OutboundRFCOMMDelegate?) {
        guard let pointer, length > 0 else { return }
        let chunk = Data(bytes: pointer, count: min(length, 8192))
        DispatchQueue.main.async { [weak self] in
            guard let self, let source, source === self.channel,
                  self.outboundDelegate === delegate else { return }
            self.received.append(chunk)
            guard self.received.count <= 32_768 else {
                self.log("HFP 响应超过安全上限，已断开。")
                self.stop(); self.connectedChanged(false, self.address); return
            }
            let text = String(decoding: self.received, as: UTF8.self)
            self.processUnsolicited(text)
            if text.contains("\r\nERROR\r\n") || text.hasSuffix("ERROR\r\n") {
                self.diagnostic["lastErrorResponse"] = text
                self.log("手机拒绝了 HFP 握手指令（阶段 \(self.stage.rawValue)）。")
                self.received.removeAll()
            } else if text.contains("\r\nOK\r\n") || text.hasSuffix("OK\r\n") {
                self.received.removeAll()
                self.advanceAfterOK(response: text)
            }
        }
    }

    func rfcommChannelClosed(_ source: IOBluetoothRFCOMMChannel!) {
        handleChannelClosed(source, from: nil)
    }

    private func handleChannelClosed(_ source: IOBluetoothRFCOMMChannel?,
                                     from delegate: OutboundRFCOMMDelegate?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let source, source === self.channel,
                  self.outboundDelegate === delegate else { return }
            let oldAddress = self.address
            _ = source.setDelegate(nil)
            self.channel = nil
            self.outboundDelegate = nil
            self.connected = false
            self.state = CallState()
            self.stage = self.listener.isListening ? .listening : .stopped
            self.diagnostic["stage"] = self.stage.rawValue
            self.diagnostic["slcConnected"] = false
            self.connectedChanged(false, oldAddress)
            self.stateChanged(self.state)
            self.log("手机关闭了 RFCOMM 免提通道。")
        }
    }

    private func requireConnected() throws {
        guard connected, channel != nil else { throw BridgeError("尚未完成 HFP 服务级连接。") }
    }

    func dial(_ number: String) throws { try requireConnected(); send("ATD\(number);\r") }
    func hangup() throws { try requireConnected(); send("AT+CHUP\r") }
    func dtmf(_ key: String) throws { try requireConnected(); send("AT+VTS=\(key)\r") }
    func requestAudio() throws { try requireConnected(); send("AT+BCC\r") }
}
