const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const ts=require('/Applications/DevEco-Studio.app/Contents/tools/ohpm/node_modules/typescript');
const flush=async()=>{for(let i=0;i<15;i++)await Promise.resolve()};
function fixture(){
 const calls=[],timers=new Map(),exports={};let active=false,id=0,gate,loadCount=0;
 const window={setWindowKeepScreenOn:async v=>{calls.push(v);if(v&&gate)await gate}};
 const source=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/entryability/EntryAbility.ets'),'utf8');
 vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,{
  exports,console,setInterval:f=>{timers.set(++id,f);return id},clearInterval:i=>timers.delete(i),require:n=>{
   if(n==='@kit.AbilityKit')return {UIAbility:class{}};
   if(n.includes('ProbeState'))return {ProbeState:{report:'test'}};
   if(n.includes('HspAssistService'))return {HspAssistService:{checkDeadline(){},stop(){},dump(){return 'test'}}};
   if(n.includes('WirelessControlService'))return {WirelessControlService:{isActive:()=>active,setForeground(){},checkDeadline(){},stop(){active=false},dump(){return 'test'}}};
   if(n==='@kit.ArkUI'||n==='@kit.BasicServicesKit')return {};
   throw Error(n);
  }});
 const ability=new exports.default();
 return {ability,calls,timers,active:v=>active=v,blockEnable:()=>{let release;gate=new Promise(r=>release=r);return release},
  attach:()=>ability.onWindowStageCreate({getMainWindowSync:()=>window,loadContent:(_,cb)=>{loadCount++;cb({code:0})}}),
  badAttach:()=>ability.onWindowStageCreate({getMainWindowSync:()=>{throw {code:1300002}},loadContent:(_,cb)=>{loadCount++;cb({code:0})}}),
  tick:()=>{for(const f of timers.values())f()},loads:()=>loadCount};
}
(async()=>{
 let f=fixture();f.attach();f.ability.onForeground();await flush();assert.deepEqual(f.calls,[false]);
 f.active(true);f.tick();await flush();assert.deepEqual(f.calls,[false,true]);f.ability.onBackground();await flush();
 assert.deepEqual(f.calls,[false,true,false]);assert.equal(f.timers.size,0);
 console.log('PASS active foreground only; background releases screen');
 f=fixture();f.attach();f.ability.onForeground();await flush();const release=f.blockEnable();f.active(true);f.tick();await flush();
 f.active(false);f.tick();release();await flush();assert.deepEqual(f.calls,[false,true,false]);
 assert.match(f.ability.onDump([]).at(-1),/requested=false; applied=false/);
 console.log('PASS late enable cannot override Stop');
 f=fixture();f.badAttach();await flush();assert.equal(f.loads(),1);assert.match(f.ability.onDump([]).at(-1),/error=1300002/);
 console.log('PASS screen API failure does not prevent app UI loading');
 console.log('PASS 3 session-screen lifecycle checks; fake window only');
})().catch(e=>{console.error(e);process.exitCode=1});
