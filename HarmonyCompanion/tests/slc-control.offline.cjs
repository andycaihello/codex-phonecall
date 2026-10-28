// Offline protocol/lifecycle checks. Executes the actual ETS classes after TypeScript erasure.
// All Harmony APIs and timers are fake: this script cannot access Bluetooth or a phone.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const serviceDir = path.join(__dirname, '../entry/src/main/ets/services');
const commands = ['AT+BRSF=0\r', 'AT+CIND=?\r', 'AT+CIND?\r', 'AT+CMER=3,0,0,1\r'];
const responses = [
  '\r\n+BRSF: 512\r\nOK\r\n',
  '\r\n+CIND: ("service",(0,1)),("call",(0,1)),("signal",(0-5))\r\nOK\r\n',
  '\r\n+CIND: 1,0,5\r\nOK\r\n',
  '\r\nOK\r\n'
];

function sandbox() {
  let now = 1000;
  let nextTimer = 0;
  let closeFailure = false;
  let serverCloseFailure = false;
  const timers = new Map();
  const writes = [], closedClients = [], closedServers = [], connections = [], listeners = [];
  const callbacks = [], accepts = [];
  const peer = '01:23:45:67:89:AB';
  let actualPeer = peer;
  const socket = {
    SppType: { SPP_RFCOMM: 0 },
    sppConnect: (id, options, cb) => connections.push({ id, options, cb }),
    sppListen: (name, options, cb) => listeners.push({ name, options, cb }),
    sppAccept: (server, cb) => accepts.push({ server, cb }),
    getDeviceId: () => actualPeer,
    on: (event, id, cb) => callbacks.push(cb),
    off: () => {},
    sppWrite: (id, buffer) => writes.push(Buffer.from(buffer).toString('ascii')),
    sppCloseClientSocket: id => {
      if (closeFailure) { throw { code: 2900099 }; }
      closedClients.push(id);
    },
    sppCloseServerSocket: id => {
      if (serverCloseFailure) { throw { code: 2900099 }; }
      closedServers.push(id);
    }
  };
  const fileIo = { OpenMode: {}, openSync: () => ({ fd: 1 }), writeSync: () => {},
    closeSync: () => {}, renameSync: () => {} };
  const cache = {};
  class FakeDate extends Date { static now() { return now; } }
  function load(name) {
    if (cache[name]) { return cache[name]; }
    const source = fs.readFileSync(path.join(serviceDir, name + '.ets'), 'utf8');
    const result = ts.transpileModule(source, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    });
    const exports = {};
    vm.runInNewContext(result.outputText, {
      exports, Date: FakeDate, Uint8Array, ArrayBuffer,
      setTimeout: (cb, ms) => { const id = ++nextTimer; timers.set(id, { cb, at: now + ms }); return id; },
      clearTimeout: id => timers.delete(id),
      require: specifier => {
        if (specifier === '@kit.ConnectivityKit') { return { socket }; }
        if (specifier === '@kit.CoreFileKit') { return { fileIo }; }
        if (specifier === './HfSlcMachine') { return load('HfSlcMachine'); }
        throw Error('Unexpected runtime dependency: ' + specifier);
      }
    }, { filename: name + '.js' });
    cache[name] = exports;
    return exports;
  }
  return {
    Machine: load('HfSlcMachine').HfSlcMachine,
    Service: load('HspAssistService').HspAssistService,
    context: { filesDir: '/mock-private' }, peer, writes, closedClients, closedServers,
    connections, listeners, callbacks, accepts, timers,
    setTime: value => { now = value; }, setPeer: value => { actualPeer = value; },
    setCloseFailure: value => { closeFailure = value; },
    setServerCloseFailure: value => { serverCloseFailure = value; }
  };
}

let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS ' + name); }
function feed(machine, text, now = 1000) { machine.feed(new Uint8Array(Buffer.from(text, 'ascii')), now); }
function toStage(machine, stage) {
  machine.start();
  for (let i = 0; i < stage; i++) {
    assert.equal(machine.takeCommand(1000), commands[i]); feed(machine, responses[i]);
  }
}

