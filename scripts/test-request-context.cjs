// Deterministic request-boundary integration tests. No device, network or paid model calls.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
    { exports, setTimeout, clearTimeout, console, require: id => load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const { RequestContext } = load(root + '/services/RequestContext');
const { ContextTools, projectResults, resultTokenBudget } = load(root + '/services/ContextTools');
const { threadEntries, projectedHistory } = load(root + '/model/ContextProjection');
const { sessionContextSource } = load(root + '/services/SessionContext');
const { estimateTextTokens, estimateContextTokens, validateCompaction } = load(root + '/model/ConversationContext');
const { emptyData, parseAppData } = load(root + '/model/Conversation');
const { Cancellation } = load(root + '/services/Cancellation');
const { runAgentLoop } = load(root + '/services/AgentLoop');
const { AgentRuntime } = load(root + '/services/AgentRuntime');
const { ProviderRegistry } = load(root + '/services/providers/ProviderRegistry');
const config = () => ({ configured: true, providerId: 'test', model: 'test', baseUrl: '', credentialAlias: '', systemPrompt: '', contextWindow: 8192 });
const call = (id, name = 'execute_code', args = {}) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (content, toolCalls = []) => ({ content, toolCalls });
function fixture() {
  return { id: 'chat', title: 'Test', updatedAt: 1, messages: [
    { id: 'u1', role: 'user', content: 'Keep working. Never repeat writes.', status: 'complete', error: '' },
    { id: 'a1', role: 'assistant', content: '', status: 'generating', error: '', steps: [] }
  ] };
}
function source(thread, persist = async () => {}) { return sessionContextSource(thread, () => [{ name: 'rules', content: 'Follow the user.' }], persist, () => {}); }
async function main() {
  // A long single user turn compacts inside the turn, then continues without replaying any tool.
  const thread = fixture(), turn = { content: '', steps: [] }, requests = [], writes = [], saved = [];
  const manager = new RequestContext(source(thread, async () => saved.push(JSON.stringify(thread))), config());
  const tools = new ContextTools({ definitions: () => [], execute: async c => { writes.push(c.id); return 'receipt ' + c.id; } }, () => threadEntries(thread), 8192);
  let modelCalls = 0, summaries = 0;
  const model = { stream: async (messages, definitions, signal, onText, options) => {
    if (options?.usagePurpose === 'compaction') { summaries++; return reply('Completed writes are recorded. Continue remaining work; do not repeat writes.'); }
    requests.push(JSON.parse(JSON.stringify(messages))); modelCalls++;
    return modelCalls <= 4 ? reply('analysis '.repeat(1000), [call('write' + modelCalls)]) : reply('done');
  } };
  await runAgentLoop({ model, tools, turn, messages: [], maxSteps: 8, contextWindow: 8192,
    prepareRequest: (defs, pending, signal) => manager.prepare(model, defs, signal, pending), recordResponse: r => manager.recordResponse(r) }, new Cancellation(), {
    event: () => { thread.messages[1].steps = turn.steps; thread.messages[1].content = turn.content; },
    checkpoint: async () => saved.push(JSON.stringify(thread))
  });
  assert.equal(modelCalls, 5); assert.ok(summaries >= 1); assert.equal(new Set(writes).size, 4); assert.equal(writes.length, 4);
  assert.ok(thread.compaction.firstKeptStep > 0); assert.equal(turn.steps.length, 5);
  assert.ok(requests.every(messages => estimateContextTokens(messages, tools.definitions()) <= 4096));
  thread.messages[1].status = 'complete';
  const data = emptyData(); data.threads = [thread]; data.activeThreadId = thread.id;
  const restored = parseAppData(JSON.stringify(data)).threads[0]; validateCompaction(restored.compaction, restored);
  const replay = projectedHistory(threadEntries(restored), restored.compaction);
  assert.ok(replay.some(m => m.content === 'done')); assert.ok(replay.some(m => m.content.includes('Never repeat writes')));
  assert.equal(restored.messages[1].steps[0].tools[0].output, 'receipt write1');
  console.log('PASS mid-turn compaction, exact user anchor, no repeated side effects, complete transcript survives reload');

  // Huge results remain byte-for-byte in the transcript and can be paged after compaction/reload.
  const big = 'BEGIN\n' + '中文😀'.repeat(14000) + '\nEND';
  const resultThread = fixture(); resultThread.messages[1].status = 'complete';
  resultThread.messages[1].steps = [{ content: '', tools: [{ call: call('large'), status: 'complete', output: big }] }];
  const original = JSON.stringify(resultThread);
  const projected = projectResults(threadEntries(resultThread), 8192);
  const preview = JSON.parse(projected.flatMap(e => e.messages).find(m => m.role === 'tool').content);
  assert.equal(preview.contextPreview, true); assert.equal(preview.totalCharacters, big.length); assert.equal(JSON.stringify(resultThread), original);
  let toolExecutions = 0;
  const reader = new ContextTools({ definitions: () => [], execute: async () => { toolExecutions++; return ''; } }, () => threadEntries(resultThread), 8192);
  let offset = 0, collected = '';
  while (offset < big.length) {
    const pageText = await reader.execute(call('page', 'read_tool_result', { messageId: 'a1', callId: 'large', offset, length: 8000 }), new Cancellation());
    assert.ok(estimateTextTokens(pageText) <= resultTokenBudget(8192));
    const page = JSON.parse(pageText); assert.ok(page.nextOffset > offset); offset = page.nextOffset; collected += page.content;
  }
  assert.equal(collected, big); assert.equal(toolExecutions, 0);
  await assert.rejects(reader.execute(call('bad', 'read_tool_result', { messageId: 'other', callId: 'large' }), new Cancellation()), /not found/);
  console.log('PASS complete large Unicode result retained, bounded pages reconstruct it exactly, cross-conversation references rejected');

  // Usage calibrates only an unchanged request prefix. Prompt/tool changes invalidate it.
  const usageThread = fixture(), usageManager = new RequestContext(source(usageThread), config());
  const usageModel = { stream: async () => { throw Error('Unexpected compaction'); } };
  await usageManager.prepare(usageModel, [], new Cancellation());
  usageManager.recordResponse({ ...reply('ok'), usage: { status: 'complete', tokens: { input: 100, output: 1 } } });
  usageThread.messages[1].steps = [{ content: 'ok', uiValidation: '', tools: [] }];
  let prepared = await usageManager.prepare(usageModel, [], new Cancellation());
  assert.equal(prepared.context.source, 'usage+estimate'); assert.ok(prepared.context.tokens >= 100);
  prepared = await usageManager.prepare(usageModel, tools.definitions(), new Cancellation());
  assert.equal(prepared.context.source, 'estimate'); assert.ok(prepared.context.sections.rules > 0);
  assert.ok(!JSON.stringify(prepared.context).includes('Follow the user'));
  console.log('PASS usage calibration, invalidation on tool change, content-free section diagnostics');

  // Failed persistence rolls back only the checkpoint, never receipts; cancellation does not commit it.
  const failureThread = JSON.parse(original); failureThread.messages[1].steps[0].content = 'x'.repeat(30000);
  const before = JSON.stringify(failureThread);
  const broken = new RequestContext(source(failureThread, async () => { throw Error('disk full'); }), config());
  const summaryModel = { stream: async () => reply('short summary') };
  await assert.rejects(broken.prepare(summaryModel, [], new Cancellation()), /disk full/);
  assert.equal(JSON.stringify(failureThread), before);
  const cancelled = new Cancellation();
  const cancelManager = new RequestContext(source(failureThread), config());
  await assert.rejects(cancelManager.prepare({ stream: async () => { cancelled.cancel(); return reply('summary'); } }, [], cancelled));
  assert.equal(JSON.stringify(failureThread), before);
  console.log('PASS failed checkpoint write and cancelled compaction preserve original history');

  // Runtime's default (team-worker) path receives the same context machinery.
  const registry = new ProviderRegistry(); let invocations = 0, toolRuns = 0;
  registry.register({ info: { id: 'test', name: 'Test' }, endpoint: () => '', stream: async req => {
    if (req.usageOrigin?.purpose === 'compaction') return reply('saved work');
    invocations++; return invocations === 1 ? reply('computing', [call('worker', 'execute_code', { code: '/*' + 'x'.repeat(128 * 1024) + '*/return 42;' })]) : reply('worker complete');
  } });
  const runtime = new AgentRuntime(registry, { read: async () => '' });
  const result = await runtime.run({ sessionId: 'worker', config: config(), messages: [{ role: 'user', content: 'work' }],
    tools: { definitions: () => [], execute: async () => { toolRuns++; return 'saved'; } } }, { prepare: async () => {}, checkpoint: async () => {} });
  assert.equal(result.status, 'complete', result.error); assert.equal(toolRuns, 1); assert.ok(result.turn.compaction);
  assert.ok(result.turn.steps[0].tools[0].call.function.arguments.length > 128 * 1024);
  console.log('PASS default runtime/team-worker path batches oversized code history and continues without altering arguments');

  // A checkpoint at the next step survives a crash while that response is still partial.
  const crashed = JSON.parse(JSON.stringify(thread));
  crashed.compaction.firstKeptStep = crashed.messages[1].steps.length;
  crashed.messages[1].steps.push({ content: 'partial text must not replay', tools: [], uiValidation: 'pending' });
  crashed.messages[1].status = 'generating';
  data.threads = [crashed];
  const recovered = parseAppData(JSON.stringify(data)).threads[0];
  const afterCrash = projectedHistory(threadEntries(recovered), recovered.compaction);
  assert.ok(!afterCrash.some(m => m.content.includes('partial text')));
  assert.ok(afterCrash.some(m => m.content.includes('Never repeat writes')));
  console.log('PASS interrupted next-step boundary remains valid on reload without replaying partial prose');

  // Steering is checked during preparation, consumed only on successful admission, and sent once.
  const steerThread = fixture(), steerTurn = { content: '', steps: [] };
  steerThread.messages[1].steps = steerTurn.steps;
  let pending = { id: 's1', mode: 'steer', text: 'New instruction' }, consumed = 0;
  const steerManager = new RequestContext(source(steerThread), config());
  const steeringModel = { stream: async messages => {
    assert.equal(messages.filter(m => m.content === 'New instruction').length, 1); return reply('done');
  } };
  await runAgentLoop({ model: steeringModel, tools: { definitions: () => [], execute: async () => '' }, messages: [], turn: steerTurn, maxSteps: 2,
    prepareRequest: (defs, extra, signal) => steerManager.prepare(steeringModel, defs, signal, extra) }, new Cancellation(), {
    event: () => { steerThread.messages[1].steps = steerTurn.steps; }, checkpoint: async () => {},
    steering: { peek: () => pending, consume: () => { pending = undefined; consumed++; } }
  });
  assert.equal(consumed, 1); assert.equal(steerTurn.steps[0].steering.text, 'New instruction');
  let kept = { id: 's2', mode: 'steer', text: 'keep me' };
  await assert.rejects(runAgentLoop({ model: steeringModel, tools: { definitions: () => [], execute: async () => '' }, messages: [], turn: { content: '', steps: [] }, maxSteps: 2,
    prepareRequest: async () => { throw Error('preparation failed'); } }, new Cancellation(), {
    event: () => {}, checkpoint: async () => {}, steering: { peek: () => kept, consume: () => { kept = undefined; } }
  }), /preparation failed/);
  assert.equal(kept.text, 'keep me');
  console.log('PASS steering appears exactly once and failed preparation leaves it queued');

  // No usage estimate from before compaction leaks into subsequent requests.
  const resetThread = fixture(), resetManager = new RequestContext(source(resetThread), config());
  await resetManager.prepare(summaryModel, [], new Cancellation());
  resetManager.recordResponse({ ...reply(''), usage: { status: 'complete', tokens: { input: 100, output: 1 } } });
  resetThread.messages[1].steps.push({ content: 'large '.repeat(4000), tools: [], uiValidation: '' });
  const reset = await resetManager.prepare(summaryModel, [], new Cancellation());
  assert.ok(resetThread.compaction); assert.equal(reset.context.source, 'estimate');
  console.log('PASS compaction invalidates earlier provider usage');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
