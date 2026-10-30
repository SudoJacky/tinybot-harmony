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
const buildProfile = { DEBUG: true, BUILD_MODE_NAME: 'debug' };
const deviceInfo = { productModel: 'Mate 70 Pro+' };
const privacyManager = {
  AppPrivacyMgmtType: { FULL_MODE: 1 }, AppPrivacyLinkType: { PRIVACY_STATEMENT_LINK: 1 },
  AppPrivacyType: { PRIVACY_AGREEMENT: 1 }, AppPrivacyResultType: { FULL_MODE_AGREED: 1 },
  getAppPrivacyMgmtInfo() { privacyReads++; if (failure) throw failure; return info; },
  getAppPrivacyResult() { privacyReads++; if (failure) throw failure; return records; },
  disableService() { revocations++; if (revokeFailure) throw revokeFailure; records = []; },
  async requestAppPrivacyConsent() { requests++; if (requestFailure) throw requestFailure; if (nextRequest) return nextRequest; return { results: records }; }
};
const commonEventManager = {
  async createSubscriber(options) { assert.equal(options.events[0], 'usual.event.PRIVACY_STATE_CHANGED'); return {}; },
  subscribe(_subscriber, callback) { subscriptions++; notify = callback; },
  unsubscribe() { subscriptions--; notify = undefined; }
};
function load(file, imports) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, console,
    AppStorage: { setOrCreate: (k, v) => state.set(k, v), get: k => state.get(k) },
    require: id => { if (!(id in imports)) throw Error('Unexpected import ' + id); return imports[id]; } });
  return exports;
}
const { HostedPrivacy, hostedPrivacy } = load('services/HostedPrivacy.ets', {
  '@kit.AppGalleryKit': { privacyManager }, '@kit.BasicServicesKit': { commonEventManager, deviceInfo },
  'BuildProfile': buildProfile,
  '../model/I18n': { t: (key, args = []) => key.replace(/\{(\d+)\}/g, (_, i) => args[i]) }
});
const agreed = (versionCode = 2) => [{ type: 1, id: 'policy', versionCode, result: 1 }];
const tick = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  let changes = [], opened = [];
  const context = { startAbility: async want => opened.push(want), getApplicationContext: () => ({ filesDir: '/app' }),
    terminateSelf: async () => { exits++; if (exitFailure) throw exitFailure; } };
  const service = new HostedPrivacy();
  await service.initialize(context, allowed => changes.push(allowed));
  assert.equal(service.allowed, false); assert.equal(requests, 0, 'Wait for the ability window before requesting consent');
  assert.throws(() => service.requireConsent(), /系统弹窗/);
  records = [{ type: 2, id: 'terms', versionCode: 2, result: 1 }]; notify(null, { data: '{"resultType":1}' });
  assert.equal(service.allowed, false, 'Terms or an event payload cannot authorize the privacy policy');
  records = agreed(); notify(null, {}); assert.equal(service.allowed, true); service.requireConsent();
  await service.openPolicy(context); assert.equal(opened[0].uri, link.url);
  records = agreed(1); service.refresh(); assert.equal(service.allowed, false, 'Old version cannot authorize current policy');
  records = [{ ...agreed()[0], result: 2 }]; service.refresh(); assert.equal(service.allowed, false);
  records = [{ ...agreed()[0], id: 'another-policy' }]; service.refresh(); assert.equal(service.allowed, false);
  failure = { code: 1006700003, message: 'PRIVATE DATA' }; service.refresh();
  assert.equal(service.allowed, false); assert.match(service.error, /1006700003/); assert.doesNotMatch(service.error, /PRIVATE/);
  failure = undefined; records = agreed(); service.refresh(); assert.equal(service.allowed, true);
  records = []; notify(null, {}); assert.equal(service.allowed, false, 'Withdrawal closes access');
  let resolve; nextRequest = new Promise(done => resolve = done);
  const request = service.requestConsent(); await service.requestConsent(); assert.equal(requests, 1, 'No duplicate system popup');
  records = agreed(); resolve({ results: records }); await request; nextRequest = undefined;
  assert.equal(service.allowed, true);
  await service.requestConsent(); assert.equal(requests, 1, 'Current valid consent never repeats the dialog');
  revokeFailure = { code: 1006700002, message: 'PRIVATE DATA' };
  assert.throws(() => service.revokeConsent(), error => /1006700002/.test(error.message) && !/PRIVATE/.test(error.message));
  assert.equal(service.allowed, true, 'Failed withdrawal is not reported as successful');
  assert.equal(records.length, 1);
  revokeFailure = undefined;
  service.revokeConsent();
  assert.equal(revocations, 2); assert.equal(records.length, 0);
  assert.equal(service.allowed, false, 'Successful withdrawal closes access without waiting for a system event');
  assert.equal(state.get('tinybot.privacy.allowed'), false); assert.equal(changes.at(-1), false);
  assert.equal(exits, 1, 'Withdrawal exits after closing business access');
  assert.throws(() => service.requireConsent(), /系统弹窗/);
  records = agreed(); notify(null, {}); assert.equal(service.allowed, false, 'Late events cannot reopen an exiting app');
  service.dispose(); await service.initialize(context, allowed => changes.push(allowed));
  await service.requestConsent(); assert.equal(service.allowed, true, 'A new launch can restore system consent');
  info = { type: 0, privacyInfo: [] }; service.refresh(); assert.equal(service.allowed, false);
  info = { type: 1, privacyInfo: [link] };
  service.dispose(); assert.equal(subscriptions, 0); assert.equal(state.get('tinybot.privacy.allowed'), false);
  records = []; await service.initialize(context, () => {}); await service.requestConsent();
  assert.equal(exits, 2, 'Refusal exits'); const refusedRequests = requests;
  await service.requestConsent(); assert.equal(requests, refusedRequests, 'No reopen while terminating');
  service.dispose(); await service.initialize(context, () => {});
  requestFailure = { code: 1006700001, message: 'PRIVATE DATA' };
  await service.requestConsent(); assert.equal(exits, 2); assert.equal(service.allowed, false);
  assert.match(service.error, /1006700001/); assert.doesNotMatch(service.error, /PRIVATE/);
  requestFailure = undefined; exitFailure = { code: 16000050, message: 'PRIVATE DATA' };
  await service.requestConsent(); assert.equal(exits, 3); assert.match(service.error, /16000050/);
  exitFailure = undefined; await service.exit(); assert.equal(exits, 4);
  service.dispose(); await service.initialize(context, () => {});
  nextRequest = new Promise(done => resolve = done); const stale = service.requestConsent(); service.dispose();
  records = agreed(); resolve({ results: records }); await stale; nextRequest = undefined;
  assert.equal(service.allowed, false); assert.equal(exits, 4, 'Disposed request cannot enable or close another lifecycle');
  console.log('PASS policy/version matching, refusal exit, withdrawal exit, retryable failures, serialization and stale completion');

  let initialized = 0, engines = 0, wants = [], accountRefresh = 0, loads = 0, stops = 0;
  const renderLifecycle = [];
  const bootOrder = [];
  const noOp = () => {};
  const { default: EntryAbility } = load('entryability/EntryAbility.ets', {
    '../model/Diagnostics': { Diagnostics: { log: noOp, acceptsLog: () => false } },
    '@kit.ArkWeb': { webview: { WebviewController: { initializeWebEngine() { engines++; } } } },
    '../services/NativeActions': { ShareInbox: { receive: want => wants.push(want) } },
    '../services/NativeDiagnosticLog': { configureNativeDiagnosticLog: () => bootOrder.push('logging') },
    '../services/LanguagePreferences': { LanguagePreferences: { initialize: () => bootOrder.push('language'), refresh: noOp } },
    '../services/AppearancePreferences': { AppearancePreferences: { initialize: () => bootOrder.push('appearance'), refresh: noOp, activate: noOp } },
    '../services/McpOAuth': { McpOAuth: { receive: noOp } },
    '../services/LaunchActions': { LaunchActions: { receive: noOp, setForeground: noOp } },
    '../services/BackgroundGeneration': { backgroundGeneration: { setForeground: noOp, dispose: noOp } },
    '../services/CompletionNotifications': { completionNotifications: { setForeground: noOp, dispose: noOp } },
    '../services/WebUiPreflight': { WebUiPreflight: { setForeground: value => renderLifecycle.push(['preflight', value]) } },
    '../services/PreviewCapture': { PreviewCapture: { setForeground: value => renderLifecycle.push(['capture', value]) } },
    '../services/DeveloperDiagnostics': { DeveloperDiagnostics: { initialize() { initialized++; }, stop() { stops++; }, setForeground: noOp } },
    '../services/HuaweiAccount': { huaweiAccount: { refresh() { accountRefresh++; } } },
    '../services/HostedPrivacy': { hostedPrivacy }, '@kit.AbilityKit': { UIAbility: class {} }
  });
  records = [];
  const beforeStartupRequests = requests;
  const stage = { loadContent(_page, callback) { loads++; callback({ code: 0 }); },
    getMainWindowSync: () => ({ setWindowSystemBarProperties: () => Promise.resolve() }) };
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
  assert.equal(initialized, 0); assert.equal(engines, 0); assert.equal(wants.length, 0); assert.equal(accountRefresh, 0);
  records = agreed(); notify(null, {});
  await tick();
  assert.equal(initialized, 1); assert.equal(engines, 1); assert.equal(wants.length, 2);
  ability.onForeground(); notify(null, {}); assert.equal(engines, 1); assert.equal(loads, 1);
  hostedPrivacy.revokeConsent(); assert.equal(stops, 1); const oldRefresh = accountRefresh;
  ability.onForeground(); ability.onNewWant({ uri: 'blocked' }, {});
  assert.equal(accountRefresh, oldRefresh); assert.equal(wants.length, 2);
  records = agreed(); notify(null, {}); assert.equal(wants.length, 2); assert.equal(engines, 1);
  ability.onDestroy(); assert.equal(subscriptions, 0);
  records = []; const beforeRestartRequests = requests, beforeRestartExits = exits;
  const restarted = new EntryAbility(); restarted.context = context;
  restarted.onCreate({}, {}); restarted.onWindowStageCreate(stage); await tick();
  assert.equal(requests, beforeRestartRequests); assert.equal(exits, beforeRestartExits);
  assert.equal(initialized, 1); assert.equal(engines, 1); restarted.onDestroy();
  records = agreed(); const beforeAgreedRequests = requests;
  const accepted = new EntryAbility(); accepted.context = context;
  accepted.onCreate({}, {}); accepted.onWindowStageCreate(stage); await tick();
  assert.equal(requests, beforeAgreedRequests, 'An accepted cold start enters directly');
  assert.equal(initialized, 2); accepted.onDestroy();
  console.log('PASS actual EntryAbility avoids duplicate AppGallery startup dialog, blocks unsigned launches, restores accepted launch and cleans up');

  // Run the real Index action handler; the two dialogs must not revoke before final confirmation.
  const indexSource = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
  const handler = indexSource.slice(indexSource.indexOf('  private async openSupport('), indexSource.indexOf('  private openFiles('));
  const uiExports = {}, dialogs = [], toasts = [];
  vm.runInNewContext(ts.transpileModule('export class Probe {\n' + handler + '\n}', { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports: uiExports, t: key => key, $r: key => key });
  records = agreed(); const uiPrivacy = new HostedPrivacy(); await uiPrivacy.initialize(context, () => {});
  const probe = Object.assign(new uiExports.Probe(), { privacy: uiPrivacy, appearance: { surface: 0 },
    getUIContext: () => ({ showAlertDialog: dialog => dialogs.push(dialog), getHostContext: () => context,
      getPromptAction: () => ({ showToast: toast => toasts.push(toast.message) }) }) });
  const beforeDialogsExits = exits, beforeViews = opened.length;
  await probe.openSupport('privacy'); let dialog = dialogs.at(-1);
  assert.equal(dialog.primaryButton.value, '查看'); assert.equal(dialog.secondaryButton.value, '拒绝');
  dialog.primaryButton.action(); await tick(); assert.equal(opened.length, beforeViews + 1);
  assert.equal(opened.at(-1).uri, link.url); assert.equal(uiPrivacy.allowed, true);
  await probe.openSupport('privacy'); dialogs.at(-1).secondaryButton.action();
  dialog = dialogs.at(-1); assert.match(dialog.message, /退出应用/);
  assert.equal(dialog.secondaryButton.value, '拒绝并退出'); assert.equal(exits, beforeDialogsExits);
  dialog.primaryButton.action(); assert.equal(uiPrivacy.allowed, true); assert.equal(exits, beforeDialogsExits);
  revokeFailure = { code: 1006700002 };
  await probe.openSupport('privacy'); dialogs.at(-1).secondaryButton.action(); dialogs.at(-1).secondaryButton.action();
  assert.match(toasts.at(-1), /1006700002/); assert.equal(uiPrivacy.allowed, true); assert.equal(exits, beforeDialogsExits);
  revokeFailure = undefined;
  await probe.openSupport('privacy'); dialogs.at(-1).secondaryButton.action(); dialogs.at(-1).secondaryButton.action();
  assert.equal(uiPrivacy.allowed, false); assert.equal(exits, beforeDialogsExits + 1); uiPrivacy.dispose();
  console.log('PASS actual privacy menu: view link, two-step rejection, cancel preserves consent, failure stays open, confirm revokes and exits');

  // An AppGallery error is never permission to bypass consent on hardware or release builds.
  for (const [debug, mode, model] of [
    [true, 'debug', 'Mate 70 Pro+'], [false, 'release', 'Mate 70 Pro+'],
    [false, 'release', 'emulator'], [true, 'release', 'emulator'],
    [false, 'debug', 'emulator'], [true, 'debug', 'unknown']
  ]) {
    buildProfile.DEBUG = debug; buildProfile.BUILD_MODE_NAME = mode; deviceInfo.productModel = model;
    failure = { code: 1006700003 };
    const guarded = new HostedPrivacy(); await guarded.initialize(context, () => {});
    assert.equal(guarded.simulatorDebug, false);
    guarded.acceptDebugConsent(); assert.equal(guarded.allowed, false);
    assert.match(guarded.error, /1006700003/);
    assert.throws(() => guarded.requireConsent(), /1006700003/);
    failure = undefined; records = agreed(); guarded.refresh();
    assert.equal(guarded.allowed, true, 'Non-emulator paths still require real system consent');
    guarded.dispose();
  }
  console.log('PASS debug hardware, release hardware, release emulator and unknown devices cannot use debug consent');

  buildProfile.DEBUG = true; buildProfile.BUILD_MODE_NAME = 'debug'; deviceInfo.productModel = 'emulator';
  failure = { code: 1006700003 };
  const counts = [privacyReads, requests, revocations, subscriptions];
  const debugContext = { ...context, currentHapModuleInfo: { metadata: [
    { name: 'appgallery_privacy_link_privacy_statement', value: 'https://example.com/debug-policy' }
  ] } };
  const debugService = new HostedPrivacy();
  debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false, 'Consent needs an active lifecycle');
  await debugService.initialize(debugContext, () => {});
  assert.equal(debugService.simulatorDebug, true); assert.equal(debugService.error, '');
  debugService.refresh(); await debugService.requestConsent();
  assert.equal(debugService.allowed, false, 'Refresh/retry never auto-accepts debug consent');
  assert.throws(() => debugService.requireConsent(), /模拟器调试/);
  await debugService.openPolicy(debugContext); assert.equal(opened.at(-1).uri, 'https://example.com/debug-policy');
  debugService.acceptDebugConsent(); debugService.requireConsent(); assert.equal(debugService.allowed, true);
  debugService.refresh(); assert.equal(debugService.allowed, true, 'Foreground keeps this run consent');
  debugService.revokeConsent(); assert.equal(debugService.allowed, false);
  debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false, 'No consent while exiting');
  debugService.dispose(); await debugService.initialize(debugContext, () => {});
  assert.equal(debugService.allowed, false, 'New launch requires a fresh explicit choice');
  await debugService.exit(); debugService.acceptDebugConsent(); assert.equal(debugService.allowed, false);
  debugService.dispose();
  assert.deepEqual([privacyReads, requests, revocations, subscriptions], counts, 'No AppGallery interaction in emulator debug flow');

  const beforeDebugServices = [initialized, engines, wants.length];
  const debugAbility = new EntryAbility(); debugAbility.context = debugContext;
  debugAbility.onCreate({ uri: 'debug-initial' }, {}); debugAbility.onWindowStageCreate(stage);
  await tick(); debugAbility.onForeground(); debugAbility.onNewWant({ uri: 'debug-shared' }, {});
  assert.deepEqual([initialized, engines, wants.length], beforeDebugServices, 'Business and pending intents wait for explicit consent');
  hostedPrivacy.acceptDebugConsent(); await tick();
  assert.deepEqual([initialized, engines, wants.length], beforeDebugServices.map((n, i) => n + (i === 2 ? 2 : 1)));
  hostedPrivacy.acceptDebugConsent(); debugAbility.onForeground();
  assert.equal(engines, beforeDebugServices[1] + 1, 'Duplicate clicks do not restart services');
  hostedPrivacy.revokeConsent(); assert.equal(hostedPrivacy.allowed, false);
  const afterRevokeWants = wants.length; debugAbility.onNewWant({ uri: 'blocked-debug' }, {});
  assert.equal(wants.length, afterRevokeWants); debugAbility.onDestroy();
  assert.deepEqual([privacyReads, requests, revocations, subscriptions], counts);
  console.log('PASS emulator explicit consent, policy viewing, foreground, rejection, withdrawal, cold restart and actual ability gating');
})().catch(error => { console.error(error); process.exitCode = 1; });
