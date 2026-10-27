// Request-prefix regressions through the real runtime, persistence projection and protocol encoders.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
const unitCases = [];
const hypium = { describe: (_name, body) => body(), it: (name, _size, body) => unitCases.push({ name, body }),
  expect: actual => ({ assertEqual: expected => assert.equal(actual, expected), assertTrue: () => assert.equal(actual, true),
    assertFalse: () => assert.equal(actual, false), assertUndefined: () => assert.equal(actual, undefined) }) };
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('Team.test.ets')) source += '\nexport { Fixture };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, console, Observed: cls => cls, setTimeout, clearTimeout, require: id => {
    if (id === '@ohos/hypium') return hypium;
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, 'main/ets', name));
const plain = value => JSON.parse(JSON.stringify(value));
const { AgentRuntime } = from('services/AgentRuntime');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { RequestContext } = from('services/RequestContext');
const { sessionContextSource } = from('services/SessionContext');
const { ToolCatalog } = from('services/ToolCatalog');
const { threadEntries, projectedHistory } = from('model/ContextProjection');
const { defaultConfig, emptyData, parseAppData, requestHistory } = from('model/Conversation');
const { RequestPrefix } = from('model/RequestPrefix');
const { Diagnostics } = from('model/Diagnostics');
const { compactContext } = from('services/ContextCompactor');
const { Cancellation } = from('services/Cancellation');
const { anthropicRequest, responsesRequest } = from('services/providers/WireProtocols');
const { chatRequest } = from('services/providers/ChatCompletionsProtocol');
const { builtinProviderInfos } = from('model/Provider');
const definition = name => ({ type: 'function', promptSnippet: 'Use ' + name, function: {
  name, description: name, parameters: { type: 'object', properties: {}, required: [], additionalProperties: false }
} });
const call = (id, name, args = {}) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (content, toolCalls = []) => ({ content, toolCalls });
function restore(thread) {
  const data = emptyData(); data.threads = [plain(thread)]; data.activeThreadId = thread.id;
  return parseAppData(JSON.stringify(data)).threads[0];
}
async function main() {
  const config = { ...defaultConfig(), configured: true, providerId: 'test', model: 'test', contextWindow: 200000 };
  let thread = { id: 'thread', title: 'Test', updatedAt: 1, messages: [] };
  let environment = 'workspace version 1';
  const sections = () => [{ name: 'identity', content: 'Stable app policy.' }, { name: 'workspace', content: environment, dynamic: true }];
  let allowed = true;
  const tools = { definitions: () => [definition('read_file')].concat(allowed ? [definition('lookup_alpha')] : []),
    execute: async incoming => { assert.equal(incoming.function.name, 'lookup_alpha'); return 'evidence'; } };
  const requests = [], saved = [];
  let failTransport = false;
  let replies = [reply('', [call('lookup-first', 'lookup_alpha')]),
    reply('', [call('lookup', 'lookup_alpha')]), reply('done')];
  const provider = { info: { id: 'test', name: 'Test', protocol: 'chat-completions', defaultBaseUrl: '', defaultModel: 'test' },
    endpoint: url => url, stream: async request => {
      requests.push(plain(request));
      for (const snapshot of request.messages.filter(message => message.runtimeContext)) {
        assert.ok(saved.at(-1).messages.some(message => (message.steps || []).some(step => step.runtimeContext === snapshot.content)),
          'Every visible context snapshot must have passed persistence before transport');
      }
      if (failTransport) throw Error('network down');
      return replies.shift() || reply('done');
    } };
  const registry = new ProviderRegistry(); registry.register(provider);
  const runtime = new AgentRuntime(registry, { read: async () => '' });
  async function run(text, persist = async () => { saved.push(plain(thread)); }) {
    thread.messages.push({ id: 'u' + thread.messages.length, role: 'user', content: text, status: 'complete', error: '' },
      { id: 'a' + thread.messages.length, role: 'assistant', content: '', status: 'generating', error: '', steps: [] });
    const answer = thread.messages.at(-1);
    const off = runtime.subscribe(event => { answer.steps = event.run.turn.steps; answer.content = event.run.turn.content; });
    const result = await runtime.run({ sessionId: thread.id, config, messages: [], tools }, {
      prepare: async () => {}, checkpoint: persist, context: sessionContextSource(thread, sections, persist, () => {})
    });
    answer.status = result.status; answer.error = result.error; off(); return result;
  }
  Diagnostics.start();
  assert.equal((await run('Find evidence')).status, 'complete');
  assert.equal(requests.length, 3);
  assert.equal(requests[0].messages[0].content, requests[1].messages[0].content);
  assert.deepEqual(requests[1].tools, requests[0].tools, 'Direct tool calls leave the complete catalog unchanged');
  assert.deepEqual(requests[1].messages.slice(0, requests[0].messages.length), requests[0].messages);
  assert.deepEqual(requests[2].messages.slice(0, requests[1].messages.length), requests[1].messages);
  assert.equal(thread.messages[1].steps.filter(step => step.runtimeContext !== undefined).length, 1, 'Full catalog needs only the initial context snapshot');
  assert.deepEqual(plain(thread.messages[1].steps.map(step => step.context.prefix.change)), ['cold', 'append', 'append']);
  const logs = Diagnostics.snapshot().logging.records;
  assert.ok(!logs.some(event => event.log.event === 'request_prefix' && event.log.fields.change === 'tools'));
  assert.ok(!JSON.stringify(logs).includes(environment)); Diagnostics.stop();
  console.log('PASS persisted input admission, unchanged system and schemas, deduplicated snapshots and content-free diagnostics');

  thread = restore(thread);
  const history = plain(projectedHistory(threadEntries(thread)));
  assert.deepEqual(plain(requestHistory(thread.messages, '')), history, 'Both history projections retain snapshots in the same order');
  const resumed = await run('Continue'); assert.equal(resumed.status, 'complete', resumed.error);
  const continued = requests.at(-1);
  assert.deepEqual(continued.tools, requests[2].tools, 'Direct catalog survives cold reload');
  assert.deepEqual(continued.messages.slice(0, requests[2].messages.length), requests[2].messages);
  assert.equal(thread.messages.at(-1).steps[0].runtimeContext, undefined, 'No duplicate snapshot after reopening');
  environment = 'workspace version 2';
  assert.equal((await run('Use the updated environment')).status, 'complete');
  const changed = requests.at(-1);
  assert.deepEqual(changed.messages.slice(0, continued.messages.length), continued.messages);
  assert.ok(changed.messages.at(-1).runtimeContext && changed.messages.at(-1).content.includes(environment));
  assert.ok(changed.messages.some(message => message.runtimeContext && message.content.includes('workspace version 1')));
  allowed = false;
  assert.equal((await run('Continue after revocation')).status, 'complete');
  assert.ok(!requests.at(-1).tools.some(tool => tool.function.name === 'lookup_alpha'));
  const denied = new ToolCatalog({ definitions: () => [], execute: async () => { throw Error('revoked'); } });
  assert.equal(denied.definitions().length, 0);
  await assert.rejects(denied.execute(call('denied', 'lookup_alpha'), new Cancellation()), /revoked/);
  const malformed = plain(thread); malformed.messages[1].steps[0].runtimeContext = 3;
  assert.throws(() => restore(malformed));
  console.log('PASS cold reload, cross-turn reuse, append-only environment updates, revocation and persisted-input validation');

  environment = 'admitted before transport failure'; failTransport = true;
  const interrupted = await run('Retain the admitted snapshot'); failTransport = false;
  assert.equal(interrupted.status, 'failed');
  assert.ok(projectedHistory(threadEntries(restore(thread))).some(message => message.runtimeContext && message.content.includes(environment)),
    'An admitted snapshot survives transport failure even without tool calls or steering');

  const beforeFailure = requests.length;
  let checkpoints = 0;
  environment = 'must persist before request';
  const failed = await run('Stop on storage failure', async () => { if (++checkpoints > 1) throw Error('disk full'); });
  assert.equal(failed.status, 'failed'); assert.match(failed.error, /disk full/); assert.equal(requests.length, beforeFailure);
  console.log('PASS failed snapshot admission never reaches model transport');

  const prefixTools = [definition('read_file')];
  const prefixMessages = [{ role: 'system', content: 'Original policy' }, { role: 'user', content: 'original request' },
    { role: 'assistant', content: 'Completed work' }];
  const plan = { messages: prefixMessages.slice(1), previousSummary: '', firstKeptMessageId: 'next', tokensBefore: 1000 };
  let summaryCall;
  const summarize = { stream: async (messages, definitions, signal, onText, options) => {
    summaryCall = { messages: plain(messages), tools: plain(definitions), options }; return reply('Useful checkpoint');
  } };
  const checkpoint = await compactContext(plan, { window: 8192, autoCompact: true, keepRecent: 100 }, summarize,
    new Cancellation(), () => {}, { messages: prefixMessages, tools: prefixTools });
  assert.deepEqual(summaryCall.messages.slice(0, prefixMessages.length), prefixMessages);
  assert.deepEqual(summaryCall.tools, prefixTools); assert.equal(summaryCall.options.usagePurpose, 'compaction');
  assert.equal(checkpoint.summary, 'Useful checkpoint');
  await assert.rejects(compactContext(plan, { window: 8192 }, { stream: async () => reply('bad', [call('bad', 'read_file')]) },
    new Cancellation(), () => {}, { messages: prefixMessages, tools: prefixTools }));
  console.log('PASS summary calls preserve original messages/tools and reject unexpected tool output');

  const compactedThread = { id: 'compact', title: 'Test', updatedAt: 1, messages: [
    { id: 'old-user', role: 'user', content: 'Preserve the evidence', status: 'complete', error: '' },
    { id: 'old-answer', role: 'assistant', content: '', status: 'complete', error: '', steps: [
      { content: 'Evidence '.repeat(2000), tools: [], uiValidation: '', runtimeContext: requests[0].messages.find(message => message.runtimeContext).content }
    ] },
    { id: 'next-user', role: 'user', content: 'Continue', status: 'complete', error: '' },
    { id: 'next-answer', role: 'assistant', content: '', status: 'generating', error: '', steps: [] }
  ] };
  const compactManager = new RequestContext(sessionContextSource(compactedThread, sections, async () => {}, () => {}), config);
  const beforeCompaction = plain(compactManager.inspect(prefixTools).messages);
  const admitted = await compactManager.prepare(summarize, prefixTools, new Cancellation(), [], true);
  assert.ok(summaryCall.messages.length > 2);
  assert.deepEqual(summaryCall.messages.slice(0, -1), beforeCompaction.slice(0, summaryCall.messages.length - 1));
  assert.ok(admitted.runtimeContext && admitted.runtimeContext.includes(environment));
  compactedThread.messages[3].steps.push({ content: '', tools: [], uiValidation: 'pending', runtimeContext: admitted.runtimeContext });
  const retained = await new RequestContext(sessionContextSource(restore(compactedThread), sections, async () => {}, () => {}), config)
    .prepare(summarize, prefixTools, new Cancellation());
  assert.equal(retained.runtimeContext, undefined, 'Re-admitted state survives compaction and reopening');
  console.log('PASS real compaction preserves its routed prefix and restores current context after shadowing');

  const { Fixture } = load(path.join(root, 'test/Team.test'));
  const team = new Fixture(); team.options.contextSections = [{ name: 'workspace', content: 'Shared project' }];
  await team.execute(); assert.equal(team.run.status, 'completed');
  const [first, second] = team.provider.requests;
  assert.equal(first.messages[0].content, second.messages[0].content);
  assert.deepEqual(plain(first.messages[1]), plain(second.messages[1]));
  assert.ok(first.messages[1].content.includes('Shared project'));
  assert.ok(first.messages[2].content.includes('Researcher') && second.messages[2].content.includes('Analyst'));
  console.log('PASS parallel teammates share system and project context while retaining distinct assignments');

  const anthropic = builtinProviderInfos().find(info => info.id === 'anthropic');
  assert.equal(anthropic.promptCaching, true);
  const cached = anthropicRequest('test', prefixMessages, prefixTools, 4096, true);
  assert.deepEqual(plain(cached.cache_control), { type: 'ephemeral' });
  assert.equal(cached.system[0].text, 'Original policy');
  assert.deepEqual(plain(cached.system[0].cache_control), { type: 'ephemeral' });
  assert.equal(anthropicRequest('test', prefixMessages, prefixTools).cache_control, undefined, 'Compatible endpoints remain opt-in');
  for (const body of [chatRequest('test', prefixMessages, prefixTools), responsesRequest('test', prefixMessages, prefixTools)]) {
    assert.ok(!JSON.stringify(body).includes('runtimeContext') && !JSON.stringify(body).includes('cache_control'));
  }
  const tracker = new RequestPrefix(); tracker.observe(prefixMessages, prefixTools);
  assert.equal(tracker.observe([{ role: 'system', content: 'Changed policy' }], prefixTools).change, 'system');
  assert.equal(tracker.observe(prefixMessages, prefixTools).change, 'system');
  assert.equal(tracker.observe(prefixMessages.slice(0, 2), prefixTools).change, 'history');
  console.log('PASS provider-scoped Anthropic cache boundaries, clean wire encoding and explicit prefix-change classification');
  for (const name of ['Team', 'ChatTeam', 'ContextManagement', 'SessionService']) load(path.join(root, 'test', name + '.test')).default();
  for (const test of unitCases) {
    try { await test.body(); }
    catch (error) { error.message = test.name + ': ' + error.message; throw error; }
  }
  console.log(`PASS ${unitCases.length} existing Team, ChatTeam, ContextManagement and SessionService unit cases on the host`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
