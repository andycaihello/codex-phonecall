import { common } from '@kit.AbilityKit';
import { socket } from '@kit.ConnectivityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HfSlcMachine } from './HfSlcMachine';

class HspEvent {
  time: string = '';
  kind: string = '';
  detail: string = '';
}

class HspDiagnostic {
  schema: number = 1;
  appVersion: string = '0.4.10';
  mode: string = 'hsp-listener';
  state: string = 'idle';
  active: boolean = false;
  serviceUuid: string = '00001108-0000-1000-8000-00805f9b34fb';
  expectedServiceClass: string = '1108 (unverified by remote SDP)';
  expectedProfileDescriptor: string = 'Current record unverified; prior device 1108 had no attribute 0009; OpenHarmony source predicts 1101/0102';
  audioVerified: boolean = false;
  slcControlComplete: boolean = false;
  hfStage: number = -1;
  agFeatures: string = '';
  cindDefinitions: string = '';
  cindValues: string = '';
  transmittedBytes: number = 0;
  receivedBytes: number = 0;
  peerVerified: boolean = false;
  cleanupSucceeded: boolean = true;
  cleanupScope: string = 'Returned socket IDs only; pending native operations are reported separately';
  pendingConnect: boolean = false;
  nativeConnectStatus: string = 'not-started';
  serverSocket: number = -1;
  clientSocket: number = -1;
  unclosedClientSockets: number[] = [];
  unclosedServerSockets: number[] = [];
  startedAt: string = '';
  expiresAt: string = '';
  updatedAt: string = '';
  diagnosticPath: string = '';
  fileError: string = '';
  events: HspEvent[] = [];
}

type HspObserver = (summary: string, active: boolean, exchangeReady: boolean) => void;

export class WirelessHelperStatus {
  state: string = 'idle';
  active: boolean = false;
  peerVerified: boolean = false;
  slcControlComplete: boolean = false;
  hfStage: number = -1;
  cleanupSucceeded: boolean = true;
  pendingConnect: boolean = false;
  remainingSeconds: number = 0;
}

// These public socket experiments control RFCOMM only. They do not grant SCO ownership.
export class HspAssistService {
  // The production wireless session uses an inactivity lease instead of the
  // diagnostic build's six-minute absolute deadline. A verified Mac refreshes
  // this lease with every valid control heartbeat. The absolute 180-second
  // deadline remains in place for the standalone diagnostic modes.
  private static readonly WIRELESS_IDLE_MS: number = 8 * 60 * 60 * 1000;
  private static report: HspDiagnostic = new HspDiagnostic();
  private static expectedPeer: string = '';
  private static generation: number = 0;
  private static deadline: number = 0;
  private static connectDeadline: number = 0;
  private static deadlineTimer: number = -1;
  private static retryTimer: number = -1;
  private static stageTimer: number = -1;
  private static hfMachine: HfSlcMachine | undefined = undefined;
  private static readObserver: ((data: ArrayBuffer) => void) | undefined = undefined;
  private static observer: HspObserver | undefined = undefined;
  private static pendingLine: string = '';

  static observe(observer: HspObserver | undefined): void {
    HspAssistService.observer = observer;
    HspAssistService.notify();
  }

  static start(context: common.UIAbilityContext, expectedPairedPeer: string): void {
    HspAssistService.startListener(context, expectedPairedPeer, false);
  }

  static startHfListener(context: common.UIAbilityContext, expectedPairedPeer: string): void {
    HspAssistService.startListener(context, expectedPairedPeer, true);
  }

  static startHfGatedListener(context: common.UIAbilityContext, expectedPairedPeer: string): void {
    HspAssistService.startListener(context, expectedPairedPeer, true, true);
  }

  static startWirelessListener(context: common.UIAbilityContext, peer: string): void {
    if (HspAssistService.report.active || HspAssistService.report.pendingConnect) { return; }
    HspAssistService.startListener(context, peer, true, true);
    if (HspAssistService.report.active) {
      HspAssistService.armWirelessLease();
    }
  }

