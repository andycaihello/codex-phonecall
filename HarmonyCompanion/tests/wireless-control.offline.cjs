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
  let dialerMode = "resolve";
  let dialerResolution;
  let callState = 0;
  const timers = new Map();
  const writes = [], closedClients = [], closedServers = [], connections = [], listeners = [], dialers = [];
  const callbacks = [], accepts = [];
  const backgroundStarts = [];
  const peer = '01:23:45:67:89:AB';
  let actualPeer = peer;
  const socket = {
    SppType: { SPP_RFCOMM: 0 },
    sppConnect: (id, options, cb) => connections.push({ id, options, cb }),
    sppListen: (name, options, cb) => listeners.push({ name, options, cb }),
    sppAccept: (server, cb) => accepts.push({ server, cb }),
    getDeviceId: () => actualPeer,
    on: (event, id, cb) => callbacks.push({id, cb}),
    off: () => {},
    sppWrite: (id, buffer) => writes.push({id, text:Buffer.from(buffer).toString('ascii')}),
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
        if (specifier === '@kit.AudioKit') { return { audio: { ActiveDeviceType: { BLUETOOTH_SCO: 1 }, getAudioManager: () => ({ setDeviceActive: async () => {}, isDeviceActive: async () => true }) } }; }
        if (specifier === '@kit.TelephonyKit') { return { call: { CallState: { CALL_STATE_IDLE: 0 }, getCallStateSync: () => callState, makeCall: async (context, number) => { dialers.push({ context, number }); if (dialerMode === 'reject') { throw {code:8300002}; } if (dialerMode === 'pending') { await new Promise(resolve => {dialerResolution=resolve}); } } } }; }
        if (specifier === './BluetoothBackground') { return { BluetoothBackground: { start: context => {
          backgroundStarts.push(context);
          return { then: cb => { cb(true); return { catch: () => {} }; } };
        }, stop: () => {}, retainForReconnect: () => {}, isActive: () => true, dump: () => 'background=true' } }; }
        if (specifier === './HfSlcMachine') { return load('HfSlcMachine'); }
        if (specifier === './HspAssistService') { return load('HspAssistService'); }
        throw Error('Unexpected runtime dependency: ' + specifier);
      }
    }, { filename: name + '.js' });
    cache[name] = exports;
    return exports;
  }
  return {
    Control: load('WirelessControlService').WirelessControlService,
    Machine: load('HfSlcMachine').HfSlcMachine,
    Service: load('HspAssistService').HspAssistService,
    context: { filesDir: '/mock-private' }, peer, writes, closedClients, closedServers,
    connections, listeners, callbacks, accepts, timers, dialers, backgroundStarts,
    setDialerMode: value => { dialerMode = value; }, resolveDialer: () => dialerResolution?.(),
    setCallState: value => { callState = value; },
    setTime: value => { now = value; }, setPeer: value => { actualPeer = value; },
    runTimersThrough: value => {
      now = value;
      for (const [id, timer] of [...timers.entries()].sort((a,b)=>a[1].at-b[1].at)) {
        if (timer.at <= now) { timers.delete(id); timer.cb(); }
      }
    },
    setCloseFailure: value => { closeFailure = value; },
    setServerCloseFailure: value => { serverCloseFailure = value; }
  };
}


