import Foundation
import Combine
import IOBluetooth
import CoreBluetooth
import BridgeCore
import BluetoothShim

struct PhoneDevice: Identifiable, Codable {
    var id: String
    var name: String
    var paired: Bool
    var bluetoothConnected: Bool
    var cachedHFP: Bool
}

final class BluetoothBridge: NSObject, ObservableObject, IOBluetoothDeviceAsyncCallbacks, CBCentralManagerDelegate {
    @Published var devices: [PhoneDevice] = []
    @Published var state = CallState()
    @Published var selectedAddress = ""
    @Published var connecting = false
    @Published var waitingForPhone = false
    @Published var refreshing = false
    @Published var radioState = "未初始化"
    var log: (String) -> Void = { _ in }
    var lostAudio: () -> Void = {}
    private var queryDevice: IOBluetoothDevice?
    private var timeout: DispatchWorkItem?
    private var central: CBCentralManager?
    private let localService = LocalHandsFreeService()
    private let incoming = IncomingHfpSession()
    private let rawProbe = RawHfpProbe()
    var rawProbeActive: Bool { rawProbe.active }
    var rawProbeDiagnostic: [String: Any] { rawProbe.diagnostic }
    var incomingDiagnostic: [String: Any] { incoming.diagnostic }
    var localServiceDiagnostic: [String: Any] { localService.diagnostic }
    var audioDriverDiagnostic: [String: Any] {
        ["stage": "public_iobluetooth_sco_unsupported_macos26",
         "reason": "The public IOBluetooth connectSCO path is stubbed as kIOReturnUnsupported on this Mac; the system Bluetooth audio path remains under investigation."]
    }

    var connectionLabel: String {
        if connecting { return "正在建立免提连接" }
        if waitingForPhone { return "等待手机重新连接免提" }
        return state.label
    }

    func refresh() {
        guard !refreshing else { return }
        if central == nil {
            // Keep CoreBluetooth for the normal permission/status callback, but
            // do not block Classic Bluetooth HFP on that callback. On a
            // background-only app macOS can defer it indefinitely even while
            // IOBluetooth reports the radio and paired devices as available.
            central = CBCentralManager(delegate: self, queue: .main)
        }
        radioState = "正在读取蓝牙设备"
        refreshing = true
        // On macOS 26, IOBluetooth's first coordinator initialization waits on
        // CoreBluetooth. Running it on the main queue can deadlock its callback.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
            // macOS can return the same newly paired device more than once.
            // SwiftUI requires a unique identity, so merge observations by address.
            var unique: [String: PhoneDevice] = [:]
            for device in paired {
                guard let address = device.addressString?.lowercased(), !address.isEmpty else { continue }
                let previous = unique[address]
                unique[address] = PhoneDevice(id: address, name: device.name ?? previous?.name ?? "未命名设备",
                    paired: device.isPaired() || previous?.paired == true,
                    bluetoothConnected: device.isConnected() || previous?.bluetoothConnected == true,
                    cachedHFP: device.isHandsFreeAudioGateway || previous?.cachedHFP == true)
            }
            let found = unique.values.sorted { $0.name < $1.name }
            DispatchQueue.main.async {
                guard let self else { return }
                self.devices = found
                self.refreshing = false
                if self.central?.state == .poweredOn || !found.isEmpty { self.radioState = "蓝牙已开启" }
                self.log("已读取 \(found.count) 个配对设备。")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.refreshing else { return }
            self.log("系统蓝牙查询仍未返回。请检查系统蓝牙权限；窗口和控制接口仍可操作。")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            radioState = "蓝牙已开启"
            refreshing = false
            refresh()
        case .unauthorized:
            radioState = "蓝牙权限未允许"
            refreshing = false
            log("请在系统设置 → 隐私与安全性 → 蓝牙中允许“通话桥”。")
        case .poweredOff:
            radioState = "蓝牙已关闭"; refreshing = false
            disconnect(); log(radioState)
        case .unsupported: radioState = "系统不支持蓝牙"; refreshing = false; log(radioState)
        case .resetting: radioState = "蓝牙正在重置"
        default: radioState = "正在等待系统蓝牙状态"
        }
    }

    func probeServicePublication() throws -> [[String: Any]] {
        guard !refreshing else { throw BridgeError("请先完成蓝牙状态查询。") }
        guard !connecting, !waitingForPhone, !state.connected, !rawProbe.active else { throw BridgeError("请先停止当前免提连接或检查。") }
        let results = LocalHandsFreeService.probePublication()
        log("已完成独立服务发布检查，共 \(results.count) 组；未连接或拨打手机。")
        return results
    }