  static renewWirelessLease(): boolean {
    if (!HspAssistService.report.active ||
      HspAssistService.report.mode !== 'hf-slc-listener-gated') { return false; }
    HspAssistService.armWirelessLease();
    return true;
  }

  private static armWirelessLease(): void {
    if (HspAssistService.deadlineTimer >= 0) { clearTimeout(HspAssistService.deadlineTimer); }
    HspAssistService.deadline = Date.now() + HspAssistService.WIRELESS_IDLE_MS;
    HspAssistService.report.expiresAt = new Date(HspAssistService.deadline).toISOString();
    const generation = HspAssistService.generation;
    HspAssistService.deadlineTimer = setTimeout(() => {
      if (generation === HspAssistService.generation) {
        HspAssistService.stop('paired Mac heartbeat timeout');
      }
    }, HspAssistService.WIRELESS_IDLE_MS);
  }

  static wirelessStatus(): WirelessHelperStatus {
    HspAssistService.checkDeadline();
    const value = new WirelessHelperStatus();
    value.state = HspAssistService.report.state;
    value.active = HspAssistService.report.active;
    value.peerVerified = HspAssistService.report.peerVerified;
    value.slcControlComplete = HspAssistService.report.slcControlComplete;
    value.hfStage = HspAssistService.report.hfStage;
    value.cleanupSucceeded = HspAssistService.report.cleanupSucceeded;
    value.pendingConnect = HspAssistService.report.pendingConnect;
    value.remainingSeconds = Math.max(0, Math.floor((HspAssistService.deadline - Date.now()) / 1000));
    return value;
  }

  private static startListener(context: common.UIAbilityContext, peer: string, hf: boolean,
    gated: boolean = false): void {
    if (HspAssistService.report.active || HspAssistService.report.pendingConnect) { return; }
    HspAssistService.begin(context, peer, gated ? 'hf-slc-listener-gated' :
      (hf ? 'hf-slc-listener' : 'hsp-listener'));
    const generation = HspAssistService.generation;
    if (hf) {
      HspAssistService.report.serviceUuid = '0000111e-0000-1000-8000-00805f9b34fb';
      HspAssistService.report.expectedServiceClass = '111e auxiliary HF class (unverified by remote SDP)';
    }
    HspAssistService.event('start', hf ? 'Temporary HF class; vendor profile descriptor unverified; not certified HFP; audio unverified' :
      'Temporary HSP HS class; audio unverified; no data transmission');
    const options: socket.SppOptions = {
      uuid: HspAssistService.report.serviceUuid,
      secure: true,
      type: socket.SppType.SPP_RFCOMM
    };
    try {
      socket.sppListen(hf ? 'PhoneBridge HF diagnostic' : 'PhoneBridge HSP diagnostic', options,
        (error: BusinessError, server: number) => {
        if (generation !== HspAssistService.generation || !HspAssistService.report.active) {
          if (!error && server >= 0) { HspAssistService.closeLateServer(server); }
          return;
        }
        if (HspAssistService.checkDeadline()) {
          if (!error && server >= 0) { HspAssistService.closeLateServer(server); }
          return;
        }
        if (error) {
          HspAssistService.event('listen-error', `code=${error.code}`);
          HspAssistService.stop('listen failed');
          return;
        }
        HspAssistService.report.serverSocket = server;
        HspAssistService.report.state = 'listening';
        HspAssistService.event('listen-ready', 'Server socket retained; remote SDP still needs verification');
        HspAssistService.accept(generation);
      });
    } catch (error) {
      HspAssistService.event('listen-exception', `code=${(error as BusinessError).code}`);
      HspAssistService.stop('listen threw');
    }
  }

  private static begin(context: common.UIAbilityContext, peer: string, mode: string): void {
    HspAssistService.generation++;
    HspAssistService.expectedPeer = peer.toUpperCase();
    HspAssistService.pendingLine = '';
    HspAssistService.hfMachine = undefined;
    HspAssistService.report = new HspDiagnostic();
    HspAssistService.report.mode = mode;
    HspAssistService.report.diagnosticPath = `${context.filesDir}/phonebridge-hsp-diagnostic.json`;
    HspAssistService.report.active = true;
    HspAssistService.report.state = 'starting';
    HspAssistService.report.startedAt = new Date().toISOString();
    HspAssistService.deadline = Date.now() + 180000;
    HspAssistService.report.expiresAt = new Date(HspAssistService.deadline).toISOString();
    HspAssistService.deadlineTimer = setTimeout(() => HspAssistService.stop('180-second deadline'), 180000);
  }

