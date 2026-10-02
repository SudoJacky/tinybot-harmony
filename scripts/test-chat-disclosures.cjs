// View-model regression checks; ArkUI rendering is verified separately on device.
// Run: node scripts/test-chat-disclosures.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
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
const { ThreadViewModel } = load(path.join(root, 'viewmodel/SessionViewModels'));
const { buildTimeline } = load(path.join(root, 'model/ProcessPresentation'));
const call = id => ({ call: { id, type: 'function', function: { name: 'read_file', arguments: '{}' } }, status: 'running', output: '' });
const message = id => ({ id, role: 'assistant', content: '', error: '', status: 'generating',
  steps: [{ content: '', reasoningContent: 'Inspecting files', tools: [call('read-1')] }] });
const data = { id: 'thread', title: 'test', updatedAt: 1, messages: [message('a'), message('b')] };
const thread = new ThreadViewModel(data);
const first = thread.messages[0];
const groupKey = buildTimeline(first.stepViews)[0].key;
const group = first.disclosures.get(groupKey);
const thought = first.disclosures.get('thinking-0');
const tool = first.disclosures.get('tool-read-1');
first.processOpen = true;
group.open = true;
thought.open = true; thought.limit = 8000;
tool.open = true; tool.limit = 12000; tool.rawOpen = true; tool.rawLimit = 6000;

// New streaming snapshots and later steps must not erase existing reading state.
data.messages[0].steps[0].tools[0].output = 'file output';
data.messages[0].steps[0].tools[0].status = 'complete';
data.messages[0].steps.push({ content: '', reasoningContent: 'Continue inspecting', tools: [call('read-2')] });
thread.update(data);
assert.equal(thread.messages[0], first);
assert.equal(buildTimeline(first.stepViews)[0].key, groupKey);
assert.equal(first.disclosures.get('tool-read-1'), tool);
assert.equal(tool.limit, 12000);
assert.equal(tool.rawOpen, true);
assert.equal(tool.rawLimit, 6000);
assert.equal(first.disclosures.get('thinking-0').limit, 8000);
assert.equal(first.disclosures.get('tool-read-2').open, false);
console.log('PASS streaming updates and new tools preserve prior reading state');

// Simulate retrieving state after whole-process / group / tool remounts.
group.open = false; first.processOpen = false;
group.open = true; first.processOpen = true;
assert.equal(first.disclosures.get('thinking-0').open, true);
assert.equal(first.disclosures.get('tool-read-1').open, true);
data.messages[0].status = 'complete';
data.messages[0].steps.push({ content: 'Final answer', tools: [] });
thread.update(data);
assert.equal(first.processOpen, true);
assert.equal(first.disclosures.get(groupKey), group);
assert.equal(first.disclosures.get('thinking-0'), thought);
console.log('PASS completion and re-access preserve explicit expansion choices');

// Identical tool IDs in another message and freshly loaded history are isolated.
assert.equal(thread.messages[1].disclosures.get('tool-read-1').open, false);
assert.equal(thread.messages[1].processOpen, false);
const reloaded = new ThreadViewModel(data);
assert.equal(reloaded.messages[0].processOpen, false);
assert.equal(reloaded.messages[0].disclosures.get('thinking-0').open, false);
assert.equal(reloaded.messages[0].disclosures.get('tool-read-1').rawLimit, 2000);
assert.equal(Object.hasOwn(data.messages[0], 'disclosures'), false);
console.log('PASS message isolation and compact history defaults without persisted UI state');
