import { common } from '@kit.AbilityKit';
import { socket } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { call } from '@kit.TelephonyKit';
import { BluetoothBackground } from './BluetoothBackground';
import { HspAssistService, WirelessHelperStatus } from './HspAssistService';

class ControlRequest { id: string = ''; op: string = ''; number: string = ''; }
class ControlReply extends WirelessHelperStatus {
  id: string = '';
  ok: boolean = false;
  error: string = '';
  protocol: string = 'phonebridge-helper/1';
  routeRequested: boolean = false;
  routeActive: boolean = false;
  routeError: string = '';
  callState: number = -1;
  backgroundActive: boolean = false;
  standby: boolean = false;
  dialerStage: string = 'idle';
  dialerError: string = '';
  dialerRequestId: string = '';
  foreground: boolean = false;
}

// This paired-only channel prepares the proven audio services. Telephone
// commands remain on the phone's standard HFP AG, not an app telephony API.
export class WirelessControlService {
  static readonly uuid: string = '9d8b4c21-742e-4e0c-9c6f-4a1fa5c3a701';
  // Valid messages from the selected paired Mac renew this inactivity lease.
  // It is intentionally finite so a crashed desktop cannot leave stale phone
  // listeners behind indefinitely, but normal use has no visible countdown.
  private static readonly IDLE_LEASE_MS: number = 8 * 60 * 60 * 1000;
  private static server: number = -1;
  private static client: number = -1;
  private static context: common.UIAbilityContext | undefined = undefined;
  private static peer: string = '';
  private static generation: number = 0;
  private static active: boolean = false;
  private static sessionEnabled: boolean = false;
  private static expires: number = 0;
  private static timer: number = -1;
  private static pending: string = '';
  private static received: number = 0;
  private static status: string = '通话桥尚未启动。';
  private static observer: ((text: string, active: boolean) => void) | undefined = undefined;
  private static reader: ((data: ArrayBuffer) => void) | undefined = undefined;
  private static clientSilenceTimer: number = -1;
  private static acceptFailures: number = 0;
  private static accepting: boolean = false;
  private static routeRequested: boolean = false;
  private static routeActive: boolean = false;
  private static routeError: string = '';
  private static foreground: boolean = false;
  private static dialerStage: string = 'idle';
  private static dialerError: string = '';
  private static dialerRequestId: string = '';
  private static dialerTimer: number = -1;

  static setForeground(value: boolean): void { WirelessControlService.foreground = value; }
  static isActive(): boolean { return WirelessControlService.active && WirelessControlService.sessionEnabled; }
  static isListening(): boolean { return WirelessControlService.active; }