  static startHf(context: common.UIAbilityContext, expectedPairedPeer: string): void {
    if (HspAssistService.report.active || HspAssistService.report.pendingConnect) { return; }
    HspAssistService.begin(context, expectedPairedPeer, 'hf-slc-client');
    const generation = HspAssistService.generation;
    HspAssistService.report.serviceUuid = '0000111f-0000-1000-8000-00805f9b34fb';
    HspAssistService.report.expectedServiceClass = 'Remote Mac AG 111f; no local HF record published';
    HspAssistService.report.expectedProfileDescriptor = 'No local profile descriptor; auxiliary SLC experiment only';
    HspAssistService.report.state = 'hf-connecting';
    HspAssistService.report.pendingConnect = true;
    HspAssistService.report.nativeConnectStatus = 'callback-pending';
    HspAssistService.connectDeadline = Date.now() + 20000;
    HspAssistService.event('start', 'Connecting to paired Mac AG; four fixed SLC commands only; audio unverified');
    const options: socket.SppOptions = {
      uuid: HspAssistService.report.serviceUuid,
      secure: true,
      type: socket.SppType.SPP_RFCOMM
    };
    HspAssistService.stageTimer = setTimeout(() => {
      if (generation === HspAssistService.generation && HspAssistService.report.state === 'hf-connecting') {
        HspAssistService.stop('20-second connect timeout');
      }
    }, 20000);
    try {
      socket.sppConnect(HspAssistService.expectedPeer, options, (error: BusinessError, client: number) => {
        HspAssistService.report.pendingConnect = false;
        HspAssistService.report.nativeConnectStatus = 'callback-returned';
        if (generation !== HspAssistService.generation || !HspAssistService.report.active) {
          if (!error && client >= 0) {
            if (!HspAssistService.closeLateClient(client)) {
              HspAssistService.report.clientSocket = client;
              HspAssistService.report.cleanupSucceeded = false;
              HspAssistService.report.active = true;
              HspAssistService.report.state = 'cleanup-error';
            }
          }
          HspAssistService.event('hf-late-connect-returned', 'Native callback returned after app stop; no handshake resumed');
          return;
        }
        if (HspAssistService.checkDeadline()) {
          if (!error && client >= 0) { HspAssistService.closeLateClient(client); }
          return;
        }
        if (Date.now() >= HspAssistService.connectDeadline) {
          if (!error && client >= 0) { HspAssistService.report.clientSocket = client; }
          HspAssistService.stop('connect callback after 20-second deadline');
          return;
        }
        if (HspAssistService.stageTimer >= 0) { clearTimeout(HspAssistService.stageTimer); }
        HspAssistService.stageTimer = -1;
        if (error) {
          HspAssistService.event('hf-connect-error', `code=${error.code}`);
          HspAssistService.stop('HF control connect failed');
          return;
        }
        HspAssistService.report.clientSocket = client;
        let peer = '';
        try { peer = socket.getDeviceId(client).toUpperCase(); } catch (error) {}
        if (peer.length === 0 || peer !== HspAssistService.expectedPeer) {
          HspAssistService.stop('HF socket peer verification failed');
          return;
        }
        HspAssistService.report.peerVerified = true;
        HspAssistService.beginHfExchange(client, generation);
      });
    } catch (error) {
      HspAssistService.report.pendingConnect = false;
      HspAssistService.report.nativeConnectStatus = 'API-threw-before-callback';
      HspAssistService.event('hf-connect-exception', `code=${(error as BusinessError).code}`);
      HspAssistService.stop('HF control connect threw');
    }
  }

