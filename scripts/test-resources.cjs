// Exercise production session/runtime and live dispatch; native network and vault are deterministic fixtures.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
let ids = 0;
const nativeSecrets = new Map(), nativeLogs = [];
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText,
    { exports, setTimeout, clearTimeout, console, Observed: x => x, require: id => {
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => 'native-' + ++ids } };
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { error: (...args) => nativeLogs.push(args) } };
      if (id.startsWith('@kit.')) return {};
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const stub = (name, value) => cache.set(path.join(root, name + '.ets'), value);
const connections = [], calls = [];
class FakeMcp {
  constructor(server) { this.server = structuredClone(server); connections.push(this.server); }
  async list(cancel) { cancel.check(); return [{ name: 'echo', description: 'Echo text', inputSchema: { type: 'object' } }]; }
  async call(name, args, cancel) { cancel.check(); calls.push({ server: this.server, name, args }); return { text: args.text }; }
}
stub('services/McpClient', { McpClient: FakeMcp });
stub('services/CredentialStore', { CredentialStore: class {
  async write(k, v) { nativeSecrets.set(k, v); } async read(k) { return nativeSecrets.get(k) || ''; } async remove(k) { nativeSecrets.delete(k); }
} });
stub('services/McpOAuth', { McpOAuth: { login: async () => 'oauth-alias' } });
const { emptyData, parseAppData } = from('model/Conversation');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { defaultProductivity } = from('model/Productivity');
const { modelConfig } = from('model/ProviderProfiles');
const { parseSkill } = from('model/Skills');
const { parseMcpRequest, parseSkillRequest, saveSkillCandidate } = from('model/ResourceManagement');
const { Cancellation } = from('services/Cancellation');
const { ToolApproval } = from('services/ToolApproval');
const { prepareNativeMcp } = from('services/NativeResourceSetup');
const { SkillInstaller } = from('services/SkillInstaller');
const { SkillTools } = from('services/SkillTools');
const { McpTools } = from('services/McpTools');
const { ToolSet } = from('services/ToolSet');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { AgentRuntime } = from('services/AgentRuntime');
const { SessionService } = from('services/SessionService');
const document = (name = 'test-skill', body = 'Follow the reference.') => `---\nname: ${name}\ndescription: Test workflow\n---\n${body}\n`;
const call = (name, args) => ({ id: 'call-' + ++ids, type: 'function', function: { name, arguments: JSON.stringify(args) } });
const reply = (content = 'done', toolCalls = []) => ({ content, toolCalls });
const invoke = (tools, name, args, cancel = new Cancellation()) => tools.execute(call(name, args), cancel);
function seed() {
  const data = emptyData(), profile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: '', noApiKey: true, enabled: true, models: ['model'], contextWindow: 32768 };
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions(); data.productivity.options.autoMemory = false;
  data.providerProfiles = [profile]; data.config = modelConfig([profile], { providerId: 'test', modelId: 'model' }, data.config);
  data.threads = [{ id: 'chat', title: 'Test', titleEdited: true, updatedAt: 1, messages: [], draft: '', modelRef: { providerId: 'test', modelId: 'model' } }];
  data.activeThreadId = 'chat'; return data;
}
async function fixture(data = seed()) {
  const requests = [], errors = [], logs = [], secrets = new Map(); let liveTools;
  const repo = { saved: JSON.stringify(data), beforeSave: async () => {}, load: async () => parseAppData(repo.saved),
    save: async d => { const text = JSON.stringify(d); await repo.beforeSave(d); repo.saved = text; } };
  const provider = { info: { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: '', defaultModel: 'model' }, endpoint: b => b,
    respond: async () => reply(), stream: async (r, c, emit) => { requests.push(r); const result = await provider.respond(r); c.check(); emit(result.content); return result; } };
  const registry = new ProviderRegistry(); registry.register(provider);
  const keys = { read: async k => secrets.get(k) || '', write: async (k,v) => secrets.set(k,v), remove: async k => secrets.delete(k) };
  const approval = { request: async (_title, _detail, cancel) => cancel.check() };
  const resources = { createId: () => 'id-' + ++ids, ensureWorkspace: async () => {}, configureProviders: () => {},
    tools: (_id, extensions, selected, extras, _attachments, live) => {
      liveTools = new ToolSet([new SkillTools(extensions.skills, selected, () => live.skills()), new McpTools(extras.servers, approval, () => live.servers())]); return liveTools;
    }, reportError: s => errors.push(s), reportResources: s => logs.push(s),
    installSkill: async source => ({ ...parseSkill(document('downloaded')), source: { url: source, installedAt: 1, modified: false } }),
    prepareMcp: async (server, request, cancel) => { cancel.check(); if (request.auth === 'bearer') { server.credentialAlias = 'secret-' + ++ids; await keys.write(server.credentialAlias, 'PRIVATE-TOKEN'); } return server; },
    testMcp: async (_server, cancel) => { cancel.check(); return 1; } };
  const session = new SessionService(repo, new AgentRuntime(registry, keys), keys, resources); await session.initialize();
  return { session, repo, provider, requests, resources, errors, logs, secrets, tools: () => liveTools,
    send: async script => { let i = 0; provider.respond = async () => i < script.length ? reply('', [script[i++]]) : reply(); session.setDraft('Manage my resources'); await session.send(); } };
}
const receipts = f => f.requests.flatMap(r => r.messages.filter(m => m.role === 'tool').map(m => m.content));
async function main() {
  for (const bad of [null, [], {}, { action:'save', name:'x', url:'https://x', auth:'bearer', token:'SECRET' }, { action:'remove' }, {action:'test',id:'x',url:'https://x'}]) assert.throws(() => parseMcpRequest(JSON.stringify(bad)));
  for (const bad of [{action:'create',name:'overwrite',document:document()}, {action:'update',name:'x'}, {action:'install',document:document()}]) assert.throws(() => parseSkillRequest(JSON.stringify(bad)));
  const f = await fixture();
  const create = call('skill_manage', {action:'create',document:document(),files:JSON.stringify([{path:'references/guide.md',content:'REFERENCE'}])});
  await f.send([create, call('read_skill',{name:'test-skill'}), call('read_skill',{name:'test-skill',path:'references/guide.md'}),
    call('skill_manage',{action:'update',name:'test-skill',document:document('test-skill','Updated body'),files:'[]'}), call('read_skill',{name:'test-skill'})]);
  assert.ok(receipts(f).some(r => r.includes('REFERENCE'))); assert.ok(receipts(f).some(r => r.includes('Updated body')));
  assert.equal(f.session.snapshot().extensions.skills[0].files.length,0);
  assert.equal((await f.repo.load()).threads[0].messages.at(-1).content,'done');
  const schemas = f.requests.map(r => JSON.stringify(r.tools.filter(t => ['skill_manage','mcp_manage','read_skill','list_skills','mcp_call','mcp_search_tools','mcp_list_tools'].includes(t.function.name))));
  assert.ok(schemas.every(s => s === schemas[0]));
  const reboot = await fixture(await f.repo.load()); await reboot.send([call('read_skill',{name:'test-skill'})]); assert.ok(receipts(reboot).some(r => r.includes('Updated body')));
  await f.send([call('skill_manage',{action:'disable',name:'test-skill'}), call('read_skill',{name:'test-skill'}), call('skill_manage',{action:'remove',name:'test-skill'})]);
  assert.equal(f.session.snapshot().extensions.skills.length,0);
  console.log('PASS create/update/reference reads in the same turn, fixed schemas, disable/remove and restart persistence');

  const failed = await fixture(); failed.repo.beforeSave = async d => { if (d.extensions?.skills.length) { failed.session.setDraft('concurrent typing'); throw Error('disk full'); } };
  await failed.send([create]); assert.equal(failed.session.snapshot().extensions.skills.length,0); assert.equal(failed.session.snapshot().threads[0].draft,'concurrent typing');
  assert.ok(failed.errors.some(e => e.includes('disk full')));
  const ro = seed(); ro.productivity.options.readOnly = true; const readonly = await fixture(ro); await readonly.send([]);
  assert.ok(!readonly.requests[0].tools.some(t => ['skill_manage','mcp_manage'].includes(t.function.name)));
  const manual = parseSkill(document().replace('description:', 'disable-model-invocation: true\ndescription:'));
  await assert.rejects(() => invoke(new SkillTools([], '', () => [manual]),'read_skill',{name:manual.name}));
  const ui = await fixture(); assert.equal(await ui.session.saveSkill('',document(),[]),true); await ui.send([call('read_skill',{name:'test-skill'})]);
  assert.ok(receipts(ui).some(r => r.includes('Follow the reference')));
  console.log('PASS atomic save failure, concurrent drafts, UI/chat shared storage, read-only and manual-only restrictions');

  const racing = await fixture(); let open, entered;
  const gate = new Promise(resolve => { open = resolve; }), started = new Promise(resolve => { entered = resolve; });
  let held = false;
  racing.repo.beforeSave = async d => { if (!held && d.extensions?.skills.length) { held = true; entered(); await gate; } };
  const running = racing.send([create]); await started;
  racing.session.setDraft('typing during resource save'); const flush = racing.session.flushDraft();
  await Promise.resolve(); open(); await Promise.all([running,flush]);
  assert.equal((await racing.repo.load()).extensions.skills.length,1);
  assert.equal((await racing.repo.load()).threads[0].draft,'typing during resource save');
  console.log('PASS concurrent draft persistence cannot overwrite a committed resource snapshot');

  const team = await fixture(); let parent = 0;
  team.provider.respond = async request => {
    if (request.tools.some(t => t.function.name === 'team_complete_task')) {
      assert.ok(!request.tools.some(t => ['skill_manage','mcp_manage'].includes(t.function.name)));
      return request.messages.some(m => m.role === 'tool') ? reply('internal draft') : reply('',[call('team_complete_task',{summary:'verified evidence',unresolved:[],artifacts:[]})]);
    }
    if (++parent === 1) return reply('',[call('team_recruit',{goal:'Research',members:[{id:'researcher',instructions:'Research'}],tasks:[{id:'facts',title:'Facts',memberId:'researcher',instructions:'Return evidence',dependencies:[]}]})]);
    if (parent === 2) return reply('premature final');
    assert.ok(JSON.stringify(request.messages).includes('verified evidence')); return reply('integrated final');
  };
  team.session.setDraft('/team research'); await team.session.send();
  assert.ok(team.session.snapshot().threads[0].messages.at(-1).content.includes('integrated final'));
  console.log('PASS resource wrappers preserve team completion guards; workers cannot change app resources');

  const m = await fixture(); let serverId;
  m.provider.respond = async r => {
    const count = m.requests.length;
    if (count === 1) return reply('',[call('mcp_manage',{action:'save',name:'Echo',url:'https://echo.example/mcp',auth:'bearer'})]);
    serverId = m.session.snapshot().productivity.servers[0]?.id;
    if (count === 2) return reply('',[call('mcp_list_tools',{server:serverId})]);
    if (count === 3) return reply('',[call('mcp_call',{server:serverId,tool:'echo',arguments:'{"text":"hello"}'})]);
    return reply();
  };
  m.session.setDraft('Configure echo'); await m.session.send(); assert.equal(calls.at(-1).args.text,'hello');
  assert.ok(!JSON.stringify(m.requests).includes('PRIVATE-TOKEN')); assert.ok(!m.repo.saved.includes('PRIVATE-TOKEN'));
  const old = structuredClone(m.session.snapshot().productivity.servers[0]);
  m.resources.testMcp = async () => { throw Error('probe failed'); };
  await m.send([call('mcp_manage',{action:'save',id:serverId,name:'Changed',url:'https://other.example/mcp',auth:'bearer'})]);
  assert.equal(m.session.snapshot().productivity.servers[0].url,old.url); assert.equal(m.secrets.size,1); assert.ok(m.errors.some(e => e.includes('probe failed')));
  m.resources.testMcp = async () => 1;
  await m.send([call('mcp_list_tools',{server:serverId}),call('mcp_manage',{action:'save',id:serverId,name:'Changed',url:'https://other.example/mcp',auth:'none'}),
    call('mcp_call',{server:serverId,tool:'echo',arguments:'{}'}),call('mcp_search_tools',{server:serverId,query:'echo'}),call('mcp_call',{server:serverId,tool:'echo',arguments:'{"text":"new"}'})]);
  assert.equal(calls.at(-1).server.url,'https://other.example/mcp'); assert.equal(m.secrets.size,0);
  assert.ok(receipts(m).some(r => r.includes('mcp_list_tools') && !r.includes('next')));
  await m.send([call('mcp_manage',{action:'disable',id:serverId}),call('mcp_list_tools',{server:serverId}),call('mcp_manage',{action:'enable',id:serverId}),call('mcp_list_tools',{server:serverId}),call('mcp_manage',{action:'remove',id:serverId})]);
  assert.equal(m.session.snapshot().productivity.servers.length,0);
  console.log('PASS MCP save/probe/discover/call in one turn, failure rollback, stale schema invalidation and credential cleanup');

  const fetched = [], docs = new Map();
  const transport = { resolve: (ref,base) => new URL(ref,base).href, get: async (url,cancel) => { cancel.check(); fetched.push(url); const body = docs.get(url); if (body === undefined) throw Error('404 '+url); return {url,contentType:'text/plain',body}; } };
  const installer = new SkillInstaller(transport), source = 'https://raw.example/a/SKILL.md';
  docs.set(source,document('downloaded','Exact\r\nsource')); docs.set('https://raw.example/a/references/a.md','exact reference');
  const downloaded = await installer.install(source,['references/a.md'],new Cancellation());
  assert.equal(downloaded.document,docs.get(source)); assert.equal(downloaded.files[0].content,'exact reference'); assert.equal(downloaded.source.modified,false);
  const settings = {webEnabled:true,skills:[downloaded]}; assert.equal(saveSkillCandidate(settings,'downloaded',downloaded.document,downloaded.files).skills[0].source.modified,true);
  for (const paths of [['../secret'],['%2e%2e/secret'],['SKILL.md'],['a','a']]) await assert.rejects(() => installer.install(source,paths,new Cancellation()));
  await assert.rejects(() => installer.install(source,['missing.md'],new Cancellation()));
  const gh = 'https://github.com/org/repo/tree/main/skill';
  docs.set('https://api.github.com/repos/org/repo/contents/skill?ref=main',JSON.stringify([{type:'file',path:'skill/SKILL.md',download_url:source},{type:'dir',path:'skill/references'}]));
  docs.set('https://api.github.com/repos/org/repo/contents/skill/references?ref=main',JSON.stringify([{type:'file',path:'skill/references/a.md',download_url:'https://raw.example/a/references/a.md'}]));
  assert.equal((await installer.install(gh,[],new Cancellation())).files[0].path,'references/a.md');
  docs.set('https://raw.example/a/references/a.md','binary\0data'); await assert.rejects(() => installer.install(gh,[],new Cancellation()));
  console.log('PASS exact-source HTTPS/GitHub installs, provenance, references and bounded path/binary/missing-file failures');

  const approval = new ToolApproval(), server = {id:'native',name:'Native',url:'https://echo.example/mcp',enabled:true,credentialAlias:''};
  const prepared = prepareNativeMcp(server,{action:'save',auth:'bearer'},approval,undefined,new Cancellation());
  assert.equal(approval.form.fields[0].type,'password'); approval.submit(['super-secret']); const result = await prepared;
  assert.equal(nativeSecrets.get(result.credentialAlias),'super-secret'); assert.ok(!JSON.stringify(result).includes('super-secret')); assert.equal(approval.form,undefined);
  const cancel = new Cancellation(), pending = prepareNativeMcp(server,{action:'save',auth:'bearer'},approval,undefined,cancel);
  cancel.cancel(); await assert.rejects(() => pending); assert.equal(approval.form,undefined);
  const dismissed = prepareNativeMcp(server,{action:'save',auth:'bearer'},approval,undefined,new Cancellation()); approval.cancelForm(); await assert.rejects(() => dismissed);
  assert.equal(nativeSecrets.size,1);
  console.log('PASS native password isolation, user cancellation and cleanup');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
