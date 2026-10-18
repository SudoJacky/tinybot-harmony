// Exercise real SessionService, AgentRuntime, tool dispatch and team workers.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText,
    { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
      if (id === '@ohos/hypium') return {};
      if (!id.startsWith('.')) throw Error('Unexpected platform dependency ' + id);
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file });
  return exports;
}
const { Fixture, seed } = load(root + '/test/SessionService.test');
const { ChatViewModel } = load(root + '/main/ets/viewmodel/ChatViewModel');
const { TOOL_GROUPS, BASIC_FILE_TOOLS, TOOL_CAPABILITIES, OPTIONAL_TOOL_NAMES, MANAGED_TOOL_NAMES } = load(root + '/main/ets/model/ToolGroups');
const { SkillTools } = load(root + '/main/ets/services/SkillTools');
const { validateToolSelection, toolEnabled, normalizeDisabledTools } = load(root + '/main/ets/model/AgentMode');
const { SelectedTools } = load(root + '/main/ets/services/SelectedTools');
const { RuleTools } = load(root + '/main/ets/services/RuleTools');
const { Cancellation } = load(root + '/main/ets/services/Cancellation');
const { AgentRuntime } = load(root + '/main/ets/services/AgentRuntime');
const { ProviderRegistry } = load(root + '/main/ets/services/providers/ProviderRegistry');
const { parseAppData } = load(root + '/main/ets/model/Conversation');
const clean = value => JSON.parse(JSON.stringify(value));
const all = Array.from(TOOL_GROUPS.flatMap(group => group.tools));
const optional = Array.from(OPTIONAL_TOOL_NAMES);
const def = name => ({ type: 'function', function: { name, description: name, parameters: { type: 'object', properties: {} } } });
const call = (name, args = {}) => ({ id: 'call-' + name, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (...toolCalls) => ({ content: toolCalls.length ? '' : 'done', toolCalls });
const executor = { async execute(code, catalog, invoke) {
  const tools = Object.fromEntries(JSON.parse(catalog).map(tool => [tool.name, async args => JSON.parse(await invoke(tool.name, JSON.stringify(args)))]));
  try { return JSON.stringify({ status: 'ok', result: await vm.runInNewContext('(async()=>{' + code + '})()', { tools, ALL_TOOLS: JSON.parse(catalog) }) }); }
  catch (error) { return JSON.stringify({ status: 'error', error: error.message }); }
} };
function fixture(data = seed()) {
  data.threads[0].titleEdited = true;
  const f = new Fixture(data), calls = [];
  // These tools are added by SessionService/AgentRuntime or belong to workers.
  const owned = ['memory', 'skill_manage', 'mcp_manage', 'read_tool_result', 'orchestrate'];
  f.resources.agentTools = { definitions: () => all.filter(name => !name.startsWith('team_') && !owned.includes(name)).map(def),
    execute: async incoming => { calls.push(incoming.function.name); return JSON.stringify({ ok: true, content: '[1,2]' }); } };
  const registry = new ProviderRegistry(); registry.register(f.provider);
  f.session.runtime = new AgentRuntime(registry, f.keys, undefined, undefined, executor);
  f.calls = calls; return f;
}
async function main() {
  assert.equal(all.length, 40); assert.equal(new Set(all).size, 40); assert.equal(BASIC_FILE_TOOLS.length, 6);
  assert.equal(optional.length, 30);
  assert.ok(!all.includes('generate_image'));
  const removed = seed(); removed.productivity.options.image = {providerId:'old', modelId:'image'};
  removed.threads[0].agentMode = 'custom'; removed.threads[0].disabledTools = ['generate_image'];
  const loaded = parseAppData(JSON.stringify(removed));
  assert.equal(loaded.threads[0].disabledTools.length, 0);
  assert.equal(loaded.threads[0].messages.length, removed.threads[0].messages.length);
  const covered = Array.from(TOOL_CAPABILITIES.flatMap(capability => capability.tools));
  assert.equal(TOOL_CAPABILITIES.length, 12);
  assert.equal(new Set(covered).size, 30); assert.deepEqual(covered.slice().sort(), optional.slice().sort());
  const obsolete = {agentMode:'custom', disabledTools:Array.from(MANAGED_TOOL_NAMES).concat(['generate_image'])};
  validateToolSelection(obsolete);
  assert.deepEqual(Array.from(normalizeDisabledTools(obsolete.disabledTools)), []);
  for (const name of MANAGED_TOOL_NAMES) assert.equal(toolEnabled(name, obsolete), true);
  const skills = [{ name:'enabled', description:'Enabled', enabled:true, document:'Enabled instructions', files:[] },
    { name:'disabled', description:'Disabled', enabled:false, document:'Disabled instructions', files:[] }];
  const skillTools = new SelectedTools(new SkillTools(skills, '', () => skills), obsolete);
  assert.equal(JSON.parse(await skillTools.execute(call('read_skill',{name:'enabled'}),new Cancellation())).content,'Enabled instructions');
  await assert.rejects(skillTools.execute(call('read_skill',{name:'disabled'}),new Cancellation()), error => error.code==='TOOL_UNAVAILABLE');
  assert.equal(JSON.parse(await skillTools.execute(call('list_skills'),new Cancellation())).find(skill => skill.name==='disabled').enabled,false);
  for (const capability of TOOL_CAPABILITIES) {
    for (const member of capability.tools) {
      const selection = { agentMode:'custom', disabledTools:[member] };
      const grouped = new SelectedTools({ definitions: () => all.map(def), execute: async () => 'unexpected' }, selection);
      assert.deepEqual(Array.from(normalizeDisabledTools([member])).sort(), Array.from(capability.tools).sort());
      for (const name of capability.tools) {
        assert.equal(toolEnabled(name, selection), false);
        assert.ok(!grouped.definitions().some(tool => tool.function.name === name));
        await assert.rejects(grouped.execute(call(name), new Cancellation()), error => error.code === 'PERMISSION_DENIED');
      }
    }
  }
  const legacyData = seed(); legacyData.threads[0].agentMode = 'custom';
  legacyData.threads[0].disabledTools = ['browser_action','publish_data_view','team_complete_task','mcp_call',...MANAGED_TOOL_NAMES];
  const migrated = parseAppData(JSON.stringify(legacyData));
  assert.deepEqual(Array.from(migrated.threads[0].disabledTools).sort(),
    Array.from(normalizeDisabledTools(legacyData.threads[0].disabledTools)).sort());
  const legacy = fixture(migrated), legacyApp = new ChatViewModel(); await legacyApp.initialize(legacy.session);
  const legacyWrites = legacy.repository.writes.length;
  for (const id of ['browser','preview','team','mcp']) {
    const capability = TOOL_CAPABILITIES.find(item => item.id === id);
    assert.ok(capability.tools.every(name => legacyApp.active.disabledTools.includes(name)));
    await legacy.session.setToolEnabled(capability.tools.at(-1), true);
    assert.ok(capability.tools.every(name => !legacyApp.active.disabledTools.includes(name)));
    await legacy.session.setToolEnabled(capability.tools[0], false);
    assert.ok(capability.tools.every(name => legacyApp.active.disabledTools.includes(name)));
  }
  assert.equal(legacy.repository.writes.length, legacyWrites, 'Capability toggles keep the existing save-on-send behavior');
  for (const name of MANAGED_TOOL_NAMES) await assert.rejects(legacy.session.setToolEnabled(name,false));
  console.log('PASS 12 selectable capabilities, legacy memory/Skills overrides removed, individual Skill state retained and atomic group catalog/dispatch');
  for (const selection of [{ agentMode: 'research' }, { disabledTools: ['write_file'] }, { disabledTools: ['unknown'] },
    { disabledTools: ['read_web', 'read_web'] }, { disabledTools: 'read_web' }, { disabledTools: [null] }]) {
    assert.throws(() => validateToolSelection(selection));
  }
  const original = { agentMode: 'custom', disabledTools: ['read_web'] }, effects = [];
  const selected = new SelectedTools({ definitions: () => all.map(def), execute: async incoming => { effects.push(incoming.function.name); return '{}'; } }, original);
  original.disabledTools.length = 0;
  assert.ok(!selected.definitions().some(item => item.function.name === 'read_web'));
  await assert.rejects(selected.execute(call('read_web'), new Cancellation()), error => error.code === 'PERMISSION_DENIED');
  for (const name of BASIC_FILE_TOOLS) await selected.execute(call(name), new Cancellation());
  assert.deepEqual(effects, Array.from(BASIC_FILE_TOOLS));
  const readOnly = new RuleTools(selected, true);
  for (const name of ['memory','skill_manage']) assert.ok(!readOnly.definitions().some(tool => tool.function.name===name));
  await assert.rejects(readOnly.execute(call('write_file'), new Cancellation()), error => error.code === 'PERMISSION_DENIED');
  assert.equal(toolEnabled('team_recruit', { agentMode: 'custom', disabledTools: ['team_complete_task'] }), false);
  assert.equal(toolEnabled('team_resume', { agentMode: 'custom', disabledTools: ['team_complete_task'] }), false);
  console.log('PASS validated inventory, mandatory file tools, immutable selection, direct dispatch and permission intersection');

  const f = fixture(), app = new ChatViewModel(); await app.initialize(f.session);
  assert.equal(app.active.agentMode, 'full');
  const events = []; f.session.subscribe(event => events.push(event));
  const initialWrites = f.repository.writes.length;
  await app.setToolEnabled('read_web', false); await app.setToolEnabled('mcp_call', false);
  await app.setToolEnabled('read_tool_result', false);
  const disabledCount = normalizeDisabledTools(['read_web','mcp_call','read_tool_result']).length;
  assert.equal(app.active.agentMode, 'custom'); assert.equal(app.active.disabledTools.length, disabledCount);
  assert.equal(f.repository.writes.length, initialWrites); assert.equal(f.provider.requests.length, 0);
  assert.ok(events.every(event => event.state.phase === 'idle' && event.kind !== 'snapshot'));
  await app.setAgentMode('full'); assert.equal(app.active.disabledTools.length, disabledCount);
  await app.setAgentMode('custom'); await assert.rejects(app.setToolEnabled('edit_file', false));
  f.session.setDraft('try blocked operation');
  f.provider.respond = async index => index === 0 ? reply(call('read_web', { url: 'https://example.com' })) : reply();
  await f.session.send();
  const advertised = f.provider.requests[0].tools.map(item => item.function.name);
  for (const name of ['read_web', 'mcp_call', 'memory']) assert.ok(!advertised.includes(name));
  for (const name of ['read_file', 'write_file', 'edit_file', 'orchestrate', 'tool_search']) assert.ok(advertised.includes(name));
  for (const name of ['list_files', 'find_files', 'search_file_content']) assert.ok(!advertised.includes(name));
  assert.ok(!f.provider.requests[1].tools.some(item => item.function.name === 'read_tool_result'), 'runtime-added retrieval remains disabled');
  assert.deepEqual(f.calls, [], 'a forged direct call cannot execute a hidden tool');
  const saved = await f.repository.load(); assert.equal(saved.threads[0].agentMode, 'custom');
  assert.equal(saved.threads[0].disabledTools.length, disabledCount);
  const restored = fixture(saved); await restored.session.initialize();
  assert.equal(restored.session.snapshot().threads[0].disabledTools.length, disabledCount);
  await app.setAgentMode('full'); f.session.setDraft('full mode');
  f.provider.respond = async () => reply(); await f.session.send();
  assert.ok(f.provider.requests.at(-1).tools.some(item => item.function.name === 'tool_search' && item.function.description.includes('read_web')));
  assert.equal((await f.repository.load()).threads[0].disabledTools.length, disabledCount, 'full mode preserves custom configuration');
  await app.setAgentMode('custom'); assert.equal(app.active.disabledTools.length, disabledCount);
  assert.equal(await f.session.forkThread(), true); assert.equal(f.session.active.agentMode, 'custom');
  assert.equal(f.session.active.disabledTools.length, disabledCount);
  const badData = clean(f.session.snapshot()); badData.threads[0].disabledTools = ['write_file']; assert.throws(() => parseAppData(JSON.stringify(badData)));
  console.log('PASS view-model selection, zero-IO toggles, real model catalog/dispatch, restart, full/custom switching and branch inheritance');

  const sdk = fixture(); await sdk.session.initialize(); await sdk.session.setToolEnabled('read_web', false);
  sdk.provider.respond = async index => index === 0 ? reply(call('orchestrate', { code: 'return await tools.read_web({url:"https://example.com"});' })) : reply();
  sdk.session.setDraft('blocked SDK tool'); await sdk.session.send(); assert.deepEqual(sdk.calls, []);
  const outer = sdk.session.active.messages.at(-1).steps[0].tools[0];
  assert.equal(outer.status, 'failed'); assert.match(outer.output, /read_web/);
  await sdk.session.setToolEnabled('orchestrate', false);
  sdk.provider.respond = async () => reply(); sdk.session.setDraft('without orchestration'); await sdk.session.send();
  assert.ok(!sdk.provider.requests.at(-1).tools.some(item => item.function.name === 'orchestrate'));
  assert.ok(sdk.provider.requests.at(-1).tools.some(item => item.function.name === 'read_file'));
  await sdk.session.setDisabledTools(optional); sdk.session.setDraft('basic files only'); await sdk.session.send();
  const basic = sdk.provider.requests.at(-1).tools;
  assert.deepEqual(Array.from(basic, item => item.function.name).sort(), ['read_file', 'write_file', 'edit_file', 'tool_search'].sort());
  for (const name of ['list_files', 'find_files', 'search_file_content']) assert.ok(basic.find(tool => tool.function.name === 'tool_search').function.description.includes(name));
  console.log('PASS SDK children respect custom selection and disabling orchestration retains direct file tools');

  const frozen = fixture(); await frozen.session.initialize(); await frozen.session.setToolEnabled('read_web', false);
  let enter, release; const entered = new Promise(resolve => { enter = resolve; }); const held = new Promise(resolve => { release = resolve; });
  frozen.provider.respond = async () => { enter(); await held; return reply(); };
  frozen.session.setDraft('hold current task'); const running = frozen.session.send(); await entered;
  assert.equal(await frozen.session.setAgentMode('full'), false); assert.equal(await frozen.session.setToolEnabled('read_web', true), false);
  release(); await running; assert.ok(frozen.session.active.disabledTools.includes('read_web'));
  console.log('PASS a running task cannot change mode or tool selection');

  const team = fixture(); await team.session.initialize(); await team.session.setTeamEnabled(true);
  await team.session.setToolEnabled('execute_code', false); await team.session.setToolEnabled('orchestrate', false);
  let parentCalls = 0, workerCalls = 0;
  team.provider.respond = async index => {
    const request = team.provider.requests[index], names = request.tools.map(item => item.function.name);
    if (names.includes('team_complete_task')) {
      workerCalls++; assert.ok(!names.includes('execute_code')); assert.ok(!names.includes('orchestrate'));
      return workerCalls === 1 ? reply(call('team_complete_task', { summary: 'reviewed', unresolved: [], artifacts: [] })) : reply();
    }
    if (parentCalls++ === 0) return reply(call('team_recruit', { goal: 'review', members: [{ id: 'worker', instructions: 'Read and report', toolProfile: 'research' }],
      tasks: [{ id: 'task', memberId: 'worker', title: 'Review', instructions: 'Read and report', dependencies: [] }] }));
    if (parentCalls === 2) return reply(call('team_wait', { runId: team.session.active.teams[0].id, waitFor: 'all_tasks' }));
    return reply();
  };
  team.session.setDraft('review with team'); await team.session.send();
  assert.equal(workerCalls, 2); assert.equal(team.session.active.teams[0].status, 'completed');
  await team.session.setToolEnabled('team_complete_task', false);
  team.provider.respond = async () => reply(); team.session.setDraft('handoff disabled'); await team.session.send();
  const catalog = team.provider.requests.at(-1).tools.map(item => item.function.name);
  assert.ok(!catalog.includes('team_recruit')); assert.ok(!catalog.includes('team_resume'));
  console.log('PASS real team workers inherit tool selection and required handoff gates team dispatch');

  const memoryData = seed(); memoryData.productivity.options.autoMemory = true;
  memoryData.threads[0].agentMode='custom'; memoryData.threads[0].disabledTools=['memory'];
  const memory = fixture(memoryData); await memory.session.initialize(); await memory.session.setDisabledTools(optional);
  let reviews=0; memory.session.reviewMemory = async () => { reviews++; };
  memory.provider.respond = async index => index===0 ? reply(call('memory',{operations:[]})) : reply();
  memory.session.setDraft('remember this'); await memory.session.send();
  assert.ok(memory.provider.requests[0].tools.find(tool => tool.function.name==='tool_search').function.description.includes('memory:'));
  assert.equal(memory.session.active.messages.at(-1).steps[0].tools[0].status,'complete'); assert.equal(reviews,1);
  await memory.session.setSettingsToggle('autoMemory',false);
  memory.provider.respond=async()=>reply(); memory.session.setDraft('memory off'); await memory.session.send();
  assert.ok(!memory.provider.requests.at(-1).tools.find(tool => tool.function.name==='tool_search').function.description.includes('memory:'));
  assert.equal(reviews,1);
  assert.equal(memory.session.active.messages.at(-1).status, 'complete');
  console.log('PASS autoMemory is the single switch for memory tools/background review, including legacy overrides and all optional capabilities off');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
