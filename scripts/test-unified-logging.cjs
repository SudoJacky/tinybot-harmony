// Exercise the public production interface and its actual native output adapter.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map(), native = [];
let serialization = 0;
const sink = Object.fromEntries(['debug', 'info', 'warn', 'error'].map(level => [level, (...args) => native.push({ level, args })]));
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS } }).outputText, { exports, JSON: { stringify: value => { serialization++; return JSON.stringify(value); } },
    require: id => id === '@kit.PerformanceAnalysisKit' ? { hilog: sink } : load(path.resolve(path.dirname(file), id)) });
  return exports;
}
const { DiagnosticsCollector, Diagnostics } = load(path.join(root, 'model/Diagnostics'));
const { configureNativeDiagnosticLog, recentDiagnosticLogs, clearRecentDiagnosticLogs } = load(path.join(root, 'services/NativeDiagnosticLog'));
configureNativeDiagnosticLog();
let now = 100, clocks = 0, reads = 0;
Diagnostics.configureClock(() => { clocks++; return now; });
const fields = { get chars() { reads++; return 9000; }, get apiKey() { throw Error('Secret field must not be inspected'); } };
const error = { get message() { throw Error('Disabled logs must not inspect errors'); } };
for (let index = 0; index < 100000; index++) {
  Diagnostics.log('debug', 'speech', 'vad', fields, error);
  Diagnostics.log('info', 'network', 'request_start', fields, error);
}
assert.equal(reads, 0); assert.equal(clocks, 0); assert.equal(serialization, 0); assert.equal(native.length, 0);
assert.equal(Diagnostics.eventsSince(0).length, 0);
assert.equal(recentDiagnosticLogs().records.length, 0, 'Disabled Debug/Info must not populate recent logs');
console.log('PASS closed Debug/Info perform no field/error reads, clocks, serialization, buffering or native writes');

const secret = 'PRIVATE_API_KEY_0123456789';
Diagnostics.log('warn', 'web', 'navigation_blocked', { scheme: 'https', threadId: secret, authorization: secret });
Diagnostics.log('error', 'session', 'run_failed', { code: 401 }, Error('timeout Authorization: Bearer ' + secret + ' https://secret.example/path prompt=PRIVATE_PROMPT'));
assert.equal(clocks, 0); assert.equal(native.length, 2); assert.equal(serialization, 2);
assert.equal(Diagnostics.snapshot().logging.records.length, 0); assert.equal(Diagnostics.eventsSince(0).length, 0);
assert.ok(!JSON.stringify(native).includes(secret)); assert.ok(!JSON.stringify(native).includes('secret.example'));
assert.equal(JSON.parse(native[1].args.at(-1)).fields.errorKind, 'timeout');
const recent = recentDiagnosticLogs(); assert.equal(recent.records.length, 2);
assert.ok(!JSON.stringify(recent).includes(secret)); assert.ok(!JSON.stringify(recent).includes('secret.example'));
assert.equal(recent.records[1].data.fields.errorKind, 'timeout');
clearRecentDiagnosticLogs(); assert.equal(recentDiagnosticLogs().records.length, 0);
console.log('PASS closed Warn/Error retain sanitized recent records and HiLog output without enabling diagnostic capture');

Diagnostics.start(); Diagnostics.detailed = false;
Diagnostics.log('debug', 'speech', 'vad', fields); assert.equal(reads, 0);
Diagnostics.log('info', 'network', 'request_start', { operationId: 7, threadId: secret, protocol: 'chat-completions', chars: 22,
  apiKey: secret, Authorization: secret, request: secret, prompt: 'PRIVATE_PROMPT', body: { text: secret }, url: 'https://secret.example', path: 'C:/private/user' });