    func probeRawControl(address: String) throws {
        guard !refreshing else { throw BridgeError("请先完成蓝牙状态查询。") }
        guard !connecting, !waitingForPhone, !state.connected, !rawProbe.active else { throw BridgeError("请先停止当前免提连接或检查。") }
        guard devices.contains(where: { $0.id == address && $0.paired }),
              let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            throw BridgeError("请选择已配对的手机。")
        }
        rawProbe.changed = { [weak self] in self?.objectWillChange.send() }
        rawProbe.log = { [weak self] in self?.log($0) }
        selectedAddress = address
        log("开始直接检查手机免提控制通道，最多 15 秒。")
        try rawProbe.start(device: device)
    }

    func resetTargetTransport(address: String) throws -> IOReturn {
        guard !refreshing else { throw BridgeError("请先完成蓝牙状态查询。") }
        guard !connecting, !waitingForPhone, !state.connected, !rawProbe.active else {
            throw BridgeError("请先停止当前免提连接或检查。")
        }
        guard devices.contains(where: { $0.id == address && $0.paired }),
              let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            throw BridgeError("请选择已配对的手机。")
        }
        let status = device.closeConnection()
        log("已请求重置目标手机的基础蓝牙连接（状态 \(status)）；配对信息保持不变。")
        return status
    }

    func advertiseForPairing() throws {
        guard !refreshing else { throw BridgeError("请先完成蓝牙状态查询。") }
        guard !connecting, !state.connected, !rawProbe.active else { throw BridgeError("请先停止当前免提连接或检查。") }
        if waitingForPhone, localServiceDiagnostic["published"] as? Bool == true { return }
        let localChannel = try localService.start()
        configureIncomingCallbacks()
        do { try incoming.start(channelID: localChannel, expectedAddress: nil) }
        catch { localService.stop(); throw error }
        selectedAddress = ""
        waitingForPhone = true
        log("已发布可用于新配对的 Mac HF 服务（RFCOMM 通道 \(localChannel)），将持续等待。")
    }

    func connect(address: String) throws {
        guard !refreshing else { throw BridgeError("正在读取蓝牙设备，请等待查询完成。") }
        guard !connecting, !state.connected, !rawProbe.active else { throw BridgeError("请先断开当前免提连接或停止检查。") }
        guard devices.contains(where: { $0.id == address }),
              let device = IOBluetoothDevice(addressString: address), device.isPaired() else {
            throw BridgeError("请先在系统蓝牙设置中配对手机，然后刷新设备。")
        }
        if waitingForPhone { disconnect() }
        selectedAddress = address
        configureIncomingCallbacks()
        let localChannel = try localService.start()
        // Publishing the HF record is enough for the phone to identify our
        // role. Registering a simultaneous incoming channel session makes
        // bluetoothd occasionally reuse the same internal Pipe handle as the
        // outbound connection, so keep the two modes separate.
        do { try incoming.start(channelID: localChannel, expectedAddress: address,
                                outboundDevice: device, listenForIncoming: false) }
        catch { localService.stop(); throw error }
        connecting = false
        waitingForPhone = true
        log("已发布 Mac 免提角色，正在通过实时 SDP 串行连接手机 AG 通道。")
    }

    func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connecting, let device,
                  device.addressString == self.selectedAddress else { return }
            guard status == kIOReturnSuccess, device.isHandsFreeAudioGateway else {
                self.connecting = false
                self.timeout?.cancel()
                self.localService.stop()
                self.log("未发现可用的 HFP Audio Gateway 服务（状态 \(status)）。")
                return
            }
            guard let service = device.handsFreeAudioGatewayServiceRecord() else {
                self.connecting = false
                self.timeout?.cancel()
                self.localService.stop()
                self.log("手机未返回免提服务记录。")
                return
            }
            var channel: BluetoothRFCOMMChannelID = 0
            let channelStatus = service.getRFCOMMChannelID(&channel)
            guard channelStatus == kIOReturnSuccess, (1...30).contains(channel) else {
                self.connecting = false
                self.timeout?.cancel()
                self.localService.stop()
                self.log("手机免提服务的 RFCOMM 通道无效（状态 \(channelStatus)，通道 \(channel)）。")
                return
            }
            self.log("发现手机免提服务：\(service.getServiceName() ?? "HFP")，RFCOMM 通道 \(channel)。正在连接…")
            self.log("已完成手机服务查询；入站连接由原始 RFCOMM 会话处理。")
        }
    }

    // Required by the SDK protocol; this bridge only initiates SDP queries.
    func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}
    func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    func disconnect() {
        rawProbe.cancel()
        timeout?.cancel()
        connecting = false
        waitingForPhone = false
        lostAudio()
        incoming.stop()
        queryDevice = nil
        let removalStatus = localService.stop()
        if removalStatus != kIOReturnSuccess { log("本机临时免提服务清理失败：\(removalStatus)，退出程序后由系统清理。") }
        state = CallState()
        log("已请求断开免提连接。")
    }

    private func ready() throws -> IncomingHfpSession {
        guard state.connected, incoming.connected else { throw BridgeError("尚未连接手机免提服务。") }
        return incoming
    }
    func dial(_ number: String) throws {
        let value = try CallInput.number(number)
        let phone = try ready()
        guard !state.active, state.setup == 0, state.held == 0 else { throw BridgeError("已有通话，不能重复拨号。") }
        try phone.dial(value)
        log("已提交拨号请求，等待手机反馈。")
    }
    func hangup() throws { try ready().hangup(); log("已提交挂断请求，等待手机反馈。") }
    func dtmf(_ key: String) throws {
        let value = try CallInput.dtmf(key)
        guard state.active else { throw BridgeError("需要先建立通话。") }
        try ready().dtmf(value)
        log("已发送一个菜单按键。")
    }
    func audioToMac() throws {
        _ = try ready()
        throw BridgeError("公开 IOBluetooth connectSCO 在这台 macOS 26 上固定返回不支持；当前仍没有可供 PhoneBridge 使用的手机通话音频端点。")
    }
    func audioToPhone() throws {
        lostAudio()
        _ = try ready()
        log("已停止电脑端音频；通话声音继续由手机处理。")
    }

    private func configureIncomingCallbacks() {
        incoming.log = { [weak self] in self?.log($0) }
        incoming.connectedChanged = { [weak self] connected, address in
            guard let self else { return }
            self.state.connected = connected
            self.waitingForPhone = !connected
            if connected {
                self.selectedAddress = address
            } else {
                self.lostAudio()
            }
        }
        incoming.stateChanged = { [weak self] state in
            guard let self else { return }
            self.state = state
            if !state.active && state.setup == 0 {
                self.lostAudio()
            }
        }
    }
}