  static observe(observer: ((text: string, active: boolean) => void) | undefined): void {
    WirelessControlService.observer = observer;
    WirelessControlService.notify();
  }
  private static notify(): void {
    if (WirelessControlService.observer) {
      WirelessControlService.observer(WirelessControlService.status, WirelessControlService.isActive());
    }
  }
  static start(context: common.UIAbilityContext, peer: string, sessionEnabled: boolean = true): void {
    if (WirelessControlService.active || WirelessControlService.server >= 0 || WirelessControlService.client >= 0) { return; }
    const previous = HspAssistService.wirelessStatus();
    if (previous.active || previous.pendingConnect || !previous.cleanupSucceeded) { return; }
    const generation = ++WirelessControlService.generation;
    WirelessControlService.context = context;
    WirelessControlService.peer = peer.toUpperCase();
    WirelessControlService.active = true;
    WirelessControlService.sessionEnabled = sessionEnabled;
    WirelessControlService.pending = '';
    WirelessControlService.received = 0;
    WirelessControlService.acceptFailures = 0;
    WirelessControlService.accepting = false;
    WirelessControlService.routeRequested = false;
    WirelessControlService.routeActive = false;
    WirelessControlService.routeError = '';
    WirelessControlService.dialerStage = 'idle';
    WirelessControlService.dialerError = '';
    WirelessControlService.dialerRequestId = '';
    if (sessionEnabled) { WirelessControlService.armLease(generation); }
    WirelessControlService.status = sessionEnabled ? '正在准备通话桥…' : '已准备蓝牙唤起入口，等待 Mac 启动会话。';
    WirelessControlService.notify();
    // The owner explicitly started a paired-device Bluetooth listener. Keep
    // its system-visible bluetoothInteraction task alive while waiting; when
    // acquired only after accept, HarmonyOS can suspend the SPP read handler
    // and leave macOS connected to a stale SDP record with no replies.
    BluetoothBackground.start(context).then((ready: boolean) => {
      if (generation !== WirelessControlService.generation || !WirelessControlService.active) { return; }
      if (!ready) {
        WirelessControlService.stop('后台蓝牙待命未能启动，请检查通知权限后重试。'); return;
      }
      // Keep the gated HF SDP record published alongside the SPP wake entry.
      // On this phone macOS receives a nil RFCOMM open callback if the SPP
      // service is the only phone-side record at profile discovery time.
      HspAssistService.startWirelessListener(context, peer);
      try {
        socket.sppListen('PhoneBridge Control', { uuid: WirelessControlService.uuid,
          secure: true, type: socket.SppType.SPP_RFCOMM }, (error: BusinessError, server: number) => {
          if (generation !== WirelessControlService.generation || !WirelessControlService.active) {
            if (!error && server >= 0) { WirelessControlService.closeServer(server); }
            return;
          }
          if (error) { WirelessControlService.stop(`蓝牙准备失败：${error.code}`); return; }
          WirelessControlService.server = server;
          WirelessControlService.status = WirelessControlService.sessionEnabled ?
            '已准备好，请在 Mac 上点击连接。' : '蓝牙唤起入口已就绪，可在 Mac 上点击连接。';
          WirelessControlService.notify();
          WirelessControlService.accept(generation);
        });
      } catch (error) { WirelessControlService.stop(`蓝牙准备失败：${(error as BusinessError).code}`); }
    }).catch((error: BusinessError) => {
      if (generation === WirelessControlService.generation && WirelessControlService.active) {
        WirelessControlService.stop(`后台蓝牙待命失败：${error.code || 0}`);
      }
    });
  }
  private static accept(generation: number): void {
    if (!WirelessControlService.active || generation !== WirelessControlService.generation ||
      WirelessControlService.accepting || WirelessControlService.server < 0) { return; }
    WirelessControlService.accepting = true;
    try {
      socket.sppAccept(WirelessControlService.server, (error: BusinessError, client: number) => {
        if (generation === WirelessControlService.generation) { WirelessControlService.accepting = false; }
        if (generation !== WirelessControlService.generation || !WirelessControlService.active) {
          if (!error && client >= 0) { WirelessControlService.closeClient(client); }
          return;
        }
        if (error) {
          // A transient RFCOMM accept failure must not discard the user's
          // already published listener and background task. Keep the same
          // trusted peer and retry only while this session still owns them.
          WirelessControlService.acceptFailures++;
          if (WirelessControlService.acceptFailures > 3 || WirelessControlService.server < 0) {
            WirelessControlService.stop(`蓝牙监听连续失败：${error.code}`); return;
          }
          WirelessControlService.status = '蓝牙连接中断，正在自动恢复监听…';
          WirelessControlService.notify();
          const wait = WirelessControlService.acceptFailures * 300;
          setTimeout(() => {
            if (generation === WirelessControlService.generation && WirelessControlService.active &&
              WirelessControlService.server >= 0 && WirelessControlService.client < 0) {
              WirelessControlService.accept(generation);
            }
          }, wait);
          return;
        }
        WirelessControlService.acceptFailures = 0;
        let actualPeer = '';
        try { actualPeer = socket.getDeviceId(client).toUpperCase(); } catch (error) {}
        if (actualPeer !== WirelessControlService.peer) {
          if (WirelessControlService.closeClient(client)) { WirelessControlService.accept(generation); }
          else { WirelessControlService.stop('无法关闭非目标连接。'); }
          return;
        }
        const helper = HspAssistService.wirelessStatus();
        if (WirelessControlService.sessionEnabled && !helper.active && !helper.pendingConnect &&
          helper.cleanupSucceeded && WirelessControlService.context) {
          // A completed Mac call retires only the previous auxiliary HF
          // listener. Recreate it when the same paired Mac reconnects so one
          // phone session can serve multiple calls without another tap.
          HspAssistService.startWirelessListener(WirelessControlService.context, WirelessControlService.peer);
        }
        WirelessControlService.dialerStage = 'idle';
        WirelessControlService.dialerError = '';
        WirelessControlService.dialerRequestId = '';
        WirelessControlService.client = client;
        WirelessControlService.reader = (data: ArrayBuffer) => {
          if (generation === WirelessControlService.generation && WirelessControlService.active) {
            WirelessControlService.receive(data);
          }
        };
        try {
          socket.on('sppRead', client, WirelessControlService.reader);
          WirelessControlService.armClientSilence(generation, client);
          WirelessControlService.status = WirelessControlService.sessionEnabled ?
            'Mac 已连接，正在准备后台蓝牙连接…' : 'Mac 已连接，等待启动通话会话…';
          WirelessControlService.notify();
          WirelessControlService.prepareBackground(generation);
        } catch (error) { WirelessControlService.stop('蓝牙接收未就绪。'); }
      });
    } catch (error) {
      WirelessControlService.accepting = false;
      WirelessControlService.acceptFailures++;
      if (WirelessControlService.acceptFailures > 3) {
        WirelessControlService.stop('蓝牙连接未就绪。'); return;
      }
      setTimeout(() => { WirelessControlService.accept(generation); }, WirelessControlService.acceptFailures * 300);
    }
  }
  private static receive(data: ArrayBuffer): void {
    WirelessControlService.armClientSilence(WirelessControlService.generation, WirelessControlService.client);
    if (WirelessControlService.checkDeadline()) { return; }
    const bytes = new Uint8Array(data);
    WirelessControlService.received += bytes.length;
    if (WirelessControlService.received > 65536) { WirelessControlService.stop('控制消息超过本轮限制。'); return; }
    for (let i = 0; i < bytes.length; i++) {
      const value = bytes[i];
      if (value === 10) {
        const line = WirelessControlService.pending;
        WirelessControlService.pending = '';
        WirelessControlService.command(line);
        // The per-message length bound is the relevant memory guard. Reset the
        // transport counter so a healthy long-running heartbeat stream cannot
        // eventually terminate its own session.
        WirelessControlService.received = 0;
        if (!WirelessControlService.active) { return; }
      } else if (value >= 32 && value <= 126) {
        WirelessControlService.pending += String.fromCharCode(value);
        if (WirelessControlService.pending.length > 512) { WirelessControlService.stop('控制消息过长。'); return; }
      } else { WirelessControlService.stop('控制消息格式无效。'); return; }
    }
  }
  private static command(line: string): void {
    let request: ControlRequest;
    try { request = JSON.parse(line) as ControlRequest; }
    catch (error) { WirelessControlService.stop('控制消息格式无效。'); return; }
    const dialerRequest = request && request.op === 'dial_ui';
    const expectedKeys = dialerRequest ? 3 : 2;
    if (!request || typeof request.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(request.id) ||
      typeof request.op !== 'string' || Object.keys(request).length !== expectedKeys ||
      (dialerRequest && (typeof request.number !== 'string' || !/^\+?[0-9]{3,15}$/.test(request.number)))) {
      WirelessControlService.stop('控制消息参数无效。'); return;
    }
    let ok = true;
    let error = '';
    const stopRequested = request.op === 'stop';
    const stopGeneration = WirelessControlService.generation;
    if (request.op === 'status' || request.op === 'exchange' || request.op === 'audio' || request.op === 'dial_ui') {
      if (WirelessControlService.sessionEnabled) { WirelessControlService.armLease(WirelessControlService.generation); }
      HspAssistService.renewWirelessLease();
    }
    if (request.op === 'start_session') {
      ok = WirelessControlService.activateSession();
      if (!ok) { error = 'session-start-not-ready'; }
      WirelessControlService.sendReply(request.id, ok, error);
      return;
    }
    if (request.op === 'dial_ui') {
      WirelessControlService.openSystemDialer(request.id, request.number, stopGeneration);
      return;
    }
    if (request.op === 'audio') {
      WirelessControlService.activateCallAudio(request.id, stopGeneration);
      return;
    }
    if (request.op === 'exchange') { ok = HspAssistService.startHfExchange(); if (!ok) { error = 'exchange-not-ready'; } }
    // For stop, acknowledge over the still-open control channel first. Closing
    // the auxiliary HFP listener can also retire sibling RFCOMM channels on
    // some phones, so stopping it before sppWrite races away the acknowledgement.
    else if (stopRequested) {}
    else if (request.op !== 'status') { ok = false; error = 'unsupported-operation'; }
    WirelessControlService.sendReply(request.id, ok, error);
    if (stopRequested) {
      setTimeout(() => {
        if (stopGeneration === WirelessControlService.generation && WirelessControlService.active) {
          WirelessControlService.recycleClient(stopGeneration);
        }
      }, 120);
    }
    // Keep the control socket until explicit disconnect/deadline, so status can
    // independently confirm auxiliary cleanup before Mac closes the channel.
  }
  private static async prepareBackground(generation: number): Promise<void> {
    const context = WirelessControlService.context;
    if (!context) { return; }
    const ok = await BluetoothBackground.start(context);
    if (generation !== WirelessControlService.generation || !WirelessControlService.active) {
      BluetoothBackground.stop(); return;
    }
    if (!ok) {
      WirelessControlService.stop('后台蓝牙连接未能启动，请查看应用通知权限后重试。'); return;
    }
    WirelessControlService.status = WirelessControlService.sessionEnabled ?
      'Mac 已连接，后台蓝牙连接已启用。' : 'Mac 已连接，可启动通话会话。';
    WirelessControlService.notify();
  }
  static activateSession(): boolean {
    if (!WirelessControlService.active || !WirelessControlService.context || !BluetoothBackground.isActive()) { return false; }
    if (WirelessControlService.sessionEnabled) { return true; }
    try { if (call.getCallStateSync() !== call.CallState.CALL_STATE_IDLE) { return false; } }
    catch (error) { return false; }
    const helper = HspAssistService.wirelessStatus();
    if (!helper.active && (helper.pendingConnect || !helper.cleanupSucceeded)) { return false; }
    WirelessControlService.sessionEnabled = true;
    WirelessControlService.armLease(WirelessControlService.generation);
    if (!helper.active) {
      HspAssistService.startWirelessListener(WirelessControlService.context, WirelessControlService.peer);
    }
    WirelessControlService.status = 'Mac 已请求启动通话会话，正在准备蓝牙电话控制…';
    WirelessControlService.notify();
    return true;
  }
  // The owner may stop call readiness without removing the paired Mac's
  // Bluetooth-only wake listener. The background task remains visible to the
  // owner and is released when the app process is destroyed or Bluetooth ends.
  static park(reason: string): void {
    if (!WirelessControlService.active) { return; }
    WirelessControlService.sessionEnabled = false;
    if (WirelessControlService.timer >= 0) { clearTimeout(WirelessControlService.timer); WirelessControlService.timer = -1; }
    WirelessControlService.expires = 0;
    if (WirelessControlService.client >= 0) { WirelessControlService.recycleClient(WirelessControlService.generation); }
    else { HspAssistService.stop(reason); }
    WirelessControlService.status = reason;
    WirelessControlService.notify();
    const generation = WirelessControlService.generation;
    setTimeout(() => {
      if (generation !== WirelessControlService.generation || !WirelessControlService.active ||
        !WirelessControlService.context || WirelessControlService.sessionEnabled) { return; }
      const helper = HspAssistService.wirelessStatus();
      if (!helper.active && !helper.pendingConnect && helper.cleanupSucceeded) {
        HspAssistService.startWirelessListener(WirelessControlService.context, WirelessControlService.peer);
      }
    }, 600);
  }
  private static openSystemDialer(id: string, number: string, generation: number): void {
    if (!WirelessControlService.context || !WirelessControlService.foreground) {
      WirelessControlService.sendReply(id, false, 'dialer-requires-foreground'); return;
    }
    if (!BluetoothBackground.isActive()) {
      WirelessControlService.sendReply(id, false, 'background-not-ready'); return;
    }
    if (WirelessControlService.dialerStage !== 'idle') {
      WirelessControlService.sendReply(id, false, 'dialer-already-requested'); return;
    }
    try {
      if (call.getCallStateSync() !== call.CallState.CALL_STATE_IDLE) {
        WirelessControlService.sendReply(id, false, 'phone-not-idle'); return;
      }
    } catch (error) { WirelessControlService.sendReply(id, false, 'phone-state-unknown'); return; }
    WirelessControlService.dialerRequestId = id;
    WirelessControlService.dialerStage = 'requested';
    WirelessControlService.dialerError = '';
    // Ack acceptance before UI launch, so a slow system transition cannot block
    // the serialized RFCOMM status queue. This is NOT a visible-page assertion.
    WirelessControlService.sendReply(id, true, '');
    WirelessControlService.dialerTimer = setTimeout(() => {
      WirelessControlService.dialerTimer = -1;
      if (generation !== WirelessControlService.generation || !WirelessControlService.active ||
        WirelessControlService.dialerStage !== 'requested') { return; }
      if (!WirelessControlService.foreground) {
        WirelessControlService.dialerStage = 'failed';
        WirelessControlService.dialerError = 'dialer-requires-foreground';
        return;
      }
      WirelessControlService.submitSystemDialer(number, generation);
    }, 0);
  }
  private static async submitSystemDialer(number: string, generation: number): Promise<void> {
    const context = WirelessControlService.context;
    if (!context) { return; }
    WirelessControlService.dialerTimer = setTimeout(() => {
      if (generation === WirelessControlService.generation && WirelessControlService.dialerStage === 'requested') {
        WirelessControlService.dialerStage = 'failed';
        WirelessControlService.dialerError = 'dialer-api-timeout';
        WirelessControlService.notify();
      }
    }, 7000);
    try {
      await call.makeCall(context, number);
      if (generation !== WirelessControlService.generation || !WirelessControlService.active ||
        WirelessControlService.dialerStage !== 'requested') { return; }
      WirelessControlService.dialerStage = 'submitted';
      WirelessControlService.status = '系统拨号请求已提交，请核对手机是否显示拨号页面。';
    } catch (error) {
      if (generation !== WirelessControlService.generation || !WirelessControlService.active ||
        WirelessControlService.dialerStage !== 'requested') { return; }
      WirelessControlService.dialerStage = 'failed';
      WirelessControlService.dialerError = `dialer-open-error-${(error as BusinessError).code || 0}`;
      WirelessControlService.status = '系统拨号请求未完成，请在手机检查。';
    } finally {
      if (generation === WirelessControlService.generation) {
        if (WirelessControlService.dialerTimer >= 0) { clearTimeout(WirelessControlService.dialerTimer); }
        WirelessControlService.dialerTimer = -1;
        WirelessControlService.notify();
      }
    }
  }
  private static async activateCallAudio(id: string, generation: number): Promise<void> {
    WirelessControlService.routeRequested = true;
    WirelessControlService.routeActive = false;
    WirelessControlService.routeError = '';
    try {
      const manager = audio.getAudioManager();
      await manager.setDeviceActive(audio.ActiveDeviceType.BLUETOOTH_SCO, true);
      if (generation !== WirelessControlService.generation || !WirelessControlService.active) { return; }
      WirelessControlService.routeActive = await manager.isDeviceActive(audio.ActiveDeviceType.BLUETOOTH_SCO);
      if (!WirelessControlService.routeActive) { WirelessControlService.routeError = 'bluetooth-sco-not-active'; }
    } catch (error) {
      const code = (error as BusinessError).code;
      WirelessControlService.routeError = `audio-route-error-${code}`;
    }
    if (generation === WirelessControlService.generation && WirelessControlService.active) {
      WirelessControlService.sendReply(id, WirelessControlService.routeActive, WirelessControlService.routeError);
    }
  }
  private static sendReply(id: string, ok: boolean, error: string): void {
    const state = HspAssistService.wirelessStatus();
    const reply = new ControlReply();
    reply.id = id; reply.ok = ok; reply.error = error;
    reply.state = state.state; reply.active = state.active; reply.peerVerified = state.peerVerified;
    reply.slcControlComplete = state.slcControlComplete; reply.hfStage = state.hfStage;
    reply.cleanupSucceeded = state.cleanupSucceeded; reply.pendingConnect = state.pendingConnect;
    reply.remainingSeconds = state.remainingSeconds;
    reply.routeRequested = WirelessControlService.routeRequested;
    reply.routeActive = WirelessControlService.routeActive;
    reply.routeError = WirelessControlService.routeError;
    reply.backgroundActive = BluetoothBackground.isActive();
    reply.standby = WirelessControlService.active && !WirelessControlService.sessionEnabled;
    reply.dialerStage = WirelessControlService.dialerStage;
    reply.dialerError = WirelessControlService.dialerError;
    reply.dialerRequestId = WirelessControlService.dialerRequestId;
    reply.foreground = WirelessControlService.foreground;
    try { reply.callState = call.getCallStateSync(); } catch (error) { reply.callState = -1; }
    const encoded = JSON.stringify(reply) + '\n';
    const bytes = new Uint8Array(encoded.length);
    for (let i = 0; i < encoded.length; i++) { bytes[i] = encoded.charCodeAt(i); }
    try { socket.sppWrite(WirelessControlService.client, bytes.buffer); }
    catch (error) { WirelessControlService.stop('控制通道写入失败。'); return; }
  }
  private static armClientSilence(generation: number, client: number): void {
    if (WirelessControlService.clientSilenceTimer >= 0) {
      clearTimeout(WirelessControlService.clientSilenceTimer);
    }
    WirelessControlService.clientSilenceTimer = setTimeout(() => {
      WirelessControlService.clientSilenceTimer = -1;
      if (generation !== WirelessControlService.generation || !WirelessControlService.active ||
        WirelessControlService.client !== client) { return; }
      // A vanished Mac control process must not keep the only SPP client slot.
      // Never retire this channel merely for silence while a call is ongoing.
      if (WirelessControlService.dialerStage === 'requested') {
        WirelessControlService.armClientSilence(generation, client);
        return;
      }
      try {
        if (call.getCallStateSync() === call.CallState.CALL_STATE_IDLE) {
          WirelessControlService.recycleClient(generation);
          return;
        }
      } catch (error) {}
      WirelessControlService.armClientSilence(generation, client);
    }, 6000);
  }
  private static recycleClient(generation: number): void {
    if (!WirelessControlService.active || generation !== WirelessControlService.generation) { return; }
    // End the completed call's auxiliary HF resources, but retain the user's
    // explicitly started control listener. This keeps the phone ready for a
    // later plugin call until the inactivity lease or the user stops it.
    HspAssistService.stop('Mac 已结束本次连接。');
    if (WirelessControlService.clientSilenceTimer >= 0) {
      clearTimeout(WirelessControlService.clientSilenceTimer);
      WirelessControlService.clientSilenceTimer = -1;
    }
    const client = WirelessControlService.client;
    if (client >= 0 && WirelessControlService.reader) {
      try { socket.off('sppRead', client, WirelessControlService.reader); } catch (error) {}
    }
    WirelessControlService.reader = undefined;
    WirelessControlService.acceptFailures = 0;
    WirelessControlService.pending = '';
    WirelessControlService.received = 0;
    WirelessControlService.routeRequested = false;
    WirelessControlService.routeActive = false;
    WirelessControlService.routeError = '';
    if (client >= 0 && !WirelessControlService.closeClient(client)) { return; }
    WirelessControlService.client = -1;
    if (WirelessControlService.server < 0) {
      WirelessControlService.stop('蓝牙监听已结束，请重新启动会话。');
      return;
    }
    // Publish the auxiliary HF service BEFORE the Mac refreshes its ACL/SDP.
    // Recreating it in accept() is too late: macOS has already completed
    // profile discovery by then and never initiates the helper's SLC.
    const retired = HspAssistService.wirelessStatus();
    if (WirelessControlService.context && !retired.active &&
      !retired.pendingConnect && retired.cleanupSucceeded) {
      HspAssistService.startWirelessListener(WirelessControlService.context, WirelessControlService.peer);
    }
    if (WirelessControlService.sessionEnabled) { WirelessControlService.armLease(generation); }
    WirelessControlService.status = WirelessControlService.sessionEnabled ?
      '已准备好，等待 Mac 下次连接。' : '蓝牙唤起入口已就绪，等待 Mac 启动会话。';
    WirelessControlService.notify();
    // Register the next native accept before the background JS task can be
    // suspended. A timer here can leave a published SDP record with no accept
    // pending after the screen locks, so Mac connects but receives no bytes.
    WirelessControlService.accept(generation);
  }
  static checkDeadline(): boolean {
    if (WirelessControlService.active && WirelessControlService.sessionEnabled && Date.now() >= WirelessControlService.expires) {
      WirelessControlService.park('Mac 长时间未响应，通话会话已暂停；蓝牙唤起入口仍可用。'); return true;
    }
    return false;
  }
  private static armLease(generation: number): void {
    if (WirelessControlService.timer >= 0) { clearTimeout(WirelessControlService.timer); }
    WirelessControlService.expires = Date.now() + WirelessControlService.IDLE_LEASE_MS;
    WirelessControlService.timer = setTimeout(() => {
      if (generation === WirelessControlService.generation) {
        WirelessControlService.park('Mac 长时间未响应，通话会话已暂停；蓝牙唤起入口仍可用。');
      }
    }, WirelessControlService.IDLE_LEASE_MS);
  }
  private static closeClient(id: number): boolean {
    try { socket.sppCloseClientSocket(id); return true; }
    catch (error) {
      WirelessControlService.client = id;
      WirelessControlService.active = true;
      WirelessControlService.status = '关闭连接未确认，请再次停止。';
      WirelessControlService.notify();
      return false;
    }
  }
  private static closeServer(id: number): boolean {
    try { socket.sppCloseServerSocket(id); return true; }
    catch (error) {
      WirelessControlService.server = id;
      WirelessControlService.active = true;
      WirelessControlService.status = '关闭服务未确认，请再次停止。';
      WirelessControlService.notify();
      return false;
    }
  }
  static stop(reason: string): void {
    WirelessControlService.generation++;
    WirelessControlService.accepting = false;
    WirelessControlService.sessionEnabled = false;
    if (WirelessControlService.clientSilenceTimer >= 0) {
      clearTimeout(WirelessControlService.clientSilenceTimer);
      WirelessControlService.clientSilenceTimer = -1;
    }
    BluetoothBackground.stop();
    if (WirelessControlService.dialerTimer >= 0) { clearTimeout(WirelessControlService.dialerTimer); }
    WirelessControlService.dialerTimer = -1;
    if (WirelessControlService.dialerStage === 'requested') { WirelessControlService.dialerStage = 'cancelled'; }
    WirelessControlService.active = false;
    if (WirelessControlService.routeRequested) {
      try { audio.getAudioManager().setDeviceActive(audio.ActiveDeviceType.BLUETOOTH_SCO, false); } catch (error) {}
    }
    WirelessControlService.routeRequested = false;
    WirelessControlService.routeActive = false;
    if (WirelessControlService.timer >= 0) { clearTimeout(WirelessControlService.timer); WirelessControlService.timer = -1; }
    HspAssistService.stop(reason);
    if (WirelessControlService.client >= 0) {
      if (WirelessControlService.reader) {
        try { socket.off('sppRead', WirelessControlService.client, WirelessControlService.reader); } catch (error) {}
      }
      if (WirelessControlService.closeClient(WirelessControlService.client)) { WirelessControlService.client = -1; }
    }
    if (WirelessControlService.server >= 0 && WirelessControlService.closeServer(WirelessControlService.server)) {
      WirelessControlService.server = -1;
    }
    WirelessControlService.reader = undefined;
    WirelessControlService.pending = '';
    WirelessControlService.active = WirelessControlService.client >= 0 || WirelessControlService.server >= 0;
    if (!WirelessControlService.active) { WirelessControlService.context = undefined; }
    WirelessControlService.status = WirelessControlService.active ? '关闭连接未确认，请再次停止。' : reason;
    WirelessControlService.notify();
  }
  static dump(): string {
    WirelessControlService.checkDeadline();
    return `PhoneBridgeWireless: active=${WirelessControlService.active}; sessionEnabled=${WirelessControlService.sessionEnabled}; server=${WirelessControlService.server}; client=${WirelessControlService.client}; accepting=${WirelessControlService.accepting}; expires=${WirelessControlService.expires}; foreground=${WirelessControlService.foreground}; dialerStage=${WirelessControlService.dialerStage}; dialerError=${WirelessControlService.dialerError}; ${BluetoothBackground.dump()}`;
  }
}
