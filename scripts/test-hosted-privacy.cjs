// Exercise the real service and ability lifecycle with controlled AppGallery responses.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const state = new Map();
const link = { type: 1, id: 'policy', versionCode: 2, url: 'https://example.com/policy?v=2' };
let info = { type: 1, privacyInfo: [link] }, records = [], failure, notify, nextRequest, requests = 0, subscriptions = 0;
let revokeFailure, requestFailure, exitFailure, revocations = 0, exits = 0;
let privacyReads = 0;
let resultFailure, timerId = 0;
let createFailure, subscribeFailure, callbackFailure, createWait, subscriberCreates = 0;
const activeSubscribers = new Map();
const timers = new Map(), privacyLogs = [];
function nextRetry(delay) {
  assert.equal(timers.size, 1, 'Only one privacy retry can be pending');
  const [id, timer] = timers.entries().next().value;
  assert.equal(timer.delay, delay);
  timers.delete(id); timer.callback();
}
function exhaustRetries() { [500, 1000, 2000, 4000].forEach(nextRetry); assert.equal(timers.size, 0); }
async function initializeVisible(service, context, onChange) {
  await service.initialize(context, onChange); service.onPageShow();
}
const buildProfile = { DEBUG: true, BUILD_MODE_NAME: 'debug' };
const deviceInfo = { productModel: 'Mate 70 Pro+' };
const privacyManager = {
  AppPrivacyMgmtType: { FULL_MODE: 1 }, AppPrivacyLinkType: { PRIVACY_STATEMENT_LINK: 1 },
  AppPrivacyType: { PRIVACY_AGREEMENT: 1 },
  AppPrivacyResultType: { DISAGREED: 0, FULL_MODE_AGREED: 1, REQUIRE_RESIGNING_VERSION_UPDATE: 2 },
  getAppPrivacyMgmtInfo() { privacyReads++; if (failure) throw failure; return info; },
  getAppPrivacyResult() { privacyReads++; if (failure || resultFailure) throw failure || resultFailure; return records; },
  disableService() { revocations++; if (revokeFailure) throw revokeFailure; records = []; },
  async requestAppPrivacyConsent() { requests++; if (requestFailure) throw requestFailure; if (nextRequest) return nextRequest; return { results: records }; }
};
const commonEventManager = {
  async createSubscriber(options) { subscriberCreates++; assert.equal(options.events[0], 'usual.event.PRIVACY_STATE_CHANGED'); if (createFailure) throw createFailure; return createWait ? await createWait : {}; },
  subscribe(subscriber, callback) { if (subscribeFailure) throw subscribeFailure; activeSubscribers.set(subscriber, callback); subscriptions = activeSubscribers.size; notify = callback; if (callbackFailure) callback(callbackFailure); },
  unsubscribe(subscriber, callback) { activeSubscribers.delete(subscriber); subscriptions = activeSubscribers.size; notify = Array.from(activeSubscribers.values()).at(-1); callback?.(); }
};
function load(file, imports) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, console,
    setTimeout: (callback, delay) => { const id = ++timerId; timers.set(id, { callback, delay }); return id; },
    clearTimeout: id => timers.delete(id),
    AppStorage: { setOrCreate: (k, v) => state.set(k, v), get: k => state.get(k) },
    require: id => { if (!(id in imports)) throw Error('Unexpected import ' + id); return imports[id]; } });
  return exports;
}
const { HostedPrivacy, hostedPrivacy } = load('services/HostedPrivacy.ets', {
  '@kit.AppGalleryKit': { privacyManager }, '@kit.BasicServicesKit': { commonEventManager, deviceInfo },
  'BuildProfile': buildProfile,
  '../model/Diagnostics': { Diagnostics: { log: (...args) => privacyLogs.push(args) } },
  '../model/I18n': { t: (key, args = []) => key.replace(/\{(\d+)\}/g, (_, i) => args[i]) }
});
const agreed = (versionCode = 2) => [{ type: 1, id: 'policy', versionCode, result: 1 }];
const refused = () => [{ ...agreed()[0], result: 0 }];
const resign = (versionCode = 2) => [{ ...agreed(versionCode)[0], result: 2 }];
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  let changes = [], opened = [];
  const context = { startAbility: async want => opened.push(want), getApplicationContext: () => ({ filesDir: '/app' }),
    terminateSelf: async () => { exits++; if (exitFailure) throw exitFailure; } };
  // Subscription failures are logged without blocking a fresh query or an explicit request.
  for (const fault of ['create', 'subscribe']) {
    for (const recovery of ['manual_retry', 'page_show']) {
      const failure = { code: 1500007, message: 'PRIVATE SUBSCRIBER DATA' };
      createFailure = fault === 'create' ? failure : undefined; subscribeFailure = fault === 'subscribe' ? failure : undefined;
      records = agreed(); const recovering = new HostedPrivacy(), reads = privacyReads, beforeRequests = requests;
      await recovering.initialize(context, () => {}); recovering.onPageShow(); await tick();
      assert.equal(recovering.allowed, true); assert.equal(recovering.error, ''); assert.equal(privacyReads, reads + 2);
      assert.ok(privacyLogs.some(log => log[3]?.operation === 'subscribe' && log[3]?.code === 1500007));
      assert.equal(recovering.checking, false); assert.equal(recovering.busy, false, 'Failure releases the query/consent guards');
      createFailure = subscribeFailure = undefined;
      if (recovery === 'page_show') { recovering.onPageHide(); recovering.onPageShow(); }
      else { recovering.refresh('manual_retry'); }
      await tick();
      assert.equal(recovering.allowed, true, fault + ' failure must recover via ' + recovery + ' without restarting');
      assert.equal(recovering.error, ''); assert.equal(subscriptions, 1); assert.equal(requests, beforeRequests);
      recovering.dispose(); assert.equal(subscriptions, 0);
    }
  }
  // One in-flight subscription serves repeated recovery triggers without reinitializing the lifecycle.
  let releaseCreate; createWait = new Promise(resolve => releaseCreate = resolve);
  const coalesced = new HostedPrivacy(), beforeCreates = subscriberCreates;
  const preparing = coalesced.initialize(context, () => {}); coalesced.onPageShow();
  coalesced.refresh('manual_retry'); coalesced.onPageShow(); coalesced.refresh('manual_retry');
  assert.equal(subscriberCreates, beforeCreates + 1);
  createWait = undefined; releaseCreate({}); await preparing; assert.equal(coalesced.allowed, true); assert.equal(subscriptions, 1);
  const oldCallback = notify; oldCallback({code:1500007}); assert.equal(coalesced.allowed, true); assert.equal(subscriptions, 0);
  coalesced.refresh('manual_retry'); await tick(); assert.equal(coalesced.allowed, true); assert.equal(subscriptions, 1);
  const beforeStaleEvent=privacyReads; oldCallback({code:1500007}); oldCallback(null,{});
  assert.equal(privacyReads,beforeStaleEvent); assert.equal(coalesced.allowed,true,'Late callbacks cannot invalidate a replacement subscription');
  coalesced.dispose();
  callbackFailure={code:1500007}; const synchronous=new HostedPrivacy(); await synchronous.initialize(context,()=>{}); synchronous.onPageShow(); await tick();
  assert.equal(synchronous.allowed,true); assert.equal(synchronous.error,''); assert.equal(subscriptions,0);
  callbackFailure=undefined;synchronous.refresh('manual_retry');await tick();assert.equal(synchronous.allowed,true);synchronous.dispose();
  // Disposal/reinitialization with the SAME context object must reject the old pending completion.
  createWait=new Promise(resolve=>releaseCreate=resolve);const staleService=new HostedPrivacy();
  const oldInitialization=staleService.initialize(context,()=>{});staleService.onPageShow();staleService.dispose();
  createWait=undefined;await staleService.initialize(context,()=>{});staleService.onPageShow();assert.equal(subscriptions,1);
  const beforeLateCreate=privacyReads;releaseCreate({});await oldInitialization;
  assert.equal(subscriptions,1);assert.equal(staleService.allowed,true);assert.equal(privacyReads,beforeLateCreate);staleService.dispose();
  createWait=new Promise(resolve=>releaseCreate=resolve);const hidden=new HostedPrivacy(),hiddenReads=privacyReads;
  const hiddenInit=hidden.initialize(context,()=>{});hidden.onPageShow();hidden.onPageHide();
  createWait=undefined;releaseCreate({});await hiddenInit;assert.equal(privacyReads,hiddenReads+2);
  hidden.onPageShow();assert.equal(hidden.allowed,true);hidden.dispose();assert.equal(subscriptions,0);
  records = []; privacyReads = 0;
  console.log('PASS subscriber creation/start failures recover via retry and foreground page show without a second consent dialog');
  const service = new HostedPrivacy();
  await service.initialize(context, allowed => changes.push(allowed));
  assert.equal(privacyReads, 0, 'onCreate initialization must not query privacy');
  notify(null, {}); service.refresh('new_want');
  assert.equal(privacyReads, 0, 'Events and wants before onPageShow cannot start the first query');
  failure = { code: 1006700003, message: 'PRIVATE DATA' };
  service.onPageShow();
  assert.equal(service.allowed, true, 'The first failed query must not delay entry');
  assert.equal(service.checking, true); assert.equal(service.error, '');
  assert.doesNotThrow(() => service.requireConsent());
  const waitingReads = privacyReads;
  service.refresh(); notify(null, {}); service.onPageShow();
  assert.equal(privacyReads, waitingReads, 'Repeated triggers cannot reset or overlap a retry round');
  exhaustRetries();
  assert.equal(privacyReads, waitingReads + 4, 'One initial query plus four delayed retries');
  assert.equal(service.checking, false); assert.equal(service.allowed, true); assert.equal(service.error, '');
  assert.equal(privacyLogs.at(-1)[3].operation, 'getAppPrivacyMgmtInfo');
  assert.equal(privacyLogs.at(-1)[3].code, 1006700003);

  failure = undefined; resultFailure = { code: 1006700003 }; service.refresh();
  assert.equal(service.allowed, true);
  assert.equal(privacyLogs.at(-1)[3].operation, 'getAppPrivacyResult');
  resultFailure = undefined; records = resign(1); nextRetry(500);
  assert.equal(service.allowed, false, 'A retry can discover that the prior version requires re-signing');
  assert.equal(timers.size, 0);
  service.onGateFocus(true);
  assert.equal(timers.size, 1);
  service.onGateFocus(false);
  assert.equal(timers.size, 0, 'The system modal taking focus cancels the app startup request');
  records = agreed(); service.onGateFocus(true);
  nextRetry(3000); await tick();
  assert.equal(service.allowed, true, 'Recheck for system consent even when the event was missed');
  assert.equal(requests, 0);
  await service.openPolicy(context); assert.equal(opened[0].uri, link.url);

  for (const inconclusive of [
    [],
    [{ ...refused()[0], type: 2 }],
    [{ ...refused()[0], versionCode: 1 }],
    [{ ...resign()[0], id: 'another-policy' }],
    [{ ...agreed()[0], result: 99 }]
  ]) {
    records = inconclusive; notify(null, { data: '{"resultType":0}' });
    assert.equal(service.allowed, true, 'Unrelated or inconclusive records and event payloads do not block entry');
  }
  info = { type: 0, privacyInfo: [] }; service.refresh();
  assert.equal(service.allowed, true);
  info = { type: 1, privacyInfo: [link] };
  failure = { code: 1006700003 }; service.refresh(); service.onPageHide();
  assert.equal(timers.size, 0, 'Hiding the page cancels pending retries');
  notify(null, {});
  assert.equal(timers.size, 0, 'Background checks cannot schedule delayed retries');

  failure = undefined; records = agreed(); service.onPageShow();
  service.onPageHide(); records = refused(); notify(null, {});
  assert.equal(service.allowed, false, 'Explicit refusal stops background business');
  assert.equal(exits, 1);
  records = agreed(); notify(null, {}); assert.equal(service.allowed, false, 'Late events cannot reopen an exiting app');
  service.dispose();

  records = resign(); await initializeVisible(service, context, allowed => changes.push(allowed));
  failure = { code: 1006700001 }; service.refresh();
  assert.equal(service.allowed, false, 'A query error cannot erase a known re-sign requirement');
  assert.match(service.error, /1006700001/);
  failure = undefined;
  let resolve; nextRequest = new Promise(done => resolve = done);
  const request = service.requestConsent(); await service.requestConsent();
  assert.equal(requests, 1, 'No duplicate system popup');
  records = agreed(); resolve({ results: records }); await request; nextRequest = undefined;
  assert.equal(service.allowed, true);
  await service.requestConsent(); assert.equal(requests, 1);

  revokeFailure = { code: 1006700002, message: 'PRIVATE DATA' };
  assert.throws(() => service.revokeConsent(), error => /1006700002/.test(error.message) && !/PRIVATE/.test(error.message));
  assert.equal(service.allowed, true, 'Failed withdrawal keeps access and reports the error');
  revokeFailure = undefined; service.revokeConsent();
  assert.equal(revocations, 2); assert.equal(service.allowed, false); assert.equal(exits, 2);
  assert.equal(state.get('tinybot.privacy.allowed'), false); assert.equal(changes.at(-1), false);
  service.dispose();

  records = refused(); exitFailure = { code: 16000050 };
  await initializeVisible(service, context, () => {}); await tick();
  assert.equal(service.allowed, false); assert.match(service.error, /16000050/);
  exitFailure = undefined; await service.requestConsent();
  assert.equal(exits, 4, 'Retry after a failed termination only retries termination');
  assert.equal(requests, 1);
  service.dispose();

  records = resign(); await initializeVisible(service, context, () => {});
  requestFailure = { code: 1006700003, message: 'PRIVATE DATA' };
  service.onGateFocus(true); nextRetry(3000); await tick();
  assert.equal(service.allowed, false); assert.equal(exits, 4);
  assert.match(service.error, /1006700003/); assert.doesNotMatch(service.error, /PRIVATE/);
  service.onPageHide(); service.onPageShow(); service.onGateFocus(true);
  assert.equal(timers.size, 0, 'A failed automatic request cannot start a prompt loop');
  requestFailure = undefined;
  nextRequest = Promise.resolve({ results: [] });
  await service.requestConsent();
  assert.equal(service.allowed, false); assert.equal(exits, 4, 'Empty dialog results do not imply refusal');
  nextRequest = Promise.resolve({ results: refused() });
  await service.requestConsent();
  assert.equal(service.allowed, false); assert.equal(exits, 5, 'An explicit refusal in the system dialog exits');
  service.dispose();

  records = resign(); await initializeVisible(service, context, () => {});
  nextRequest = new Promise(done => resolve = done); const stale = service.requestConsent(); service.dispose();
  records = agreed(); resolve({ results: records }); await stale; nextRequest = undefined;
  assert.equal(service.allowed, false); assert.equal(exits, 5, 'Disposed requests cannot change access or exit');
  failure = { code: 1006700003 };
  await initializeVisible(service, context, () => {}); service.dispose();
  assert.equal(timers.size, 0, 'Disposal cancels pending privacy retries');
  failure = undefined;
  buildProfile.DEBUG = false; buildProfile.BUILD_MODE_NAME = 'release';
  for (const queryFailure of [undefined, { code: 1006700001 }]) {
    const beforeRequests = requests, beforeExits = exits;
    records = []; resultFailure = queryFailure;
    await initializeVisible(service, context, () => {});
    assert.equal(service.allowed, true, 'A release cold start with no definitive result enters immediately');
    assert.equal(service.error, '');
    service.onGateFocus(true);
    await service.requestConsent();
    assert.equal(timers.size, 0); assert.equal(requests, beforeRequests); assert.equal(exits, beforeExits);
    service.dispose();
  }
  resultFailure = undefined;
  buildProfile.DEBUG = true; buildProfile.BUILD_MODE_NAME = 'debug';
  console.log('PASS inconclusive startup, retry recovery, explicit refusal and re-sign, revocation, and stale dialog results');
  let initialized = 0, engines = 0, wants = [], loads = 0, stops = 0;
  const renderLifecycle = [];
  const bootOrder = [];
  const noOp = () => {};
  const { default: EntryAbility } = load('entryability/EntryAbility.ets', {
    '../model/Diagnostics': { Diagnostics: { log: noOp, acceptsLog: () => false } },
    '../common/ApiLevel': { ApiLevel: { sdk: 20 } },
    '../common/DeviceForm': { IS_PC: false },
    '@kit.ArkUI': {},
    '@kit.ArkWeb': { webview: { WebviewController: { initializeWebEngine() { engines++; } } } },
    '../services/NativeActions': { ShareInbox: { receive: want => wants.push(want) } },
    '../services/NativeDiagnosticLog': { configureNativeDiagnosticLog: () => bootOrder.push('logging') },
    '../services/LanguagePreferences': { LanguagePreferences: { initialize: () => bootOrder.push('language'), refresh: noOp } },
    '../services/AppearancePreferences': { AppearancePreferences: { initialize: () => bootOrder.push('appearance'), refresh: noOp, activate: noOp } },
    '../services/BackupDeviceState': { configureBackupPreferenceRefresh: noOp },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => ({ getSync: (_key, fallback) => fallback }) } },
    '../services/McpOAuth': { McpOAuth: { receive: noOp } },
    '../services/LaunchActions': { LaunchActions: { receive: noOp, setForeground: noOp } },
    '../services/BackgroundGeneration': { backgroundGeneration: { setForeground: noOp, dispose: noOp } },
    '../services/CompletionNotifications': { completionNotifications: { setForeground: noOp, dispose: noOp } },
    '../services/WebUiPreflight': { WebUiPreflight: { setForeground: value => renderLifecycle.push(['preflight', value]) } },
    '../services/PreviewCapture': { PreviewCapture: { setForeground: value => renderLifecycle.push(['capture', value]) } },
    '../services/DeveloperDiagnostics': { DeveloperDiagnostics: { initialize() { initialized++; }, stop() { stops++; }, setForeground: noOp } },
    '../services/HostedPrivacy': { hostedPrivacy }, '@kit.AbilityKit': { UIAbility: class {} },
    '../services/AutoCloudBackup': { autoCloudBackup: { setForeground: noOp, onBackground: noOp, dispose: noOp } }
  });
  records = [];
  const beforeStartupReads = privacyReads;
  const beforeStartupRequests = requests;
  const stage = { loadContent(_page, callback) { loads++; callback({ code: 0 }); },
    getMainWindowSync: () => ({ setWindowBackgroundColor: () => {}, setWindowSystemBarProperties: () => Promise.resolve() }) };
  const ability = new EntryAbility(); ability.context = context;
  ability.onCreate({ uri: 'initial' }, {}); await tick();
  assert.deepEqual(bootOrder, ['logging', 'language', 'appearance'], 'Early settings failures already have a native diagnostic sink');
  ability.onForeground(); ability.onNewWant({ uri: 'shared' }, {});
  assert.deepEqual(renderLifecycle.slice(-2), [['preflight', true], ['capture', true]]);
  ability.onBackground();
  assert.deepEqual(renderLifecycle.slice(-2), [['preflight', false], ['capture', false]]);
  ability.onForeground();
  ability.onWindowStageCreate(stage); await tick();
  assert.equal(requests, beforeStartupRequests, 'AppGallery owns the startup dialog; do not stack an explicit request');
  ability.onForeground(); await tick(); assert.equal(requests, beforeStartupRequests, 'Foreground cannot duplicate the automatic dialog');
  assert.equal(privacyReads, beforeStartupReads, 'Ability lifecycle cannot query before root onPageShow');
  failure = { code: 1006700003 };
  hostedPrivacy.onPageShow();
  assert.equal(initialized, 1); assert.equal(engines, 0); assert.equal(wants.length, 2);
  assert.equal(requests, beforeStartupRequests, 'An inconclusive startup leaves the dialog to AppGallery');
  failure = undefined;
  records = agreed(); nextRetry(500);
  records = agreed(); notify(null, {});
  await tick();
  assert.equal(initialized, 1); assert.equal(engines, 0); assert.equal(wants.length, 2);
  ability.onForeground(); notify(null, {}); assert.equal(engines, 0); assert.equal(loads, 1);
  hostedPrivacy.revokeConsent(); assert.equal(stops, 1);
  ability.onForeground(); ability.onNewWant({ uri: 'blocked' }, {});
  assert.equal(wants.length, 2);
  records = agreed(); notify(null, {}); assert.equal(wants.length, 2); assert.equal(engines, 0);
  ability.onDestroy(); assert.equal(subscriptions, 0);
  records = refused(); const beforeRestartRequests = requests, beforeRestartExits = exits;
  const restarted = new EntryAbility(); restarted.context = context;
  restarted.onCreate({}, {}); restarted.onWindowStageCreate(stage); await tick();
  hostedPrivacy.onPageShow();
  assert.equal(requests, beforeRestartRequests); assert.equal(exits, beforeRestartExits + 1);
  assert.equal(initialized, 1); assert.equal(engines, 0); restarted.onDestroy();
  records = agreed(); const beforeAgreedRequests = requests;
  const accepted = new EntryAbility(); accepted.context = context;
  accepted.onCreate({}, {}); accepted.onWindowStageCreate(stage); await tick();
  assert.equal(initialized, 1, 'Existing consent is not queried before root onPageShow');
  hostedPrivacy.onPageShow();
  assert.equal(requests, beforeAgreedRequests, 'An accepted cold start enters directly');
  assert.equal(initialized, 2); accepted.onDestroy();
  console.log('PASS actual EntryAbility starts on query failure, exits on explicit refusal, restores accepted launch and cleans up');

  // Run the real Index action handler; viewing must be direct and revocation must require confirmation.
  const indexSource = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const handler = indexSource.slice(indexSource.indexOf('  private async openSupport('), indexSource.indexOf('  private openFiles('));
  const uiExports = {}, dialogs = [], toasts = [];
  vm.runInNewContext(ts.transpileModule('export class Probe {\n' + handler + '\n}', { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports: uiExports, t: key => key, $r: key => key });
  records = agreed(); const uiPrivacy = new HostedPrivacy(); await initializeVisible(uiPrivacy, context, () => {});
  const probe = Object.assign(new uiExports.Probe(), { privacy: uiPrivacy, appearance: { surface: 0 },
    getUIContext: () => ({ showAlertDialog: dialog => dialogs.push(dialog), getHostContext: () => context,
      getPromptAction: () => ({ showToast: toast => toasts.push(toast.message) }) }) });
  const beforeDialogsExits = exits, beforeViews = opened.length;
  await probe.openSupport('privacy');
  assert.equal(dialogs.length,0,'Viewing the policy opens it directly');
  assert.equal(opened.length, beforeViews + 1);
  assert.equal(opened.at(-1).uri, link.url); assert.equal(uiPrivacy.allowed, true);
  await probe.openSupport('revoke-privacy');
  let dialog = dialogs.at(-1); assert.match(dialog.message, /退出应用/);
  assert.equal(dialog.secondaryButton.value, '拒绝并退出'); assert.equal(exits, beforeDialogsExits);
  dialog.primaryButton.action(); assert.equal(uiPrivacy.allowed, true); assert.equal(exits, beforeDialogsExits);
  revokeFailure = { code: 1006700002 };
  await probe.openSupport('revoke-privacy'); dialogs.at(-1).secondaryButton.action();
  assert.match(toasts.at(-1), /1006700002/); assert.equal(uiPrivacy.allowed, true); assert.equal(exits, beforeDialogsExits);
  revokeFailure = undefined;
  await probe.openSupport('revoke-privacy'); dialogs.at(-1).secondaryButton.action();
  assert.equal(uiPrivacy.allowed, false); assert.equal(exits, beforeDialogsExits + 1); uiPrivacy.dispose();
  console.log('PASS actual privacy menu: direct policy link, explicit withdrawal confirmation, cancel preserves consent, failure stays open, confirm revokes and exits');


  buildProfile.DEBUG = true; buildProfile.BUILD_MODE_NAME = 'debug'; deviceInfo.productModel = 'emulator';
  failure = { code: 1006700003 };
  const counts = [privacyReads, requests, revocations, subscriptions];
  const debugContext = { ...context, currentHapModuleInfo: { metadata: [
    { name: 'appgallery_privacy_link_privacy_statement', value: 'https://example.com/debug-policy' }
  ] } };
  const debugService = new HostedPrivacy();
  debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false, 'Consent needs an active lifecycle');
  await debugService.initialize(debugContext, () => {});
  debugService.onPageShow();
  assert.equal(debugService.simulatorDebug, true); assert.equal(debugService.error, '');
  debugService.refresh(); await debugService.requestConsent();
  assert.equal(debugService.allowed, false, 'Refresh/retry never auto-accepts debug consent');
  assert.throws(() => debugService.requireConsent(), /模拟器调试/);
  await debugService.openPolicy(debugContext); assert.equal(opened.at(-1).uri, 'https://example.com/debug-policy');
  debugService.acceptDebugConsent(); debugService.requireConsent(); assert.equal(debugService.allowed, true);
  debugService.refresh(); assert.equal(debugService.allowed, true, 'Foreground keeps this run consent');
  debugService.revokeConsent(); assert.equal(debugService.allowed, false);
  debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false, 'No consent while exiting');
  debugService.dispose(); await initializeVisible(debugService, debugContext, () => {});
  assert.equal(debugService.allowed, false, 'New launch requires a fresh explicit choice');
  await debugService.exit(); debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false);
  debugService.dispose();
  assert.deepEqual([privacyReads, requests, revocations, subscriptions], counts, 'No AppGallery interaction in emulator debug flow');

  const beforeDebugServices = [initialized, engines, wants.length];
  const debugAbility = new EntryAbility(); debugAbility.context = debugContext;
  debugAbility.onCreate({ uri: 'debug-initial' }, {}); debugAbility.onWindowStageCreate(stage);
  await tick(); debugAbility.onForeground(); debugAbility.onNewWant({ uri: 'debug-shared' }, {});
  hostedPrivacy.onPageShow();
  assert.deepEqual([initialized, engines, wants.length], beforeDebugServices, 'Business and pending intents wait for explicit consent');
  hostedPrivacy.acceptDebugConsent(); await tick();
  assert.deepEqual([initialized, engines, wants.length], beforeDebugServices.map((n, i) => n + (i === 2 ? 2 : i === 0 ? 1 : 0)));
  hostedPrivacy.acceptDebugConsent(); debugAbility.onForeground();
  assert.equal(engines, beforeDebugServices[1], 'Native startup never preloads ArkWeb');
  hostedPrivacy.revokeConsent(); assert.equal(hostedPrivacy.allowed, false);
  const afterRevokeWants = wants.length; debugAbility.onNewWant({ uri: 'blocked-debug' }, {});
  assert.equal(wants.length, afterRevokeWants); debugAbility.onDestroy();
  assert.deepEqual([privacyReads, requests, revocations, subscriptions], counts);
  console.log('PASS emulator explicit consent, policy viewing, foreground, rejection, withdrawal, cold restart and actual ability gating');

})().catch(error => { console.error(error); process.exitCode = 1; });
