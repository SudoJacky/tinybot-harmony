// Deterministic integration checks: real request/context code, scripted providers, no network or device.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map(), logs = [], usage = [];
let httpScript = () => { throw Error('Unexpected network request'); };
class Decoder {
  decoder = new TextDecoder();
  decodeToString(bytes, options) { return this.decoder.decode(bytes, options); }
}
const kits = {
  '@kit.ArkTS': { util: { TextDecoder: Decoder, generateRandomUUID: () => 'request-' + usage.length } },
  '@kit.PerformanceAnalysisKit': { hilog: Object.fromEntries(['info', 'warn', 'error'].map(name => [name, (...args) => logs.push(args)])) },
  '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, createHttp: () => {
    const handlers = {}; let closed = false;
    return { on: (name, cb) => { handlers[name] = cb; }, destroy: () => { closed = true; },
      requestInStream: (url, options, callback) => httpScript({ url, options, callback,
        emit: (name, text) => { if (!closed) handlers[name]?.(name === 'dataReceive' ? new TextEncoder().encode(text).buffer : text); } }) };
  } } }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText,
    { exports, setTimeout, clearTimeout, console, Error, Uint8Array, Observed: cls => cls, require: id => {
      if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
      if (!kits[id]) throw Error('Unexpected import: ' + id);
      return kits[id];
    } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { parseSkill, expandSkillCommand } = from('model/Skills');
const { emptyData, parseAppData, requestHistory } = from('model/Conversation');
const { planContextCompaction } = from('model/ConversationContext');
const { threadEntries, projectedHistory } = from('model/ContextProjection');
const { RequestContext } = from('services/RequestContext');
const { ContextTools } = from('services/ContextTools');
const { sessionContextSource } = from('services/SessionContext');
const { Cancellation } = from('services/Cancellation');
const { runAgentLoop } = from('services/AgentLoop');
const { ContextOverflowError, httpProviderError } = from('services/providers/ProviderErrors');
const { ProtocolProvider } = from('services/providers/ProtocolProvider');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { WebTools } = from('services/WebTools');
const { RuleTools } = from('services/RuleTools');
const { chatRequest } = from('services/providers/ChatCompletionsProtocol');
const { responsesRequest, anthropicRequest } = from('services/providers/WireProtocols');
const { buildTimeline } = from('model/ProcessPresentation');
const reply = (content, toolCalls = []) => ({ content, toolCalls });
const call = (id, name, args = {}) => ({ id, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const config = () => ({ configured: true, providerId: 'test', model: 'test', baseUrl: '', credentialAlias: '', systemPrompt: '', contextWindow: 32768 });
const fixture = () => ({ id: 'chat', title: 'Test', updatedAt: 1, messages: [
  { id: 'u1', role: 'user', content: 'Finish the job', status: 'complete', error: '' },
  { id: 'a1', role: 'assistant', content: '', status: 'generating', error: '', steps: [] }
] });
const source = (thread, persist = async () => {}) => sessionContextSource(thread, () => [{ name: 'identity', content: 'Complete the task.' }], persist, () => {});
const restore = thread => {
  const data = emptyData(); data.threads = [thread]; data.activeThreadId = thread.id;
  return parseAppData(JSON.stringify(data)).threads[0];
};

async function main() {
  const skill = parseSkill('---\nname: report\ndescription: Report guidance\ndisable-model-invocation: true\n---\nUse this exact procedure.');
  skill.files = [{ path: 'references/source.md', content: 'evidence' }];
  const thread = fixture(); thread.messages[0].content = '/skill:report\nReview the source';
  thread.messages[0].skillPrompt = expandSkillCommand(thread.messages[0].content, [skill]);
  thread.messages[1].status = 'complete'; thread.messages[1].content = 'done';
  const original = thread.messages[0].skillPrompt;
  skill.document = skill.document.replace('exact procedure', 'changed procedure');
  skill.enabled = false;
  const restored = restore(thread);
  assert.equal(restored.messages[0].content, '/skill:report\nReview the source');
  const history = requestHistory(restored.messages, '');
  assert.equal(history[0].content, original);
  assert.ok(original.includes('Use this exact procedure.') && original.includes('references/source.md'));
  assert.ok(original.endsWith('Review the source') && !original.includes('description:'));
  assert.throws(() => expandSkillCommand('/skill:report task', [skill]));
  assert.equal(expandSkillCommand('ordinary task', [skill]), undefined);
  restored.messages[0].skillPrompt = 42; assert.throws(() => restore(restored), /Skill/);
  console.log('PASS explicit Skill body, arguments and references survive reload independently of later skill edits');

  const workspace = new WorkspaceTools({});
  const readonly = new RuleTools(workspace, true);
  const manager = new RequestContext(source(fixture()), config());
  const readPrompt = manager.inspect(readonly.definitions());
  assert.ok(readPrompt.messages[0].content.includes('read_file_lines'));
  assert.ok(!readPrompt.messages[0].content.includes('write_file') && !readPrompt.messages[0].content.includes('edit_file'));
  const writePrompt = manager.inspect(workspace.definitions());
  assert.ok(writePrompt.messages[0].content.includes('write_file 会覆盖同名文件'));
  assert.ok(writePrompt.context.tokens > readPrompt.context.tokens);
  const web = new WebTools({}).definitions();
  const webPrompt = manager.inspect(web).messages[0].content;
  for (const tool of web) {
    assert.ok(webPrompt.includes(tool.function.name));
    for (const guideline of tool.promptGuidelines) {
      assert.ok(webPrompt.includes(guideline));
      assert.ok(!readPrompt.messages[0].content.includes(guideline));
    }
  }
  const defs = workspace.definitions();
  defs[0].promptGuidelines = ['shared rule', 'shared rule']; defs[1].promptGuidelines = ['shared rule'];
  assert.equal(manager.inspect(defs).messages[0].content.split('shared rule').length - 1, 1);
  for (const request of [chatRequest('test', [], defs), responsesRequest('test', [], defs), anthropicRequest('test', [], defs)]) {
    const json = JSON.stringify(request.tools);
    assert.ok(!json.includes('promptSnippet') && !json.includes('promptGuidelines') && !json.includes('shared rule'));
  }
  const calibrator = new RequestContext(source(fixture()), config());
  await calibrator.prepare({}, defs, new Cancellation());
  calibrator.recordResponse({ ...reply('ok'), usage: { status: 'complete', tokens: { input: 99, output: 1 } } });
  defs[0].promptGuidelines = ['changed rule'];
  assert.equal(calibrator.inspect(defs).context.source, 'estimate');
  console.log('PASS active tools determine prompt guidance and budgeting; local metadata never leaks into wire schemas');

  const fileThread = fixture();
  fileThread.messages[1].steps = [
    { content: 'read source '.repeat(800), uiValidation: '', tools: [{ call: call('r', 'read_file_lines', { path: 'src/a.ets' }), status: 'complete', output: '{}' }] },
    { content: 'write result '.repeat(800), uiValidation: '', tools: [{ call: call('w', 'write_file', { path: 'out/report.md', content: 'done' }), status: 'complete', output: '{}' }] },
    { content: 'failed write', uiValidation: '', tools: [{ call: call('f', 'write_file', { path: 'not-written.md' }), status: 'failed', output: 'failed' }] }
  ];
  const files = new RequestContext(source(fileThread), { ...config(), contextWindow: 8192 });
  const summarizer = { stream: async () => reply('Completed work.') };
  await files.prepare(summarizer, [], new Cancellation(), [], true);
  assert.deepEqual(JSON.parse(JSON.stringify(fileThread.compaction.fileOperations)), { readFiles: ['src/a.ets'], modifiedFiles: ['out/report.md'] });
  fileThread.messages[1].steps.push({ content: 'edit', uiValidation: '', tools: [
    { call: call('e', 'edit_file', { path: 'out/report.md' }), status: 'complete', output: '{}' },
    { call: call('n', 'write_file', { path: 'next.md' }), status: 'complete', output: '{}' }
  ] });
  // Force the entire completed prefix into a second summary; duplicates remain deduplicated.
  const plan = planContextCompaction(threadEntries(fileThread), fileThread.compaction, 0, 1000);
  const { compactContext } = from('services/ContextCompactor');
  const checkpoint = await compactContext(plan, { window: 32768 }, summarizer, new Cancellation(), () => {});
  fileThread.compaction = checkpoint;
  const after = restore(fileThread);
  const summary = projectedHistory(threadEntries(after), after.compaction)[0].content;
  assert.ok(summary.includes('src/a.ets') && summary.includes('out/report.md') && summary.includes('next.md'));
  assert.ok(!summary.includes('not-written.md'));
  assert.equal(checkpoint.fileOperations.modifiedFiles.filter(p => p === 'out/report.md').length, 1);
  after.compaction.fileOperations.readFiles = [42]; assert.throws(() => restore(after), /file operations/);
  console.log('PASS successful file receipts remain structured across repeated compaction/reload without inventing failed writes');

  async function overflowRun(mode) {
    const thread = fixture(), turn = { content: '', steps: [] }, signal = new Cancellation();
    let requests = 0, summaries = 0, writes = 0, consumed = 0, pending;
    const cfg = config(); if (mode === 'disabled') cfg.autoCompact = false;
    const context = new RequestContext(source(thread), cfg);
    const tools = new ContextTools({ definitions: () => [], execute: async () => { writes++; return 'committed'; } }, () => threadEntries(thread), cfg.contextWindow);
    const model = { stream: async (messages, definitions, cancellation, onText, options) => {
      if (options?.usagePurpose === 'compaction') {
        summaries++;
        if (mode === 'cancel') { signal.cancel(); }
        if (mode === 'summary-failure') throw Error('summary failed');
        return reply('Write completed.');
      }
      requests++;
      if (requests === 1) { pending = { id: 'steer', mode: 'steer', text: 'Keep this new requirement' }; return reply('long history '.repeat(250), [call('write', 'write_file', { path: 'saved.txt', content: 'saved' })]); }
      if (requests === 2 || mode === 'twice') {
        onText('rejected partial response');
        if (mode === 'network') throw Error('network down');
        throw new ContextOverflowError();
      }
      assert.ok(!messages.some(m => m.content.includes('rejected partial response')));
      assert.equal(messages.filter(m => m.content === 'Keep this new requirement').length, 1);
      assert.ok(JSON.stringify(messages).includes('saved.txt'));
      return reply('finished');
    } };
    let error;
    try {
      await runAgentLoop({ model, tools, turn, messages: [], maxSteps: mode === 'limit' ? 2 : 6,
        prepareRequest: (defs, pending, cancel, recover) => context.prepare(model, defs, cancel, pending, false, recover) }, signal, {
        event: () => { thread.messages[1].steps = turn.steps; thread.messages[1].content = turn.content; }, checkpoint: async () => {},
        steering: { peek: () => pending, consume: () => { consumed++; pending = undefined; } }
      });
    } catch (caught) { error = caught; }
    assert.equal(writes, 1); assert.equal(consumed, 1);
    return { thread, turn, error, requests, summaries };
  }
  const success = await overflowRun('success');
  assert.equal(success.error, undefined); assert.equal(success.requests, 3); assert.equal(success.summaries, 1);
  assert.ok(success.turn.content.endsWith('finished') && !success.turn.content.includes('rejected partial response'));
  assert.equal(success.turn.steps[2].context.compactionReason, 'overflow');
  assert.ok(!buildTimeline(success.turn.steps).some(entry => entry.kind === 'text' && entry.step === 1));
  const { MessageViewModel } = from('viewmodel/SessionViewModels');
  const view = new MessageViewModel(success.thread.messages[1]);
  assert.ok(!buildTimeline(view.stepViews).some(entry => entry.kind === 'text' && entry.step === 1));
  assert.ok(!JSON.stringify(projectedHistory(threadEntries(restore(success.thread)), success.thread.compaction)).includes('rejected partial response'));
  const twice = await overflowRun('twice');
  assert.ok(twice.error instanceof ContextOverflowError); assert.equal(twice.requests, 3); assert.equal(twice.summaries, 1);
  for (const mode of ['network', 'disabled', 'limit', 'cancel', 'summary-failure']) {
    const failed = await overflowRun(mode); assert.ok(failed.error, mode); assert.equal(failed.requests, 2, mode);
    assert.equal(failed.summaries, ['cancel', 'summary-failure'].includes(mode) ? 1 : 0, mode);
  }
  console.log('PASS overflow retries once without replaying writes/steering; cancellation, ordinary errors and limits stop recovery');

  const { AgentRuntime } = from('services/AgentRuntime');
  const { ProviderRegistry } = from('services/providers/ProviderRegistry');
  const registry = new ProviderRegistry(); let attempts = 0, runtimeSummaries = 0, runtimeWrites = 0;
  registry.register({ info: { id: 'test', name: 'Test' }, endpoint: () => '', stream: async request => {
    if (request.usageOrigin.purpose === 'compaction') { runtimeSummaries++; return reply('Write completed.'); }
    attempts++;
    if (attempts === 1) return reply('history '.repeat(500), [call('w', 'write_file', { path: 'runtime.txt', content: 'done' })]);
    if (attempts === 2) throw new ContextOverflowError();
    assert.ok(JSON.stringify(request.messages).includes('runtime.txt'));
    return reply('done');
  } });
  const runtime = new AgentRuntime(registry, { read: async () => '' });
  const runtimeResult = await runtime.run({ sessionId: 'worker', config: config(), messages: [{ role: 'user', content: 'work' }],
    tools: { definitions: () => [], execute: async () => { runtimeWrites++; return 'saved'; } } }, { prepare: async () => {}, checkpoint: async () => {} });
  assert.equal(runtimeResult.status, 'complete', runtimeResult.error);
  assert.equal(attempts, 3); assert.equal(runtimeSummaries, 1); assert.equal(runtimeWrites, 1);
  console.log('PASS AgentRuntime forwards overflow recovery to the shared context boundary for worker runs');

  const provider = new ProtocolProvider({ id: 'test', name: 'Test', protocol: 'chat-completions', defaultBaseUrl: 'https://test.invalid', defaultModel: 'test' }, { hydrate: async messages => messages, recordUsage: record => usage.push(record) });
  const request = { baseUrl: 'https://test.invalid', model: 'test', apiKey: 'secret', messages: [], tools: [] };
  const payload = JSON.stringify({ error: { code: 'context_length_exceeded', message: 'secret echoed by upstream' } });
  for (const order of ['status-first', 'status-last']) {
    httpScript = req => {
      if (order === 'status-first') req.callback(null, 400);
      for (const part of [payload.slice(0, 17), payload.slice(17)]) req.emit('dataReceive', part);
      req.emit('dataEnd');
      if (order === 'status-last') req.callback(null, 400);
    };
    await assert.rejects(provider.stream(request, new Cancellation(), () => {}), e => e instanceof ContextOverflowError);
  }
  for (const status of [400, 413, 429, 500]) {
    assert.ok(!(httpProviderError(status, JSON.stringify({ error: { code: 'rate_limit_exceeded' } })) instanceof ContextOverflowError));
  }
  assert.ok(!(httpProviderError(429, payload) instanceof ContextOverflowError));
  assert.ok(!(httpProviderError(413, '<html>too large</html>') instanceof ContextOverflowError));
  assert.ok(httpProviderError(400, JSON.stringify({ error: { type: 'invalid_request_error', message: 'prompt is too long: 200001 tokens > 200000 maximum' } })) instanceof ContextOverflowError);
  const { ChatStream } = from('services/ChatStream');
  const { ResponsesStream, AnthropicStream } = from('services/providers/EventStreams');
  for (const [stream, event] of [
    [new ChatStream(() => {}), { error: { code: 'context_length_exceeded' } }],
    [new ResponsesStream(() => {}), { type: 'response.failed', response: { error: { code: 'context_window_exceeded' } } }],
    [new AnthropicStream(() => {}), { type: 'error', error: { type: 'invalid_request_error', message: 'prompt is too long: 200001 tokens > 200000 maximum' } }]
  ]) assert.throws(() => stream.push('data: ' + JSON.stringify(event) + '\n\n'), e => e instanceof ContextOverflowError);
  assert.throws(() => new ResponsesStream(() => {}).push('data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}\n\n'), e => !(e instanceof ContextOverflowError));
  assert.ok(!JSON.stringify(logs).includes('secret')); assert.ok(usage.some(record => record.status === 'failed'));
  console.log('PASS HTTP and SSE overflow classification, response ordering, safe diagnostics and no retry for output limits');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