  static canStartHfExchange(): boolean {
    return HspAssistService.report.active && HspAssistService.report.peerVerified &&
      HspAssistService.report.clientSocket >= 0 && HspAssistService.report.mode === 'hf-slc-listener-gated' &&
      HspAssistService.report.state === 'hf-awaiting-handshake' &&
      HspAssistService.readObserver !== undefined && Date.now() < HspAssistService.deadline;
  }

  static startHfExchange(): boolean {
    if (HspAssistService.checkDeadline() || !HspAssistService.canStartHfExchange()) { return false; }
    HspAssistService.pendingLine = '';
    HspAssistService.event('hf-manual-exchange-request', 'Manual start accepted for verified gated HF socket');
    HspAssistService.beginHfExchange(HspAssistService.report.clientSocket, HspAssistService.generation, true);
    return true;
  }

  private static beginHfExchange(client: number, generation: number, alreadySubscribed: boolean = false): void {
    if (generation !== HspAssistService.generation || !HspAssistService.report.active ||
      !HspAssistService.report.peerVerified) { return; }
    HspAssistService.report.state = 'hf-handshake';
    const machine = new HfSlcMachine();
    HspAssistService.hfMachine = machine;
    machine.start();
    if (!alreadySubscribed) {
      HspAssistService.readObserver = (data: ArrayBuffer) => {
        if (generation === HspAssistService.generation && HspAssistService.report.active) {
          HspAssistService.receive(data);
        }
      };
    }
    try {
      if (!alreadySubscribed && HspAssistService.readObserver) {
        socket.on('sppRead', client, HspAssistService.readObserver);
      }
      HspAssistService.event('hf-connected', 'Paired Mac verified; starting bounded SLC exchange');
      HspAssistService.advanceHf(generation);
    } catch (error) {
      HspAssistService.event('hf-subscription-error', `code=${(error as BusinessError).code}`);
      HspAssistService.stop('HF read subscription failed');
    }
  }

  private static advanceHf(generation: number): void {
    const machine = HspAssistService.hfMachine;
    if (!machine || generation !== HspAssistService.generation || !HspAssistService.report.active) { return; }
    if (HspAssistService.checkDeadline()) { return; }
    HspAssistService.report.hfStage = machine.stage;
    HspAssistService.report.agFeatures = machine.agFeatures;
    HspAssistService.report.cindDefinitions = machine.cindDefinitions;
    HspAssistService.report.cindValues = machine.cindValues;
    if (machine.checkTimeout(Date.now())) { HspAssistService.stop(machine.reason); return; }
    if (machine.state === 'complete') {
      if (HspAssistService.stageTimer >= 0) { clearTimeout(HspAssistService.stageTimer); }
      HspAssistService.stageTimer = -1;
      if (!HspAssistService.report.slcControlComplete) {
        HspAssistService.report.slcControlComplete = true;
        HspAssistService.report.state = 'hf-control-complete';
        HspAssistService.event('hf-slc-complete', 'Four control stages acknowledged; SCO and audio remain unverified');
      }
      return;
    }
    const command = machine.takeCommand(Date.now());
    if (command.length === 0) { return; }
    const allowed = command === 'AT+BRSF=0\r' || command === 'AT+CIND=?\r' ||
      command === 'AT+CIND?\r' || command === 'AT+CMER=3,0,0,1\r';
    if (!allowed || !HspAssistService.report.peerVerified) { HspAssistService.stop('command guard failed'); return; }
    if (HspAssistService.stageTimer >= 0) { clearTimeout(HspAssistService.stageTimer); }
    HspAssistService.stageTimer = setTimeout(() => {
      if (generation === HspAssistService.generation) { HspAssistService.advanceHf(generation); }
    }, 12000);
    try {
      const bytes = new Uint8Array(command.length);
      for (let i = 0; i < command.length; i++) { bytes[i] = command.charCodeAt(i); }
      socket.sppWrite(HspAssistService.report.clientSocket, bytes.buffer);
      HspAssistService.report.transmittedBytes += bytes.length;
      HspAssistService.event('hf-command', command.trim());
    } catch (error) {
      HspAssistService.event('hf-write-error', `code=${(error as BusinessError).code}`);
      HspAssistService.stop('HF command write failed');
    }
  }

