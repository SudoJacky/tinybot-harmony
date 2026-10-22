// Real runtime/request/dispatch tests, with local tool adapters and scripted model responses.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, 'main/ets', name));
const { ToolDiscovery, discoveredToolDefinitions } = from('services/ToolDiscovery');
const { ToolSet } = from('services/ToolSet');
const { OrchestrationTools } = from('services/OrchestrationTools');
const { AgentRuntime } = from('services/AgentRuntime');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { SelectedTools } = from('services/SelectedTools');
const { RuleTools } = from('services/RuleTools');
const { Cancellation } = from('services/Cancellation');
const { WorkspaceTools } = from('services/WorkspaceTools');
const { InteractionTools } = from('services/InteractionTools');
const { CodeExecutionTools } = from('services/CodeExecutionTools');
const { PreviewTools } = from('services/PreviewTools');
const { PresentTools } = from('services/PresentTools');
const { ResourceTools } = from('services/ResourceTools');
const { MemoryTools } = from('services/MemoryTools');
const { McpTools } = from('services/McpTools');
const { WebTools } = from('services/WebTools');
const { ToolApproval } = from('services/ToolApproval');
const { RequestContext } = from('services/RequestContext');
const { sessionPromptSections } = from('services/SessionContext');
const { INTERACTIVE_UI_INSTRUCTIONS } = from('model/InteractiveUiInstructions');
const { defaultConfig } = from('model/Conversation');
const { defaultExtensions } = from('model/Skills');
const { toolSchemas } = from('model/Agent');
const { runAgentLoop } = from('services/AgentLoop');
const { Fixture } = load(root + '/test/SessionService.test');
const plain = value => JSON.parse(JSON.stringify(value));
const names = tools => Array.from(tools.definitions(), item => item.function.name);
let sequence = 0;
const call = (name, args = {}) => ({ id: 'tool-' + ++sequence, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (...calls) => ({ content: calls.length ? '' : 'Done', toolCalls: calls });
const invoke = async (tools, name, args, cancellation = new Cancellation()) => JSON.parse(await tools.execute(call(name, args), cancellation));
const definition = (name, executionMode) => ({ type: 'function', executionMode, function: { name, description: name,
  parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } } });
const initialNames = ['read_file', 'write_file', 'edit_file', 'orchestrate', 'tool_search'];
// Host adapter double; the native QuickJS bridge is checked by the orchestration suite/device smoke.
const executor = { async execute(code, catalog, invoke) {
  const tools = Object.fromEntries(JSON.parse(catalog).map(tool => [tool.name,
    async args => JSON.parse(await invoke(tool.name, JSON.stringify(args)))]));
  try { return JSON.stringify({ status: 'ok', result: await vm.runInNewContext('(async()=>{' + code + '})()', { tools, ALL_TOOLS: JSON.parse(catalog) }) }); }
  catch (error) { return JSON.stringify({ status: 'error', error: error.message }); }
} };
async function main() {
  const searchable = (name, description, properties = {}) => ({ ...definition(name), promptSnippet: '专用工具',
    function: { name, description, parameters: { type: 'object', properties, required: [], additionalProperties: false } } });
  const ranked = async (query, entries) => (await invoke(new ToolDiscovery({ definitions: () => entries, execute: async () => '{}' }),
    'tool_search', { query })).loaded;
  const corpus = [
    searchable('mcp__github__list_issues', 'List issues in a repository.', { state: { type: 'string', description: 'open or closed' } }),
    searchable('mcp__github__create_pull_request', 'Open a pull request.'),
    searchable('mcp__linear__search_issues', 'Search Linear issues by text.'),
    searchable('mcp__docs__search', 'Search the documentation.')
  ];
  assert.deepEqual(await ranked('issue', corpus), ['mcp__linear__search_issues', 'mcp__github__list_issues']);
  assert.equal((await ranked('pull requests', corpus))[0], 'mcp__github__create_pull_request');
  assert.deepEqual(await ranked('closed', corpus), ['mcp__github__list_issues']);
  assert.deepEqual(await ranked('listIssues for the GitHub_repo', corpus), await ranked('list issue git hub repo', corpus));
  assert.deepEqual(await ranked('searches queries HTTPServer', corpus), await ranked('search query http server', corpus));
  for (const query of ['the and with', 'kubernetes', 'tickets', 'umentation', '!!!']) assert.deepEqual(await ranked(query, corpus), []);
  const weighted = [searchable('frequent', 'common '.repeat(40)), searchable('rare', 'raretoken'),
    searchable('other', 'common'), searchable('another', 'common')];
  assert.equal((await ranked('common raretoken', weighted))[0], 'rare', 'Rare terms outweigh repeated common terms');
  assert.deepEqual(await ranked('common common common raretoken', weighted), await ranked('common raretoken', weighted));
  assert.deepEqual(await ranked('needle', [searchable('long', 'needle ' + 'filler '.repeat(30)), searchable('short', 'needle')]),
    ['short', 'long'], 'BM25 normalizes document length');
  const ties = ['zeta', 'alpha', 'eta', 'beta', 'theta', 'gamma', 'iota', 'delta'].map(name => searchable(name, 'needle'));
  assert.deepEqual(await ranked('needle', ties), ties.slice(0, 6).map(tool => tool.function.name), 'Stable ties and a six-result limit');
  const nested = [searchable('nested', 'Process records', { payload: { type: 'array', description: 'Rows', items: {
    type: 'object', description: 'Record', properties: { referenceId: { description: 'Identifier', anyOf: [
      { type: 'string', description: 'Opaque locator' }, { type: 'number', description: 'Numeric locator' }
    ] } }
  } } }), searchable('unrelated', 'Something else')];
  for (const query of ['payload', 'referenceId', 'opaque locator']) assert.deepEqual(await ranked(query, nested), ['nested']);
  const chinese = [searchable('preview', '发布交互文件预览'), searchable('image', '生成图片'), searchable('web', '检索网页')];
  assert.deepEqual(await ranked('文件预览', chinese), ['preview']);
  assert.deepEqual(await ranked('生成图片', chinese), ['image']);
  assert.deepEqual(await ranked('天气', chinese), []);
  console.log('PASS BM25 relevance, frequency saturation, length normalization, deduplicated queries, stable ties, English/Chinese tokenization and recursive schema search');

  const approval = new ToolApproval();
  const code = new CodeExecutionTools({ execute: async (_code, input) => JSON.stringify({ status: 'ok', result: JSON.parse(input) }) });
  const contents = new Map([['data.txt', 'needle'], ['unread.txt', 'original']]);
  const files = {
    list: async path => ({ path, entries: Array.from(contents.keys(), name => ({ name, kind: 'file' })), truncated: false }),
    read: async path => ({ path, content: contents.get(path), version: contents.get(path) })
  };
  const base = new ToolSet([new WorkspaceTools(files), new InteractionTools(approval), code,
    new PreviewTools({}, async () => {}), new PresentTools(async path => path),
    new ResourceTools(async args => JSON.stringify(args), async () => '{}'), new MemoryTools(async () => '{}'),
    new McpTools([{ id: 'remote', name: 'Remote', enabled: true, url: 'https://example.com/mcp' }], approval, () => ({})), new WebTools({})]);
  const catalog = new OrchestrationTools(base, executor);
  const tools = new ToolDiscovery(catalog);
  assert.deepEqual(names(tools).sort(), initialNames.slice().sort());
  for (const name of ['list_files', 'find_files', 'search_file_content']) assert.ok(!names(tools).includes(name));
  const listed = await invoke(tools, 'tool_search', { query: '' });
  assert.ok(listed.tools.some(tool => tool.name === 'publish_preview'));
  assert.ok(!JSON.stringify(listed).includes('parameters'));
  assert.ok(!names(tools).includes('publish_preview'), 'Listing names does not load schemas');
  for (const name of ['list_files', 'find_files', 'search_file_content']) assert.ok(listed.tools.some(tool => tool.name === name));
  const expanded = new ToolDiscovery(catalog);
  await invoke(expanded, 'tool_search', { query: 'find_files' });
  assert.ok(names(expanded).includes('find_files'), 'Deferred file tools remain directly discoverable');
  const config = defaultConfig(); config.contextWindow = 1000000;
  const source = { state: {}, entries: () => [], sections: () => sessionPromptSections(config, defaultExtensions()), persist: async () => {}, progress() {} };
  const manager = new RequestContext(source, config);
  const initial = manager.inspect(tools.definitions());
  assert.ok(!initial.messages.some(message => message.content.includes('new OrbitControls')));
  const query = await invoke(tools, 'tool_search', { query: 'publish_preview' });
  assert.equal(query.loaded[0], 'publish_preview');
  assert.ok(names(tools).includes('publish_preview'));
  assert.equal(query.loaded[0], 'publish_preview', 'Exact name ranks first; shared terms may load related tools');
  const expandedRequest = manager.inspect(tools.definitions());
  assert.ok(expandedRequest.messages.some(message => message.runtimeContext && message.content.includes(INTERACTIVE_UI_INSTRUCTIONS.trim())));
  assert.equal(expandedRequest.messages[0].content, initial.messages[0].content, 'Tool discovery leaves the system prefix unchanged');
  assert.deepEqual(plain(toolSchemas(tools.definitions()).slice(0, initialNames.length)),
    plain(toolSchemas(new ToolDiscovery(catalog).definitions())), 'New schemas follow existing declarations');
  const selectedPreview = tools.definitions().find(tool => tool.function.name === 'publish_preview');
  assert.deepEqual(plain(selectedPreview.function.parameters), plain(catalog.definitions().find(tool => tool.function.name === 'publish_preview').function.parameters));
  assert.ok(!JSON.stringify(toolSchemas(tools.definitions())).includes('promptGuidelines'));
  assert.equal((await invoke(tools, 'tool_search', { query: 'xyzzyqwerty987' })).loaded.length, 0);
  for (const args of [{}, { query: 2 }, { query: 'a'.repeat(301) }, { query: 'web', extra: true }]) await assert.rejects(invoke(tools, 'tool_search', args));
  const cancelled = new Cancellation(); cancelled.cancel(); await assert.rejects(invoke(tools, 'tool_search', { query: 'execute_code' }, cancelled));
  console.log('PASS compact initial catalog, discovery/listing, exact schema activation and preview instructions only after discovery');

  const fullSource = { ...source, sections: () => source.sections().concat([{ name: 'interactive_ui', content: INTERACTIVE_UI_INSTRUCTIONS }]) };
  const full = new RequestContext(fullSource, config).inspect(catalog.definitions());
  const chars = (request, defs) => JSON.stringify({ messages: request.messages, tools: toolSchemas(defs) }).length;
  const before = chars(full, catalog.definitions()), after = chars(initial, new ToolDiscovery(catalog).definitions());
  assert.ok(after < before * 0.65, `Expected substantial request reduction: ${before} -> ${after}`);
  console.log(`SIZE same authorized catalog: ${catalog.definitions().length} -> ${new ToolDiscovery(catalog).definitions().length} initial tools; ${before} -> ${after} JSON characters (-${Math.round((1 - after / before) * 100)}%); estimated tokens ${full.context.tokens} -> ${initial.context.tokens}`);

  const restricted = new ToolDiscovery(new RuleTools(new SelectedTools(catalog, { agentMode: 'custom', disabledTools: ['publish_preview', 'execute_code'] }), true));
  const available = (await invoke(restricted, 'tool_search', { query: '' })).tools.map(tool => tool.name);
  for (const name of ['publish_preview', 'execute_code', 'memory', 'skill_manage', 'mcp_call']) assert.ok(!available.includes(name));
  assert.ok(!(await invoke(restricted, 'tool_search', { query: 'publish_preview' })).loaded.includes('publish_preview'));
  await assert.rejects(invoke(restricted, 'publish_preview', { path: 'a.js' }), error => error.code === 'PERMISSION_DENIED');
  await assert.rejects(invoke(restricted, 'write_file', { path: 'a', content: 'b' }), error => error.code === 'PERMISSION_DENIED');
  const handoff = new ToolDiscovery({ definitions: () => [definition('team_complete_task'), definition('team_recruit')], execute: async () => '{}' });
  assert.ok(names(handoff).includes('team_complete_task'));
  let enabled = true;
  const live = new ToolDiscovery({ definitions: () => enabled ? [definition('read_web')] : [], execute: async () => { if (!enabled) throw Error('disabled'); return '{}'; } });
  await invoke(live, 'tool_search', { query: 'read_web' }); enabled = false;
  assert.ok(!names(live).includes('read_web')); await assert.rejects(invoke(live, 'read_web', {}));
  assert.ok(!names(new ToolDiscovery(catalog)).includes('publish_preview'), 'A new run starts compact');
  let finished = false;
  await new ToolDiscovery({ definitions: () => [], execute: async () => '{}', beforeFinish: async () => { finished = true; return 'handoff required'; } }).beforeFinish(new Cancellation());
  assert.ok(finished);
  console.log('PASS custom/readonly policy, live revocation, worker handoff, per-run isolation and completion guards');

  const events = [], turn = { content: '', steps: [] };
  const executable = new ToolDiscovery({ definitions: () => [definition('write_special', 'sequential'), definition('read_file', 'parallel')],
    execute: async incoming => { events.push(incoming.function.name + ':start'); await new Promise(setImmediate); events.push(incoming.function.name + ':end'); return '{}'; } });
  let rounds = 0;
  await runAgentLoop({ model: { stream: async () => rounds++ === 0 ? reply(call('write_special'), call('read_file')) : reply() },
    tools: executable, turn, messages: [], maxSteps: 3 }, new Cancellation(), { event() {}, checkpoint: async () => {} });
  assert.deepEqual(events, ['write_special:start', 'write_special:end', 'read_file:start', 'read_file:end']);
  assert.equal(turn.steps[0].tools[0].status, 'complete');
  console.log('PASS deferred visibility preserves sequential execution metadata and durable dispatch for known tool calls');

  const f = new Fixture();
  f.resources.agentTools = { definitions: () => base.definitions().filter(tool => !['skill_manage', 'mcp_manage', 'memory'].includes(tool.function.name)),
    execute: (incoming, cancellation, context) => base.execute(incoming, cancellation, context) };
  const registry = new ProviderRegistry(); registry.register(f.provider);
  f.session.runtime = new AgentRuntime(registry, f.keys, undefined, undefined, executor);
  await f.session.initialize();
  f.provider.respond = async index => index === 0 ? reply(call('tool_search', { query: 'execute_code' })) :
    index === 1 ? reply(call('execute_code', { code: 'return input;', input: { values: [1, 2] } })) : reply();
  f.session.setDraft('Compute using the sandbox'); await f.session.send();
  assert.equal(f.session.active.messages.at(-1).status, 'complete');
  assert.deepEqual(Array.from(f.provider.requests[0].tools, tool => tool.function.name).sort(), initialNames.slice().sort());
  assert.ok(!f.provider.requests[0].tools.some(tool => tool.function.name === 'execute_code'));
  assert.ok(f.provider.requests[1].tools.some(tool => tool.function.name === 'execute_code'));
  assert.deepEqual(JSON.parse(f.session.active.messages.at(-1).steps[1].tools[0].output).result, { values: [1, 2] });
  assert.equal(JSON.parse(f.repository.saved).threads[0].messages.at(-1).steps[0].tools[0].call.function.name, 'tool_search');
  f.provider.respond = async () => reply();
  f.session.setDraft('A fresh ordinary turn'); await f.session.send();
  assert.ok(f.provider.requests.at(-1).tools.some(tool => tool.function.name === 'execute_code'), 'Durable discovery survives the next turn');
  const inspector = f.session.runtime.inspectContext(source, config, base);
  assert.equal(inspector.context.toolTokens, initial.context.toolTokens);
  assert.deepEqual(plain(discoveredToolDefinitions([])), []);
  console.log('PASS real SessionService/AgentRuntime discovery -> loaded schema -> tool execution -> saved receipt -> retained next-turn discovery and matching context inspector');

  const start = f.provider.requests.length;
  f.provider.respond = async index => index === start ? reply(call('orchestrate', { code: `
    const listing = await tools.list_files({path:'.'});
    const found = await tools.find_files({path:'.',glob:'data.*'});
    const matches = await tools.search_file_content({path:'.',query:'needle'});
    const data = await tools.read_file({path:'data.txt'});
    return {listing,found,matches,data,schema:ALL_TOOLS.find(t=>t.name==='find_files').parameters};` })) : reply();
  f.session.setDraft('Browse, find, search and read through orchestration'); await f.session.send();
  const receipt = f.session.active.messages.at(-1).steps[0].tools[0];
  assert.equal(receipt.status, 'complete');
  const result = JSON.parse(receipt.output).result;
  assert.deepEqual(result.found.paths, ['data.txt']); assert.equal(result.matches.matches[0].path, 'data.txt');
  assert.equal(result.data.content, 'needle'); assert.ok(result.schema.properties.glob);
  assert.deepEqual(Array.from(receipt.children, child => child.call.function.name), ['list_files', 'find_files', 'search_file_content', 'read_file']);
  assert.ok(receipt.children.every(child => child.status === 'complete'));
  assert.equal(JSON.parse(f.repository.saved).threads[0].messages.at(-1).steps[0].tools[0].children.length, 4);
  assert.ok(!f.provider.requests[start].tools.some(tool => tool.function.name === 'list_files'));
  for (const args of [ {path:'../outside',edits:[{oldText:'original',newText:'changed'}]},
    {path:'unread.txt',edits:[{oldText:'original',newText:'changed'}]} ]) {
    const next = f.provider.requests.length;
    f.provider.respond = async index => index === next ? reply(call('orchestrate', {code:'return await tools.edit_file(' + JSON.stringify(args) + ');'})) : reply();
    f.session.setDraft('Check mutation protection'); await f.session.send();
    const failed = f.session.active.messages.at(-1).steps[0].tools[0];
    assert.equal(failed.status, 'failed'); assert.equal(failed.children[0].status, 'failed');
    assert.equal(JSON.parse(failed.children[0].output).code, args.path.startsWith('..') ? 'FS_INVALID_PATH' : 'FS_NOT_OBSERVED');
    assert.equal(contents.get('unread.txt'), 'original');
  }
  console.log('PASS five initial schemas -> existing orchestration -> deferred listing/find/search/read, schema lookup, durable child receipts and path/read-before-edit protection');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
