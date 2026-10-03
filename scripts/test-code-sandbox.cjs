// Tool/adaptor contract tests. The real engine tests live in cpp/tests/sandbox_test.cpp.
// Run: node scripts/test-code-sandbox.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets/services');
const cache = new Map();
let active; let cancels = []; let submissions = 0;
const native = {
  execute(id) {
    if (active) throw Error('busy');
    submissions++;
    return new Promise(resolve => { active = { id, resolve }; });
  },
  cancel(id) { cancels.push(id); },
};
function finish(output = '{"status":"ok","result":42}') { const job = active; active = undefined; job.resolve(output); }
function load(name) {
  const file = path.resolve(root, name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 },
  }).outputText;
  vm.runInNewContext(compiled, { exports, require: id => {
    if (id === 'libtinybot_sandbox.so') return { default: native };
    if (id === '@kit.ArkTS') return { util: { generateRandomUUID: crypto.randomUUID } };
    if (id === '../model/I18n') return { t: text => text };
    if (id === '../model/Team' || id === '../model/SystemPrompt') return {};
    return load(id);
  }, Set, Map, Object, JSON, Error }, { filename: file });
  return exports;
}
const { Cancellation } = load('Cancellation');
const { CodeExecutionTools, codeUtf8Bytes } = load('CodeExecutionTools');
const { NativeCodeExecutor } = load('NativeCodeExecutor');
const { RuleTools } = load('RuleTools');
const { ToolSet } = load('ToolSet');
const call = args => ({ id: 'call', type: 'function', function: { name: 'execute_code', arguments: JSON.stringify(args) } });
async function main() {
  const received = [];
  const code = new CodeExecutionTools({ execute: async (...args) => { received.push(args); return '{"status":"ok"}'; } });
  const signal = new Cancellation();
  const readOnly = new RuleTools(new ToolSet([code]), true);
  assert.equal(readOnly.definitions()[0].function.name, 'execute_code');
  await readOnly.execute(call({ code: 'return input;' }), signal);
  assert.equal(received[0][1], 'null');
  await code.execute(call({ code: 'return input;', input: '{"x":2}' }), signal);
  assert.equal(received[1][1], '{"x":2}');
  const invalid = [null, [], 3, 'str', {}, { code: '' }, { code: ' ' }, { code: 1 }, { code: 'return 1;', input: {} },
    { code: 'return 1;', memoryLimit: 999999999 }, { code: 'return 1;', network: true },
    { code: '中'.repeat(11000) }, { code: 'return input;', input: '🙂'.repeat(9000) }];
  for (const args of invalid) await assert.rejects(code.execute(call(args), signal));
  await assert.rejects(code.execute({ function: { name: 'execute_code', arguments: '{' } }, signal));
  assert.equal(received.length, 2);
  for (const value of ['', 'ascii', '中文🙂', '\ud800', '\udc00', 'a\ud800b']) {
    assert.equal(codeUtf8Bytes(value), Buffer.byteLength(value));
  }
  console.log('PASS tool validation, UTF-8 limits, fixed capabilities, read-only ToolSet routing');

  const executor = new NativeCodeExecutor();
  const stopped = new Cancellation(); stopped.cancel();
  await assert.rejects(executor.execute('return 1;', 'null', stopped));
  assert.equal(submissions, 0);
  const running = new Cancellation();
  const pending = executor.execute('while(true){}', 'null', running);
  const id = active.id;
  let settled = false;
  const observed = pending.then(() => { settled = true; }, () => { settled = true; });
  running.cancel();
  assert.deepEqual(cancels, [id]);
  await Promise.resolve();
  assert.equal(settled, false, 'cancellation must await native cleanup');
  await assert.rejects(executor.execute('return 1;', 'null', new Cancellation()), /busy/);
  finish('{"status":"cancelled"}');
  await assert.rejects(pending); await observed;
  const nextSignal = new Cancellation();
  const next = executor.execute('return 42;', 'null', nextSignal);
  assert.notEqual(active.id, id);
  finish();
  assert.equal(JSON.parse(await next).result, 42);
  nextSignal.cancel();
  assert.deepEqual(cancels, [id], 'completed execution unsubscribed');
  console.log('PASS cancellation waits for cleanup, busy rejection, unique IDs, recovery and listener cleanup');

  const { TeamToolLane } = load('TeamCoordinator');
  const lane = new TeamToolLane();
  const nativeTools = new CodeExecutionTools(executor);
  const firstSignal = new Cancellation();
  const first = lane.execute(nativeTools, call({ code: 'while(true){}' }), firstSignal);
  const rejected = assert.rejects(first);
  await new Promise(setImmediate);
  const firstId = active.id;
  const queued = lane.execute(nativeTools, call({ code: 'return 42;' }), new Cancellation());
  firstSignal.cancel();
  await new Promise(setImmediate);
  assert.equal(active.id, firstId, 'lane stays occupied until native cancellation completes');
  finish('{"status":"cancelled"}');
  await rejected;
  await new Promise(setImmediate);
  assert.notEqual(active.id, firstId);
  finish();
  assert.equal(JSON.parse(await queued).result, 42);
  console.log('PASS TeamToolLane advances after cancelled native execution has cleaned up');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