  private static accept(generation: number): void {
    if (generation !== HspAssistService.generation || !HspAssistService.report.active) { return; }
    if (HspAssistService.checkDeadline()) { return; }
    try {
      socket.sppAccept(HspAssistService.report.serverSocket, (error: BusinessError, client: number) => {
        if (generation !== HspAssistService.generation || !HspAssistService.report.active) {
          if (!error && client >= 0) { HspAssistService.closeLateClient(client); }
          return;
        }
        if (HspAssistService.checkDeadline()) {
          if (!error && client >= 0) { HspAssistService.closeLateClient(client); }
          return;
        }
        if (error) {
          HspAssistService.event('accept-retry', `code=${error.code}; no accepted connection`);
          HspAssistService.retryTimer = setTimeout(() => HspAssistService.accept(generation), 1000);
          return;
        }
        let peer = '';
        try { peer = socket.getDeviceId(client).toUpperCase(); }
        catch (error) {
          HspAssistService.event('peer-verification-error', `code=${(error as BusinessError).code}`);
        }
        if (peer.length === 0 || peer !== HspAssistService.expectedPeer) {
          if (!HspAssistService.closeLateClient(client)) { return; }
          HspAssistService.event('peer-rejected', 'Peer did not match the selected paired Mac');
          HspAssistService.retryTimer = setTimeout(() => HspAssistService.accept(generation), 1000);
          return;
        }
        HspAssistService.report.clientSocket = client;
        HspAssistService.report.peerVerified = true;
        if (HspAssistService.report.mode === 'hf-slc-listener') {
          HspAssistService.beginHfExchange(client, generation);
          return;
        }
        const gated = HspAssistService.report.mode === 'hf-slc-listener-gated';
        HspAssistService.report.state = gated ? 'hf-awaiting-handshake' : 'connected';
        HspAssistService.readObserver = (data: ArrayBuffer) => {
          if (generation === HspAssistService.generation && HspAssistService.report.active) {
            HspAssistService.receive(data);
          }
        };
        try {
          socket.on('sppRead', client, HspAssistService.readObserver);
          HspAssistService.event(gated ? 'hf-awaiting-handshake' : 'connected', gated ?
            'Paired Mac verified; no AT sent; waiting for manual HF exchange button' :
            'Paired Mac verified; RFCOMM retained; no AT command sent');
        } catch (error) {
          HspAssistService.event('read-subscription-error', `code=${(error as BusinessError).code}`);
          HspAssistService.stop('read subscription failed');
        }
      });
    } catch (error) {
      HspAssistService.event('accept-exception', `code=${(error as BusinessError).code}`);
      HspAssistService.stop('accept threw');
    }
  }

  private static receive(data: ArrayBuffer): void {
    if (HspAssistService.checkDeadline()) { return; }
    const bytes = new Uint8Array(data);
    HspAssistService.report.receivedBytes += bytes.length;
    if (HspAssistService.report.receivedBytes > 2097152) {
      HspAssistService.stop('diagnostic byte limit');
      return;
    }
    const machine = HspAssistService.hfMachine;
    if (machine) {
      machine.feed(bytes, Date.now());
      for (const line of machine.receivedLines) { HspAssistService.event('hf-response', line); }
      HspAssistService.advanceHf(HspAssistService.generation);
      HspAssistService.persist();
      return;
    }
    for (let i = 0; i < bytes.length; i++) {
      const value = bytes[i];
      if (value === 10 || value === 13) {
        if (HspAssistService.pendingLine.length > 0) {
          HspAssistService.recordLine(HspAssistService.pendingLine.trim());
          HspAssistService.pendingLine = '';
        }
      } else if (value >= 32 && value < 127) {
        HspAssistService.pendingLine += String.fromCharCode(value);
        if (HspAssistService.pendingLine.length > 512) {
          HspAssistService.stop('control line length limit');
          return;
        }
      }
    }
    HspAssistService.persist();
  }

