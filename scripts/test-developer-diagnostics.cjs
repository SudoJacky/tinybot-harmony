// Production collector, native adapter and compiled UI callbacks with observable platform effects.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
function evaluate(file, dependencies = {}, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  }).outputText, { exports, ...globals, require: id => {
    if (id in dependencies) return dependencies[id];
    if (id.startsWith('.')) return evaluate(path.relative(root, path.resolve(root, path.dirname(file), id)).replaceAll('\\', '/'), {}, globals);
    throw Error('Unmocked dependency ' + id);
  } });
  return exports;
}
const { DiagnosticsCollector, DeveloperGate } = evaluate('model/Diagnostics');
const plain = value => JSON.parse(JSON.stringify(value));
let now = 100, clocks = 0;
const p = new DiagnosticsCollector(); p.configureClock(() => { clocks++; return now; });
for (let i = 0; i < 1000; i++) { assert.equal(p.begin(), undefined); p.event('disabled'); p.measure('disabled', 10); }
assert.equal(clocks, 0); assert.equal(p.snapshot().events.length, 0);
p.adjust('render.chunks', 4); p.start();
const mark = p.begin(42); now += 20; p.end('markdown.parse', mark, { sourceChars: 200000, secret: 'DO_NOT_EXPORT', invalid: NaN });
let snapshot = plain(p.snapshot()); const parse = snapshot.events.find(e => e.name === 'markdown.parse');
assert.equal(parse.duration, 20); assert.equal(parse.id, 42); assert.deepEqual(parse.values, { sourceChars: 200000 });
assert.equal(snapshot.metrics.find(m => m.name === 'render.chunks').last, 4);
assert.ok(!JSON.stringify(snapshot).includes('DO_NOT_EXPORT'));
const stale = p.begin(); p.stop(); p.start(); p.end('stale', stale); assert.ok(!p.snapshot().metrics.some(m => m.name === 'stale'));
p.detailed = false; const ordinary = p.begin(); now++; p.end('ordinary', ordinary); const slow = p.begin(); now += 51; p.end('slow', slow);
assert.ok(p.snapshot().metrics.some(m => m.name === 'ordinary')); assert.ok(!p.snapshot().events.some(e => e.name === 'ordinary'));
assert.ok(p.snapshot().events.some(e => e.name === 'slow'));
p.detailed = true;
for (let i = 0; i < 13000; i++) p.event('bounded', { number: i });
snapshot = p.snapshot(); assert.equal(snapshot.events.length, 12000); assert.ok(snapshot.overwritten > 0);
assert.equal(snapshot.events[0].values.number, 1000); assert.equal(snapshot.events.at(-1).values.number, 12999);
assert.ok(snapshot.events.every((event, i, all) => !i || all[i - 1].seq < event.seq));
p.clear(); assert.equal(p.snapshot().events.length, 0); assert.equal(p.snapshot().elapsedMs, 0);
const gate = new DeveloperGate(); assert.equal(gate.verify('TB2026&', 0), false);
for (let i = 0; i < 6; i++) assert.equal(gate.tap(i * 200), false);
assert.equal(gate.tap(1200), true); assert.equal(gate.verify('wrong', 1300), false);
for (let i = 0; i < 4; i++) gate.verify('wrong', 1400);
assert.equal(gate.verify('TB2026&', 1500), false); assert.equal(gate.remaining(1500), 30);
assert.equal(gate.verify('TB2026&', 32000), true); gate.cancel(); assert.equal(gate.verify('TB2026&', 32001), false);
for (let i = 0; i < 6; i++) gate.tap(33000 + i * 100);
assert.equal(gate.tap(40000), false, 'Long gaps reset tap sequence');
console.log('PASS disabled no-clock path, numeric-only data, session boundaries, histogram statistics, bounded ring, seven taps, password, cooldown and cancellation');
const viewSource = path.join(root, 'views/DeveloperPanel.ets');
// Derive from the repo rather than the SDK's temporary working directory.
const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/DeveloperPanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(viewSource).mtimeMs, 'Build before diagnostics UI tests');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const declaration = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'DeveloperPanel');
let polls = 0; const panelTimers = new Set();
const uiContext = { exports: {}, t: (_key, args) => args.join('|'),
  setInterval: () => { panelTimers.add(++polls); return polls; }, clearInterval: id => panelTimers.delete(id) };
