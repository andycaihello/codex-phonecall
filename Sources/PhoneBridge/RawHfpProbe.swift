import Foundation
import IOBluetooth
import BridgeCore

/// A bounded, read-only HFP control probe. It never publishes a local service,
/// dials, answers, or opens audio. Successful BRSF is only the first SLC step.
final class RawHfpProbe: NSObject, IOBluetoothDeviceAsyncCallbacks, IOBluetoothRFCOMMChannelDelegate {
    private(set) var active = false
    private(set) var diagnostic: [String: Any] = ["stage": "not_started", "active": false]
    var changed: () -> Void = {}
    var log: (String) -> Void = { _ in }
    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var timeout: DispatchWorkItem?
    private var received = Data()
    private var generation = UUID()

    func start(device: IOBluetoothDevice) throws {
        guard !active else { throw BridgeError("控制通道检查正在进行。") }
        generation = UUID()
        let current = generation
        self.device = device
        received.removeAll()
        active = true
        diagnostic = ["stage": "querying_sdp", "active": true,
                      "startedAt": ISO8601DateFormatter().string(from: Date()),
                      "localServicePublished": false, "rfcommOpened": false,
                      "featureReplyReceived": false, "audioValidated": false]
        changed()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == current else { return }
            self.finish("timeout")
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        let status = device.performSDPQuery(self)
        diagnostic["sdpStartStatus"] = status
        if status != kIOReturnSuccess { finish("sdp_start_failed") }
    }

    func cancel() { if active { finish("cancelled") } }

    private func finish(_ stage: String) {
        guard active else { return }
        active = false
        timeout?.cancel(); timeout = nil
        diagnostic["lastStage"] = diagnostic["stage"]
        diagnostic["stage"] = stage
        diagnostic["active"] = false
        diagnostic["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        let ownChannel = channel
        channel = nil
        if let ownChannel { diagnostic["closeStatus"] = ownChannel.close() }
        device = nil
        received.removeAll()
        changed()
        log("直接控制通道检查结束：\(stage)。未拨号，未启用通话音频。")
    }

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let device, device === self.device else { return }
            self.diagnostic["sdpStatus"] = status
            guard status == kIOReturnSuccess,
                  let service = device.handsFreeAudioGatewayServiceRecord() else {
                self.finish("sdp_failed"); return
            }
            var channelID: BluetoothRFCOMMChannelID = 0
            let channelStatus = service.getRFCOMMChannelID(&channelID)
            self.diagnostic["channelLookupStatus"] = channelStatus
            self.diagnostic["channelID"] = Int(channelID)
            guard channelStatus == kIOReturnSuccess, (1...30).contains(channelID) else {
                self.finish("invalid_channel"); return
            }
            self.diagnostic["stage"] = "opening_rfcomm"
            let result = device.openRFCOMMChannelAsync(&self.channel, withChannelID: channelID, delegate: self)
            self.diagnostic["openStartStatus"] = result
            self.changed()
            if result != kIOReturnSuccess { self.finish("open_start_failed") }
        }
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let channel, channel === self.channel else { return }
            self.diagnostic["openCompletionStatus"] = error
            guard error == kIOReturnSuccess else { self.finish("open_failed"); return }
            self.diagnostic["rfcommOpened"] = true
            self.diagnostic["stage"] = "waiting_feature_reply"
            self.changed()
            let current = self.generation
            // Fixed HFP capability negotiation only; no caller-supplied AT text.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var command = Array("AT+BRSF=0\r".utf8)
                let result = command.withUnsafeMutableBytes {
                    channel.writeSync($0.baseAddress, length: UInt16($0.count))
                }
                DispatchQueue.main.async {
                    guard let self, self.active, self.generation == current else { return }
                    self.diagnostic["featureWriteStatus"] = result
                    self.changed()
                    if result != kIOReturnSuccess { self.finish("feature_write_failed") }
                }
            }
        }
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let pointer, length > 0 else { return }
        // Copy during the callback: the framework owns the original pointer.
        let bytes = Data(bytes: pointer, count: min(length, 4096))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let channel, channel === self.channel else { return }
            guard self.received.count + bytes.count <= 4096 else { self.finish("reply_limit"); return }
            self.received.append(bytes)
            self.diagnostic["receivedBytes"] = self.received.count
            let text = String(decoding: self.received, as: UTF8.self)
            let lines = text.components(separatedBy: CharacterSet.newlines).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let features = lines.contains { $0.hasPrefix("+BRSF:") }
            self.diagnostic["featureReplyReceived"] = features
            self.changed()
            if lines.contains("ERROR") { self.finish("feature_rejected") }
            else if features && lines.contains("OK") { self.finish("feature_exchange_confirmed") }
        }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let channel, channel === self.channel else { return }
            self.finish("remote_closed")
        }
    }

    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
}