  private static recordLine(line: string): void {
    if (line === 'RING' || line === 'OK' || line === 'ERROR') {
      HspAssistService.event('ag-notification', line);
    } else if (/^\+VG[SM]\s*[:=]\s*\d{1,2}$/.test(line)) {
      HspAssistService.event('ag-gain', line);
    } else {
      // Do not save unknown AG lines: they could contain caller identity or unrelated metadata.
      HspAssistService.event('ag-other', `Redacted control line (${line.length} characters)`);
    }
  }

  static checkDeadline(): boolean {
    if (HspAssistService.report.active && Date.now() >= HspAssistService.deadline) {
      HspAssistService.stop('deadline reached');
      return true;
    }
    return false;
  }

  static stop(reason: string): void {
    if (!HspAssistService.report.active) { return; }
    HspAssistService.generation++;
    HspAssistService.report.active = false;
    if (HspAssistService.deadlineTimer >= 0) { clearTimeout(HspAssistService.deadlineTimer); }
    if (HspAssistService.retryTimer >= 0) { clearTimeout(HspAssistService.retryTimer); }
    if (HspAssistService.stageTimer >= 0) { clearTimeout(HspAssistService.stageTimer); }
    HspAssistService.deadlineTimer = -1;
    HspAssistService.retryTimer = -1;
    HspAssistService.stageTimer = -1;
    if (HspAssistService.hfMachine) { HspAssistService.hfMachine.stop(reason); }
    const client = HspAssistService.report.clientSocket;
    const server = HspAssistService.report.serverSocket;
    let clientClosed = true;
    let serverClosed = true;
    if (client >= 0) {
      if (HspAssistService.readObserver) {
        try { socket.off('sppRead', client, HspAssistService.readObserver); } catch (error) {}
      }
      clientClosed = HspAssistService.closeLateClient(client);
    }
    // Close the accepted socket before the listener; each API uses its own numeric socket IDs.
    if (server >= 0) { serverClosed = HspAssistService.closeLateServer(server); }
    for (const socketId of HspAssistService.report.unclosedClientSockets.slice()) {
      if (socketId !== client) { HspAssistService.closeLateClient(socketId); }
    }
    for (const socketId of HspAssistService.report.unclosedServerSockets.slice()) {
      if (socketId !== server) { HspAssistService.closeLateServer(socketId); }
    }
    HspAssistService.readObserver = undefined;
    HspAssistService.pendingLine = '';
    HspAssistService.expectedPeer = '';
    HspAssistService.report.clientSocket = clientClosed ? -1 : client;
    HspAssistService.report.serverSocket = serverClosed ? -1 : server;
    HspAssistService.report.cleanupSucceeded = clientClosed && serverClosed &&
      HspAssistService.report.unclosedClientSockets.length === 0 && HspAssistService.report.unclosedServerSockets.length === 0;
    HspAssistService.report.active = !HspAssistService.report.cleanupSucceeded;
    HspAssistService.report.state = HspAssistService.report.cleanupSucceeded ? 'stopped' : 'cleanup-error';
    if (HspAssistService.report.pendingConnect) {
      HspAssistService.report.nativeConnectStatus = 'callback-pending-after-app-stop; native cancellation unconfirmed';
    }
    HspAssistService.event('stop', reason);
  }

  private static closeLateClient(client: number): boolean {
    try {
      socket.sppCloseClientSocket(client);
      HspAssistService.report.unclosedClientSockets = HspAssistService.report.unclosedClientSockets
        .filter((socketId: number) => socketId !== client);
      return true;
    }
    catch (error) {
      if (!HspAssistService.report.unclosedClientSockets.includes(client)) {
        HspAssistService.report.unclosedClientSockets.push(client);
      }
      HspAssistService.report.cleanupSucceeded = false;
      HspAssistService.report.active = true;
      HspAssistService.report.state = 'cleanup-error';
      HspAssistService.event('client-close-error', `code=${(error as BusinessError).code}`);
      return false;
    }
  }