let snapshot = Diagnostics.snapshot(); let log = snapshot.logging.records.at(-1);
assert.equal(log.log.fields.threadId, 'ref-1'); assert.equal(log.log.fields.protocol, 'chat-completions');
assert.equal(log.log.fields.chars, 22); assert.equal(log.log.fields.operationId, 7);
assert.equal(log.log.fields.apiKey, undefined); assert.equal(log.log.fields.request, undefined);
assert.ok(!JSON.stringify(snapshot).includes('PRIVATE_')); assert.ok(!JSON.stringify(snapshot).includes('secret.example'));
Diagnostics.log('info', 'network', 'request_end', { threadId: secret, protocol: secret });
log = Diagnostics.snapshot().logging.records.at(-1); assert.equal(log.log.fields.threadId, 'ref-1'); assert.equal(log.log.fields.protocol, '[redacted]');
const before = Diagnostics.snapshot().logging.records.length;
Diagnostics.log('info', 'constructor', 'request_start', fields); Diagnostics.log('info', 'network', secret, fields);
assert.equal(Diagnostics.snapshot().logging.records.length, before); assert.equal(reads, 0);
assert.equal(Diagnostics.snapshot().logging.rejected, 2);
Diagnostics.logLevel = 'error';
const warnings = native.length; Diagnostics.log('warn', 'web', 'navigation_blocked', { scheme: 'data' });
assert.equal(native.length, warnings + 1); assert.equal(Diagnostics.snapshot().logging.records.length, before);
Diagnostics.log('error', 'session', 'save_failed', {}, Object.assign(Error('PRIVATE_SECRET ' + secret), { code: 28 }));
log = Diagnostics.snapshot().logging.records.at(-1); assert.equal(log.log.fields.errorCode, 28); assert.equal(log.log.fields.errorKind, 'unknown');
assert.equal(Diagnostics.snapshot().logging.counts.error, 1); assert.ok(Diagnostics.snapshot().logging.filtered >= 2);
Diagnostics.log('error', 'browser', 'observation_changed', undefined, Object.assign(Error(secret), { code: 'STALE_BROWSER_SNAPSHOT' }));
assert.equal(Diagnostics.snapshot().logging.records.at(-1).log.fields.errorCode, 'STALE_BROWSER_SNAPSHOT');
Diagnostics.logLevel = 'debug'; Diagnostics.log('debug', 'speech', 'vad', { speaking: false });
assert.equal(Diagnostics.snapshot().logging.counts.debug, 1);
console.log('PASS all levels, allowlisted names/fields/enums, private payload exclusion, error classification/codes and per-capture references');

const collector = new DiagnosticsCollector(); collector.configureClock(() => ++now); collector.start();
for (let index = 0; index < 1100; index++) collector.log('info', 'diagnostics', 'marker', { count: index });
for (let index = 0; index < 14000; index++) collector.event('render.test', { number: index }, 0, true);
snapshot = collector.snapshot();
assert.equal(snapshot.logging.records.length, 1000); assert.equal(snapshot.logging.overwritten, 100); assert.equal(snapshot.logging.counts.info, 1100);
assert.equal(snapshot.events.length, 12000); assert.ok(snapshot.events.every(event => !event.log));
assert.equal(snapshot.logging.records[0].log.fields.count, 100); assert.equal(snapshot.logging.records.at(-1).log.fields.count, 1099);
const all = collector.eventsSince(0); assert.equal(all.length, 13000); assert.ok(all.every((event, index) => !index || event.seq > all[index - 1].seq));
assert.ok(all.every((event, index) => !index || event.time >= all[index - 1].time));
assert.equal(collector.snapshot(false).logging.records.length, 0);
collector.stop(); const stopped = JSON.stringify(collector.snapshot()); collector.log('error', 'session', 'save_failed', {}, Error(secret));
assert.equal(JSON.stringify(collector.snapshot()), stopped, 'Stopped collector without native sink remains unchanged');
collector.start(); assert.equal(collector.snapshot().logging.records.length, 0); assert.equal(collector.snapshot().logging.overwritten, 0);
collector.log('info', 'network', 'request_start', { threadId: 'different id' });
assert.equal(collector.snapshot().logging.records[0].log.fields.threadId, 'ref-1');
collector.configureLogSink(() => { throw Error('native output unavailable'); }); collector.log('error', 'session', 'save_failed');
assert.equal(collector.snapshot().logging.sinkFailures, 1); collector.clear(); assert.equal(collector.snapshot().logging.records.length, 0);
console.log('PASS independent bounded log ring, monotonic shared sequence, overwrite accounting, stop/reset and visible sink failures');

