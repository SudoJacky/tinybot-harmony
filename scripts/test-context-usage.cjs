// Run after devecocli build. Exercise the emitted context panel against real persisted view models.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..'), sourceRoot = path.join(root, 'entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, require: id => load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const { summarizeUsage } = load(path.join(sourceRoot, 'model/MessageUsage'));
const { ThreadViewModel } = load(path.join(sourceRoot, 'viewmodel/SessionViewModels'));
const source = path.join(sourceRoot, 'views/ContextDetails.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ContextDetails.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ContextDetails before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ContextDetails');
const methods = ['records', 'usage', 'counted', 'rows', 'tokens', 'total', 'ratio', 'remaining', 'compact', 'percent', 'segmentWidth']
  .map(name => component.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
const context = { exports: {}, summarizeUsage, t: key => key };
vm.runInNewContext(ts.transpileModule(`class Panel { ${methods} } exports.Panel = Panel;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, context);
const panel = new context.exports.Panel();
const record = (id, tokens, status = 'complete') => ({ id, provider: 'test', model: 'model', startedAt: 1, durationMs: 100, status, tokens });
const step = usage => ({ content: '', tools: [], usage });
const message = (id, role, steps = []) => ({ id, role, content: '', status: 'complete', error: '', steps });
const data = { id: 'conversation', title: 'Test', updatedAt: 1, messages: [
  message('user-1', 'user'),
  message('answer-1', 'assistant', [step(record('req-1', { input: 100, output: 20, cached: 80, reasoning: 5, cacheWrite: 10 })),
    step(record('req-2', { input: 200, output: 30, cached: 100, reasoning: 0, cacheWrite: 0 }))]),
  message('user-2', 'user'),
  message('answer-2', 'assistant', [step(record('req-3', { input: 400, output: 50, cached: 300, reasoning: 10, cacheWrite: 0 }))])
] };
const app = { active: new ThreadViewModel(data), visibleMessages: [], contextDetails: [], generating: false };
panel.app = app;
let total = panel.usage();
assert.equal(total.requests, 3); assert.equal(total.reported, 3);
assert.equal(total.input, 700); assert.equal(total.output, 100);
assert.equal(total.cached, 480); assert.equal(total.cacheWrite, 10); assert.equal(total.reasoning, 15);
assert.equal(total.input + total.output, 800, 'Cache and reasoning are subsets, not additional tokens');
const singleTurn = summarizeUsage(app.active.messages.at(-1).steps.map(item => item.usage));
assert.equal(singleTurn.requests, 1); assert.equal(singleTurn.input, 400, 'Per-message usage keeps its single-turn scope');
app.visibleMessages = app.active.messages.slice(-2);
app.active.compaction = { summary: 'Older turns summarized' };
assert.equal(panel.usage().input, 700, 'Pagination and context compaction do not drop saved earlier turns');
app.active = new ThreadViewModel(JSON.parse(JSON.stringify(data)));
assert.equal(panel.usage().input, 700, 'Reopening persisted conversation retains the cumulative total');
console.log('PASS all saved turns and tool-loop requests accumulate once, per-turn usage stays separate, pagination/compaction/reload preserve totals');

data.messages.push(message('user-3', 'user'), message('answer-3', 'assistant', [
  step(record('req-4', { input: 10, output: 0 }, 'failed')), step(undefined), step(record('req-6', undefined, 'cancelled'))
]));
app.active.update(data); total = panel.usage();
assert.equal(total.requests, 6); assert.equal(total.reported, 4);
assert.equal(total.input, 710); assert.equal(total.output, 100);
assert.equal(panel.counted(total.input, total.reported), '710（部分）');
assert.equal(panel.counted(total.cached, total.cacheReports), '480（部分）');
assert.equal(total.requests - total.reported, 2, 'Missing report differs from a reported zero');
app.active = new ThreadViewModel({ id: 'other', title: 'Other', updatedAt: 2, messages: [
  message('user', 'user', [step(record('not-an-assistant-request', { input: 999, output: 999 }))]),
  message('answer', 'assistant', [step(record('zero', { input: 0, output: 0, cached: 0 }))])
] });
assert.equal(panel.usage().requests, 1); assert.equal(panel.usage().input, 0);
assert.equal(panel.counted(0, 1), '0');
app.active = new ThreadViewModel({ id: 'empty', title: 'Empty', updatedAt: 3, messages: [] });
assert.equal(panel.usage().requests, 0); assert.equal(panel.counted(0, 0), '未报告');
console.log('PASS live updates, failed/cancelled/missing reports, partial markers, real zero values, active conversation isolation and empty history');

// Calibration can be higher or lower than the local breakdown. Segment widths
// must track the real occupied fraction without rewriting category estimates.
app.contextWindow = 1000;
app.contextDetails = [{ id: 'sys', kind: 'system', tokens: 300 }, { id: 'tool', kind: 'definitions', tokens: 100 }];
for (const used of [0, 200, 600, 1200]) {
  app.contextUsed = used;
  assert.ok(Math.abs(panel.segmentWidth('system') + panel.segmentWidth('definitions') - Math.min(used / 10, 100)) < 1e-9);
  assert.equal(panel.segmentWidth('user'), 0);
  assert.equal(panel.tokens('system'), 300, 'Calibration must not fabricate per-category token counts');
  assert.equal(panel.remaining(), Math.max(0, 1000 - used));
}
assert.equal(panel.percent(panel.ratio()), '120%', 'Do not conceal over-limit usage behind a clamped bar');
app.contextDetails.push({ id: 'draft', kind: 'user', tokens: 100 });
app.contextUsed = 500;
assert.equal(panel.segmentWidth('user'), 10, 'Draft updates participate in the live segment distribution');
app.contextDetails = []; app.contextUsed = 0;
assert.equal(panel.segmentWidth('system'), 0);
app.contextWindow = 0;
assert.equal(panel.ratio(), 0); assert.equal(panel.segmentWidth('system'), 0);
assert.equal(panel.percent(0), '0%'); assert.equal(panel.percent(0.00001), '<0.1%');
assert.equal(panel.compact(5391), '5.4k'); assert.equal(panel.compact(1000000), '1M');
assert.equal(panel.compact(1200000), '1.2M'); assert.equal(panel.compact(0), '0');
console.log('PASS calibrated segments, draft updates, empty/zero-window data, overflow and compact number formatting');
