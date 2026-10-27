// Source-level regressions for the actual event, projection and persistence paths. No device/App installation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture };';
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText;
  vm.runInNewContext(js, { exports, console, setTimeout, clearTimeout, Observed: cls => cls, require: id => {
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = file => load(path.join(root, 'main/ets', file));
const clone = value => JSON.parse(JSON.stringify(value));
const tool = (id, name = 'read_file', status = 'running', output = '') => ({ call: { id, type: 'function',
  function: { name, arguments: '{"path":"notes.txt"}' } }, status, output });
const message = (id, tools = []) => ({ id, role: 'assistant', content: '', status: 'generating', error: '',
  steps: [{ content: 'Working', tools }] });
const gate = () => { let open; const promise = new Promise(resolve => open = resolve); return { promise, open }; };
let completed = false;
process.on('beforeExit', () => { if (!completed) { console.error('Tool responsiveness regressions did not finish'); process.exitCode = 1; } });

async function main() {
  const { CheckpointQueue } = from('services/CheckpointQueue');
  let state = 0, active = 0, peak = 0; const saved = [], entered = gate(), release = gate();
  const queue = new CheckpointQueue(async () => {
    peak = Math.max(peak, ++active); saved.push(state);
    try { if (saved.length === 1) { entered.open(); await release.promise; } } finally { active--; }
  });
  state = 1; const first = queue.save(); state = 2; const second = queue.save();
  assert.equal(saved.length, 0, 'checkpoint yields before synchronous snapshot work');
  await entered.promise;
  assert.deepEqual(saved, [2], 'same-turn intents share one durable snapshot');
  state = 3; let thirdDone = false; const third = queue.save().then(() => thirdDone = true);
  release.open(); await Promise.all([first, second]);
  assert.equal(thirdDone, false, 'IO already in flight cannot acknowledge a newer intent');
  await third; assert.deepEqual(saved, [2, 3]); assert.equal(peak, 1);
  let fail = true; const broken = new CheckpointQueue(async () => { if (fail) throw Error('disk full'); });
  const failures = await Promise.allSettled([broken.save(), broken.save()]);
  assert.ok(failures.every(item => item.status === 'rejected' && item.reason.message === 'disk full'));
  fail = false; await broken.save();
  console.log('PASS coalesced checkpoints: captured intents, ordered IO, failure propagation and queue recovery');

  const { ConversationCapture } = from('model/ConversationCapture');
  const { emptyData } = from('model/Conversation');
  const data = emptyData(); data.activeThreadId = 't';
  let oldReads = 0; const old = { id: 'old', role: 'user', status: 'complete', error: '',
    get content() { oldReads++; return 'large historical tool output'.repeat(10000); } };
  const answer = message('answer', [tool('one')]);
  data.threads = [{ id: 't', title: 'Before', updatedAt: 1, messages: [old, answer],
    memorySnapshot: 'memory', references: [], teams: [], queuePaused: false }];
  const capture = new ConversationCapture(); capture.capture(data);
  const initialReads = oldReads;
  answer.steps[0].tools[0].status = 'complete'; answer.steps[0].tools[0].output = 'committed';
  data.threads[0].title = 'After';
  const snapshot = capture.capture(data, ['t'], { threadId: 't', messageId: 'answer' });
  assert.equal(oldReads, initialReads, 'runtime checkpoints never reserialize unchanged historical messages');
  answer.steps[0].tools[0].output = 'later'; data.threads[0].title = 'Later';
  const restored = JSON.parse(snapshot.threads.get('t'));
  assert.equal(restored.title, 'After'); assert.equal(restored.memorySnapshot, 'memory');
  assert.equal(restored.messages[1].steps[0].tools[0].output, 'committed', 'capture preserves call-time values');
  capture.capture(data, ['t']); assert.equal(oldReads, initialReads + 1, 'ordinary edits recapture all changed messages');
  data.threads[0].messages.splice(0, 1);
  assert.equal(JSON.parse(capture.capture(data, ['t'], { threadId: 't', messageId: 'answer' }).threads.get('t')).messages.length, 1);
  capture.clear(); capture.capture(data, ['t'], { threadId: 't', messageId: 'answer' });
  data.threads = []; assert.equal(capture.capture(data).threads.size, 0);
  console.log('PASS transcript capture: history reuse, metadata preservation, detached snapshots, edits and deletion');

  const { MessageViewModel } = from('viewmodel/SessionViewModels');
  const view = new MessageViewModel(message('reply', [tool('old', 'read_file', 'complete', 'unchanged'), tool('parent', 'orchestrate')]));
  const progress = view.plan, previousTool = view.stepViews[0].tools[0], timeline = view.timeline;
  const parent = view.stepViews[0].tools[1]; const child = tool('child');
  view.updateTool(0, clone(child), 'parent'); child.status = 'complete'; child.output = 'child result';
  view.updateTool(0, clone(child), 'parent');
  assert.equal(view.stepViews[0].tools[0], previousTool); assert.equal(view.stepViews[0].tools[1], parent);
  assert.equal(view.timeline, timeline, 'status-only changes retain the timeline');
  assert.equal(view.plan, progress); assert.equal(parent.children.length, 1); assert.equal(parent.children[0].output, 'child result');
  assert.equal(view.steps[0].tools[1].children[0].status, 'complete');
  assert.throws(() => view.updateTool(0, tool('unknown')), /no matching parent/);
  const planned = new MessageViewModel(message('plan', [tool('plan-call', 'update_plan')]));
  planned.plan.expanded = true;
  planned.updateTool(0, tool('plan-call', 'update_plan', 'complete', JSON.stringify({ steps: [{ step: 'Check', status: 'in_progress' }] })));
  assert.equal(planned.plan.currentStep, 'Check'); assert.equal(planned.plan.expanded, true); assert.equal(planned.plan.running, true);
  console.log('PASS targeted projection: child upserts, retained identities/timeline, fail-fast mismatches and live plan updates');

  const { Fixture } = load(path.join(root, 'test/SessionService.test'));
  const { ChatViewModel } = from('viewmodel/ChatViewModel');
  const f = new Fixture(), app = new ChatViewModel(); const events = [];
  f.resources.agentTools = { definitions: () => [{ type: 'function', function: { name: 'read_file', description: 'read',
    parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } }],
    execute: async () => 'result' };
  f.provider.respond = async index => index === 0 ? { content: 'Read', toolCalls: [tool('a').call, tool('b').call] } :
    { content: 'Done', toolCalls: [] };
  await app.initialize(f.session);
  f.session.subscribe(event => {
    if (event.kind === 'tool') {
      events.push(clone(event));
      assert.equal(event.message, undefined, 'tool events carry one receipt, never the full reply');
      event.tool.output = 'tampered by observer';
    }
  });
  f.session.setDraft('Read both files'); await f.session.send();
  assert.equal(events.length, 4); assert.deepEqual(events.map(item => item.tool.call.id).sort(), ['a', 'a', 'b', 'b']);
  const final = f.session.snapshot().threads[0].messages.at(-1);
  assert.ok(final.steps[0].tools.every(item => item.output === 'result'));
  assert.equal(app.active.messages.at(-1).status, 'complete');
  assert.ok(app.active.messages.at(-1).stepViews[0].tools.every(item => item.output === 'result'));
  console.log('PASS actual AgentRuntime -> SessionService -> ChatViewModel tool events and observer isolation');

  const { AgentRuntime } = from('services/AgentRuntime');
  const { ProviderRegistry } = from('services/providers/ProviderRegistry');
  const nested = new Fixture(), nestedApp = new ChatViewModel(), nestedEvents = [];
  const registry = new ProviderRegistry(); registry.register(nested.provider);
  nested.resources.agentTools = f.resources.agentTools;
  nested.session.runtime = new AgentRuntime(registry, nested.keys, undefined, undefined, {
    execute: async (_code, _catalog, invoke) => {
      await Promise.all([invoke('read_file', '{"path":"a"}'), invoke('read_file', '{"path":"b"}')]);
      return '{"status":"ok"}';
    }
  });
  const outerCall = tool('outer', 'orchestrate').call; outerCall.function.arguments = '{"code":"return 1"}';
  nested.provider.respond = async index => index === 0 ? { content: '', toolCalls: [outerCall] } : { content: 'Done', toolCalls: [] };
  await nestedApp.initialize(nested.session);
  nested.session.subscribe(event => { if (event.kind === 'tool') nestedEvents.push(clone(event)); });
  nested.session.setDraft('Compose two tools'); await nested.session.send();
  assert.equal(nestedEvents.length, 6);
  const childEvents = nestedEvents.filter(event => event.parentToolCallId);
  assert.equal(childEvents.length, 4); assert.ok(childEvents.every(event => event.parentToolCallId === 'outer'));
  assert.equal(new Set(childEvents.map(event => event.tool.call.id)).size, 2);
  assert.ok(childEvents.every(event => event.tool.call.id !== 'outer'));
  const nestedView = nestedApp.active.messages.at(-1).stepViews[0].tools[0];
  assert.equal(nestedView.children.length, 2); assert.ok(nestedView.children.every(child => child.status === 'complete'));
  console.log('PASS actual orchestration child IDs, parent routing and complete live child projection');

  const { OrchestrationTools } = from('services/OrchestrationTools');
  const { executeToolBatch } = from('services/ToolExecution');
  const { Cancellation } = from('services/Cancellation');
  const batchStep = { content: '', tools: [{ call: outerCall, status: 'pending', output: '' }] }, snapshots = [];
  const batchTools = new OrchestrationTools({ definitions: f.resources.agentTools.definitions,
    execute: async incoming => {
      assert.ok(snapshots.at(-1).tools[0].children.some(child => child.call.id === incoming.id && child.status === 'running'),
        'every effect must have a durable intent even when checkpoints coalesce');
      return 'result';
    }
  }, { execute: async (_code, _catalog, invoke) => {
    await Promise.all(Array.from({ length: 20 }, (_, index) => invoke('read_file', JSON.stringify({ path: String(index) }))));
    return '{"status":"ok"}';
  } });
  await executeToolBatch(batchStep, 0, batchTools, batchTools.definitions(), new Cancellation(), {
    event: () => {}, checkpoint: async () => { snapshots.push(clone(batchStep)); }
  });
  assert.ok(snapshots.length < 42, 'parallel child checkpoints must not all serialize separate snapshots');
  assert.equal(snapshots.at(-1).tools[0].children.length, 20);
  assert.ok(snapshots.at(-1).tools[0].children.every(child => child.status === 'complete'));
  console.log('PASS 20 actual orchestration children: ' + snapshots.length + ' durable snapshots instead of 42, with every intent and result retained');

  const { workspaceDiffs } = from('model/WorkspaceDiff');
  const firstDiff = workspaceDiffs('a', 'old\n', 'new\n', 'old\n', false, false);
  assert.equal(firstDiff.current, firstDiff.cumulative, 'the first write computes its identical diff once');
  const nextDiff = workspaceDiffs('a', 'new\n', 'third\n', 'old\n', false, false);
  assert.equal(nextDiff.current.rows.find(row => row.kind === 'removed').text, 'new');
  assert.equal(nextDiff.cumulative.rows.find(row => row.kind === 'removed').text, 'old');
  console.log('PASS current/cumulative diff semantics without duplicate first-write computation');
  completed = true;
}
main().catch(error => { console.error(error); process.exitCode = 1; });
