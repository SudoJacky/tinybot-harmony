// Replay a newer snapshot through the current reader, real store and session commits.
const fs = require('node:fs'), fsp = fs.promises, path = require('node:path'), os = require('node:os');
const vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
const io = {
  access: async file => { try { await fsp.access(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } },
  readText: file => fsp.readFile(file, 'utf8'), mkdir: file => fsp.mkdir(file), rename: (from, to) => fsp.rename(from, to), unlink: file => fsp.unlink(file)
};
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Error, console, setTimeout, clearTimeout, Observed: cls => cls, Concurrent: fn => fn,
    require: id => {
      if (id === '@kit.CoreFileKit') return { fileIo: io };
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: require('node:crypto').randomUUID },
        taskpool: { execute: async (fn, file, text) => { await fsp.writeFile(file, text, 'utf8'); return Buffer.byteLength(text); } } };
      assert.ok(id.startsWith('.'), 'Unexpected platform dependency: ' + id);
      return load(path.resolve(path.dirname(file), id));
    }
  }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name)), plain = value => JSON.parse(JSON.stringify(value));
const { emptyData, parseAppData } = from('model/Conversation');
const { ConversationStore } = from('model/ConversationStore');
const { defaultProductivity } = from('model/Productivity');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { SessionService } = from('services/SessionService');
const { AgentRuntime } = from('services/AgentRuntime');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { availableModels, modelConfig } = from('model/ProviderProfiles');
const { BrowserSession } = from('services/BrowserSession');
const { SelectedTools } = from('services/SelectedTools');
const { Cancellation } = from('services/Cancellation');
const { Diagnostics } = from('model/Diagnostics');
const { LogSanitizer } = from('model/DiagnosticLog');
const { isSupportedProtocol } = from('model/ProviderEndpoint');
const { saveSearchSettings } = from('services/SearchSettings');
const { McpTools } = from('services/McpTools');
const { ToolApproval } = from('services/ToolApproval');
const { mergeSavedConfiguration } = from('model/SavedConfiguration');
const { saveMcpCandidate, saveSkillCandidate } = from('model/ResourceManagement');
const { parseSkill } = from('model/Skills');
const profile = (id, protocol = 'chat-completions') => ({ id, name: id, protocol, baseUrl: 'https://example.com/v1',
  credentialAlias: '', noApiKey: true, enabled: true, models: ['model'], futureProfile: { retained: true } });
