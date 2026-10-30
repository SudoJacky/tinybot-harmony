// Real settings persistence with an in-memory credential vault; no device or network.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, require: id => {
    assert.ok(id.startsWith('.'), 'Unexpected native dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name)), plain = value => JSON.parse(JSON.stringify(value));
const { saveSearchSettings } = from('services/SearchSettings');
const diagnosticLogs = [];
from('model/Diagnostics').Diagnostics.configureLogSink(data => diagnosticLogs.push(data));
const { emptyData, parseAppData } = from('model/Conversation');
const { defaultProductivity } = from('model/Productivity');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const { validateSearchConfig, searchCredentialAlias } = from('model/WebSearch');
const { searchEditorDraft, searchSaveDraft, searchProviderStatus, tavilyKeyReady } = from('model/SearchEditor');
const endpoint = 'https://api.tavily.com';
function fixture() {
  const data = emptyData(); data.productivity = defaultProductivity();
  data.productivity.options = defaultAssistantOptions();
  data.productivity.options.search = { provider: 'tavily', enabled: true, baseUrl: endpoint, credentialAlias: 'old-key', future: { retained: true } };
  const f = { data, keys: new Map([['old-key', 'test-secret']]), writes: [], removed: [], commits: 0, ids: 0, reads: [] };
  f.vault = { read: async alias => { f.reads.push(alias); return f.keys.get(alias) || ''; },
    write: async (alias, key) => { f.writes.push(alias); f.keys.set(alias, key); },
    remove: async alias => { f.removed.push(alias); f.keys.delete(alias); } };
  f.save = (draft, commit = async next => { f.commits++; f.data = parseAppData(JSON.stringify(next)); }) =>
    saveSearchSettings(f.data, draft, f.vault, () => String(++f.ids), commit);
  f.draft = () => searchEditorDraft(f.data.productivity.options.search);
  f.config = () => f.data.productivity.options.search;
  return f;
}
(async () => {
  const f = fixture();
  let draft = f.draft(); draft.provider = 'bing-browser';
  await f.save(searchSaveDraft(draft));
  assert.equal(f.config().tavily.credentialAlias, 'old-key');
  assert.equal(f.config().credentialAlias, undefined);
  assert.equal(f.reads.length, 0); assert.equal(f.writes.length, 0); assert.equal(f.removed.length, 0);
  assert.deepEqual(plain(f.config().future), { retained: true });
  draft = f.draft(); assert.equal(tavilyKeyReady(draft), true); draft.provider = 'tavily';
  await f.save(searchSaveDraft(draft));
  assert.equal(f.config().credentialAlias, 'old-key'); assert.deepEqual(f.reads, ['old-key']);
  assert.equal(f.writes.length, 0); assert.equal(f.removed.length, 0);
  console.log('PASS Tavily → Bing → cold reload → Tavily retains endpoint, key and unknown fields');

  draft = f.draft(); draft.baseUrl = 'https://new.example';
  const before = plain(f.data);
  assert.equal(tavilyKeyReady(draft), false);
  await assert.rejects(f.save(searchSaveDraft(draft)), /重新填写/);
  assert.deepEqual(plain(f.data), before); assert.equal(f.keys.get('old-key'), 'test-secret');
  draft.apiKey = 'replacement-secret';
  await assert.rejects(f.save(searchSaveDraft(draft), async () => { throw Error('Disk failure'); }), /Disk failure/);
  assert.deepEqual(plain(f.data), before); assert.equal(f.keys.get('old-key'), 'test-secret');
  assert.deepEqual([...f.keys.keys()], ['old-key']);
  await f.save(searchSaveDraft(draft), async next => {
    assert.equal(f.keys.has('old-key'), true, 'Do not delete the old key before the config commits');
    f.data = parseAppData(JSON.stringify(next));
  });
  assert.equal(f.config().baseUrl, 'https://new.example'); assert.equal(f.keys.has('old-key'), false);
  assert.equal(f.keys.get(f.config().credentialAlias), 'replacement-secret');
  assert.ok(!JSON.stringify(f.data).includes('replacement-secret'));
  console.log('PASS endpoint isolation, explicit key replacement, failed commit rollback and post-commit cleanup');
  const rollback = fixture(), rollbackDraft = rollback.draft(); rollbackDraft.apiKey = 'PRIVATE_NEW_KEY';
  const primary = Object.assign(Error('primary commit failure'), { code: 28 });
  rollback.vault.remove = async () => { throw Object.assign(Error('PRIVATE_ALIAS cleanup failed'), { code: 201 }); };
  await assert.rejects(rollback.save(searchSaveDraft(rollbackDraft), async () => { throw primary; }), error => error === primary);
  const primaryLog = diagnosticLogs.findLast(data => data.event === 'save_failed');
  const cleanupLog = diagnosticLogs.findLast(data => data.event === 'credential_rollback_failed');
  assert.equal(primaryLog.fields.errorCode, 28); assert.equal(cleanupLog.fields.errorCode, 201);
  assert.equal(cleanupLog.fields.credentialScope, 'search');
  assert.ok(!JSON.stringify(diagnosticLogs).includes('PRIVATE_'));
  console.log('PASS rollback failure cannot replace the original settings commit failure; both retain native codes');

  const clear = fixture(); draft = clear.draft(); draft.clearKey = true;
  await assert.rejects(clear.save(searchSaveDraft(draft)), /重新填写/);
  assert.equal(clear.keys.has('old-key'), true);
  draft.provider = 'bing-browser'; await clear.save(searchSaveDraft(draft));
  assert.equal(clear.config().tavily.credentialAlias, ''); assert.equal(clear.keys.has('old-key'), false);
  draft = clear.draft(); draft.provider = 'tavily';
  await assert.rejects(clear.save(searchSaveDraft(draft)), /重新填写/);
  draft.enabled = false; await clear.save(searchSaveDraft(draft));
  assert.equal(clear.config().enabled, false);
  console.log('PASS explicit removal from inactive provider and enabled-Tavily validation');

  const changed = fixture(); draft = changed.draft(); draft.provider = 'bing-browser'; draft.baseUrl = 'https://changed.example/';
  await changed.save(searchSaveDraft(draft));
  assert.equal(changed.config().tavily.baseUrl, 'https://changed.example'); assert.equal(changed.config().tavily.credentialAlias, '');
  assert.equal(changed.keys.has('old-key'), false);
  const missing = fixture(); missing.keys.clear();
  await assert.rejects(missing.save(searchSaveDraft(missing.draft())), /API Key 为空/);
  assert.equal(missing.commits, 0);
  console.log('PASS inactive endpoint changes discard stale credentials; missing vault entries fail visibly');

  const multi = fixture();
  const profile = { id: 'deepseek', name: 'Official', protocol: 'chat-completions', baseUrl: 'https://api.deepseek.com',
    enabled: true, noApiKey: false, credentialAlias: 'model-key', models: ['deepseek-chat'] };
  multi.data.providerProfiles = [profile]; multi.keys.set('model-key', 'model-secret');
  multi.config().deepseek = { futureOption: 'preserve' };
  multi.config().tavily = { baseUrl: endpoint, credentialAlias: 'old-key', futureOption: 'preserve' };
  draft = multi.draft(); draft.provider = 'deepseek'; draft.apiKey = 'new-inactive-tavily-key';
  await multi.save(searchSaveDraft(draft));
  assert.equal(multi.config().provider, 'deepseek'); assert.equal(multi.config().modelProviderId, 'deepseek');
  assert.equal(multi.config().deepseek.modelProviderId, 'deepseek'); assert.ok(multi.reads.includes('model-key'));
  assert.equal(multi.config().deepseek.futureOption, 'preserve'); assert.equal(multi.config().tavily.futureOption, 'preserve');
  assert.equal(multi.keys.get(multi.config().tavily.credentialAlias), 'new-inactive-tavily-key');
  assert.equal(searchCredentialAlias(multi.config(), [profile]), 'model-key');
  draft = multi.draft(); draft.provider = 'bing-browser'; await multi.save(searchSaveDraft(draft));
  assert.equal(multi.draft().modelProviderId, 'deepseek');
  console.log('PASS editing an inactive provider commits atomically while validating the selected provider');

  const future = fixture();
  future.data.productivity.options.search = { provider: 'future-search', enabled: true, custom: { keep: 'unchanged' } };
  const futureData = parseAppData(JSON.stringify(future.data));
  assert.equal(futureData.productivity.options.search.provider, 'future-search');
  assert.throws(() => searchSaveDraft(future.draft()), /配置已保留/);
  assert.throws(() => validateSearchConfig(future.config()));
  assert.throws(() => searchCredentialAlias(future.config(), []));
  draft = future.draft(); draft.provider = 'bing-browser'; await future.save(searchSaveDraft(draft));
  assert.deepEqual(plain(future.config().custom), { keep: 'unchanged' });
  for (const invalid of [null, { provider: 'bad name', enabled: true }, { provider: 'tavily', enabled: false, baseUrl: 'http://unsafe', credentialAlias: '' },
    { provider: 'bing-browser', enabled: true, tavily: { baseUrl: endpoint, credentialAlias: 5 } },
    { provider: 'bing-browser', enabled: true, deepseek: 'invalid' }]) {
    assert.throws(() => validateSearchConfig(invalid, true));
  }
  assert.match(searchProviderStatus('deepseek', searchEditorDraft(), [], 'enabled'), /未配置/);
  assert.match(searchProviderStatus('deepseek', searchEditorDraft(), [profile], 'enabled'), /已就绪/);
  assert.match(searchProviderStatus('deepseek', searchEditorDraft(), [profile, { ...profile, id: 'second' }], 'enabled'), /未配置/);
  assert.match(searchProviderStatus('bing-browser', searchEditorDraft(), [], 'disabled'), /需要启用浏览器/);
  console.log('PASS unknown-provider retention, explicit replacement, structural validation and readiness states');
})().catch(error => { console.error(error); process.exitCode = 1; });
