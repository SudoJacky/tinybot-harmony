// Pure ArkTS query regression and workload benchmark; no phone or user data involved.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  vm.runInNewContext(js, { exports, require: id => load(path.resolve(path.dirname(file), id)), setTimeout, clearTimeout, Map, Set, Date, JSON, console }, { filename: file });
  return exports;
}
const { UsageQuery, USAGE_PAGE_SIZE } = load(path.join(__dirname, '../entry/src/main/ets/model/UsageQuery'));
const { summarizeUsage } = load(path.join(__dirname, '../entry/src/main/ets/model/UsageStatistics'));
const now = Date.now();
const filter = { range: 3, provider: '', model: '', threadId: '', now };
function record(i) {
  return { id: 'request-' + String(i).padStart(6, '0'), provider: 'provider-' + i % 3, model: 'model-' + i % 5,
    startedAt: now - Math.floor(i / 11), durationMs: 50, status: 'complete', tokens: { input: 100, output: 20 },
    origin: { threadId: 'thread-' + i % 5000, threadTitle: 'Thread ' + i % 5000, turnId: 'turn-' + i % 10000, purpose: 'conversation' } };
}
(async () => {
  const small = Array.from({ length: 97 }, (_, i) => record(i)).reverse();
  const query = new UsageQuery(small); let cursor; const ids = [];
  do {
    const page = await query.page(filter, cursor); assert.ok(page.records.length <= USAGE_PAGE_SIZE);
    ids.push(...page.records.map(item => item.id)); cursor = page.next;
  } while (cursor);
  const expected = summarizeUsage(small, 3, '', '', now);
  assert.equal(ids.join(','), expected.records.map(item => item.id).join(','), 'tied timestamps must not skip or duplicate requests');
  const scoped = { ...filter, provider: 'provider-1', model: 'model-1' };
  assert.equal((await query.page(scoped)).records.length, summarizeUsage(small, 3, scoped.provider, scoped.model, now).records.length);
  const first = await query.page(filter);
  const inserted = new UsageQuery([record(1000000), ...small]);
  assert.equal((await inserted.page(filter, first.next)).records[0].id, ids[USAGE_PAGE_SIZE], 'cursor is stable after inserting unrelated older records');
  const cancelled = new UsageQuery(small); const pending = cancelled.summary(filter); cancelled.cancel();
  await assert.rejects(pending, /superseded/);
  const records = Array.from({ length: 100000 }, (_, i) => record(i));
  const large = new UsageQuery(records); let ticks = 0; let maxGap = 0; let last = performance.now();
  const heartbeat = setInterval(() => { const next = performance.now(); maxGap = Math.max(maxGap, next - last); last = next; ticks++; }, 5);
  try {
    const begin = performance.now();
    const summary = await large.summary(filter); const summaryMs = performance.now() - begin;
    assert.equal(summary.totals.calls, 100000); assert.equal(summary.totals.total, 12000000);
    assert.equal(summary.records.length, 0);
    assert.ok(summary.sessions.every(item => item.records.length === 0 && item.turns.length === 0), 'summary does not retain request lists or eagerly build turns');
    const pageBegin = performance.now(); const page = await large.page(filter);
    assert.equal(page.records.length, USAGE_PAGE_SIZE); assert.ok(page.next);
    const turns = await large.turns(filter, 'thread-10');
    assert.equal(turns.reduce((sum, item) => sum + item.calls, 0), 20);
    assert.ok(turns.every(item => item.records.length === 0));
    console.log(JSON.stringify({ records: records.length, sessions: summary.sessions.length, summaryMs: Math.round(summaryMs),
      pageAndTurnsMs: Math.round(performance.now() - pageBegin), eventLoopTicks: ticks, maxEventLoopGapMs: Math.round(maxGap), retainedPageRecords: page.records.length }));
    console.log('PASS bounded pages, exact totals, tied timestamps, filters, lazy turns and cancellation; timing is informational');
  } finally {
    clearInterval(heartbeat);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
