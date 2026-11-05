// Native errors and remote failures through the real discovery/settings services.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map(), logs = [];
let networkError, keyError, streamError, streamThrows = false, response = { responseCode: 200, result: '{"data":[]}' };
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } }, '@kit.RemoteCommunicationKit': { rcp: {} },
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
    destroy() {}, on() {}, async request() { if (networkError) throw networkError; return response; },
    requestInStream(url, options, callback) { if (streamThrows) throw streamError; callback(streamError, 0); }
  }) } },
  '@kit.AssetStoreKit': { asset: { Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, SYNC_TYPE: 5 },
    ReturnType: { ALL: 1 }, Accessibility: { DEVICE_UNLOCKED: 1 }, SyncType: { NEVER: 1 }, ErrorCode: { NOT_FOUND: 404 },
    async query() { if (keyError) throw keyError; return [new Map([[2, new TextEncoder().encode('saved')]])]; },
    async add() { if (keyError) throw keyError; }, async remove() {} } },
  '@kit.ArkTS': { util: { generateRandomUUID: () => 'request', TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
    TextDecoder: class { decodeToString(b) { return new TextDecoder().decode(b); } } } }
};
function load(name) {
  const file = path.resolve(root, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, setTimeout, clearTimeout, Observed: cls => cls, require: id => {
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
    assert.ok(kits[id], id); return kits[id];
  } }, { filename: file });
  return exports;
}
const { discoverModels } = load('services/ModelDiscovery');
const { ProfileSettings } = load('services/ProfileSettings');
const { CredentialStore } = load('services/CredentialStore');
const { emptyData } = load('model/Conversation');
const { Diagnostics } = load('model/Diagnostics'); Diagnostics.configureLogSink(log => logs.push(log));
const draft = { id: '', name: 'Fixture', protocol: 'chat-completions', baseUrl: 'https://fixture.invalid/v1',
  apiKey: 'fixture', noApiKey: false, enabled: true, models: 'test', contextWindow: '' };
async function rejected(action) { try { await action(); } catch (error) { return error; } throw Error('Expected failure'); }
(async () => {
  networkError = Object.assign(Error('Internal error'), { code: 111001 });
  let error = await rejected(() => discoverModels(draft, []));
  assert.match(error.message, /获取模型/); assert.match(error.message, /111001/); assert.match(error.message, /Internal error/);
  assert.equal(error.code, 111001); assert.equal(logs.at(-1).fields.errorCode, 111001);
  networkError = undefined; response = { responseCode: 403, result: '{"error":{"code":"permission_denied","message":"PRIVATE_KEY"}}' };
  error = await rejected(() => discoverModels(draft, []));
  assert.match(error.message, /403/); assert.match(error.message, /permission_denied/); assert.ok(!error.message.includes('PRIVATE_KEY'));
  response = { responseCode: 200, result: '<html>PRIVATE_KEY</html>' };
  error = await rejected(() => discoverModels(draft, []));
  assert.match(error.message, /JSON/); assert.ok(!error.message.includes('PRIVATE_KEY'));
  const settings = new ProfileSettings(new CredentialStore(), () => 'fixture');
  keyError = Object.assign(Error('Internal error'), { code: 222001 });
  error = await rejected(() => settings.save(emptyData(), draft, async () => {}));
  assert.match(error.message, /写入.*API Key/); assert.match(error.message, /222001/); assert.equal(error.code, 222001);
  const data = emptyData(); data.providerProfiles = [{ ...draft, id: 'p', models: ['test'], credentialAlias: 'saved' }];
  error = await rejected(() => settings.save(data, { ...draft, id: 'p', apiKey: '' }, async () => {}));
  assert.match(error.message, /读取.*API Key/); assert.equal(error.code, 222001);
  keyError = undefined;
  error = await rejected(() => settings.save(emptyData(), draft, async () => { throw Object.assign(Error('Disk full'), { code: 333001 }); }));
  assert.match(error.message, /保存模型配置/); assert.match(error.message, /333001/);
  const { httpProviderError, TransientProviderError } = load('services/providers/ProviderErrors');
  const quota = httpProviderError(429, '{"error":{"code":"insufficient_quota","message":"PRIVATE_PROMPT"}}');
  const limited = httpProviderError(429, '{"error":{"code":"rate_limit_exceeded"}}');
  assert.match(quota.message, /余额|额度/); assert.match(limited.message, /频率|限流/); assert.notEqual(quota.message, limited.message);
  assert.ok(!(quota instanceof TransientProviderError)); assert.ok(limited instanceof TransientProviderError);
  assert.match(httpProviderError(402, '{}').message, /余额|额度/);
  for (const item of [quota, limited]) { Diagnostics.log('error', 'network', 'request_failed', {}, item); }
  assert.equal(logs.at(-1).fields.providerCode, 'rate_limit_exceeded'); assert.equal(logs.at(-1).fields.http, 429);
  const { ProtocolProvider } = load('services/providers/ProtocolProvider');
  const { Cancellation } = load('services/Cancellation');
  const provider = new ProtocolProvider({ id: 'fixture', protocol: 'chat-completions' }, { hydrate: async messages => messages, recordUsage() {} });
  const input = { baseUrl: draft.baseUrl, apiKey: 'fixture', model: 'test', messages: [{ role: 'user', content: 'test' }], tools: [] };
  streamThrows = true; streamError = Object.assign(Error('Internal error'), { code: 444001 });
  error = await rejected(() => provider.stream(input, new Cancellation(), () => {}));
  assert.match(error.message, /创建模型网络请求失败/); assert.match(error.message, /444001/); assert.equal(logs.at(-1).fields.errorCode, 444001);
  streamThrows = false; streamError = Object.assign(Error('Connection refused'), { code: 2300006 });
  error = await rejected(() => provider.stream(input, new Cancellation(), () => {}));
  assert.ok(error instanceof TransientProviderError); assert.match(error.message, /Connection refused/); assert.match(error.message, /2300006/);
  assert.equal(logs.at(-1).fields.nativeCode, 2300006);
  const { ChatStream } = load('services/ChatStream');
  error = await rejected(async () => new ChatStream(() => {}).push('data: ' + JSON.stringify({ error: { code: 'insufficient_quota', message: 'PRIVATE_PROMPT' } }) + '\n\n'));
  assert.match(error.message, /余额|额度/); assert.equal(error.providerCode, 'insufficient_quota');
  const cases = [];
  kits['@ohos/hypium'] = { describe: (_name, run) => run(), it: (name, _flags, run) => cases.push({ name, run }),
    expect: value => ({ assertEqual: expected => assert.equal(value, expected), assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false) }) };
  load(path.resolve(root, '../../test/ProviderProfiles.test')).default();
  for (const test of cases) await test.run();
  console.log('PASS existing provider profile/protocol contracts: ' + cases.length + ' cases');
  assert.ok(!JSON.stringify(logs).includes('PRIVATE_'));
  console.log('PASS native error codes, operation stages, safe response errors, quota/rate-limit distinction and diagnostics');
})().catch(error => { console.error(error); process.exitCode = 1; });
