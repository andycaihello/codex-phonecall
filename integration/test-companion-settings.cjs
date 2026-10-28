'use strict';
// Execute only the actual Preferences adapter with a fully in-memory SDK fake.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const root = path.resolve(__dirname, '..');
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js');
const source = fs.readFileSync(path.join(root, 'HarmonyCompanion/entry/src/main/ets/services/CompanionSettings.ets'), 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const state = new Map();
const calls = [];
let failFlush = false;
const store = {
  getSync(key, fallback) { calls.push(['get', key]); return state.has(key) ? state.get(key) : fallback; },
  putSync(key, value) { calls.push(['put', key]); state.set(key, value); },
  async flush() { calls.push(['flush']); if (failFlush) throw new Error('synthetic-secret'); }
};
const exportsObject = {};
vm.runInNewContext(output, { exports: exportsObject, require: name => {
  assert.strictEqual(name, '@kit.ArkData');
  return { preferences: { getPreferencesSync(context, options) {
    assert.strictEqual(options.name, 'phonebridge_user'); return store;
  } } };
}}, { filename: 'CompanionSettings.offline.js' });
const Settings = exportsObject.CompanionSettings;
const checks = [];
function check(name, operation) { operation(); checks.push(name); }
(async () => {
  check('fresh install does not select a peer', () => assert.strictEqual(Settings.selectedPeer({}), ''));
  await Settings.selectPeer({}, 'aa:bb:cc:dd:ee:ff');
  check('explicit peer selection persists normalized address', () => assert.strictEqual(Settings.selectedPeer({}), 'AA:BB:CC:DD:EE:FF'));
  check('only selectedPeer key is ever persisted', () => assert.deepStrictEqual([...state.keys()], ['selectedPeer']));
  state.set('selectedPeer', 'not-a-device');
  check('corrupt saved peer is not restored', () => assert.strictEqual(Settings.selectedPeer({}), ''));
  const before = calls.length;
  await assert.rejects(Settings.selectPeer({}, '10010'));
  check('invalid selection fails before Preferences access', () => assert.strictEqual(calls.length, before));
  failFlush = true;
  await assert.rejects(Settings.selectPeer({}, 'aa:bb:cc:dd:ee:ff'), error => !error.message.includes('synthetic-secret') && error.message.includes('无法保存'));
  checks.push('persistence failure returns only a bounded product error');
  const report = { passed: true, count: checks.length, checks, permissionRequests: 0, deviceOperations: 0, actualPreferencesWrites: 0 };
  fs.writeFileSync(path.join(root, 'integration/companion-settings-offline-validation-20260909.json'), JSON.stringify(report, null, 2) + '\n');
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
})().catch(error => { process.stderr.write(String(error) + '\n'); process.exitCode = 1; });
