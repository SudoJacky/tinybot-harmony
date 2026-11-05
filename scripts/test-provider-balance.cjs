// Real balance service, credential scoping and response validation, without a network/account.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map(), requests = [], logs = [];
let status = 200, payload, keyReads = 0, networkError;
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } }, '@kit.RemoteCommunicationKit': { rcp: {} },
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
    destroy() {}, async request(url, options) { requests.push({ url, options }); if (networkError) throw networkError;
      return { responseCode: status, result: typeof payload === 'string' ? payload : JSON.stringify(payload) }; }
  }) } },
  '@kit.AssetStoreKit': { asset: { Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3 }, ReturnType: { ALL: 1 }, ErrorCode: { NOT_FOUND: 404 },
    async query() { keyReads++; return [new Map([[2, new TextEncoder().encode('saved-key')]])]; } } },
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } },
    TextDecoder: class { decodeToString(b) { return new TextDecoder().decode(b); } } } }
};
function load(name) {
  const file = path.resolve(root, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText, { exports, require: id => {
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
    assert.ok(kits[id], id); return kits[id];
  } }, { filename: file }); return exports;
}
const { queryProviderBalance, supportsProviderBalance } = load('services/ProviderBalance');
load('model/Diagnostics').Diagnostics.configureLogSink(log => logs.push(log));
const row = (currency, total) => ({ currency, total_balance: total, granted_balance: '0.00', topped_up_balance: total });
const draft = { id: 'p', protocol: 'chat-completions', baseUrl: 'https://api.deepseek.com/v1', apiKey: 'new-key', noApiKey: false };
async function checkUi() {
  const file = path.join(root, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ProviderBalanceCard.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(root, 'views/ProviderBalanceCard.ets')).mtimeMs, 'Build balance card before --ui checks');
  const tree = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ProviderBalanceCard');
  const methods = component.members.filter(n => ['reset', 'refresh', 'supported', 'aboutToAppear', 'aboutToDisappear', 'visibilityChanged', 'queryOnEntry'].includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n');
  const context = { exports: {}, supportsProviderBalance, queryProviderBalance: () => new Promise(resolve => { pending.push(resolve); }) };
  const pending = [];
  vm.runInNewContext(ts.transpileModule(`class Card { ${methods} } exports.Card=Card;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
  const card = Object.assign(new context.exports.Card(), { editor: { ...draft, snapshot: () => ({ ...draft }) }, profiles: [],
    disabled: false, active: true, generation: 0, loading: false, alive: true, queriedOnEntry: false, error: '' });
  const old = card.refresh(); assert.equal(card.loading, true);
  card.reset(); const fresh = card.refresh();
  pending[0]({ available: true, amounts: [{ currency: 'CNY', total: '900' }] }); await old;
  assert.equal(card.result, undefined, 'A response for an old URL/key is discarded'); assert.equal(card.loading, true);
  pending[1]({ available: false, amounts: [{ currency: 'CNY', total: '0.00' }] }); await fresh;
  assert.equal(card.result.amounts[0].total, '0.00'); assert.equal(card.loading, false);
  context.queryProviderBalance = async () => { throw Error('Query failed [401]'); };
  await card.refresh(); assert.equal(card.result, undefined, 'A failed refresh cannot leave an old balance presented as current');
  assert.match(card.error, /401/);
  context.queryProviderBalance = () => new Promise(resolve => pending.push(resolve));
  const leaving = card.refresh(); card.aboutToDisappear(); pending[2]({ available: true }); await leaving;
  assert.equal(card.result, undefined); assert.equal(card.loading, false);
  let automaticCalls = 0;
  context.queryProviderBalance = async () => { automaticCalls++; return { available: true, amounts: [] }; };
  const entered = Object.assign(new context.exports.Card(), { editor: { ...draft, apiKey: '', canKeepKey: true, snapshot: () => ({ ...draft, apiKey: '' }) },
    profiles: [], disabled: false, active: false, generation: 0, loading: false, alive: false, queriedOnEntry: false, error: '' });
  entered.aboutToAppear(); assert.equal(automaticCalls, 0, 'Mounting a hidden destination does not query');
  entered.active = true; entered.visibilityChanged(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(automaticCalls, 1, 'Entering with a saved key automatically queries once');
  entered.aboutToAppear(); entered.visibilityChanged(); entered.queryOnEntry(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(automaticCalls, 1, 'Repeated lifecycle notifications do not duplicate the request');
  entered.reset(); entered.queryOnEntry(); assert.equal(automaticCalls, 1, 'Editing the URL/key only invalidates the old result');
  await entered.refresh(); assert.equal(automaticCalls, 2, 'Manual refresh remains available');
  entered.active = false; entered.visibilityChanged(); entered.active = true; entered.visibilityChanged(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(automaticCalls, 3, 'Returning to a retained editing page queries once again');
  entered.aboutToDisappear(); entered.disabled = true; entered.aboutToAppear(); assert.equal(automaticCalls, 3);
  entered.disabled = false; entered.queryOnEntry(); await new Promise(resolve => setImmediate(resolve)); assert.equal(automaticCalls, 4, 'Busy entry waits until the page can query');
  entered.aboutToDisappear(); entered.editor.canKeepKey = false; entered.aboutToAppear(); assert.equal(automaticCalls, 4, 'An empty new configuration does not produce a missing-key error');
  entered.aboutToDisappear(); entered.editor.apiKey = 'new-key'; entered.editor.baseUrl = 'https://other.invalid'; entered.aboutToAppear();
  assert.equal(automaticCalls, 4, 'Unsupported providers are not queried automatically');
  entered.aboutToDisappear(); entered.editor.baseUrl = draft.baseUrl;
  context.queryProviderBalance = async () => { automaticCalls++; throw Error('Query failed [401]'); };
  entered.aboutToAppear(); await new Promise(resolve => setImmediate(resolve)); assert.match(entered.error, /401/);
  entered.queryOnEntry(); assert.equal(automaticCalls, 5, 'Failed automatic queries do not loop');
  await entered.refresh(); assert.equal(automaticCalls, 6, 'Users can explicitly retry after failure');
  console.log('PASS automatic balance query once per entry, retained-page return, saved credentials, busy entry and manual retry');
  console.log('PASS emitted balance controller: refresh, scope invalidation, stale response rejection, failure and navigation teardown');
}
(async () => {
  for (const url of ['https://api.deepseek.com', 'https://api.deepseek.com/v1/', 'https://api.deepseek.com/v1/chat/completions']) {
    assert.equal(supportsProviderBalance('chat-completions', url), true);
  }
  for (const url of ['http://api.deepseek.com', 'https://api.deepseek.com.attacker.invalid', 'https://other.invalid/v1',
    'https://api.deepseek.com@other.invalid', 'https://api.deepseek.com/proxy', 'https://api.deepseek.com?key=secret']) {
    const count = requests.length;
    assert.equal(supportsProviderBalance('chat-completions', url), false);
    await assert.rejects(queryProviderBalance({ ...draft, baseUrl: url, presetId: 'deepseek' }, []), /尚未接入/);
    assert.equal(requests.length, count, 'Unsupported endpoints never receive credentials');
  }
  payload = { is_available: true, balance_infos: [row('CNY', '110.00001'), row('USD', '5.00')] };
  let result = await queryProviderBalance(draft, []);
  assert.equal(result.amounts[0].total, '110.00001'); assert.equal(result.amounts[1].currency, 'USD'); assert.ok(result.checkedAt > 0);
  assert.equal(keyReads, 0); assert.equal(requests.at(-1).url, 'https://api.deepseek.com/user/balance');
  assert.equal(requests.at(-1).options.header.Authorization, 'Bearer new-key'); assert.equal(requests.at(-1).options.maxRedirects, 0);
  const profiles = [{ ...draft, credentialAlias: 'stored', apiKey: undefined }];
  await queryProviderBalance({ ...draft, apiKey: '' }, profiles);
  assert.equal(keyReads, 1); assert.equal(requests.at(-1).options.header.Authorization, 'Bearer saved-key');
  await assert.rejects(queryProviderBalance({ ...draft, apiKey: '', baseUrl: 'https://api.deepseek.com' }, profiles), /API Key/);
  await assert.rejects(queryProviderBalance({ ...draft, noApiKey: true }, profiles), /需要 API Key/);
  payload = { is_available: false, balance_infos: [row('CNY', '0.00')] };
  result = await queryProviderBalance(draft, []); assert.equal(result.available, false); assert.equal(result.amounts[0].total, '0.00');
  payload = { is_available: false, balance_infos: [] };
  result = await queryProviderBalance(draft, []); assert.equal(result.amounts.length, 0, 'Missing balance rows are not fabricated as zero');
  for (const bad of [null, {},
    { is_available: true, balance_infos: [row('CNY', 'NaN')] }, { is_available: true, balance_infos: [row('CNY', '1'), row('CNY', '2')] }]) {
    payload = bad; await assert.rejects(queryProviderBalance(draft, []), /余额数据格式/);
  }
  payload = '<html>PRIVATE_SECRET</html>'; await assert.rejects(queryProviderBalance(draft, []), error => /JSON/.test(error.message) && !error.message.includes('PRIVATE_SECRET'));
  status = 401; payload = { error: { code: 'invalid_api_key', message: 'PRIVATE_SECRET' } };
  await assert.rejects(queryProviderBalance(draft, []), error => /401/.test(error.message) && /invalid_api_key/.test(error.message) && !error.message.includes('PRIVATE_SECRET'));
  networkError = Object.assign(Error('Internal error'), { code: 2300006 });
  await assert.rejects(queryProviderBalance(draft, []), /2300006/);
  assert.equal(logs.at(-1).fields.errorCode, 2300006);
  assert.ok(!JSON.stringify(logs).includes('new-key')); assert.ok(!JSON.stringify(logs).includes('PRIVATE_SECRET'));
  console.log('PASS DeepSeek balance, precise currency values, zero balance, credential scope, unsupported services, invalid data and error diagnostics');
  if (process.argv.includes('--ui')) await checkUi();
})().catch(error => { console.error(error); process.exitCode = 1; });
