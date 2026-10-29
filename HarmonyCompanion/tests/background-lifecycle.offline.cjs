// Execute production lifecycle code with fake OS APIs. No device or Bluetooth access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
function deferred() { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b});return {promise,resolve,reject}; }
function fixture() {
 const starts=[],stops=[],agents=[],timers=new Map();let timerID=0; let startGate,agentGate,stopFailure=false;
 const exports={};
 const src=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/services/BluetoothBackground.ets'),'utf8');
 vm.runInNewContext(ts.transpileModule(src,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,{exports,setTimeout:(cb,ms)=>{const id=++timerID;timers.set(id,{cb,ms});return id},clearTimeout:id=>timers.delete(id),require:n=>{
  if(n==='@kit.AbilityKit')return {wantAgent:{OperationType:{START_ABILITY:1},WantAgentFlags:{UPDATE_PRESENT_FLAG:1},getWantAgent:async info=>{agents.push(info);return agentGate ? await agentGate.promise : {};}}};
  if(n==='@kit.BackgroundTasksKit')return {backgroundTaskManager:{startBackgroundRunning:async (...v)=>{starts.push(v);if(startGate)await startGate.promise;},stopBackgroundRunning:async (...v)=>{stops.push(v);if(stopFailure)throw {code:9800004};}}};
  throw Error(n);
 }});
 return {B:exports.BluetoothBackground,starts,stops,agents,timers,context:{},blockStart:()=>startGate=deferred(),blockAgent:()=>agentGate=deferred(),failStop:v=>stopFailure=v};
}
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve()};
(async()=>{
 let checks=0;
 async function test(name,fn){await fn();checks++;console.log('PASS '+name)}
 await test('no background work at construction',async()=>{const f=fixture();assert.equal(f.B.isActive(),false);assert.equal(f.starts.length,0)});
 await test('connected bridge starts only Bluetooth mode and releases on stop',async()=>{const f=fixture();assert.equal(await f.B.start(f.context),true);assert.equal(f.starts.length,1);assert.deepEqual([...f.starts[0][1]],['bluetoothInteraction']);assert.equal(f.agents[0].wants[0].bundleName,'cn.andy.phonebridge.companion');assert.equal(f.B.isActive(),true);f.B.stop();await flush();assert.equal(f.stops.length,1);assert.equal(f.B.isActive(),false)});
 await test('duplicate start is idempotent',async()=>{const f=fixture();await f.B.start(f.context);await f.B.start(f.context);assert.equal(f.starts.length,1)});
 await test('stop before WantAgent return prevents native start',async()=>{const f=fixture();const g=f.blockAgent();const p=f.B.start(f.context);f.B.stop();g.resolve({});assert.equal(await p,false);assert.equal(f.starts.length,0)});
 await test('late native start after Stop is released rather than resurrected',async()=>{const f=fixture();const g=f.blockStart();const p=f.B.start(f.context);await flush();f.B.stop();g.resolve();assert.equal(await p,false);await flush();assert.equal(f.stops.length,1);assert.equal(f.B.isActive(),false)});
 await test('concurrent start cannot allocate a second task',async()=>{const f=fixture();const g=f.blockStart();const p=f.B.start(f.context);assert.equal(await f.B.start(f.context),false);g.resolve();assert.equal(await p,true);assert.equal(f.starts.length,1)});
 await test('failed native start does not pretend to be running',async()=>{const f=fixture();const g=f.blockStart();const p=f.B.start(f.context);await flush();g.reject({code:9800006});assert.equal(await p,false);assert.equal(f.B.isActive(),false);assert.match(f.B.error,/9800006/)});
 await test('failed stop preserves ownership for explicit retry',async()=>{const f=fixture();await f.B.start(f.context);f.failStop(true);f.B.stop();await flush();assert.match(f.B.error,/background-stop/);assert.equal(f.B.isActive(),false);assert.equal(await f.B.start(f.context),false);f.failStop(false);f.B.stop();await flush();assert.equal(f.stops.length,2);assert.equal(f.B.isActive(),false)});
 await test('reconnect grace never starts a task when no connection acquired it',async()=>{const f=fixture();f.B.retainForReconnect();assert.equal(f.starts.length,0);assert.equal(f.timers.size,0)});
 await test('acquired background task survives a bounded reconnect gap',async()=>{const f=fixture();await f.B.start(f.context);f.B.retainForReconnect();assert.equal(f.stops.length,0);assert.equal(f.B.isActive(),true);assert.equal([...f.timers.values()][0].ms,45000);const [id,timer]=[...f.timers][0];f.timers.delete(id);timer.cb();await flush();assert.equal(f.B.isActive(),false);assert.equal(f.stops.length,1)});
 await test('verified reconnect cancels old expiry without allocating another task',async()=>{const f=fixture();await f.B.start(f.context);f.B.retainForReconnect();await f.B.start(f.context);assert.equal(f.timers.size,0);assert.equal(f.starts.length,1);assert.equal(f.stops.length,0)});
 await test('explicit stop cancels grace immediately',async()=>{const f=fixture();await f.B.start(f.context);f.B.retainForReconnect();f.B.stop();await flush();assert.equal(f.timers.size,0);assert.equal(f.B.isActive(),false)});
 console.log(`PASS ${checks} background lifecycle checks; no device calls`);
})().catch(e=>{console.error(e);process.exitCode=1});
