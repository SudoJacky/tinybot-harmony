// View-model regression checks; ArkUI rendering is verified separately on device.
// Run: node scripts/test-chat-disclosures.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(compiled, { exports, Observed: cls => cls,
    require: id => {
      if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
      return load(path.resolve(path.dirname(file), id));
    }
  }, { filename: file });
  return exports;
}

const { buildTimeline, turnPhase, workflowEntryState } = load(path.join(root, 'model/ProcessPresentation'));
const tool = (id, status = 'running') => ({ call: { id, type: 'function', function: { name: 'read_file', arguments: '{}' } }, status, output: '' });
const step = (content = '', tools = [], reasoningContent = '') => ({ content, tools, reasoningContent });
const steps = [];
assert.equal(turnPhase('generating', steps), 'waiting');
steps.push(step('', [], 'Plan'));
assert.equal(turnPhase('generating', steps), 'thinking');
steps[0].content = 'Read files'; steps[0].tools.push(tool('one'), tool('two', 'pending'));
assert.equal(turnPhase('generating', steps), 'tools');
steps[0].tools[0].status = 'complete';
assert.equal(turnPhase('generating', steps), 'tools', 'Pending sibling keeps the turn active');
steps[0].tools[1].status = 'complete';
assert.equal(turnPhase('generating', steps), 'waiting');
steps.push(step('', [], 'Check results'));
const group = buildTimeline(steps).find(e => e.kind === 'process' && e.items.some(i => i.tool >= 0));
assert.equal(workflowEntryState(group, steps, 'generating'), 'active', 'Group spanning two model steps tracks newest thought');
assert.equal(workflowEntryState(group, steps, 'stopped'), 'stopped');
steps[1].content = 'Answer';
assert.equal(turnPhase('generating', steps), 'answer');
assert.equal(workflowEntryState(group, steps, 'generating'), 'complete');
steps[0].tools[0].status = 'failed';
assert.equal(workflowEntryState(group, steps, 'complete'), 'failed', 'Recovered failures remain visible');
steps[0].tools[0].status = 'interrupted';
assert.equal(workflowEntryState(group, steps, 'complete'), 'stopped');
steps.push(step()); steps[2].retries = [{ waiting: true, attempt: 1, delayMs: 1000 }];
assert.equal(turnPhase('generating', steps), 'retry');
for (const status of ['stopped', 'failed', 'complete']) assert.equal(turnPhase(status, steps), status);

// Exercise the actual compiled view methods, including stale keyed-group callbacks and live completion.
const source = path.join(root, 'views/MessageBubble.ets');
const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MessageBubble.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'MessageBubble');
const methods = ['aboutToAppear', 'syncWorkflow', 'timeline', 'foldable', 'folded', 'entryVisible', 'traceState'];
const context = { exports: {}, ...load(path.join(root, 'model/ProcessPresentation')),
  stepDisplayContent: s => s.content, Motion: { standard: 'ease' } };
vm.runInNewContext(ts.transpileModule(`class Probe { ${component.members.filter(n => methods.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} } exports.Probe = Probe;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const message = { status: 'generating', stepViews: [step('', [tool('read')])], processOpen: false };
const calls = [];
const probe = Object.assign(new context.exports.Probe(), { message, turnStatus: 'generating', workflowCollapsed: false,
  getUIContext: () => ({ animateTo: (options, update) => { calls.push(options); update(); } }) });
probe.aboutToAppear();
const capturedGroup = probe.timeline()[0];
message.stepViews[0].tools[0].status = 'complete';
message.stepViews.push(step('', [], 'Continue'));
assert.equal(probe.traceState(capturedGroup), 'active', 'Retained ForEach resolves live items');
message.stepViews[1].tools.push({ ...tool('preview', 'complete'), call: { id: 'preview', function: { name: 'publish_data_view', arguments: '{}' } } });
message.stepViews.push(step('Final answer'));
message.status = probe.turnStatus = 'complete'; probe.syncWorkflow();
assert.equal(probe.folded(), true); assert.equal(calls[0].duration, 280);
assert.equal(probe.entryVisible(capturedGroup, 0, probe.timeline().length), true, 'Published preview survives folding even in a retained group');
message.processOpen = true;
assert.equal(probe.folded(), false, 'Explicit reading survives completion');
probe.workflowCollapsed = true; message.status = probe.turnStatus = 'failed'; probe.syncWorkflow();
assert.equal(probe.folded(), false, 'Errors reopen a manually collapsed live trace');
probe.turnStatus = 'complete'; probe.aboutToAppear(); assert.equal(probe.settled, true, 'History initializes settled');
console.log('PASS turn workflow: actual phases, parallel tools, retry/stop/failure, retained groups, persistent preview, animated completion and manual reading');