vm.runInNewContext(ts.transpileModule('class Panel {' + declaration.members.filter(n => ['value', 'metricLine', 'syncTimer'].includes(n.name?.getText(tree)))
  .map(n => n.getText(tree)).join('\n') + '} exports.Panel = Panel;', { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, uiContext);
const ui = new uiContext.exports.Panel();
ui.stats = { metrics: [{ name: 'markdown.parse', count: 1, sum: 1, max: 1, p95Upper: 1, unit: 'ms' }] };
const retainedRender = () => ui.metricLine('markdown.parse'); assert.match(retainedRender(), /^1\|/);
ui.stats = { metrics: [{ name: 'markdown.parse', count: 200, sum: 1000, max: 20, p95Upper: 16.7, unit: 'ms' }] };
assert.match(retainedRender(), /^200\|5.00\|16.7\|20.0\|ms$/);
console.log('PASS compiled diagnostic rows resolve the latest snapshot through retained keyed callbacks');
Object.assign(ui, { mounted: true, foreground: true, recording: false, timer: -1 });
ui.syncTimer(); assert.equal(polls, 0);
ui.recording = true; ui.syncTimer(); assert.equal(panelTimers.size, 1);
ui.recording = false; ui.syncTimer(); assert.equal(panelTimers.size, 0);
ui.recording = true; ui.foreground = false; ui.syncTimer(); assert.equal(panelTimers.size, 0);
console.log('PASS compiled developer page stops statistics polling when recording or foreground ends');

const settings = new Map(), files = new Map(), handles = new Map(), timers = new Map(), storage = new Map();
let next = 0, watches = 0, frameStarts = 0, frameStops = 0, cpuStarts = 0, cpuStops = 0, flushFailure = false;
let samplingGate, frameCallback;
const collector = new DiagnosticsCollector(); collector.configureClock(() => now);
const io = {
  OpenMode: { CREATE: 1, APPEND: 2, WRITE_ONLY: 4, TRUNC: 8 },
  access: async name => files.has(name), unlink: async name => { files.delete(name); },
  rename: async (a, b) => { files.set(b, files.get(a)); files.delete(a); }, readText: async name => files.get(name),
  open: async (name, mode) => { if (mode & 8 || !files.has(name)) files.set(name, ''); const fd = ++next; handles.set(fd, name); return { fd }; },
  close: async file => { handles.delete(file.fd ?? file); },
  write: async (fd, buffer) => {
    if (flushFailure) throw Object.assign(Error('disk'), { code: 28 });
    const bytes = Buffer.from(buffer), count = Math.min(bytes.length, 211); // Force partial writes.
    const name = handles.get(fd); files.set(name, files.get(name) + bytes.subarray(0, count).toString('utf8')); return count;
  }
};
const probe = { pss: 350000, rss: 450000, vss: 5000000, cpu: 3, privateDirty: 100, sharedDirty: 10, threads: [{ id: 17, cpu: 2 }], error: 0 };
const { DeveloperDiagnostics: d } = evaluate('services/DeveloperDiagnostics', {
  '@kit.AbilityKit': {}, '@kit.ArkData': { preferences: { getPreferencesSync: () => ({ getSync: (k, v) => settings.get(k) ?? v,
    putSync: (k, v) => settings.set(k, v), flushSync() {} }) } }, '@kit.CoreFileKit': { fileIo: io },
  '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => now * 1e6 } },
  '@kit.ArkTS': { taskpool: { execute: () => samplingGate || Promise.resolve(probe) }, util: { TextEncoder: class { encodeInto(s) { return new Uint8Array(Buffer.from(s)); } } } },
  '@kit.ArkGraphics2D': { displaySync: { create: () => ({ on: (_type, fn) => { frameCallback = fn; }, off() {}, start() { frameStarts++; }, stop() { frameStops++; } }) } },
  '@kit.PerformanceAnalysisKit': { hidebug: { getAppVMMemoryInfo: () => ({ heapUsed: 100n, totalHeap: 200n, allArraySize: 50n }),
    startJsCpuProfiling() { cpuStarts++; }, stopJsCpuProfiling() { cpuStops++; files.set('/application-files/tinybot-cpu.json', '{}'); } },
    hiAppEvent: { domain: { OS: 'OS' }, event: { MAIN_THREAD_JANK: 'MAIN_THREAD_JANK', APP_FREEZE: 'APP_FREEZE', APP_CRASH: 'APP_CRASH', RESOURCE_OVERLIMIT: 'RESOURCE_OVERLIMIT' },
      addWatcher() { watches++; return {}; }, removeWatcher() { watches--; } } },
  '../model/Diagnostics': { Diagnostics: collector }, './PerformanceProbe': { collectPerformanceResources() {} }, './NativeDiagnosticLog': { configureNativeDiagnosticLog() {} },
  './AppInformation': { readAppInformation: () => ({ bundleName: 'test', versionName: '0.1.6', versionCode: 10006 }) }
}, { AppStorage: { setOrCreate: (k, v) => storage.set(k, v), get: k => storage.get(k) }, setInterval: fn => { const id = ++next; timers.set(id, fn); return id; },
  clearInterval: id => timers.delete(id), setTimeout: fn => { const id = ++next; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) });
const settle = async () => { for (let i = 0; i < 2000; i++) await Promise.resolve(); await d.writing; };
(async () => {
  d.initialize({ filesDir: '/files', cacheDir: '/cache', getApplicationContext: () => ({ filesDir: '/application-files' }) }); d.setForeground(true);
  assert.equal(timers.size, 0); d.enable(); await settle();
  assert.equal(settings.get('enabled'), true); assert.equal(watches, 1); assert.equal(timers.size, 1); assert.equal(frameStarts, 0);
  assert.equal(collector.snapshot().metrics.find(m => m.name === 'memory.pssSwap').last, probe.pss);
  now += 310; d.tick(); assert.equal(collector.snapshot().metrics.find(m => m.name === 'ui.eventLoopDelay').last, 60);
  d.setFrames(true); assert.equal(frameStarts, 1); frameCallback({ timestamp: 1000000, targetTimestamp: 17666667 }); now += 34;
  frameCallback({ timestamp: 1000000, targetTimestamp: 17666667 }); assert.equal(collector.snapshot().metrics.find(m => m.name === 'ui.frameCallbackInterval').last, 34);
  d.startCpuProfile(); assert.equal(cpuStarts, 1); assert.equal(timers.size, 2);
  d.setForeground(false); await settle(); assert.equal(timers.size, 0); assert.equal(frameStops, 1); assert.equal(cpuStops, 1);
  d.setForeground(true); await settle(); assert.equal(timers.size, 1); assert.equal(frameStarts, 2);
  collector.log('info', 'backup', 'restore_prepared', { newChats: 2, skippedChats: 1 });
  collector.log('warn', 'web', 'navigation_blocked', { scheme: 'https', threadId: 'PRIVATE_THREAD' });
  d.mark(); const exported = await d.exportCapture({ cacheDir: '/cache' }); await settle();
  assert.equal(timers.size, 0); assert.equal(watches, 0); assert.equal(handles.size, 0);
  const json = JSON.parse(files.get(exported)); assert.equal(json.capture.recording, false);
  assert.ok(json.traceEvents.some(e => e.name === 'resource.process')); assert.ok(json.traceEvents.some(e => e.name === 'user.marker'));
  for (const line of json.journal.trim().split('\n')) JSON.parse(line);
  assert.ok(json.capture.logging.records.some(event => event.log.module === 'backup' && event.log.fields.newChats === 2));
  assert.ok(json.traceEvents.some(event => event.args.level === 'warn' && event.args.module === 'web'));
  assert.ok(json.journal.includes('restore_prepared'));
  assert.ok(!JSON.stringify(json).includes('PRIVATE_THREAD'));
  assert.equal(json.application.versionCode, 10006); assert.ok(json.definitions.some(x => x.includes('official dropped')));
  d.start(); await settle(); d.flush(); await settle(); assert.ok(files.has('/files/performance-previous.jsonl'));
  flushFailure = true; d.mark(); d.flush(); await settle(); assert.match(storage.get('tinybot.developer.error'), /6 \/ 28/);
  flushFailure = false; d.flush(); await settle();
  d.disable(); await settle(); assert.equal(settings.get('enabled'), false); assert.equal(timers.size, 0); assert.equal(watches, 0);
  d.enable(); await settle(); await d.clear(); assert.equal(collector.snapshot().events.length, 0);
  assert.ok(!files.has('/files/performance-current.jsonl')); assert.ok(!files.has('/files/performance-previous.jsonl'));
  assert.ok(!files.has('/application-files/tinybot-cpu.json')); assert.ok(!files.has('/cache/tinybot-performance.json'));
  assert.equal(timers.size, 0); assert.equal(watches, 0);
  let resolve; samplingGate = new Promise(done => { resolve = done; }); d.start(); const previous = collector.session; d.stop(); d.start();
  resolve(probe); await settle(); assert.equal(collector.session, previous + 1); assert.ok(!collector.snapshot().metrics.some(m => m.name === 'memory.pssSwap'));
  samplingGate = undefined; d.disable(); await settle();
  console.log('PASS native foreground/background lifecycle, worker sampling, optional frames, CPU profile stop, export/Chrome Trace, partial writes, journal rotation/failure/retry, clearing and stale async probes');
  const cache = new Map(), wire = new TextEncoder();
  const source = 'PRIVATE_RESPONSE_请勿记录';
  const nativeHttp = { RequestMethod: { POST: 1 }, createHttp: () => {
    const listeners = {};
    return { on: (name, fn) => { listeners[name] = fn; }, destroy() {}, requestInStream(_url, _options, callback) {
      Promise.resolve().then(() => {
        now += 10; callback(undefined, 200);
        const chunks = [{ choices: [{ index: 0, delta: { reasoning_content: 'PRIVATE_REASONING' } }] },
          { choices: [{ index: 0, delta: { content: source } }] }, { choices: [{ index: 0, finish_reason: 'stop' }] }];
        for (const chunk of chunks) { now += 10; listeners.dataReceive(wire.encode('data: ' + JSON.stringify(chunk) + '\n\n').buffer); }
        listeners.dataReceive(wire.encode('data: [DONE]\n\n').buffer); listeners.dataEnd();
      });
    } };
  } };
  const productionPerf = evaluate('model/Diagnostics').Diagnostics;
  productionPerf.configureClock(() => now);
  const native = { '@kit.NetworkKit': { http: nativeHttp }, '@kit.ArkTS': { util: { generateRandomUUID: () => 'request-id', TextDecoder: class {
    constructor() { this.decoder = new TextDecoder(); } decodeToString(bytes, options) { return this.decoder.decode(bytes, options); }
  } } }, '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {}, error() {} } }, '@kit.BasicServicesKit': {} };
  function loadProduction(file) {
    file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
    if (file.endsWith('Diagnostics.ets')) return { Diagnostics: productionPerf };
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021,
      module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText, { exports, setTimeout, clearTimeout,
      Observed: x => x, require: id => id in native ? native[id] : loadProduction(path.resolve(path.dirname(file), id)) });
    return exports;
  }
  const { ProtocolProvider } = loadProduction(path.join(root, 'services/providers/ProtocolProvider'));
  const { Cancellation } = loadProduction(path.join(root, 'services/Cancellation'));
  const { executeToolBatch } = loadProduction(path.join(root, 'services/ToolExecution'));
  productionPerf.start();
  const provider = new ProtocolProvider({ id: 'local', name: 'local', protocol: 'chat-completions' }, { hydrate: async value => value, recordUsage() {} });
  const result = await provider.stream({ baseUrl: 'https://private-host.example/v1', apiKey: 'PRIVATE_API_KEY', model: 'model', messages: [
    { role: 'user', content: 'PRIVATE_PROMPT' }], tools: [] }, new Cancellation(), () => {}, () => {});
  assert.equal(result.content, source);
  const step = { content: '', tools: [{ call: { id: 'tool', type: 'function', function: { name: 'execute_code', arguments: '{"code":"PRIVATE_TOOL_CODE"}' } }, status: 'pending', output: '' }] };
  await executeToolBatch(step, 1, { execute: async () => { now += 5; return 'PRIVATE_TOOL_RESULT'; } }, [], new Cancellation(), { checkpoint: async () => {}, event() {} });
  const recorded = productionPerf.snapshot(), serialized = JSON.stringify(recorded);
  for (const name of ['network.firstData', 'network.firstText', 'network.publishText', 'network.publishReasoning', 'network.decodeParse', 'network.request', 'tool.execute']) {
    assert.ok(recorded.metrics.some(metric => metric.name === name), 'Missing actual path ' + name);
  }
  for (const forbidden of ['PRIVATE_', 'private-host', 'request-id']) assert.ok(!serialized.includes(forbidden), 'Sensitive content escaped into diagnostics');
  assert.ok(recorded.events.some(event => event.name === 'network.request' && event.values.textChars === source.length));
  productionPerf.stop();
  console.log('PASS real protocol SSE/reasoning/text/end and tool execution instrumentation; API keys, URL, prompts, reasoning, responses and tool payloads excluded');
  const iterations = 1000000, bench = new DiagnosticsCollector();
  const begin = performance.now(); for (let i = 0; i < iterations; i++) bench.begin();
  console.log(JSON.stringify({ disabledBeginIterations: iterations, hostDurationMs: +(performance.now() - begin).toFixed(2), note: 'Host microbenchmark, not device frame performance' }));
})().catch(error => { console.error(error); process.exitCode = 1; });