  private static closeLateServer(server: number): boolean {
    try {
      socket.sppCloseServerSocket(server);
      HspAssistService.report.unclosedServerSockets = HspAssistService.report.unclosedServerSockets
        .filter((socketId: number) => socketId !== server);
      return true;
    }
    catch (error) {
      if (!HspAssistService.report.unclosedServerSockets.includes(server)) {
        HspAssistService.report.unclosedServerSockets.push(server);
      }
      HspAssistService.report.cleanupSucceeded = false;
      HspAssistService.report.active = true;
      HspAssistService.report.state = 'cleanup-error';
      HspAssistService.event('server-close-error', `code=${(error as BusinessError).code}`);
      return false;
    }
  }

  private static event(kind: string, detail: string): void {
    const event = new HspEvent();
    event.time = new Date().toISOString();
    event.kind = kind;
    event.detail = detail;
    HspAssistService.report.events.push(event);
    if (HspAssistService.report.events.length > 40) { HspAssistService.report.events.shift(); }
    HspAssistService.persist();
    HspAssistService.notify();
  }

  private static persist(): void {
    HspAssistService.report.updatedAt = new Date().toISOString();
    if (HspAssistService.report.diagnosticPath.length === 0) { return; }
    const temporaryPath = `${HspAssistService.report.diagnosticPath}.tmp`;
    let fd = -1;
    try {
      HspAssistService.report.fileError = '';
      fd = fileIo.openSync(temporaryPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.TRUNC).fd;
      fileIo.writeSync(fd, JSON.stringify(HspAssistService.report));
      fileIo.closeSync(fd);
      fd = -1;
      fileIo.renameSync(temporaryPath, HspAssistService.report.diagnosticPath);
    } catch (error) {
      HspAssistService.report.fileError = `Private file save failed: code=${(error as BusinessError).code}`;
    } finally {
      if (fd >= 0) { try { fileIo.closeSync(fd); } catch (error) {} }
    }
  }

  private static notify(): void {
    if (!HspAssistService.observer) { return; }
    let summary = '临时 HSP 服务尚未启动。';
    if (HspAssistService.report.state === 'starting') {
      summary = HspAssistService.report.mode.startsWith('hf-slc-listener') ? '正在发布临时 111e 辅助 HF 服务…' :
        '正在发布临时 1108 服务…';
    }
    else if (HspAssistService.report.state === 'listening') { summary = '正在等待 Mac 连接；服务类别须由 Mac 的 SDP 查询核实。'; }
    else if (HspAssistService.report.state === 'connected') { summary = 'Mac 辅助 RFCOMM 已连接；通话音频尚未验证。'; }
    else if (HspAssistService.report.state === 'hf-connecting') { summary = '正在连接已配对 Mac 的电话网关控制服务…'; }
    else if (HspAssistService.report.state === 'hf-awaiting-handshake') {
      summary = 'Mac 辅助连接已验证，尚未发送 AT；等待点击“开始 HF 握手”。';
    }
    else if (HspAssistService.report.state === 'hf-handshake') {
      summary = `辅助 HF 控制握手，第 ${HspAssistService.report.hfStage + 1}/4 步；通话音频尚未验证。`;
    }
    else if (HspAssistService.report.state === 'hf-control-complete') {
      summary = '辅助 HF 的四步控制握手已完成；保持连接，SCO 与通话音频尚未验证。';
    }
    else if (HspAssistService.report.state === 'stopped') { summary = '临时服务已停止；诊断已保留。'; }
    else if (HspAssistService.report.state === 'cleanup-error') {
      summary = '关闭接口返回错误，尚未确认服务停止；请再次点击停止并查看诊断。';
    }
    if (HspAssistService.report.pendingConnect && !HspAssistService.report.active) {
      summary = '应用握手已停止；原生连接回调尚未返回，不能确认已取消原生请求，暂不启动其他实验。';
    }
    if (HspAssistService.report.fileError.length > 0) { summary += ' 私有诊断文件保存失败，可从应用 dump 读取。'; }
    HspAssistService.observer(summary, HspAssistService.report.active || HspAssistService.report.pendingConnect,
      HspAssistService.canStartHfExchange());
  }

  static dump(): string {
    HspAssistService.checkDeadline();
    return `PhoneBridgeHsp: ${JSON.stringify(HspAssistService.report)}`;
  }
}