// Architectural guard: new application paths cannot bypass redaction or the mode/level gate.
let migratedCalls = 0;
for (const file of fs.readdirSync(root, { recursive: true }).filter(file => file.endsWith('.ets'))) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  if (file.replaceAll('\\', '/') === 'services/NativeDiagnosticLog.ets') continue;
  assert.ok(!/\bhilog\s*\./.test(source), 'Direct HiLog bypass: ' + file);
  assert.ok(!/import\s*\{[^}]*\bhilog\b/.test(source), 'Direct HiLog import: ' + file);
  assert.ok(!/\bconsole\s*\.\s*(?:warn|error)\s*\(/.test(source), 'Direct console error bypass: ' + file);
  for (const match of source.matchAll(/Diagnostics\.log\('(debug|info|warn|error)', '([^']+)', '([^']+)'/g)) {
    const fresh = new DiagnosticsCollector(); fresh.start(); fresh.logLevel = 'debug'; fresh.log(match[1], match[2], match[3]);
    assert.equal(fresh.snapshot().logging.rejected, 0, 'Unregistered production log: ' + match[0]); migratedCalls++;
  }
}
assert.ok(migratedCalls >= 55, 'Expected the existing logging paths to migrate');
console.log('PASS application-wide logging architecture guard and fixed event catalog: ' + migratedCalls + ' literal call sites');
const { LogSanitizer } = load(path.join(root, 'model/DiagnosticLog'));
const transportFields = new LogSanitizer().sanitize({ code: 2300056, bytes: 1234, http: 0, phase: 'streaming', retryable: true,
  body: secret, url: 'https://secret.example' }, undefined, true);
assert.equal(transportFields.code,2300056);assert.equal(transportFields.bytes,1234);assert.equal(transportFields.http,0);
assert.equal(transportFields.phase,'streaming');assert.equal(transportFields.retryable,true);
assert.ok(!JSON.stringify(transportFields).includes(secret));assert.equal(transportFields.url,undefined);
console.log('PASS transport stage, retry decision and numeric evidence survive redaction without payloads or URLs');
const { ToolFailure, toolHttpFailure } = load(path.join(root, 'model/ToolFailure'));
const sanitizer = new LogSanitizer();
const rateLimit = sanitizer.sanitize(undefined, toolHttpFailure(429, secret, 'mcp'), true);
assert.equal(rateLimit.errorCode, 'RATE_LIMITED'); assert.equal(rateLimit.http, 429); assert.equal(rateLimit.service, 'mcp');
const detail = { nativeCode: 2300056, remoteCode: -32000, service: 'mcp',
  get path() { throw Error('Private details must not be inspected'); }, result: { token: secret } };
const nativeFailure = sanitizer.sanitize(undefined, new ToolFailure('NETWORK_ERROR', secret, secret, detail), true);
assert.equal(nativeFailure.nativeCode, 2300056); assert.equal(nativeFailure.remoteCode, -32000);
assert.ok(!JSON.stringify(nativeFailure).includes(secret));
assert.equal(sanitizer.sanitize(undefined, new ToolFailure(secret, secret, secret, { service: secret }), true).service, undefined);
console.log('PASS structured tool failures retain known codes and numeric service evidence without private details');
Diagnostics.stop();
const begin = performance.now();
for (let index = 0; index < 1000000; index++) Diagnostics.log('info', 'network', 'request_start');
// Benchmark is separate from deterministic zero-work assertions; never use host timing as device proof.
console.log(JSON.stringify({ iterations: 1000000, hostDurationMs: +(performance.now() - begin).toFixed(2), note: 'Host microbenchmark only' }));

// Replay the real persistence failure boundary through the production log sanitizer/sink.
const sessionFile = path.join(root, 'services/SessionService.ets');
const sessionTree = ts.createSourceFile(sessionFile, fs.readFileSync(sessionFile, 'utf8'), ts.ScriptTarget.Latest, true);
const sessionClass = sessionTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'SessionService');
const persist = sessionClass.members.find(node => node.name?.getText(sessionTree) === 'persist');
const persistScope = { exports: {}, t: text => text };
vm.runInNewContext(ts.transpileModule(`class Probe { ${persist.getText(sessionTree)} } exports.Probe = Probe;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, persistScope);
(async () => {
  Diagnostics.start();
  const failure = Object.assign(Error('disk full PRIVATE_PATH'), { code: 28 });
  const view = Object.assign(new persistScope.exports.Probe(), {
    data: {}, draftRevision: 0, dirtyDrafts: new Set(), application: {}, runningThreadIds: [],
    syncEmptyThreadPreferences: () => [], publish() {}, repository: { async save() { throw failure; } },
    resources: { reportError: (event, error, fields) => Diagnostics.log('error', 'session', event, fields, error) }
  });
  await assert.rejects(view.persist('private-thread', 'private-message'), /disk full/);
  const record = recentDiagnosticLogs().records.at(-1).data;
  assert.equal(record.fields.errorCode, 28, 'Preserve the native error object before formatting a user-facing message');
  assert.equal(record.fields.errorKind, 'storage');
  assert.equal(record.fields.threadId, 'ref-1'); assert.equal(record.fields.messageId, 'ref-2');
  assert.ok(!JSON.stringify(record).includes('PRIVATE_PATH'));
  console.log('PASS persistence failure retains native error code and anonymized operation references');
})().catch(error => { console.error(error); process.exitCode = 1; });
