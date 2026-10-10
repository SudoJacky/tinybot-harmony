// Real session/runtime code with scripted providers: no network, device or paid model requests.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
    { exports, setTimeout, clearTimeout, console, require: id => load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { applyMemoryOperations, parseMemoryOperations, MEMORY_REVIEW_PROMPT, memoryReviewTurns } = from('model/MemoryMaintenance');
const { emptyData, parseAppData } = from('model/Conversation');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { defaultProductivity } = from('model/Productivity');
const { modelConfig } = from('model/ProviderProfiles');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { AgentRuntime } = from('services/AgentRuntime');
const { SessionService } = from('services/SessionService');
const reply = (content = 'done', toolCalls = []) => ({ content, toolCalls });
const memoryCall = operations => ({ id: 'memory-call', type: 'function', function: { name: 'memory', arguments: JSON.stringify({ operations: JSON.stringify(operations) }) } });
const entry = (id, content, threadId = '', automatic = true) => ({ id, content, threadId, automatic, updatedAt: 1 });
const op = (action, fields = {}) => ({ action, sourceMessageId: 'user', ...fields });
let ids = 0;
const apply = (memories, ops, background = false) => applyMemoryOperations(memories, ops, 'chat', ['user'], () => 'new-' + ++ids, background);
function seed() {
  const data = emptyData(), profile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: '', noApiKey: true, enabled: true, models: ['model'], contextWindow: 32768 };
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
  data.providerProfiles = [profile]; data.config = modelConfig([profile], { providerId: 'test', modelId: 'model' }, data.config);
  data.threads = [{ id: 'chat', title: 'Test', titleEdited: true, updatedAt: 1, messages: [], draft: '', modelRef: { providerId: 'test', modelId: 'model' } }];
  data.activeThreadId = 'chat'; return data;
}
async function fixture(data = seed()) {
  const requests = [], errors = [], logs = [], writes = [];
  const repository = { saved: JSON.stringify(data), beforeSave: async () => {}, load: async () => parseAppData(repository.saved),
    save: async data => { const text = JSON.stringify(data); await repository.beforeSave(data); repository.saved = text; writes.push(text); } };
  const provider = { info: { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: '', defaultModel: 'model' }, endpoint: b => b,
    respond: async request => request.messages[0]?.content === MEMORY_REVIEW_PROMPT ? reply('[]') : reply(),
    stream: async (request, signal, onText) => { requests.push(request); const result = await provider.respond(request); signal.check(); onText(result.content); return result; } };
  const registry = new ProviderRegistry(); registry.register(provider);
  const keys = { read: async () => '', write: async () => {}, remove: async () => {} };
  const resources = { createId: () => 'id-' + ++ids, ensureWorkspace: async () => {}, configureProviders: () => {},
    tools: () => ({ definitions: () => [], execute: async () => { throw Error('Unexpected tool'); } }), reportError: s => errors.push(s), reportMemory: s => logs.push(s) };
  const session = new SessionService(repository, new AgentRuntime(registry, keys), keys, resources); await session.initialize();
  return { session, provider, repository, requests, errors, logs, writes, send: async text => { session.setDraft(text); await session.send(); } };
}
async function settle() { for (let i = 0; i < 300; i++) await Promise.resolve(); }
async function until(test) { for (let i = 0; i < 600; i++) { if (test()) return; await Promise.resolve(); } throw Error('Condition did not settle'); }
function gate() { let open; const promise = new Promise(resolve => { open = resolve; }); return { promise, open }; }
const isReview = request => request.messages[0]?.content === MEMORY_REVIEW_PROMPT;
async function main() {
  const original = [entry('old', '用户喜欢长回答'), entry('manual', '用户偏好中文', '', false), entry('other', '项目约定', 'other')];
  const changed = apply(original, [op('update', { id: 'old', content: '用户喜欢简短回答' }), op('add', { scope: 'thread', content: '项目使用 ArkTS' })]);
  assert.equal(changed.memories[0].id, 'old'); assert.equal(changed.memories[0].content, '用户喜欢简短回答');
  assert.equal(original[0].content, '用户喜欢长回答'); assert.equal(changed.memories.at(-1).threadId, 'chat');
  assert.equal(changed.memories[0].sourceMessageId, 'user'); assert.equal(changed.receipt.updated, 1);
  for (const id of ['manual', 'other', 'missing']) assert.throws(() => apply(original, [op('update', { id, content: 'wrong' })]));
  assert.throws(() => apply(original, [op('add', { scope: 'global', content: 'new' }), op('remove', { id: 'manual' })]));
  assert.equal(original.length, 3);
  assert.throws(() => apply(original, [op('remove', { id: 'old' })], true));
  assert.throws(() => apply(original, [op('add', { scope: 'global', content: 'x', sourceMessageId: 'assistant' })]));
  for (const bad of ['null', '{}', '[null]', '[{"action":"update","id":"old"}]', '[{"action":"add","scope":"other","content":"x"}]']) assert.throws(() => parseMemoryOperations(bad));
  assert.equal(apply([entry('existing', 'Prefers  Chinese')], [op('add', { scope: 'global', content: 'prefers chinese' })]).receipt.duplicates, 1);
  assert.equal(apply([entry('local', 'same', 'other')], [op('add', { scope: 'global', content: 'same' })]).receipt.added, 1);
  const full = Array.from({ length: 100 }, (_, i) => entry('m' + i, 'fact ' + i));
  assert.throws(() => apply(full, [op('add', { scope: 'global', content: 'overflow' })]), /100/);
  assert.equal(apply(full, [op('add', { scope: 'global', content: 'replacement' }), op('remove', { id: 'm0' })]).memories.length, 100);
  const chars = Array.from({ length: 8 }, (_, i) => entry('m' + i, String(i) + 'x'.repeat(1999)));
  assert.throws(() => apply(chars, [op('add', { scope: 'global', content: 'overflow' })]), /16000/);
  assert.equal(apply(chars, [op('update', { id: 'm0', content: 'short' }), op('add', { scope: 'global', content: 'fits' })]).receipt.added, 1);
  console.log('PASS scoped updates, manual protection, provenance, duplicate detection and atomic count/character budgets');

  const f = await fixture(); let calls = 0;
  f.provider.respond = async () => ++calls === 1 ? reply('', [memoryCall([{ action: 'add', scope: 'global', content: '用户喜欢简短回答' }])]) : reply('saved');
  await f.send('请记住我喜欢简短回答');
  assert.equal(f.requests.length, 2); assert.equal(f.session.snapshot().productivity.memories.length, 1);
  const sourceId = f.session.snapshot().threads[0].messages[0].id;
  assert.equal(f.session.snapshot().productivity.memories[0].sourceMessageId, sourceId);
  assert.ok(f.requests[1].messages.some(m => m.role === 'tool' && JSON.parse(m.content).success));
  // Once the first tool receipt exists, the runtime also advertises read_tool_result.
  const frozen = f.requests[1].messages[0].content;
  await f.send('继续'); assert.equal(f.requests[2].messages[0].content, frozen);
  const restored = await fixture(await f.repository.load()); await restored.send('重启后继续');
  assert.equal(restored.requests[0].messages[0].content, frozen);
  await f.session.newThread(); await f.send('你好'); await settle();
  assert.ok(f.requests.at(-1).messages[0].content.includes('用户喜欢简短回答'));
  const edited = f.session.snapshot().productivity; edited.memories[0].content = '手动更新'; edited.memories[0].automatic = false;
  assert.equal(await f.session.saveProductivity(edited), true); await f.send('再继续');
  assert.ok(f.requests.at(-1).messages[0].content.includes('手动更新'));
  console.log('PASS real memory tool receipts, immediate durable writes, frozen snapshots across restart and manual invalidation');

  const failed = await fixture(); let attempts = 0;
  failed.provider.respond = async () => ++attempts === 1 ? reply('', [memoryCall([{ action: 'add', scope: 'global', content: 'must not land' }])]) : reply('could not save');
  failed.repository.beforeSave = async data => { if (data.productivity.memories.length) throw Error('disk full'); };
  await failed.send('remember'); assert.equal(failed.session.snapshot().productivity.memories.length, 0);
  assert.equal((await failed.repository.load()).productivity.memories.length, 0); assert.ok(failed.errors.some(e => e.includes('disk full')));
  console.log('PASS failed persistence never publishes a successful memory mutation');

  for (const mode of ['disabled', 'readonly']) {
    const data = seed(); data.productivity.options[mode === 'disabled' ? 'autoMemory' : 'readOnly'] = mode === 'readonly';
    const blocked = await fixture(data);
    for (let i = 0; i < 10; i++) await blocked.send('turn ' + i);
    assert.equal(blocked.requests.length, 10); assert.ok(blocked.requests.every(r => !r.tools.some(t => t.function.name === 'memory')));
  }
  console.log('PASS disabled and read-only modes suppress tool writes and periodic reviews');

  const bg = await fixture(), hold = gate(); let reviewRequest;
  bg.provider.respond = async request => {
    if (!isReview(request)) return reply('Assistant speculation should not become user facts');
    reviewRequest = request; await hold.promise;
    const evidence = JSON.parse(request.messages[1].content).conversation;
    return reply(JSON.stringify([{ action: 'add', scope: 'thread', content: '项目使用 ArkTS', sourceMessageId: evidence.find(m => m.role === 'user').id }]));
  };
  for (let i = 0; i < 9; i++) await bg.send('用户消息 ' + i);
  assert.equal(bg.requests.filter(isReview).length, 0);
  await bg.send('第十轮'); await until(() => reviewRequest);
  assert.equal(bg.session.state.phase, 'idle'); assert.equal(bg.session.snapshot().productivity.memories.length, 0);
  await bg.send('复盘时继续聊天'); assert.equal(bg.session.snapshot().threads[0].messages.length, 22);
  assert.equal(bg.requests.filter(isReview).length, 1);
  const payload = JSON.parse(reviewRequest.messages[1].content);
  assert.equal(payload.conversation.filter(m => m.role === 'user').length, 10);
  assert.ok(payload.conversation.some(m => m.role === 'assistant'));
  hold.open(); await until(() => bg.session.snapshot().productivity.memories.length === 1); await settle();
  assert.equal(bg.session.snapshot().productivity.memories[0].threadId, 'chat');
  const checkpoint = await bg.repository.load(); assert.equal(memoryReviewTurns(checkpoint.threads[0]).length, 1);
  assert.equal(await bg.session.refreshMemoryContext(), true);
  assert.ok(bg.session.snapshot().threads[0].memorySnapshot.includes('项目使用 ArkTS'));
  assert.ok(!checkpoint.threads[0].memorySnapshot.includes('项目使用 ArkTS'));
  const again = await fixture(checkpoint);
  for (let i = 0; i < 8; i++) await again.send('next ' + i);
  assert.equal(again.requests.filter(isReview).length, 0);
  await again.send('next 9'); await settle(); assert.equal(again.requests.filter(isReview).length, 1);
  assert.ok(again.session.snapshot().threads[0].memoryReview);
  console.log('PASS periodic background review, role-labelled context, foreground responsiveness and durable review cursor');

  const raceData = seed(); raceData.productivity.memories = [entry('old', 'before')];
  const race = await fixture(raceData), late = gate(); let started = false;
  race.provider.respond = async request => {
    if (!isReview(request)) return reply(); started = true; await late.promise;
    const source = JSON.parse(request.messages[1].content).conversation[0].id;
    return reply(JSON.stringify([{ action: 'update', id: 'old', content: 'stale automatic update', sourceMessageId: source }]));
  };
  for (let i = 0; i < 10; i++) await race.send('message ' + i);
  await until(() => started);
  const manual = race.session.snapshot().productivity; manual.memories[0].content = 'new manual edit'; manual.memories[0].automatic = false;
  assert.equal(await race.session.saveProductivity(manual), true); late.open(); await settle();
  assert.equal(race.session.snapshot().productivity.memories[0].content, 'new manual edit');
  assert.equal(race.session.snapshot().threads[0].memoryReviewedMessageId, undefined);
  assert.ok(race.session.snapshot().threads[0].memoryReview.error); assert.ok(race.errors.length > 0);
  console.log('PASS late background results cannot overwrite newer edits; failed review remains retryable and observable');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