test('every split boundary including split OK completes only the four expected stages', () => {
  const { Machine } = sandbox();
  for (let selectedStage = 0; selectedStage < 4; selectedStage++) {
    for (let split = 0; split <= responses[selectedStage].length; split++) {
      const m = new Machine(); m.start();
      for (let i = 0; i < 4; i++) {
        assert.equal(m.takeCommand(1000), commands[i]);
        if (i === selectedStage) { feed(m, responses[i].slice(0, split)); feed(m, responses[i].slice(split)); }
        else { feed(m, responses[i]); }
      }
      assert.equal(m.state, 'complete'); assert.equal(m.cindValues, '+CIND: 1,0,5');
      assert.equal(m.takeCommand(1000), '');
    }
  }
});
test('coalesced extra OK cannot acknowledge a command that has not been sent', () => {
  const { Machine } = sandbox(); const m = new Machine(); toStage(m, 0);
  m.takeCommand(1000); feed(m, responses[0] + 'OK\r\n');
  assert.equal(m.stage, 1); assert.equal(m.state, 'ready');
  assert.equal(m.takeCommand(1000), commands[1]); assert.equal(m.state, 'waiting');
});
test('partial stale OK is discarded at the next command boundary', () => {
  const { Machine } = sandbox(); const m = new Machine(); toStage(m, 2);
  m.takeCommand(1000); feed(m, responses[2] + 'O');
  m.takeCommand(1000); feed(m, 'K\r\n'); assert.equal(m.state, 'waiting');
  feed(m, 'OK\r\n'); assert.equal(m.state, 'complete');
});
test('bare OK before BRSF, CIND definitions, or CIND values fails closed', () => {
  const { Machine } = sandbox();
  for (let stage = 0; stage < 3; stage++) {
    const m = new Machine(); toStage(m, stage); m.takeCommand(1000); feed(m, '\r\nOK\r\n');
    assert.equal(m.state, 'failed'); assert.equal(m.takeCommand(1000), '');
  }
});
test('ERROR, stage timeout, and manual stop reject later data and commands', () => {
  const { Machine } = sandbox();
  for (const reason of ['ERROR', 'timeout', 'stop']) {
    const m = new Machine(); toStage(m, 0); m.takeCommand(1000);
    if (reason === 'ERROR') { feed(m, 'ERROR\r\n'); }
    else if (reason === 'timeout') { assert.equal(m.checkTimeout(13000), true); }
    else { m.stop('user stop'); }
    feed(m, responses[0], 14000); assert.equal(m.takeCommand(14000), '');
    assert.notEqual(m.state, 'complete');
  }
});
test('unknown caller metadata is redacted and overlong/non-ASCII lines stop parsing', () => {
  const { Machine } = sandbox(); const m = new Machine(); toStage(m, 0); m.takeCommand(1000);
  feed(m, '+CLIP: "13800000000",129\r\n'); assert.equal(m.receivedLines.length, 1);
  assert.equal(m.receivedLines[0].includes('13800000000'), false);
  feed(m, 'X'.repeat(513)); assert.equal(m.state, 'failed');
  const n = new Machine(); toStage(n, 0); n.takeCommand(1000);
  n.feed(new Uint8Array([0]), 1000); assert.equal(n.state, 'failed');
});
test('real service sends the exact whitelist and reports control-only completion', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer);
  assert.equal(s.connections[0].id, s.peer);
  assert.equal(s.connections[0].options.uuid, '0000111f-0000-1000-8000-00805f9b34fb');
  s.connections[0].cb(undefined, 42);
  for (const response of responses) { s.callbacks[0](Uint8Array.from(Buffer.from(response)).buffer); }
  assert.deepEqual(s.writes, commands);
  const report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.slcControlComplete, true); assert.equal(report.audioVerified, false);
  assert.equal(report.active, true); s.Service.stop('test stop'); assert.deepEqual(s.closedClients, [42]);
});
test('connect callback after user stop closes socket without any write', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.Service.stop('user stop');
  s.connections[0].cb(undefined, 44); assert.deepEqual(s.closedClients, [44]); assert.deepEqual(s.writes, []);
});
test('late callback after absolute connect deadline closes even when timer did not run', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.setTime(21000);
  s.connections[0].cb(undefined, 45); assert.deepEqual(s.closedClients, [45]); assert.deepEqual(s.writes, []);
});
test('wrong peer gets no command; stale read after user stop cannot send another', () => {
  const wrong = sandbox(); wrong.Service.startHf(wrong.context, wrong.peer); wrong.setPeer('00:00:00:00:00:00');
  wrong.connections[0].cb(undefined, 46); assert.deepEqual(wrong.writes, []); assert.deepEqual(wrong.closedClients, [46]);
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.connections[0].cb(undefined, 47);
  s.Service.stop('user stop'); s.callbacks[0](Uint8Array.from(Buffer.from(responses[0])).buffer);
  assert.deepEqual(s.writes, [commands[0]]);
});
test('stage timeout closes socket and late response cannot advance', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.connections[0].cb(undefined, 48);
  s.setTime(13000); s.callbacks[0](Uint8Array.from(Buffer.from(responses[0])).buffer);
  assert.deepEqual(s.closedClients, [48]); assert.deepEqual(s.writes, [commands[0]]);
});
test('HSP and HF starts are mutually exclusive; listener mode has no writes', () => {
  const s = sandbox(); s.Service.start(s.context, s.peer); s.Service.startHf(s.context, s.peer);
  assert.equal(s.listeners.length, 1); assert.equal(s.connections.length, 0); assert.deepEqual(s.writes, []);
  s.Service.stop('user stop'); s.listeners[0].cb(undefined, 49); assert.deepEqual(s.closedServers, [49]);
});
test('failed close remains visible and retryable instead of claiming released resources', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.connections[0].cb(undefined, 50);
  s.setCloseFailure(true); s.Service.stop('user stop');
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.state, 'cleanup-error'); assert.equal(report.active, true);
  assert.equal(report.clientSocket, 50); s.setCloseFailure(false); s.Service.stop('retry');
  report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.cleanupSucceeded, true); assert.equal(report.active, false);
});
test('HF listener publishes PhoneBridge 111e then reuses exactly the four-stage exchange', () => {
  const s = sandbox(); s.Service.startHfListener(s.context, s.peer);
  assert.equal(s.listeners.length, 1); assert.equal(s.connections.length, 0);
  assert.equal(s.listeners[0].name, 'PhoneBridge HF diagnostic');
  assert.equal(s.listeners[0].options.uuid, '0000111e-0000-1000-8000-00805f9b34fb');
  assert.equal(s.listeners[0].options.secure, true); assert.deepEqual(s.writes, []);
  s.listeners[0].cb(undefined, 60); assert.equal(s.accepts[0].server, 60);
  s.accepts[0].cb(undefined, 61);
  for (const response of responses) { s.callbacks[0](Uint8Array.from(Buffer.from(response)).buffer); }
  assert.deepEqual(s.writes, commands);
  const report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.mode, 'hf-slc-listener'); assert.equal(report.slcControlComplete, true);
  assert.equal(report.audioVerified, false); assert.equal(report.pendingConnect, false);
  assert.equal(report.expectedProfileDescriptor.includes('1101'), true);
  s.Service.stop('test stop'); assert.deepEqual(s.closedClients, [61]); assert.deepEqual(s.closedServers, [60]);
});
test('HF listener rejects another peer before starting the protocol', () => {
  const s = sandbox(); s.Service.startHfListener(s.context, s.peer);
  s.listeners[0].cb(undefined, 62); s.setPeer('00:00:00:00:00:00'); s.accepts[0].cb(undefined, 63);
  assert.deepEqual(s.closedClients, [63]); assert.deepEqual(s.writes, []); assert.equal(s.callbacks.length, 0);
  s.Service.stop('test stop'); assert.deepEqual(s.closedServers, [62]);
});
test('HF listener late accept and late listen callbacks close sockets without AT traffic', () => {
  const s = sandbox(); s.Service.startHfListener(s.context, s.peer);
  s.listeners[0].cb(undefined, 64); s.Service.stop('user stop'); s.accepts[0].cb(undefined, 65);
  assert.deepEqual(s.closedClients, [65]); assert.deepEqual(s.closedServers, [64]); assert.deepEqual(s.writes, []);
  const t = sandbox(); t.Service.startHfListener(t.context, t.peer); t.setTime(181000);
  t.listeners[0].cb(undefined, 66); assert.deepEqual(t.closedServers, [66]);
  assert.equal(t.accepts.length, 0); assert.deepEqual(t.writes, []);
});
test('HF listener stage timeout closes both socket IDs and server-close failure is retryable', () => {
  const s = sandbox(); s.Service.startHfListener(s.context, s.peer);
  s.listeners[0].cb(undefined, 67); s.accepts[0].cb(undefined, 68);
  s.setServerCloseFailure(true); s.setTime(13000);
  s.callbacks[0](Uint8Array.from(Buffer.from(responses[0])).buffer);
  assert.deepEqual(s.writes, [commands[0]]); assert.deepEqual(s.closedClients, [68]);
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.state, 'cleanup-error'); assert.equal(report.serverSocket, 67);
  s.setServerCloseFailure(false); s.Service.stop('retry');
  report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.deepEqual(s.closedServers, [67]); assert.equal(report.cleanupSucceeded, true);
});
test('all four modes are mutually exclusive', () => {
  const starts = ['start', 'startHf', 'startHfListener', 'startHfGatedListener'];
  for (const first of starts) {
    const s = sandbox(); s.Service[first](s.context, s.peer);
    for (const next of starts) { s.Service[next](s.context, s.peer); }
    assert.equal(s.listeners.length + s.connections.length, 1); s.Service.stop('test stop');
  }
});
test('20-second app timeout keeps pending native callback explicit and blocks another experiment', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer);
  const timer = [...s.timers.values()].find(value => value.at === 21000);
  s.setTime(21000); timer.cb();
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.active, false); assert.equal(report.pendingConnect, true);
  assert.equal(report.nativeConnectStatus.includes('native cancellation unconfirmed'), true);
  s.Service.startHfListener(s.context, s.peer); assert.equal(s.listeners.length, 0);
  s.connections[0].cb(undefined, 69); assert.deepEqual(s.closedClients, [69]); assert.deepEqual(s.writes, []);
  report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.pendingConnect, false); assert.equal(report.nativeConnectStatus, 'callback-returned');
  s.Service.startHfListener(s.context, s.peer); assert.equal(s.listeners.length, 1);
});
test('failed cleanup of late native connect is retained for manual retry', () => {
  const s = sandbox(); s.Service.startHf(s.context, s.peer); s.Service.stop('user stop');
  s.setCloseFailure(true); s.connections[0].cb(undefined, 70);
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.pendingConnect, false); assert.equal(report.state, 'cleanup-error');
  assert.equal(report.clientSocket, 70); assert.deepEqual(s.writes, []);
  s.setCloseFailure(false); s.Service.stop('retry');
  report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.cleanupSucceeded, true); assert.deepEqual(s.closedClients, [70]);
});
test('failed cleanup of late listener or accept callbacks retains IDs for retry', () => {
  const s = sandbox(); s.Service.startHfListener(s.context, s.peer); s.Service.stop('user stop');
  s.setServerCloseFailure(true); s.listeners[0].cb(undefined, 71);
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.state, 'cleanup-error'); assert.deepEqual(report.unclosedServerSockets, [71]);
  s.setServerCloseFailure(false); s.Service.stop('retry'); assert.deepEqual(s.closedServers, [71]);
  const t = sandbox(); t.Service.startHfListener(t.context, t.peer); t.listeners[0].cb(undefined, 72);
  t.Service.stop('user stop'); t.setCloseFailure(true); t.accepts[0].cb(undefined, 73);
  report = JSON.parse(t.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.state, 'cleanup-error'); assert.deepEqual(report.unclosedClientSockets, [73]);
  t.setCloseFailure(false); t.Service.stop('retry'); assert.deepEqual(t.closedClients, [73]);
  assert.deepEqual(t.writes, []);
});
test('gated HF listener sends zero AT before manual start and then only the fixed exchange', () => {
  const s = sandbox(); let ready = false;
  s.Service.observe((summary, active, exchangeReady) => { ready = exchangeReady; });
  s.Service.startHfGatedListener(s.context, s.peer); assert.equal(ready, false);
  assert.equal(s.listeners[0].options.uuid, '0000111e-0000-1000-8000-00805f9b34fb');
  s.listeners[0].cb(undefined, 80); s.accepts[0].cb(undefined, 81);
  assert.equal(ready, true); assert.equal(s.Service.canStartHfExchange(), true);
  s.callbacks[0](Uint8Array.from(Buffer.from(responses.join('') + 'O')).buffer);
  assert.deepEqual(s.writes, []);
  let report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.state, 'hf-awaiting-handshake'); assert.equal(report.mode, 'hf-slc-listener-gated');
  assert.equal(report.transmittedBytes, 0); assert.equal(report.slcControlComplete, false);
  assert.equal(s.Service.startHfExchange(), true); assert.equal(ready, false);
  assert.equal(s.Service.startHfExchange(), false); assert.equal(s.callbacks.length, 1);
  s.callbacks[0](Uint8Array.from(Buffer.from('K\r\n')).buffer);
  for (const response of responses) { s.callbacks[0](Uint8Array.from(Buffer.from(response)).buffer); }
  assert.deepEqual(s.writes, commands);
  report = JSON.parse(s.Service.dump().slice('PhoneBridgeHsp: '.length));
  assert.equal(report.slcControlComplete, true); assert.equal(report.audioVerified, false);
  s.Service.stop('test stop'); assert.deepEqual(s.closedClients, [81]); assert.deepEqual(s.closedServers, [80]);
});
test('manual HF exchange is rejected before accept, in other modes, and after stop', () => {
  const s = sandbox(); assert.equal(s.Service.startHfExchange(), false);
  s.Service.startHfGatedListener(s.context, s.peer); assert.equal(s.Service.startHfExchange(), false);
  s.listeners[0].cb(undefined, 82); s.accepts[0].cb(undefined, 83);
  s.Service.stop('user stop'); assert.equal(s.Service.startHfExchange(), false);
  s.callbacks[0](Uint8Array.from(Buffer.from(responses[0])).buffer); assert.deepEqual(s.writes, []);
  const t = sandbox(); t.Service.startHfListener(t.context, t.peer);
  t.listeners[0].cb(undefined, 84); t.accepts[0].cb(undefined, 85);
  assert.equal(t.Service.startHfExchange(), false); assert.deepEqual(t.writes, [commands[0]]);
});
test('gated listener refuses wrong peer and closes late accept after stop without sending', () => {
  const s = sandbox(); s.Service.startHfGatedListener(s.context, s.peer); s.listeners[0].cb(undefined, 86);
  s.setPeer('00:00:00:00:00:00'); s.accepts[0].cb(undefined, 87);
  assert.equal(s.Service.startHfExchange(), false); assert.deepEqual(s.closedClients, [87]); assert.deepEqual(s.writes, []);
  const t = sandbox(); t.Service.startHfGatedListener(t.context, t.peer); t.listeners[0].cb(undefined, 88);
  t.Service.stop('user stop'); t.accepts[0].cb(undefined, 89);
  assert.equal(t.Service.startHfExchange(), false); assert.deepEqual(t.closedClients, [89]); assert.deepEqual(t.writes, []);
});
test('manual HF start cannot extend the 180-second deadline', () => {
  const s = sandbox(); s.Service.startHfGatedListener(s.context, s.peer);
  s.listeners[0].cb(undefined, 90); s.accepts[0].cb(undefined, 91);
  s.setTime(181000); assert.equal(s.Service.canStartHfExchange(), false);
  assert.equal(s.Service.startHfExchange(), false); assert.deepEqual(s.writes, []);
  assert.deepEqual(s.closedClients, [91]); assert.deepEqual(s.closedServers, [90]);
});
test('manual HF exchange retains the 12-second stage timeout after a delayed start', () => {
  const s = sandbox(); s.Service.startHfGatedListener(s.context, s.peer);
  s.listeners[0].cb(undefined, 92); s.accepts[0].cb(undefined, 93);
  s.setTime(61000); assert.equal(s.Service.startHfExchange(), true); assert.deepEqual(s.writes, [commands[0]]);
  s.setTime(73000); s.callbacks[0](Uint8Array.from(Buffer.from(responses[0])).buffer);
  assert.deepEqual(s.writes, [commands[0]]); assert.deepEqual(s.closedClients, [93]);
  assert.deepEqual(s.closedServers, [92]); assert.equal(s.Service.startHfExchange(), false);
});
console.log(`PASS ${passed} offline checks; no device, Bluetooth, audio, or phone API was executed.`);