function fixture() {
  const data = emptyData();
  data.futureRoot = { list: [1, false, { text: 'future' }] }; data.config.futureConfig = { retained: true };
  data.config.reasoning = 'future-effort';
  data.providerProfiles = [profile('known'), profile('future', 'future-protocol')];
  data.providerProfiles[1].baseUrl = 'future-scheme://endpoint';
  data.providerProfiles[0].presetId = 'future-preset';
  data.productivity = defaultProductivity(); data.productivity.futureProductivity = { retained: true };
  data.productivity.options = defaultAssistantOptions(); data.productivity.options.futureOptions = { retained: true };
  data.productivity.options.autoRoute = true; data.productivity.options.fast = { providerId: 'future', modelId: 'model' };
  data.productivity.options.capabilities = [{ providerId: 'known', modelId: 'model', images: true,
    requestUsage: true, reasoning: 'future-effort', futureCapability: { retained: true } }];
  data.productivity.servers = [{ id: 'future-mcp', name: 'Future MCP', url: 'https://example.com/mcp',
    enabled: true, credentialAlias: '', authType: 'future-auth', futureAuth: { retained: true } }];
  data.productivity.options.search = { provider: 'future-search', enabled: true, futureSearch: { retained: true } };
  data.extensions = { webEnabled: true, browserPolicy: 'future-policy', skills: [], futureExtensions: { retained: true } };
  data.threads = [{ id: 'thread', title: 'Saved chat', updatedAt: 1, futureThread: { retained: true },
    modelRef: { providerId: 'future', modelId: 'model' }, agentMode: 'future-mode', reasoningEffort: 'future-effort', disabledTools: ['search_web', 'future_tool'],
    messages: [{ id: 'user', role: 'user', content: 'Hi', status: 'complete', error: '', futureMessage: [1, 2] },
      { id: 'assistant', role: 'assistant', content: 'Hello', status: 'complete', error: '' }] }];
  data.activeThreadId = 'thread'; return data;
}
async function main() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tinybot-config-compat-'));
  assert.equal(path.dirname(path.resolve(directory)), path.resolve(os.tmpdir()));
  try {
    // A compatible addition must survive the actual manifest write and cold reload.
    const additive = emptyData(); additive.futureRoot = { retained: true };
    const first = new ConversationStore(directory); await first.save(parseAppData(JSON.stringify(additive)));
    assert.deepEqual(plain((await new ConversationStore(directory).load()).futureRoot), additive.futureRoot);
    const manifestFile = path.join(directory, 'sessions-v2/index.json');
    const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8')); manifest.futureManifest = { retained: true };
    fs.writeFileSync(manifestFile, JSON.stringify(manifest));
    const reloaded = new ConversationStore(directory); await reloaded.save(await reloaded.load());
    assert.deepEqual(JSON.parse(fs.readFileSync(manifestFile, 'utf8')).futureManifest, { retained: true });
    console.log('PASS unknown top-level fields survive real manifest capture and cold reload');

    const future = fixture(); const store = new ConversationStore(directory);
    await store.save(parseAppData(JSON.stringify(future)));
    const seenTools = [], requests = []; let sequence = 0;
    const registry = new ProviderRegistry();
    const resources = { createId: () => 'generated-' + ++sequence, ensureWorkspace: async () => {}, reportError() {},
      configureProviders: profiles => {
        for (const info of registry.list()) registry.unregister(info.id);
        for (const item of profiles.filter(item => isSupportedProtocol(item.protocol))) registry.register({
          info: { id: item.id, name: item.name, protocol: item.protocol, defaultBaseUrl: item.baseUrl, defaultModel: item.models[0] },
          endpoint: base => base,
          stream: async request => { requests.push(plain(request)); return { content: 'Still works', toolCalls: [] }; }
        });
      },
      tools: (id, extensions, selected, extras) => { seenTools.push(plain(extras)); return {
        definitions: () => [{ type: 'function', function: { name: 'read_file', description: 'Read', parameters: { type: 'object', properties: {} } } }],
        execute: async () => { throw Error('An unknown tool mode must never dispatch'); }
      }; } };
    const credentials = { read: async () => '', write: async () => {}, remove: async () => {} };
    const session = new SessionService(store, new AgentRuntime(registry, credentials), credentials, resources);
    Diagnostics.start(); await session.initialize();
    assert.equal(session.state.ready, true, session.state.error);
    assert.equal(session.currentConfig.configured, false, 'Only the unsupported model is unavailable');
    assert.deepEqual(plain(availableModels(session.snapshot().providerProfiles)).map(item => item.providerId), ['known']);
    assert.throws(() => modelConfig(future.providerProfiles, { providerId: 'future', modelId: 'model' }, future.config));
    assert.ok(seenTools.length); assert.equal(seenTools.at(-1).options.search.enabled, false);
    assert.equal(session.snapshot().productivity.options.search.enabled, true, 'Runtime disable must not overwrite saved intent');
    assert.ok(session.state.compatibilityWarnings.length >= 3);


    // Saving an unrelated preference exercises commitPreferences, then reload as a newer reader.
    assert.equal(await session.setSettingsToggle('autoMemory', false), true, session.state.error);
    const restored = await new ConversationStore(directory).load();
    for (const key of ['futureRoot']) assert.deepEqual(plain(restored[key]), future[key]);
    assert.deepEqual(plain(restored.config.futureConfig), future.config.futureConfig);
    assert.deepEqual(plain(restored.productivity.futureProductivity), future.productivity.futureProductivity);
    assert.deepEqual(plain(restored.productivity.options.futureOptions), future.productivity.options.futureOptions);
    assert.deepEqual(plain(restored.productivity.options.search), future.productivity.options.search);
    assert.deepEqual(plain(restored.extensions.futureExtensions), future.extensions.futureExtensions);
    assert.equal(restored.extensions.browserPolicy, 'future-policy');
    assert.equal(restored.config.reasoning, 'future-effort');
    assert.equal(restored.threads[0].reasoningEffort, 'future-effort');
    assert.equal(restored.threads[0].agentMode, 'future-mode');
    assert.deepEqual(plain(restored.productivity.options.capabilities), future.productivity.options.capabilities);
    assert.deepEqual(plain(restored.productivity.servers), future.productivity.servers);
    assert.deepEqual(plain(restored.providerProfiles), future.providerProfiles);
    assert.deepEqual(plain(restored.threads[0].futureThread), future.threads[0].futureThread);
    assert.deepEqual(plain(restored.threads[0].messages[0].futureMessage), [1, 2]);
    assert.ok(restored.threads[0].disabledTools.includes('future_tool'));
    assert.equal(restored.productivity.options.autoMemory, false);
    console.log('PASS newer snapshot -> current startup -> unrelated preference save -> cold reload retains unknown data');

    assert.equal(await session.saveProvider({ id: 'known', name: 'Renamed', presetId: 'future-preset', protocol: 'chat-completions',
      baseUrl: 'https://example.com/v1', apiKey: '', noApiKey: true, enabled: true, models: 'model', contextWindow: '' }), true, session.state.error);
    assert.deepEqual(plain(session.snapshot().providerProfiles[0].futureProfile), { retained: true });
    assert.equal(await session.selectModel('known', 'model'), true, session.state.error);
    assert.equal(session.currentConfig.configured, true);
    assert.equal(session.currentConfig.reasoning, 'default');
    session.setDraft('Continue after downgrade'); await session.send();
    assert.equal(session.state.error, ''); assert.equal(requests.length, 1);
    assert.equal(requests[0].tools.length, 0, 'Unknown tool mode allows text chat while withholding every tool');
    assert.equal(requests[0].reasoning, 'default');
    const afterSend = await new ConversationStore(directory).load();
    assert.equal(afterSend.threads[0].messages.at(-1).content, 'Still works');
    assert.equal(afterSend.threads[0].agentMode, 'future-mode');
    assert.equal(afterSend.productivity.options.capabilities[0].reasoning, 'future-effort');
    assert.deepEqual(plain(afterSend.futureRoot), future.futureRoot);
    assert.equal(afterSend.productivity.options.autoRoute, true, 'Only runtime routing is disabled');
    assert.ok(session.state.compatibilityWarnings.some(message => message.includes('自动路由')));
    console.log('PASS editing a known provider and continuing text chat preserve future data and never authorize tools');
    assert.equal(await session.setAgentMode('full'), true);
    assert.ok(!session.state.compatibilityWarnings.some(message => message.includes('工具模式')));
    session.setDraft('Use the supported mode'); await session.send();
    assert.equal(session.state.error, ''); assert.equal(requests.length, 2);
    assert.ok(requests[1].tools.some(tool => tool.function.name === 'read_file'));
    assert.equal((await new ConversationStore(directory).load()).threads[0].agentMode, 'full');
    console.log('PASS explicitly choosing a supported mode restores tools and clears its compatibility warning');

    const originalThread = session.active.id;
    const warnings = plain(session.state.compatibilityWarnings);
    assert.equal(await session.newThread(), true);
    assert.deepEqual(plain(session.state.compatibilityWarnings), warnings, 'Application warnings survive switching execution state');
    assert.equal(await session.selectThread(originalThread), true);

    const searchData = emptyData(); searchData.productivity = defaultProductivity(); searchData.productivity.options = defaultAssistantOptions();
    searchData.productivity.options.search = { provider: 'tavily', enabled: false, baseUrl: 'https://api.tavily.com',
      credentialAlias: '', futureSearch: { retained: true } };
    await saveSearchSettings(searchData, { provider: 'tavily', enabled: false, baseUrl: 'https://api.tavily.com', apiKey: '' }, credentials,
      () => 'key', async () => {});
    assert.deepEqual(plain(searchData.productivity.options.search.futureSearch), { retained: true });
    console.log('PASS editing a supported search provider retains its unknown fields');

    const mcpData = defaultProductivity(); mcpData.servers = [{ id: 'mcp', name: 'MCP', url: 'https://example.com', enabled: true,
      credentialAlias: '', futureServer: { retained: true } }];
    assert.deepEqual(plain(saveMcpCandidate(mcpData, { id: 'mcp', name: 'Edited', url: 'https://example.com', enabled: false,
      credentialAlias: '' }).servers[0].futureServer), { retained: true });
    const document = '---\nname: fixture\ndescription: Fixture\n---\nInstructions';
    const skill = parseSkill(document); skill.futureSkill = { retained: true }; skill.enabled = false;
    const skills = saveSkillCandidate({ webEnabled: true, skills: [skill] }, 'fixture', document + ' edited', []);
    assert.deepEqual(plain(skills.skills[0].futureSkill), { retained: true }); assert.equal(skills.skills[0].enabled, false);
    const merged = mergeSavedConfiguration(JSON.parse('{"__proto__":{"retained":true},"removed":"old","enabled":true}'), { removed: undefined, enabled: false });
    assert.ok(Object.hasOwn(merged, '__proto__')); assert.equal(merged.removed, undefined); assert.equal(merged.enabled, false);
    console.log('PASS resource edits preserve unknown fields while explicit removals and false values take effect');

    const browser = new BrowserSession(); browser.updatePolicy('future-policy'); assert.equal(browser.policy, 'disabled');
    const selection = { agentMode: 'future-mode', disabledTools: ['future_tool'] };
    const tools = new SelectedTools({ definitions: () => [{ type: 'function', function: { name: 'read_file' } }], execute: async () => { throw Error('Must not dispatch'); } }, selection);
    assert.equal(tools.definitions().length, 0);
    await assert.rejects(tools.execute({ id: 'call', type: 'function', function: { name: 'read_file', arguments: '{}' } }, new Cancellation()));
    const modeData = fixture(); modeData.threads[0].agentMode = 'future-mode';
    assert.equal(parseAppData(JSON.stringify(modeData)).threads[0].agentMode, 'future-mode');
    const customData = fixture(); customData.threads[0].agentMode = 'custom';
    assert.ok(parseAppData(JSON.stringify(customData)).threads[0].disabledTools.includes('future_tool'));
    let connections = 0;
    const mcp = new McpTools(future.productivity.servers, new ToolApproval(), () => { connections++; throw Error('Must not connect'); }, () => future.productivity.servers);
    await assert.rejects(mcp.execute({ id: 'mcp', type: 'function', function: { name: 'mcp_list_tools', arguments: '{"server":"future-mcp"}' } }, new Cancellation()));
    assert.equal(connections, 0);
    console.log('PASS unknown browser permission and tool mode fail closed without rewriting stored values');

    const logs = Diagnostics.snapshot().logging.records.filter(item => item.log.module === 'configuration');
    assert.ok(logs.some(item => item.log.event === 'unsupported' && item.log.fields.setting === 'search.provider'));
    assert.ok(logs.every(item => item.log.fields.dataVersion === 2));
    const sanitized = new LogSanitizer().sanitize({ setting: 'PRIVATE_SECRET', dataVersion: 2, providerId: 'PRIVATE_SECRET' }, undefined, false);
    assert.ok(!JSON.stringify(sanitized).includes('PRIVATE_SECRET')); Diagnostics.stop();
    console.log('PASS compatibility diagnostics retain setting paths and schema versions, without arbitrary configuration values');

    for (const corrupt of [data => { data.productivity.options.search.enabled = 'yes'; },
      data => { data.providerProfiles[1].protocol = 3; }, data => { data.threads[0].disabledTools = [null]; },
      data => { data.extensions.browserPolicy = {}; }, data => { data.threads[0].messages[0].content = 7; },
      data => { data.productivity.options.capabilities[0].reasoning = null; }, data => { data.productivity.servers[0].authType = 3; },
      data => { data.threads[0].disabledTools = ['write_file']; },
      data => { data.version = 999; }]) {
      const data = fixture(); corrupt(data); assert.throws(() => parseAppData(JSON.stringify(data)));
    }
    console.log('PASS corrupt known structures and unsupported storage formats still fail fast');
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
