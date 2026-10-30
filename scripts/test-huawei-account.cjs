// Exercise the real account/vault and model/session boundaries with controlled system Account Kit responses.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map(), secrets = new Map();
const alias = 'tinybot.huawei.account.v1';
let privacyAgreed = true;
const system = { current: 'user-A', responseState: undefined, loginError: undefined, checkError: undefined,
  beforeLogin: async () => {}, beforeCheck: async () => {}, failWrite: false, failRemove: false, checks: 0, logins: 0 };
const authentication = {
  IdType: { OPEN_ID: 2 }, State: { AUTHORIZED: 1, UNLOGGED_IN: 0, UNAUTHORIZED: 2 },
  AuthenticationErrorCode: { USER_CANCELED: 1001502012, NETWORK_ERROR: 1001502005,
    PACKAGE_FINGERPRINT_CHECK_ERROR: 1001500001, PARAMETER_INVALID: 1001502003, SCOPE_OR_PERMISSION_NOT_REQUESTED: 1001502014 },
  HuaweiIDProvider: class {
    createLoginWithHuaweiIDRequest() { return {}; }
    async getHuaweiIDState(request) {
      system.checks++; assert.equal(request.idType, 2); await system.beforeCheck();
      if (system.checkError) throw system.checkError;
      return { state: !system.current ? 0 : request.idValue === system.current ? 1 : 2 };
    }
  },
  AuthenticationController: class {
    async executeRequest(request) {
      system.logins++; assert.equal(request.forceLogin, true); assert.match(request.state, /^[a-f0-9-]{36}$/);
      await system.beforeLogin(); if (system.loginError) throw system.loginError;
      return { state: system.responseState === undefined ? request.state : system.responseState,
        data: { openID: system.current, unionID: 'unused-union-id', authorizationCode: 'DO-NOT-SAVE-CODE', idToken: 'DO-NOT-SAVE-TOKEN' } };
    }
  }
};
const asset = {
  Tag: { ALIAS: 'alias', SECRET: 'secret', RETURN_TYPE: 'return', ACCESSIBILITY: 'access', SYNC_TYPE: 'sync' },
  ReturnType: { ALL: 0 }, Accessibility: { DEVICE_UNLOCKED: 0 }, SyncType: { NEVER: 0 }, ErrorCode: { NOT_FOUND: 404 },
  async query(query) { const key = Buffer.from(query.get('alias')).toString();
    if (!secrets.has(key)) throw { code: 404 }; return [new Map([['secret', Buffer.from(secrets.get(key))]])]; },
  async add(record) { if (system.failWrite) throw Error('AssetStore unavailable');
    assert.equal(record.get('sync'), 0); assert.equal(record.get('access'), 0);
    secrets.set(Buffer.from(record.get('alias')).toString(), Buffer.from(record.get('secret')).toString()); },
  async remove(query) { if (system.failRemove) throw Error('AssetStore unavailable'); secrets.delete(Buffer.from(query.get('alias')).toString()); }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, setTimeout, clearTimeout, console, require: id => {
    if (id === '@kit.AccountKit') return { authentication };
    if (id === './HostedPrivacy') return { hostedPrivacy: { requireConsent() { if (!privacyAgreed) throw Error('System privacy consent required'); } } };
    if (id === '@kit.AssetStoreKit') return { asset };
    if (id === '@kit.ArkTS') return { util: { generateRandomUUID: randomUUID,
      TextEncoder: class { encodeInto(text) { return Buffer.from(text); } },
      TextDecoder: class { decodeToString(bytes) { return Buffer.from(bytes).toString(); } } } };
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected dependency: ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const { HuaweiAccount } = load(path.join(root, 'main/ets/services/HuaweiAccount'));
const accountLogs = [];
load(path.join(root, 'main/ets/model/Diagnostics')).Diagnostics.configureLogSink(data => accountLogs.push(data));
const { CredentialStore } = load(path.join(root, 'main/ets/services/CredentialStore'));
const { ProviderRegistry } = load(path.join(root, 'main/ets/services/providers/ProviderRegistry'));
const { Cancellation } = load(path.join(root, 'main/ets/services/Cancellation'));
const { defaultConfig } = load(path.join(root, 'main/ets/model/Conversation'));
const { Fixture } = load(path.join(root, 'test/SessionService.test'));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
(async () => {
  const account = new HuaweiAccount(); await account.initialize({});
  assert.equal(account.signedIn, false); assert.equal(system.logins, 0, 'Opening app never signs in without consent');
  await assert.rejects(account.requireLogin(), /登录/);
  await account.signIn(); assert.equal(account.signedIn, true); assert.equal(secrets.get(alias), 'user-A');
  assert.equal(await account.backupOpenID({}), 'user-A');
  const otherDevice = new HuaweiAccount(); await account.signOut();
  assert.equal(await otherDevice.backupOpenID({}), 'user-A', 'explicit backup action obtains the same account ID after a fresh login');
  await otherDevice.signOut(); system.loginError = { code: authentication.AuthenticationErrorCode.USER_CANCELED };
  await assert.rejects(otherDevice.backupOpenID({}), /取消/);
  system.loginError = undefined; await account.signIn();
  privacyAgreed = false;
  await assert.rejects(account.requireLogin(), /System privacy/);
  await assert.rejects(account.backupOpenID({}), /System privacy/);
  const loginCount = system.logins;
  await account.signIn(); assert.equal(system.logins, loginCount, 'No Account Kit request before system privacy consent');
  privacyAgreed = true; await account.signIn();
  assert.doesNotMatch(JSON.stringify([...secrets]), /TOKEN|CODE|union/);
  const restored = new HuaweiAccount(); await restored.initialize({}); assert.equal(restored.signedIn, true);
  system.current = 'user-B'; await assert.rejects(restored.requireLogin(), /发生变化/);
  assert.equal(secrets.has(alias), false); assert.equal(restored.signedIn, false);
  await account.signOut(); await account.signIn(); assert.equal(secrets.get(alias), 'user-B');
  system.checkError = Error('Private identifier must not leak');
  await assert.rejects(account.requireLogin(), /无法检查/); assert.doesNotMatch(account.error, /Private/);
  system.checkError = undefined; await account.requireLogin();
  const gate = deferred(); system.beforeCheck = () => gate.promise;
  const checkCount = system.checks, first = account.requireLogin(), second = account.requireLogin();
  await new Promise(resolve => setTimeout(resolve, 0)); assert.equal(system.checks, checkCount + 1, 'Concurrent workers share one system check');
  const denied = Promise.allSettled([first, second]); await account.signOut(); gate.resolve();
  assert.ok((await denied).every(item => item.status === 'rejected'), 'Late system result cannot restore a logged-out account');
  system.beforeCheck = async () => {};
  await account.signIn();
  const stale = deferred(); system.beforeCheck = () => stale.promise;
  const old = Promise.allSettled([account.requireLogin()]); await new Promise(resolve => setTimeout(resolve, 0));
  await account.signOut(); system.beforeCheck = async () => {}; await account.signIn();
  const checksBeforeFreshRequest = system.checks; await account.requireLogin();
  assert.equal(system.checks, checksBeforeFreshRequest + 1, 'A new login cannot reuse a pending check from the old login');
  stale.resolve(); assert.equal((await old)[0].status, 'rejected', 'An old request cannot cross a logout/login boundary');
  await account.signOut();
  system.responseState = 'wrong-state'; await account.signIn(); assert.equal(account.signedIn, false); assert.equal(secrets.has(alias), false);
  system.responseState = undefined; system.failWrite = true; await account.signIn(); assert.equal(account.signedIn, false);
  system.failWrite = false; system.loginError = { code: 1001500001, message: 'DO-NOT-LOG-TOKEN' }; await account.signIn();
  assert.match(account.error, /1001500001/); assert.doesNotMatch(account.error, /DO-NOT/);
  const loginFailure = accountLogs.findLast(data => data.event === 'sign_in_failed');
  assert.equal(loginFailure.fields.errorCode, 1001500001); assert.equal(loginFailure.fields.phase, 'login');
  assert.ok(!JSON.stringify(accountLogs).includes('DO-NOT-LOG-TOKEN'));
  const beforeCancel = accountLogs.length;
  system.loginError = { code: 1001502012 }; await account.signIn(); assert.match(account.error, /取消/);
  assert.equal(accountLogs.length, beforeCancel, 'User cancellation adds no warning/error');
  system.loginError = undefined; await account.signIn();
  system.failRemove = true; await account.signOut(); assert.equal(account.signedIn, false); assert.match(account.error, /无法清除/);
  assert.equal(accountLogs.at(-1).event, 'sign_out_failed');
  system.failRemove = false; await account.signOut(); await account.signIn();
  system.current = ''; await assert.rejects(account.requireLogin(), /已退出/); assert.equal(secrets.has(alias), false);
  const vault = new CredentialStore(); assert.equal(await vault.readOptional('missing'), undefined);
  await assert.rejects(vault.read('missing'), /API Key/); assert.equal(await vault.read(''), '');
  console.log('PASS native login/state, secure storage, restart, switch/logout, errors, cancellation and concurrent checks');

  system.current = 'user-B'; await account.signIn();
  const provider = { info: { id: 'test', name: 'Test' }, endpoint: value => value, calls: 0,
    async stream() { this.calls++; return { content: 'done', toolCalls: [] }; } };
  const registry = new ProviderRegistry(() => account.requireLogin()); registry.register(provider);
  const config = defaultConfig(); config.providerId = 'test'; config.model = 'test-model'; config.credentialAlias = '';
  const bound = registry.bind(config, vault);
  await bound.stream([], [], new Cancellation(), () => {}); assert.equal(provider.calls, 1);
  await account.signOut(); await assert.rejects(bound.stream([], [], new Cancellation(), () => {}), /登录/);
  assert.equal(provider.calls, 1, 'A previously bound model cannot bypass later logout');
  system.current = 'user-B'; await account.signIn();
  const holding = deferred(); const waiting = registry.bind(config, { read: () => holding.promise });
  const request = waiting.stream([], [], new Cancellation(), () => {}); await account.signOut(); holding.resolve('key');
  await assert.rejects(request, /登录/); assert.equal(provider.calls, 1, 'Logout during credential read prevents the HTTP call');
  console.log('PASS model boundary checks for every request, including previously bound models and delayed credentials');

  const fixture = new Fixture(); fixture.resources.authorizeGeneration = () => account.requireLogin();
  await fixture.session.initialize(); fixture.session.setDraft('Keep my prompt');
  const before = JSON.stringify(fixture.session.snapshot());
  await fixture.session.send(); assert.equal(JSON.stringify(fixture.session.snapshot()), before);
  await fixture.session.compactHistory(); assert.equal(fixture.provider.requests.length, 0);
  assert.match(fixture.session.state.error, /登录/);
  await account.signIn(); await fixture.session.send(); assert.equal(fixture.provider.requests.length, 1);
  const completed = fixture.session.snapshot(); await account.signOut();
  const assistant = completed.threads[0].messages.find(item => item.role === 'assistant');
  assert.equal(await fixture.session.regenerateReply(assistant.id), false);
  assert.equal(JSON.stringify(fixture.session.snapshot()), JSON.stringify(completed), 'Denied regeneration never creates a branch');
  console.log('PASS real SessionService preserves drafts/history on denied send, compaction and regeneration; signed-in chat succeeds');
})().catch(error => { console.error(error); process.exitCode = 1; });