let passed=0;
function test(name,fn){fn();passed++;console.log('PASS '+name)}
function ready(){const s=sandbox();s.Control.setForeground(true);s.Control.start(s.context,s.peer);s.listeners[0].cb(null,10);s.listeners[1].cb(null,20);s.accepts.find(x=>x.server===10).cb(null,11);s.accepts.find(x=>x.server===20).cb(null,21);return s;}
function send(s,text){s.callbacks.find(x=>x.id===21).cb(new Uint8Array(Buffer.from(text,'ascii')).buffer)}
function report(s){return JSON.parse(s.writes.filter(x=>x.id===21).at(-1).text)}
test('phone acquires background task and publishes HF before paired-only control',()=>{const s=sandbox();s.Control.start(s.context,s.peer);assert.equal(s.backgroundStarts.length,1);assert.equal(s.listeners.length,2);assert.match(s.listeners[0].options.uuid,/111e/);assert.equal(s.listeners[1].options.uuid,s.Control.uuid);assert.ok(s.listeners.every(x=>x.options.secure));assert.equal(s.connections.length,0);assert.equal(s.writes.length,0)});
test('stopped session retains paired-only wake and gated HF service',()=>{const s=sandbox();s.Control.start(s.context,s.peer,false);assert.equal(s.backgroundStarts.length,1);assert.equal(s.listeners.length,2);assert.match(s.listeners[0].options.uuid,/111e/);assert.equal(s.listeners[1].options.uuid,s.Control.uuid);s.listeners[0].cb(null,10);s.listeners[1].cb(null,20);s.accepts.find(x=>x.server===20).cb(null,21);send(s,'{"id":"a","op":"status"}\n');assert.equal(report(s).standby,true);assert.equal(report(s).backgroundActive,true);assert.equal(report(s).active,true);send(s,'{"id":"b","op":"start_session"}\n');assert.equal(report(s).ok,true);assert.equal(report(s).standby,false);assert.equal(s.listeners.length,2)});
test('wrong paired peer cannot wake a stopped session',()=>{const s=sandbox();s.Control.start(s.context,s.peer,false);s.listeners[0].cb(null,10);s.listeners[1].cb(null,20);s.setPeer('AA:AA:AA:AA:AA:AA');s.accepts.find(x=>x.server===20).cb(null,21);assert.ok(s.closedClients.includes(21));assert.equal(s.callbacks.length,0);assert.equal(s.listeners.length,2)});
test('all JSON split boundaries preserve exact status request',()=>{const req='{"id":"check_1","op":"status"}\n';for(let i=0;i<=req.length;i++){const s=ready();send(s,req.slice(0,i));send(s,req.slice(i));const r=report(s);assert.equal(r.id,'check_1');assert.equal(r.ok,true);assert.equal(r.peerVerified,true);assert.equal(r.slcControlComplete,false);assert.equal(s.writes.filter(x=>x.id===11).length,0)}});
test('coalesced messages retain independent IDs',()=>{const s=ready();send(s,'{"id":"a","op":"status"}\n{"id":"b","op":"status"}\n');assert.deepEqual(s.writes.filter(x=>x.id===21).map(x=>JSON.parse(x.text).id),['a','b'])});
test('wrong paired peer is rejected without subscription or commands',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.listeners[0].cb(null,10);s.listeners[1].cb(null,20);s.setPeer('AA:AA:AA:AA:AA:AA');s.accepts.find(x=>x.server===20).cb(null,31);assert.ok(s.closedClients.includes(31));assert.equal(s.callbacks.length,0);assert.equal(s.writes.length,0)});
test('exchange starts only gated peer handshake and cannot start twice',()=>{const s=ready();send(s,'{"id":"a","op":"exchange"}\n');assert.equal(report(s).ok,true);assert.equal(s.writes.filter(x=>x.id===11)[0].text,'AT+BRSF=0\r');send(s,'{"id":"b","op":"exchange"}\n');assert.equal(report(s).ok,false);assert.equal(s.writes.filter(x=>x.id===11).length,1)});
test('system dialer accepts only a bounded number',()=>{const s=ready();send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');assert.equal(s.dialers.length,0);assert.equal(report(s).dialerStage,'requested');s.runTimersThrough(1000);assert.equal(s.dialers.length,1);assert.equal(s.dialers[0].number,'13800000000')});
test('telephone and arbitrary command names have no effect',()=>{const s=ready();for(const op of ['dial','hangup','ATD13800000000;','start']){send(s,JSON.stringify({id:'a',op})+'\n');assert.equal(report(s).ok,false)}assert.equal(s.writes.filter(x=>x.id===11).length,0)});
test('extra fields and malformed identifiers end owned session',()=>{for(const req of [{id:'a',op:'status',number:'13800000000'},{id:'a',op:'dial_ui',number:'1892;ATD'},{id:'../a',op:'status'},{id:'a\rATD',op:'status'},{id:1,op:'status'},null]){const s=ready();send(s,JSON.stringify(req)+'\n');assert.match(s.Control.dump(),/active=false/);assert.equal(s.writes.length,0)}});
test('nonASCII CR and overlong input are rejected',()=>{for(const raw of ['\r','\x01','x'.repeat(513)]){const s=ready();send(s,raw);assert.match(s.Control.dump(),/active=false/);assert.equal(s.writes.length,0)}});
test('remote stop acknowledges then recycles per-call channels while retaining the session listener',()=>{const s=ready();send(s,'{"id":"a","op":"stop"}\n');assert.equal(report(s).ok,true);assert.equal(report(s).active,true);assert.ok(!s.closedClients.includes(11));assert.ok(!s.closedClients.includes(21));s.runTimersThrough(1120);assert.ok(s.closedClients.includes(11));assert.ok(s.closedServers.includes(10));assert.ok(s.closedClients.includes(21));assert.ok(!s.closedServers.includes(20));assert.match(s.Control.dump(),/active=true/);assert.equal(s.listeners.length,3);assert.match(s.listeners[2].options.uuid,/111e/);assert.equal(s.accepts.filter(x=>x.server===20).length,2);assert.match(s.Control.dump(),/accepting=true/)});
test('verified Mac heartbeat renews the eight-hour standby lease',()=>{const s=ready();s.setTime(600001);send(s,'{"id":"a","op":"status"}\n');assert.equal(report(s).ok,true);assert.equal(report(s).remainingSeconds,28800);s.setTime(1200001);send(s,'{"id":"b","op":"status"}\n');assert.equal(report(s).ok,true);assert.equal(report(s).remainingSeconds,28800);assert.match(s.Control.dump(),/active=true/)});
test('expired call-readiness lease parks but retains wake listener',()=>{const s=ready();s.setTime(28801001);send(s,'{"id":"a","op":"status"}\n');assert.match(s.Control.dump(),/active=true; sessionEnabled=false/);assert.ok(s.closedClients.includes(21));assert.ok(!s.closedServers.includes(20));assert.equal(s.writes.length,0)});
test('manual park closes current call helper but keeps the selected Mac wake entry',()=>{const s=ready();s.Control.park('manual');assert.match(s.Control.dump(),/active=true; sessionEnabled=false/);assert.ok(s.closedClients.includes(21));assert.ok(!s.closedServers.includes(20));assert.equal(s.listeners.length,3)});
test('silent stale Mac client is reclaimed without losing the published listener',()=>{const s=ready();s.runTimersThrough(7000);assert.ok(s.closedClients.includes(21));assert.ok(!s.closedServers.includes(20));assert.match(s.Control.dump(),/client=-1/)});
test('fresh control data renews the client silence watchdog',()=>{const s=ready();s.runTimersThrough(4000);send(s,'{"id":"beat","op":"status"}\n');s.runTimersThrough(8000);assert.ok(!s.closedClients.includes(21));s.runTimersThrough(11000);assert.ok(s.closedClients.includes(21))});
test('client silence cannot retire a live telephone call',()=>{const s=ready();s.setCallState(2);s.runTimersThrough(7000);assert.ok(!s.closedClients.includes(21));s.setCallState(0);s.runTimersThrough(14000);assert.ok(s.closedClients.includes(21))});
test('late listen callback after stop closes server and cannot restart',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.Control.stop('stop');s.listeners[1].cb(null,22);assert.ok(s.closedServers.includes(22));assert.equal(s.accepts.length,0)});
test('late accept after stop closes returned socket without reads',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.listeners[1].cb(null,20);s.Control.stop('stop');s.accepts.find(x=>x.server===20).cb(null,21);assert.ok(s.closedClients.includes(21));assert.equal(s.callbacks.length,0)});
test('transient accept failure retries the same listener without another phone tap',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.listeners[1].cb(null,20);s.accepts.find(x=>x.server===20).cb({code:2901054},-1);assert.match(s.Control.dump(),/active=true/);assert.equal(s.closedServers.length,0);s.runTimersThrough(1300);assert.equal(s.accepts.filter(x=>x.server===20).length,2);s.accepts.filter(x=>x.server===20)[1].cb(null,21);assert.equal(s.callbacks.length,1)});
test('stopping before an accept retry prevents a new listener attempt',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.listeners[1].cb(null,20);s.accepts.find(x=>x.server===20).cb({code:2901054},-1);s.Control.stop('stop');s.runTimersThrough(1300);assert.equal(s.accepts.filter(x=>x.server===20).length,1)});
test('repeated accept failures stop after a bounded retry budget',()=>{const s=sandbox();s.Control.start(s.context,s.peer);s.listeners[1].cb(null,20);for(let attempt=0;attempt<4;attempt++){s.accepts.filter(x=>x.server===20).at(-1).cb({code:2901054},-1);s.runTimersThrough(1000+(attempt+1)*1000)}assert.match(s.Control.dump(),/active=false/);assert.equal(s.accepts.filter(x=>x.server===20).length,4);assert.ok(s.closedServers.includes(20))});
test('failed socket close stays active and can be retried',()=>{const s=ready();s.setCloseFailure(true);s.Control.stop('stop');assert.match(s.Control.dump(),/active=true/);s.setCloseFailure(false);s.Control.stop('retry');assert.match(s.Control.dump(),/active=false/)});
test('dial request is acknowledged before execution and stop cancels queued UI',()=>{const s=ready();send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');assert.equal(report(s).ok,true);s.Control.stop('cancel');s.runTimersThrough(1001);assert.equal(s.dialers.length,0)});
test('background UI launch is refused without invoking telephone API',()=>{const s=ready();s.Control.setForeground(false);send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');assert.equal(report(s).ok,false);assert.equal(report(s).error,'dialer-requires-foreground');assert.equal(s.dialers.length,0)});
test('repeated dial request cannot submit another UI operation',()=>{const s=ready();send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');send(s,'{"id":"b","op":"dial_ui","number":"13800000000"}\n');assert.equal(report(s).ok,false);s.runTimersThrough(1000);assert.equal(s.dialers.length,1)});
test('hung system API times out while status messages still respond',()=>{const s=ready();s.setDialerMode('pending');send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');s.runTimersThrough(1000);send(s,'{"id":"b","op":"status"}\n');assert.equal(report(s).ok,true);s.runTimersThrough(8000);send(s,'{"id":"c","op":"status"}\n');assert.equal(report(s).dialerStage,'failed');assert.equal(report(s).dialerError,'dialer-api-timeout')});
console.log(`PASS ${passed} wireless control checks; no real device calls`);

(async () => {
 const flush = async () => { for(let i=0;i<10;i++) await Promise.resolve(); };
 let count=0;
 async function asyncTest(name,fn){await fn();count++;console.log('PASS '+name)}
 await asyncTest('system API resolution reports submission, never visible UI',async()=>{
  const s=ready();send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');
  assert.equal(report(s).dialerStage,'requested');s.runTimersThrough(1000);await flush();
  send(s,'{"id":"b","op":"status"}\n');assert.equal(report(s).dialerStage,'submitted');
  assert.equal(report(s).dialerRequestId,'a');assert.equal(report(s).dialerVisible,undefined);
 });
 await asyncTest('system API rejection is visible through the next heartbeat',async()=>{
  const s=ready();s.setDialerMode('reject');send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');
  s.runTimersThrough(1000);await flush();send(s,'{"id":"b","op":"status"}\n');
  assert.equal(report(s).dialerStage,'failed');assert.match(report(s).dialerError,/8300002/);
 });
 await asyncTest('late Promise resolution cannot undo timeout or launch again',async()=>{
  const s=ready();s.setDialerMode('pending');send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');
  s.runTimersThrough(1000);s.runTimersThrough(8000);s.resolveDialer();await flush();
  send(s,'{"id":"b","op":"status"}\n');assert.equal(report(s).dialerStage,'failed');assert.equal(s.dialers.length,1);
 });
 await asyncTest('foreground loss before scheduled submission fails without opening UI',async()=>{
  const s=ready();send(s,'{"id":"a","op":"dial_ui","number":"13800000000"}\n');s.Control.setForeground(false);
  s.runTimersThrough(1000);send(s,'{"id":"b","op":"status"}\n');assert.equal(report(s).dialerStage,'failed');assert.equal(s.dialers.length,0);
 });
 console.log(`PASS ${count} asynchronous dialer checks; no device calls`);
})().catch(e=>{console.error(e);process.exitCode=1});
