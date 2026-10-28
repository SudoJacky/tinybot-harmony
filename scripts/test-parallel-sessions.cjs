// Source-only behavioral regressions: real session/runtime/viewmodel, deterministic network and ordered storage.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true,
  } }).outputText, { exports, console, setTimeout, clearTimeout, Observed: x => x,
    require: id => id.startsWith('@kit.') ? {} : load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { emptyData, parseAppData } = from('model/Conversation');
const { defaultProductivity } = from('model/Productivity');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { modelConfig } = from('model/ProviderProfiles');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { AgentRuntime } = from('services/AgentRuntime');
const { SessionService } = from('services/SessionService');
const { ChatViewModel } = from('viewmodel/ChatViewModel');
const { Cancellation, RunCancelledError } = from('services/Cancellation');
const { ToolApproval } = from('services/ToolApproval');
const { BrowserSession } = from('services/BrowserSession');
const copy = value => JSON.parse(JSON.stringify(value));
const gate = () => { let open; const promise = new Promise(resolve => { open = resolve; }); return { promise, open }; };
async function until(check) {
  for (let i = 0; i < 100; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 1)); }
  assert.ok(check(), 'Expected asynchronous operation did not reach its barrier');
}
async function fixture(configure = () => {}) {
  const data = emptyData();
  const profile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: '', noApiKey: true, enabled: true, models: ['model-a', 'model-b'], contextWindow: 32768 };
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions(); data.productivity.options.autoMemory = false;
  data.providerProfiles = [profile]; data.config = modelConfig([profile], { providerId: 'test', modelId: 'model-a' }, data.config);
  data.threads = ['a', 'b'].map(id => ({ id, title: id, titleEdited: true, updatedAt: 1,
    messages: [], draft: '', pendingInputs: [], modelRef: { providerId: 'test', modelId: 'model-a' } }));
  data.activeThreadId = 'a';
  configure(data);
  let sequence = 0, pending = Promise.resolve(); const errors = [], requests = [];
  const repository = { saved: JSON.stringify(data), beforeSave: async () => {}, load: async () => parseAppData(repository.saved),
    save(value) {
      const captured = JSON.stringify(value);
      const result = pending.catch(() => {}).then(async () => { await repository.beforeSave(JSON.parse(captured)); repository.saved = captured; });
      pending = result; return result;
    } };
  const provider = { info: { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: '', defaultModel: 'model-a' },
    endpoint: () => 'https://example.com',
    stream(request, cancellation, onText) {
      return new Promise((resolve, reject) => {
        const remove = cancellation.onCancel(() => reject(new RunCancelledError()));
        requests.push({ request, cancellation, text: onText, finish(content, toolCalls = []) { remove(); resolve({ content, toolCalls }); } });
      });
    } };
  const providers = new ProviderRegistry(); providers.register(provider);
  const credentials = { read: async () => '', write: async () => {}, remove: async () => {} };
  const resources = { createId: () => 'id-' + ++sequence, ensureWorkspace: async () => {},
    configureProviders: () => {}, reportError: (event, error) => errors.push({ event, error }),
    tools: () => ({ definitions: () => [], execute: async () => 'ok' }) };
  const session = new SessionService(repository, new AgentRuntime(providers, credentials), credentials, resources);
  const app = new ChatViewModel(); await app.initialize(session);
  return { session, app, repository, requests, resources, errors };
}
function thread(f, id, saved = false) { return (saved ? JSON.parse(f.repository.saved) : f.session.snapshot()).threads.find(t => t.id === id); }
async function start(f, id, prompt = id) {
  assert.equal(await f.session.selectThread(id), true);
  f.session.setDraft(prompt);
  return { done: f.session.send() };
}
async function main() {
  {
    const f = await fixture(); let updatesA = 0, updatesB = 0;
    f.app.setDraft('A'); const a = f.app.send(() => updatesA++); await until(() => f.requests.length === 1);
    assert.equal(await f.app.selectThread('b'), true); assert.equal(f.app.busy, false); assert.equal(f.session.hasActiveRuns, true);
    assert.equal(await f.app.selectModel('test', 'model-b'), true);
    f.app.setDraft('B'); const b = f.app.send(() => updatesB++); await until(() => f.requests.length === 2);
    assert.deepEqual(copy(f.session.runningThreadIds).sort(), ['a', 'b']);
    assert.equal(f.requests[0].request.model, 'model-a'); assert.equal(f.requests[1].request.model, 'model-b');
    f.requests[0].text('A streaming'); assert.equal(f.app.active.id, 'b'); assert.equal(f.app.busy, true);
    assert.equal(f.app.active.messages.at(-1).content, '');
    assert.equal(f.app.threads.find(t => t.id === 'a').messages.at(-1).content, 'A streaming');
    assert.equal(await f.session.deleteThread('a'), false); assert.equal(await f.session.archiveThread('a'), false);
    assert.equal(await f.session.selectThread('a'), true);
    f.session.setDraft('A queued'); await f.session.enqueueInput('followUp');
    await f.session.stop(); await a;
    assert.equal(f.requests[0].cancellation.cancelled, true); assert.equal(f.requests[1].cancellation.cancelled, false);
    assert.equal(thread(f, 'a').pendingInputs.length, 1); assert.equal(thread(f, 'a').queuePaused, true);
    assert.equal(await f.session.selectThread('b'), true);
    const before = updatesB; f.requests[1].text('B streaming'); assert.ok(updatesB > before, 'A completion must retain B output subscription');
    f.requests[1].finish('B complete'); await b;
    assert.equal(thread(f, 'a', true).messages.at(-1).status, 'stopped');
    assert.equal(thread(f, 'b', true).messages.at(-1).content, 'B complete'); assert.equal(f.session.hasActiveRuns, false);
    console.log('PASS simultaneous requests, model isolation, background deltas, independent stop/queue, viewmodel subscriptions and persistence');
  }
  {
    const f = await fixture(), a = await start(f, 'a'); await until(() => f.requests.length === 1);
    f.session.setDraft('follow A'); await f.session.enqueueInput('followUp');
    assert.equal(await f.session.selectThread('b'), true); await f.session.selectModel('test', 'model-b');
    const b = await start(f, 'b'); await until(() => f.requests.length === 2);
    f.requests[0].finish('first A'); await until(() => f.requests.length === 3);
    assert.equal(f.requests[2].request.model, 'model-a');
    assert.ok(f.requests[2].request.messages.some(m => m.content === 'follow A'));
    assert.equal(f.app.active.id, 'b'); assert.equal(f.app.generating, true);
    f.requests[2].finish('second A'); await a.done;
    assert.equal(f.app.generating, true, 'A finalization must not mark B idle');
    f.requests[1].finish('B'); await b.done;
    assert.equal(thread(f, 'a', true).messages.length, 4); assert.equal(thread(f, 'b', true).messages.length, 2);
    console.log('PASS background queue uses its original model and finalization cannot overwrite selected-run state');
  }
  {
    const f = await fixture(), a = await start(f, 'a'); await until(() => f.requests.length === 1);
    assert.equal(await f.session.newThread(), true); const id = f.session.snapshot().activeThreadId;
    const blocked = gate(); let saving = false;
    f.repository.beforeSave = async value => { if (value.config.model === 'model-b' && !saving) { saving = true; await blocked.promise; } };
    const choose = f.session.selectModel('test', 'model-b'); await until(() => saving);
    f.requests[0].text('during metadata write'); f.requests[0].finish('A survives');
    f.session.setDraft('new draft', id); blocked.open(); assert.equal(await choose, true); await a.done;
    assert.equal(thread(f, 'a').messages.at(-1).content, 'A survives');
    assert.equal(thread(f, 'a', true).messages.at(-1).content, 'A survives');
    assert.equal(thread(f, id, true).draft, 'new draft');
    console.log('PASS new chat and delayed settings commit retain live background transcript and concurrent draft');
  }
  {
    const f = await fixture(), a = await start(f, 'a'); await until(() => f.requests.length === 1);
    await f.session.selectThread('b'); const workspace = gate(); let replacing = false;
    f.resources.ensureWorkspace = async () => { replacing = true; await workspace.promise; };
    const archive = f.session.archiveThread('b'); await until(() => replacing);
    f.requests[0].finish('Finished during workspace lookup'); await a.done;
    workspace.open(); assert.equal(await archive, true);
    assert.equal(thread(f, 'a').messages.at(-1).content, 'Finished during workspace lookup');
    assert.equal(thread(f, 'a', true).messages.at(-1).status, 'complete');
    console.log('PASS archiving an idle chat cannot restore a stale snapshot of a run completed during workspace IO');
  }
  {
    const f = await fixture(data => {
      for (let i = 0; i < 4; i++) {
        data.threads[0].messages.push({ id: 'u-' + i, role: 'user', content: 'historical input '.repeat(50), status: 'complete', error: '' });
        data.threads[0].messages.push({ id: 'r-' + i, role: 'assistant', content: 'historical answer '.repeat(50), status: 'complete', error: '' });
      }
    });
    const compacting = f.session.compactHistory(); await until(() => f.requests.length === 1);
    const b = await start(f, 'b'); await until(() => f.requests.length === 2);
    f.requests[0].finish('short summary'); await compacting;
    assert.equal(f.app.active.id, 'b'); assert.equal(f.app.generating, true); assert.equal(thread(f, 'b').compaction, undefined);
    f.requests[1].finish('B complete'); await b.done;
    assert.equal(thread(f, 'a', true).compaction.summary, 'short summary'); assert.equal(thread(f, 'a', true).messages.length, 8);
    console.log('PASS manual compaction runs beside another conversation and persists only its own context');
  }
  {
    const f = await fixture(), a = await start(f, 'a'); await until(() => f.requests.length === 1);
    const b = await start(f, 'b'); await until(() => f.requests.length === 2);
    f.repository.beforeSave = async () => { throw Error('disk unavailable'); };
    f.session.setDraft('unsaved'); await f.session.flushDraft(); await Promise.all([a.done, b.done]);
    assert.ok(f.session.state.saveError.includes('disk unavailable'));
    assert.ok(f.requests.every(r => r.cancellation.cancelled)); assert.equal(f.session.canNavigate, false);
    f.repository.beforeSave = async () => {}; await f.session.retrySave();
    assert.equal(f.session.state.saveError, ''); assert.equal(f.session.canNavigate, true);
    assert.equal(thread(f, 'b', true).draft, 'unsaved');
    console.log('PASS shared storage failure cancels every run, retains error until explicit retry and saves recovery state');
  }
  {
    const f = await fixture(), a = await start(f, 'a'); await until(() => f.requests.length === 1);
    const b = await start(f, 'b'); await until(() => f.requests.length === 2);
    const barrier = gate(); let writing = false;
    f.repository.beforeSave = async value => {
      if (!writing && value.extensions.skills.some(s => s.name === 'from-a')) { writing = true; await barrier.promise; }
    };
    const skill = name => ({ id: name, type: 'function', function: { name: 'skill_manage', arguments: JSON.stringify({
      action: 'create', document: `---\nname: ${name}\ndescription: Parallel regression\n---\nUse this skill.` }) } });
    f.requests[0].finish('', [skill('from-a')]); f.requests[1].finish('', [skill('from-b')]);
    await until(() => writing); const permission = f.session.setBrowserPolicy('enabled'); barrier.open(); await permission;
    await until(() => f.requests.length === 4); f.requests[2].finish('done'); f.requests[3].finish('done'); await Promise.all([a.done, b.done]);
    const saved = JSON.parse(f.repository.saved);
    assert.ok(saved.extensions.skills.some(s => s.name === 'from-a')); assert.ok(saved.extensions.skills.some(s => s.name === 'from-b'));
    assert.equal(saved.extensions.browserPolicy, 'enabled');
    for (const id of ['a', 'b']) assert.equal(thread(f, id).messages.at(-1).steps[0].tools[0].status, 'complete');
    console.log('PASS concurrent tool resource writes and browser preference commit serialize without lost updates');
  }
  {
    const f = await fixture(), setup = gate(); let discovering = false;
    f.resources.testMcp = async () => { discovering = true; await setup.promise; return 1; };
    const a = await start(f, 'a'); await until(() => f.requests.length === 1);
    f.requests[0].finish('', [{ id: 'mcp', type: 'function', function: { name: 'mcp_manage', arguments: JSON.stringify({
      action: 'save', name: 'Remote', url: 'https://example.com/mcp', auth: 'none' }) } }]);
    await until(() => discovering);
    const b = await start(f, 'b'); await until(() => f.requests.length === 2);
    f.requests[1].finish('B while MCP waits'); await b.done;
    setup.open(); await until(() => f.requests.length === 3); f.requests[2].finish('A with MCP'); await a.done;
    assert.equal(JSON.parse(f.repository.saved).productivity.servers[0].name, 'Remote');
    assert.equal(thread(f, 'b', true).messages.at(-1).content, 'B while MCP waits');
    console.log('PASS slow MCP setup leaves navigation and other conversations available');
  }
  {
    const approval = new ToolApproval(), first = new Cancellation(), second = new Cancellation(), third = new Cancellation();
    const a = approval.request('A', 'first', first); await until(() => approval.title === 'A');
    const b = approval.request('B', 'second', second); const rejected = assert.rejects(b, e => e.code === 'CANCELLED');
    const c = approval.request('C', 'third', third); second.cancel(); await rejected;
    assert.equal(approval.title, 'A'); approval.respond(true); await a;
    await until(() => approval.title === 'C'); approval.respond(true); await c;
    console.log('PASS shared interaction queue preserves ownership and removes a cancelled waiting request');
  }
  {
    const browser = new BrowserSession(), owner = new Cancellation(), other = new Cancellation();
    browser.attach({ open: async () => {}, snapshot: async () => ({}), act: async () => {}, userBack: () => false, close: () => {} });
    browser.updatePolicy('enabled'); await browser.acquire('a', 'https://example.com', 'test', owner);
    browser.takeOver(); let ownerResumed = false;
    const waiting = browser.wait(owner).then(() => { ownerResumed = true; });
    await browser.wait(other); assert.equal(ownerResumed, false);
    browser.handoff(); await waiting; browser.release(owner);
    console.log('PASS browser handoff pauses only the owning conversation');
  }
}
const watchdog = setTimeout(() => { throw Error('Parallel session tests did not finish'); }, 30000);
main().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(watchdog));
