// Real balance service, credential scoping and response validation, without a network/account.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map(), requests = [], logs = [];
let status = 200, payload, keyReads = 0, networkError, beforeRequest;
const responses = new Map();
const kits = {
  '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } }, '@kit.RemoteCommunicationKit': { rcp: {} },
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 'string' }, createHttp: () => ({
    destroy() {}, async request(url, options) { requests.push({ url, options }); if (beforeRequest) await beforeRequest(); if (networkError) throw networkError;
      const body = responses.has(url) ? responses.get(url) : payload;
      return { responseCode: status, result: typeof body === 'string' ? body : JSON.stringify(body) }; }
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
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, require: id => {
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
    assert.ok(kits[id], id); return kits[id];
  } }, { filename: file }); return exports;
}
const { queryProviderBalance, supportsProviderBalance } = load('services/ProviderBalance');
load('model/Diagnostics').Diagnostics.configureLogSink(log => logs.push(log));
const row = (currency, total) => ({ currency, total_balance: total, granted_balance: '0.00', topped_up_balance: total });
const draft = { id: 'p', protocol: 'chat-completions', baseUrl: 'https://api.deepseek.com/v1', apiKey: 'new-key', noApiKey: false };
async function checkUi() {
  const file = path.join(root, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ProviderBalanceResult.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(root, 'views/ProviderBalanceResult.ets')).mtimeMs, 'Build result component before --ui checks');
  const tree = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ProviderBalanceResult');
  const names = ['reset','bind','refresh','supported','aboutToAppear','aboutToDisappear','visibilityChanged','queryOnEntry'];
  const methods = component.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n');
  const pending = [];
  const context = { exports: {}, supportsProviderBalance, ...load('services/ProviderBalanceCache'),
    queryProviderBalance: () => new Promise(resolve => pending.push(resolve)) };
  vm.runInNewContext(ts.transpileModule(`class Card { ${methods} } exports.Card=Card;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
  const make = () => Object.assign(new context.exports.Card(), { draft: {...draft}, profiles: [], disabled:false, active:true,
    generation:0, loading:false, alive:true, queriedOnEntry:false, canQuery:true, error:'' });
  const card = make();
  const old = card.refresh(); assert.equal(card.loading,true);
  card.reset(); const fresh = card.refresh();
  pending[0]({amounts:[{total:'900'}]}); await old;
  assert.equal(card.result,undefined); assert.equal(card.loading,true);
  pending[1]({amounts:[{total:'0.00'}]}); await fresh; assert.equal(card.result.amounts[0].total,'0.00');
  context.queryProviderBalance = async () => { throw Error('Network unavailable'); };
  await card.refresh(); assert.equal(card.result.amounts[0].total,'0.00'); assert.match(card.error,/Network/);
  const { DetailedError } = load('model/DetailedError');
  context.queryProviderBalance = async () => { throw new DetailedError('Rejected', {httpStatus:401}); };
  await card.refresh(); assert.equal(card.result,undefined); assert.match(card.error,/401/);
  context.queryProviderBalance = () => new Promise(resolve => pending.push(resolve));
  const leaving = card.refresh(); card.aboutToDisappear(); pending[2]({amounts:[]}); await leaving; assert.equal(card.result,undefined);
  let calls=0;
  context.queryProviderBalance=async()=>{ calls++; return {amounts:[]}; };
  const entered=make(); entered.alive=false; entered.active=false; entered.aboutToAppear(); assert.equal(calls,0);
  entered.active=true; entered.visibilityChanged(); await new Promise(setImmediate); assert.equal(calls,1);
  entered.queryOnEntry(); entered.reset(); entered.queryOnEntry(); assert.equal(calls,1,'Typing never triggers requests');
  entered.active=false; entered.visibilityChanged(); entered.active=true; entered.visibilityChanged(); await new Promise(setImmediate); assert.equal(calls,2);
  entered.aboutToDisappear(); entered.disabled=true; entered.aboutToAppear(); assert.equal(calls,2);
  entered.disabled=false; entered.queryOnEntry(); await new Promise(setImmediate); assert.equal(calls,3);
  entered.aboutToDisappear(); entered.canQuery=false; entered.aboutToAppear(); assert.equal(calls,3);
  entered.aboutToDisappear(); entered.canQuery=true; entered.draft.balance={mode:'off'}; entered.aboutToAppear(); assert.equal(calls,3);
  console.log('PASS result controller: entry/visibility/busy guards, typing invalidation, stale responses, retained failure and auth rejection');
}
async function checkAdapters() {
  status = 200; networkError = undefined;
  const relay = { ...draft, baseUrl: 'https://relay.invalid/proxy/v1', balance: { mode: 'sub2api' } };
  payload = { mode: 'unrestricted', isValid: true, balance: -1.5, unit: 'USD' };
  let value = await queryProviderBalance(relay, []);
  assert.equal(value.amounts[0].total, '-1.5'); assert.equal(value.amounts[0].kind, 'account');
  assert.equal(value.available, undefined, 'A balance is not proof that the key can call models');
  assert.equal(requests.at(-1).url, 'https://relay.invalid/proxy/v1/usage');
  for (const [protocol, baseUrl, expected] of [
    ['gemini', 'https://relay.invalid', 'https://relay.invalid/v1/usage'],
    ['gemini', 'https://relay.invalid/proxy/v1beta', 'https://relay.invalid/proxy/v1/usage'],
    ['responses', 'https://relay.invalid/proxy/v1/responses', 'https://relay.invalid/proxy/v1/usage'],
    ['anthropic-messages', 'https://relay.invalid/proxy/v1/messages', 'https://relay.invalid/proxy/v1/usage']]) {
    await queryProviderBalance({ ...relay, protocol, baseUrl }, []);
    assert.equal(requests.at(-1).url, expected, 'Billing routes are independent of the inference protocol');
  }
  payload = { mode: 'quota_limited', isValid: true, status: 'quota_exhausted',
    quota: { limit: 10, used: 10, remaining: 0, unit: 'USD' },
    rate_limits: [{ window: '5h', limit: 20, used: 5, remaining: 15, reset_at: '2026-12-01T00:00:00Z' }] };
  value = await queryProviderBalance(relay, []);
  assert.equal(value.amounts[0].kind, 'key'); assert.equal(value.amounts[0].total, '0');
  assert.equal(value.amounts[1].kind, 'window'); assert.equal(value.amounts[1].resetAt, payload.rate_limits[0].reset_at);
  assert.match(value.notice, /用尽/);
  payload = { mode: 'unrestricted', isValid: true, remaining: 3, subscription: {
    daily_limit_usd: 10, daily_usage_usd: 7, weekly_limit_usd: 40, weekly_usage_usd: 12, monthly_limit_usd: null } };
  value = await queryProviderBalance(relay, []);
  assert.deepEqual(Array.from(value.amounts, item => item.total), ['3', '28']);
  payload = { mode: 'unrestricted', isValid: true, remaining: -1 };
  value = await queryProviderBalance(relay, []); assert.equal(value.amounts[0].unlimited, true); assert.equal(value.amounts[0].total, undefined);
  payload = { mode: 'unrestricted', isValid: true, planName: 'Undisclosed plan' };
  value = await queryProviderBalance(relay, []); assert.equal(value.amounts.length, 0, 'Missing subscription details are never zero');
  for (const bad of [{}, { mode: 'unrestricted', isValid: false, balance: 5 },
    { mode: 'unrestricted', isValid: true, balance: null },
    { mode: 'unrestricted', isValid: true, subscription: { daily_limit_usd: 10 } },
    { mode: 'quota_limited', isValid: true, quota: { limit: 10, remaining: 5, unit: 'USD' } }]) {
    payload = bad; await assert.rejects(queryProviderBalance(relay, []));
    assert.equal(logs.at(-1).fields.balanceAdapter, 'sub2api');
  }
  relay.balance = { mode: 'newapi' };
  const quota = { code: true, data: { object: 'token_usage', unlimited_quota: false,
    total_available: 250000, total_granted: 500000, total_used: 250000,
    user_quota: { total_available: 750000, total_used: 250000 } } };
  const station = { success: true, data: { quota_per_unit: 250000, quota_display_type: 'CNY', usd_exchange_rate: 7 } };
  payload = quota; responses.set('https://relay.invalid/proxy/api/status', station);
  value = await queryProviderBalance(relay, []);
  assert.equal(value.amounts[0].total, '7'); assert.equal(value.amounts[1].total, '21');
  assert.equal(value.amounts[0].currency, 'CNY'); assert.equal(value.amounts[1].kind, 'account');
  assert.equal(requests.at(-2).url, 'https://relay.invalid/proxy/api/usage/token/');
  assert.equal(requests.at(-1).options.header.Authorization, undefined, 'Public metadata does not receive the API key');
  for (const [display, extra, expectedUnit, expected] of [
    ['USD', {}, 'USD', '1'], ['TOKENS', {}, '额度单位', '250000'],
    ['CUSTOM', { custom_currency_symbol: 'credits', custom_currency_exchange_rate: 2.5 }, 'credits', '2.5']]) {
    station.data = { quota_per_unit: 250000, quota_display_type: display, ...extra };
    value = await queryProviderBalance(relay, []); assert.equal(value.amounts[0].total, expected); assert.equal(value.amounts[0].currency, expectedUnit);
  }
  delete quota.data.user_quota; quota.data.unlimited_quota = true; quota.data.total_available = -100;
  value = await queryProviderBalance(relay, []); assert.equal(value.amounts[0].unlimited, true); assert.equal(value.amounts[0].total, undefined);
  assert.equal(value.amounts.length, 1); assert.match(value.notice, /未开放/);
  station.data.quota_per_unit = 0; await assert.rejects(queryProviderBalance(relay, []), /quota_per_unit/);
  responses.clear();

  const custom = { mode: 'custom', path: '/billing/balance', remainingField: 'data.wallets.0.remaining',
    totalField: 'data.total', usedField: 'data.used', successField: 'success', unit: 'CNY', divisor: 100, auth: 'bearer' };
  relay.balance = custom;
  payload = { success: true, data: { wallets: [{ remaining: '12345' }], total: '20000', used: 7655 } };
  value = await queryProviderBalance(relay, []);
  assert.equal(value.amounts[0].total, '123.45'); assert.equal(value.amounts[0].limit, '200'); assert.equal(value.amounts[0].used, '76.55');
  assert.equal(requests.at(-1).url, 'https://relay.invalid/billing/balance');
  for (const auth of ['raw', 'api-key', 'none']) {
    custom.auth = auth;
    const reads = keyReads;
    await queryProviderBalance({ ...relay, noApiKey: auth === 'none', apiKey: auth === 'none' ? '' : 'new-key' }, []);
    const headers = requests.at(-1).options.header;
    assert.equal(headers.Authorization, auth === 'raw' ? 'new-key' : undefined);
    assert.equal(headers['x-api-key'], auth === 'api-key' ? 'new-key' : undefined);
    assert.equal(keyReads, reads);
  }
  custom.auth = 'bearer';
  for (const patch of [{ path: '//attacker.invalid/balance' }, { path: '/%2f%2fattacker.invalid' }, { path: '/a/../balance' },
    { path: '/balance?apiKey=secret' }, { remainingField: '__proto__.secret' }, { divisor: 0 }, { divisor: Infinity }, { auth: 'unknown' }]) {
    const count = requests.length;
    await assert.rejects(queryProviderBalance({ ...relay, balance: { ...custom, ...patch } }, []));
    assert.equal(requests.length, count, 'Invalid settings never issue HTTP requests');
  }
  payload.success = false; await assert.rejects(queryProviderBalance(relay, []), /拒绝/); payload.success = true;
  payload.data.wallets[0].remaining = null; await assert.rejects(queryProviderBalance(relay, []), /remaining/);
  payload.data.wallets[0].remaining = 'secret'; await assert.rejects(queryProviderBalance(relay, []), e => !e.message.includes('secret'));
  await assert.rejects(queryProviderBalance({ ...relay, apiKey: '', baseUrl: 'https://changed.invalid/v1' }, [{ ...relay, credentialAlias: 'saved' }]), /API Key/);
  payload = { success: true, data: { availableBalance: '12.34' } };
  const zhipu = { ...draft, baseUrl: 'https://open.bigmodel.cn/api/paas/v4', balance: { mode: 'zhipu' } };
  value = await queryProviderBalance(zhipu, []); assert.equal(value.amounts[0].total, '12.34'); assert.equal(value.amounts[0].currency, 'CNY');
  assert.equal(requests.at(-1).options.header.Authorization, 'new-key');
  for (const baseUrl of ['https://open.bigmodel.cn.attacker.invalid/api/paas/v4', 'https://api.z.ai/api/paas/v4', 'https://open.bigmodel.cn/api/coding/paas/v4']) {
    const count = requests.length; await assert.rejects(queryProviderBalance({ ...zhipu, baseUrl }, [])); assert.equal(requests.length, count);
  }
  console.log('PASS Sub2API wallet/key/subscription windows, New API configured units and visibility, custom mappings/authentication, Zhipu endpoint scope');
}

async function checkSettings() {
  const { ProviderEditorViewModel } = load('viewmodel/ProviderEditorViewModel');
  const { ProfileSettings } = load('services/ProfileSettings');
  const { emptyData, parseAppData } = load('model/Conversation');
  const editor = new ProviderEditorViewModel();
  editor.reset(); editor.name = 'Relay'; editor.baseUrl = 'https://relay.invalid/v1'; editor.apiKey = 'test-key'; editor.models = 'model';
  editor.balanceMode = 'custom'; editor.balancePath = '/balance'; editor.balanceRemaining = 'wallet.remaining';
  editor.balanceSuccess = 'success'; editor.balanceDivisor = '100';
  const expected = JSON.stringify(editor.balanceSettings());
  let id = 0, saved, writes = 0;
  const service = new ProfileSettings({ write: async () => { writes++; }, read: async () => 'saved', remove: async () => {} }, () => String(++id));
  await service.save(emptyData(), editor.snapshot(), async data => { saved = data; });
  assert.equal(writes, 1);
  saved = parseAppData(JSON.stringify(saved));
  editor.reset(saved.providerProfiles[0]); assert.equal(editor.hasChanges, false);
  assert.equal(JSON.stringify(editor.balanceSettings()), expected, 'Custom mappings survive save, disk parsing and editing');
  editor.balanceMode = 'off'; assert.equal(editor.hasChanges, true);
  await service.save(saved, editor.snapshot(), async data => { saved = data; });
  assert.equal(saved.providerProfiles[0].balance.mode, 'off');
  editor.reset(saved.providerProfiles[0]); editor.balanceMode = 'auto';
  await service.save(saved, editor.snapshot(), async data => { saved = data; });
  assert.equal(saved.providerProfiles[0].balance, undefined, 'Selecting automatic removes the previous explicit configuration');
  editor.reset(saved.providerProfiles[0]); editor.balanceMode = 'custom'; editor.balancePath = '//bad.invalid';
  await assert.rejects(service.save(saved, editor.snapshot(), async () => { throw Error('must not commit'); }), /查询路径/);
  assert.equal(writes, 1, 'Rejected edits do not write credentials');
  console.log('PASS balance settings persistence, editor round trip, disabled/automatic mode and validation before credential writes');
}
async function checkBalanceCredentials() {
  const { ProviderEditorViewModel }=load('viewmodel/ProviderEditorViewModel');
  const { ProfileSettings }=load('services/ProfileSettings');
  const { emptyData }=load('model/Conversation');
  const editor=new ProviderEditorViewModel();
  editor.reset();editor.name='Relay';editor.baseUrl='https://relay.invalid/v1';editor.models='model';editor.apiKey='model-secret';
  editor.balanceMode='newapi-account';editor.balanceUserId='7';editor.balanceApiKey='balance-secret';
  let id=0,saved,failWrite=false,failRemove=false;const secrets=new Map();
  const vault={read:async alias=>{if(!secrets.has(alias))throw Error('Missing asset');return secrets.get(alias);},
    write:async(alias,key)=>{secrets.set(alias,key);if(failWrite && key==='replacement-balance')throw Error('Write failure');},
    remove:async alias=>{if(failRemove)throw Error('Remove failure');secrets.delete(alias);}};
  const service=new ProfileSettings(vault,()=>String(++id));
  await service.save(emptyData(),editor.snapshot(),async value=>{saved=JSON.parse(JSON.stringify(value));});
  assert.equal(secrets.size,2);assert.ok(!JSON.stringify(saved).includes('balance-secret'));
  const previous=saved.providerProfiles[0];assert.equal(secrets.get(previous.balanceCredentialAlias),'balance-secret');
  editor.reset(previous);assert.equal(editor.canKeepBalanceKey,true);assert.equal(editor.hasChanges,false);assert.equal(editor.canQueryBalance,true);
  editor.balanceUserId='8';assert.equal(editor.canKeepBalanceKey,false);
  await assert.rejects(service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async()=>{}),/专用凭据/);
  editor.balanceUserId='7';editor.baseUrl='https://other.invalid/v1';assert.equal(editor.canKeepBalanceKey,false);
  editor.reset(previous);editor.apiKey='replacement-model';editor.balanceApiKey='replacement-balance';
  await assert.rejects(service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async()=>{throw Error('Commit failure');}),/Commit failure/);
  assert.equal(secrets.size,2);assert.equal(secrets.get(previous.balanceCredentialAlias),'balance-secret');
  failWrite=true;
  await assert.rejects(service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async()=>{throw Error('must not commit');}),/Write failure/);
  assert.equal(secrets.size,2,'Both new aliases roll back even if writing the second one fails');failWrite=false;
  editor.reset(previous);secrets.delete(previous.balanceCredentialAlias);
  await assert.rejects(service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async()=>{}),/读取余额查询凭据失败/);
  secrets.set(previous.balanceCredentialAlias,'balance-secret');
  editor.balanceMode='newapi';await service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async value=>{saved=value;});
  assert.equal(saved.providerProfiles[0].balanceCredentialAlias,undefined);assert.equal(secrets.size,1);
  editor.reset(saved.providerProfiles[0]);editor.balanceCredential='separate';editor.balanceApiKey='new-balance';
  await service.save(JSON.parse(JSON.stringify(saved)),editor.snapshot(),async value=>{saved=value;});assert.equal(secrets.size,2);
  failRemove=true;
  const warning=await service.remove(JSON.parse(JSON.stringify(saved)),editor.id,async value=>{saved=value;});
  assert.match(warning,/清理失败/);assert.equal(saved.providerProfiles.length,0);failRemove=false;
  // Real request routing: account tokens never fall back to model keys.
  status=200;networkError=undefined;responses.clear();
  const account={...draft,baseUrl:'https://relay.invalid/prefix/v1',balance:{mode:'newapi-account',userId:'7'},balanceApiKey:'dedicated-token'};
  responses.set('https://relay.invalid/prefix/api/user/self',{success:true,data:{id:7,quota:1000000,used_quota:250000}});
  responses.set('https://relay.invalid/prefix/api/status',{success:true,data:{quota_per_unit:500000,quota_display_type:'USD'}});
  const value=await queryProviderBalance(account,[]);assert.equal(value.amounts[0].total,'2');assert.equal(value.amounts[0].used,'0.5');
  assert.equal(requests.at(-2).options.header.Authorization,'Bearer dedicated-token');assert.equal(requests.at(-2).options.header['New-Api-User'],'7');
  assert.equal(requests.at(-1).options.header.Authorization,undefined);assert.equal(requests.at(-1).options.header['New-Api-User'],undefined);
  const count=requests.length;
  await assert.rejects(queryProviderBalance({...account,balanceApiKey:''},[]),/专用凭据/);assert.equal(requests.length,count);
  await assert.rejects(queryProviderBalance({...account,balance:{mode:'newapi-account',userId:'7\r\nInjected'}},[]),/用户 ID/);assert.equal(requests.length,count);
  responses.set('https://relay.invalid/prefix/api/user/self',{success:true,data:{id:8,quota:1000000,used_quota:0}});
  await assert.rejects(queryProviderBalance(account,[]),/id/);
  const custom={...account,balance:{mode:'sub2api',credential:'separate'},balanceApiKey:'',apiKey:'',noApiKey:true};
  const profile={...custom,balanceCredentialAlias:'saved-balance'};payload={isValid:true,mode:'unrestricted',balance:3};
  await queryProviderBalance(custom,[profile]);assert.equal(requests.at(-1).options.header.Authorization,'Bearer saved-key');
  await assert.rejects(queryProviderBalance({...custom,baseUrl:'https://elsewhere.invalid/v1'},[profile]),/专用凭据/);
  responses.clear();
  console.log('PASS dedicated balance credentials: isolation, scoped retention, user ID, transactional writes/deletion and New API account units');
}

async function checkCache() {
  const { ProviderBalanceCache, balanceProfileDraft, savedBalanceProfile, BALANCE_CACHE_MS }=load('services/ProviderBalanceCache');
  const cache=new ProviderBalanceCache();
  const profile={...draft,apiKey:undefined,name:'DeepSeek',models:['model'],enabled:true,credentialAlias:'saved'};
  assert.equal(savedBalanceProfile({...balanceProfileDraft(profile),balanceApiKey:'unsaved'},[profile]),undefined);
  assert.equal(savedBalanceProfile(balanceProfileDraft(profile),[profile]),profile);
  assert.equal(savedBalanceProfile({...balanceProfileDraft(profile),balance:{credential:'provider',mode:'auto'}},[profile]),profile,
    'Default settings and property order do not split the saved cache');
  status=200;networkError=undefined;payload={is_available:true,balance_infos:[row('CNY','4.00')]};
  let left,right;const offLeft=cache.subscribe(profile,state=>left=state);const offRight=cache.subscribe(profile,state=>right=state);
  let release;beforeRequest=()=>new Promise(resolve=>{release=resolve;});
  const count=requests.length;const first=cache.refresh(profile);const second=cache.refresh(profile);await new Promise(setImmediate);
  assert.equal(requests.length,count+1,'List and editor deduplicate concurrent queries');assert.equal(left.loading,true);
  release();await Promise.all([first,second]);beforeRequest=undefined;
  assert.equal(left.result.amounts[0].total,'4.00');assert.equal(right,left);
  await cache.refresh(profile);assert.equal(requests.length,count+1,'Fresh saved results are reused');
  cache.entries.get(profile.id).attemptedAt=Date.now()-BALANCE_CACHE_MS-1;
  await cache.refresh(profile);assert.equal(requests.length,count+2,'Entry after TTL refreshes');
  networkError=Object.assign(Error('Network unavailable'),{code:2300006});await cache.refresh(profile,true);
  assert.equal(left.result.amounts[0].total,'4.00');assert.ok(left.error);assert.equal(left.loading,false);
  const failedCount=requests.length;await cache.refresh(profile);assert.equal(requests.length,failedCount,'Automatic failures do not loop');
  networkError=undefined;status=401;payload={};await cache.refresh(profile,true);assert.equal(left.result,undefined);assert.match(left.error,/401/);
  status=200;payload={is_available:true,balance_infos:[row('CNY','9.00')]};
  beforeRequest=()=>new Promise(resolve=>{release=resolve;});const old=cache.refresh(profile,true);await new Promise(setImmediate);
  const changed={...profile,credentialAlias:'replacement'};let next;const offNext=cache.subscribe(changed,state=>next=state);
  assert.equal(next.result,undefined);release();await old;beforeRequest=undefined;assert.equal(next.result,undefined,'Late old-account responses cannot populate a new identity');
  await cache.refresh(changed);assert.equal(next.result.amounts[0].total,'9.00');
  offLeft();offRight();offNext();cache.invalidate(profile.id);assert.equal(cache.entries.size,0);
  console.log('PASS shared cache: request deduplication, TTL/manual refresh, visible stale error, auth clearing and account replacement races');
}
async function checkLifePanelSource() {
  const {ProviderBalanceSource}=load('services/ProviderBalanceSource');
  const {providerBalanceCatalog}=load('services/ProviderBalanceCatalog');
  const {parsePanelSpec,validatePanelData}=load('model/LifePanel');
  const {Cancellation}=load('services/Cancellation');
  const {providerBalanceCache}=load('services/ProviderBalanceCache');
  const profile={...draft,id:'panel-provider',name:'Wallet provider',presetId:'deepseek',apiKey:undefined,models:['model'],enabled:true,credentialAlias:'wallet-secret-alias'};
  ProviderBalanceSource.configure([profile,{...profile,id:'disabled',enabled:false},{...profile,id:'unsupported',baseUrl:'https://elsewhere.invalid'}]);
  const catalog=JSON.parse(providerBalanceCatalog());assert.equal(catalog.accounts.length,1);assert.equal(catalog.accounts[0].id,profile.id);
  assert.equal(catalog.accounts[0].presetId,'deepseek');
  const {PROVIDER_LOGOS}=load('model/ProviderLogoCatalog');
  for(const [brand,uri] of Object.entries(PROVIDER_LOGOS)) {
    assert.equal(decodeURIComponent(uri.slice('data:image/svg+xml,'.length)),
      fs.readFileSync(path.join(root,`../resources/base/media/logo_${brand}.svg`),'utf8').trim(), 'HTML and native logos share the same asset');
  }
  assert.ok(!JSON.stringify(catalog).includes('wallet-secret-alias'));assert.ok(!JSON.stringify(catalog).includes('api.deepseek.com'));
  assert.equal(catalog.html,undefined);assert.equal(catalog.guidance,undefined);
  const definition={...catalog.definition,view:{version:1,html:load('model/BalancePanelTemplate').BALANCE_PANEL_HTML,css:'',js:'',library:'none',height:420,autoHeight:true}};
  parsePanelSpec(JSON.stringify(definition));
  for(const patch of [{url:'https://evil.invalid'}, {auth:{type:'bearer'}}, {providerIds:['invalid id']}, {providerIds:[profile.id,profile.id]}, {providerIds:[]}])
    assert.throws(()=>parsePanelSpec(JSON.stringify({...definition,source:{...definition.source,...patch}})));
  assert.throws(()=>parsePanelSpec(JSON.stringify({...definition,inputs:{providerId:{type:'string',default:'other',options:['other']}}})));
  status=200;networkError=undefined;payload={is_available:true,balance_infos:[row('CNY','3.10')]};
  const value=await ProviderBalanceSource.read([profile.id],{providerId:profile.id},new Cancellation());
  validatePanelData(definition,value,{});assert.equal(value.amounts[0].total,'3.10');assert.equal(value.providerId,profile.id);
  assert.equal(value.accounts[0].presetId,'deepseek');
  assert.ok(!JSON.stringify(value).includes('wallet-secret-alias'));assert.ok(!JSON.stringify(value).includes('saved-key'));
  let count=requests.length;
  await assert.rejects(ProviderBalanceSource.read([profile.id],{providerId:'disabled'},new Cancellation()),/允许/);assert.equal(requests.length,count);
  const cancelled=new Cancellation();cancelled.cancel();await assert.rejects(ProviderBalanceSource.read([profile.id],{providerId:profile.id},cancelled));assert.equal(requests.length,count);
  status=503;payload={};await assert.rejects(ProviderBalanceSource.read([profile.id],{providerId:profile.id},new Cancellation()),/503/);
  status=200;payload={is_available:true,balance_infos:[row('CNY','8')]};let release;
  beforeRequest=()=>new Promise(resolve=>{release=resolve;});
  const pending=ProviderBalanceSource.read([profile.id],{providerId:profile.id},new Cancellation());await new Promise(setImmediate);
  ProviderBalanceSource.configure([{...profile,credentialAlias:'changed'}]);release();await assert.rejects(pending,/配置已改变/);beforeRequest=undefined;
  providerBalanceCache.invalidate(profile.id);
  ProviderBalanceSource.configure([{...profile,presetId:undefined}]);
  assert.equal(ProviderBalanceSource.accounts()[0].presetId,undefined,'Custom accounts must not inherit the wire protocol brand');
  ProviderBalanceSource.configure([]);
  assert.equal(JSON.parse(providerBalanceCatalog()).definition,undefined);
  await assert.rejects(ProviderBalanceSource.read([profile.id],{providerId:profile.id},new Cancellation()),/已移除/);
  console.log('PASS Life Panel native balance source, HTML catalog/schema, credential redaction, allowlist, failure, cancellation and configuration race');
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
  await checkAdapters();
  await checkSettings();
  await checkBalanceCredentials();
  await checkCache();
  await checkLifePanelSource();
  if (process.argv.includes('--ui')) await checkUi();
})().catch(error => { console.error(error); process.exitCode = 1; });
