// Exercise real session completion signals, installation-local history and the invitation controller.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
let disk = new Map(), working = new Map(), failFlush = false;
const store = {
  getSync: (key, fallback) => working.has(key) ? working.get(key) : fallback,
  putSync: (key, value) => working.set(key, value),
  flushSync() { if (failFlush) throw Error('disk failure'); disk = new Map(working); }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, setTimeout, clearTimeout,
    require: id => id === '@kit.ArkData' ? { preferences: { getPreferencesSync: () => store } } : load(path.resolve(path.dirname(file), id))
  }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { ReviewPreferences } = from('services/ReviewPreferences');
const history = () => new ReviewPreferences({});
const reset = () => { disk.clear(); working.clear(); failFlush = false; };
const week = 7 * 24 * 60 * 60 * 1000, now = 1800000000000;
assert.equal(history().shouldAsk(now), false);
for (let i = 0; i < 4; i++) history().recordTask();
assert.equal(history().shouldAsk(now), false);
history().recordTask(); assert.equal(history().shouldAsk(now), true);
history().didAsk(now); working = new Map(disk);
assert.equal(history().shouldAsk(now + week - 1), false);
assert.equal(history().shouldAsk(now - 1000), false, 'Clock rollback cannot bypass frequency control');
assert.equal(history().shouldAsk(now + week), true);
history().stopInvitations(); working = new Map(disk);
history().recordTask(); assert.equal(history().shouldAsk(now + week * 100), false);
reset(); failFlush = true;
assert.throws(() => history().recordTask(), /disk failure/);
assert.equal(working.get('reviewInvitation'), '', 'Failed writes roll back the Preferences cache');
failFlush = false; for (let i = 0; i < 5; i++) history().recordTask();
const prior = working.get('reviewInvitation'); failFlush = true;
assert.throws(() => history().didAsk(now), /disk failure/);
assert.throws(() => history().stopInvitations(), /disk failure/);
assert.equal(working.get('reviewInvitation'), prior);
assert.equal(history().shouldAsk(now), true);
failFlush = false;
for (const bad of ['{', 'null', '{}', '{"completedTasks":5,"lastAskedAt":0,"stopped":"false"}']) {
  working.set('reviewInvitation', bad); assert.throws(() => history().shouldAsk(now));
}
console.log('PASS task threshold, restart persistence, seven-day cooldown, opt-out, storage failure rollback and corrupt history');

// The actual UI controller runs with deterministic timer/window boundaries.
const source = fs.readFileSync(path.join(root, 'pages/Index.ets'), 'utf8');
const methods = source.slice(source.indexOf('  private reviewPreferences('), source.indexOf('  private onboardingPreferences('));
const exportsUI = {}, dialogs = [], timers = new Map(), logs = [];
let nextTimer = 0, pendingAnnouncement = false, failOpen = false;
const announcements = { loading: false, pending: () => pendingAnnouncement };
class Controller {
  constructor(options) { this.options = options; this.closed = false; }
  open() { if (failOpen) throw Error('No window'); dialogs.push(this); }
  close() { this.closed = true; this.options.onDidDisappear(); }
}
vm.runInNewContext(compile('export class Probe {\n' + methods + '\n}'), {
  exports: exportsUI, ReviewPreferences, ReviewInvitationDialog: props => props,
  CustomDialogController: Controller, DialogAlignment: { Center: 0 }, WorkbenchLayout: { dialogWidth: () => 0 },
  ShareInbox: { peek: () => false }, announcements, Diagnostics: { log: (...args) => logs.push(args) },
  t: key => key, Date: { now: () => now },
  setTimeout: (fn, ms) => { assert.equal(ms, 1500); timers.set(++nextTimer, fn); return nextTimer; },
  clearTimeout: id => timers.delete(id)
});
function page() {
  return Object.assign(new exportsUI.Probe(), {
    privacy: { allowed: true }, foreground: true, chatVisible: true, reviewDisposed: false,
    reviewTimer: -1, paths: { size: () => 0 }, appearance: {}, windowWidth: 390, approval: {},
    app: { ready: true, busy: false, draft: '', active: { id: 'chat', attachments: [], references: [], pendingInputs: [] } },
    getUIContext: () => ({ getHostContext: () => ({}), getPromptAction: () => ({ showToast() {} }) }),
    openSupport: name => { assert.equal(name, 'rating'); systemRequests++; }, offerAnnouncement() {}, offerStartupBackup() {}
  });
}
function fireTimers() { const pending = [...timers.values()]; timers.clear(); for (const fn of pending) fn(); }
function eligible() { reset(); for (let i = 0; i < 5; i++) history().recordTask(); }
let systemRequests = 0;
eligible(); const p = page();
assert.equal(dialogs.length, 0, 'Constructing/restoring the page cannot prompt');
p.foregroundChanged(); fireTimers(); assert.equal(dialogs.length, 0, 'Foreground entry cannot prompt');
for (const [target, key, value] of [
  [p, 'foreground', false], [p, 'reviewDisposed', true], [p, 'chatVisible', false], [p, 'onboardingActive', true],
  [p, 'browserExpanded', true], [p, 'detailPaneOpen', true], [p, 'drawerOpen', true], [p, 'showToolScope', true],
  [p, 'ratingOpen', true], [p, 'announcementDialog', {}], [p, 'voiceRequest', 'voice'],
  [p, 'startupBackupDialog', {}], [p, 'startupBackupRestoring', true],
  [p.app, 'busy', true], [p.app, 'error', 'failed'], [p.app, 'saveError', 'disk'], [p.app, 'draft', 'typing'],
  [p.app.active, 'attachments', [{}]], [p.app.active, 'references', [{}]], [p.app.active, 'pendingInputs', [{}]],
  [p.approval, 'title', 'approval'], [p.approval, 'form', {}], [p.privacy, 'allowed', false]
]) {
  const previous = target[key]; target[key] = value; p.offerReviewInvitation('chat'); target[key] = previous;
  assert.equal(dialogs.length, 0, 'Blocked opportunity: ' + key);
}
pendingAnnouncement = true; p.offerReviewInvitation('chat'); pendingAnnouncement = false;
p.offerReviewInvitation('other'); assert.equal(dialogs.length, 0);
p.taskCompleted('chat'); assert.equal(timers.size, 1);
p.taskCompleted('chat'); assert.equal(timers.size, 1, 'Queued completions replace the pending timer');
p.app.busy = true; fireTimers(); assert.equal(dialogs.length, 0); p.app.busy = false;
p.taskCompleted('chat'); p.app.draft = 'new draft'; fireTimers(); assert.equal(dialogs.length, 0); p.app.draft = '';
p.taskCompleted('chat'); p.cancelReviewOffer(); fireTimers(); assert.equal(dialogs.length, 0, 'New interaction cancels the pending invitation');
p.taskCompleted('chat'); fireTimers(); p.offerReviewInvitation('chat'); assert.equal(dialogs.length, 1);
dialogs.at(-1).options.onDidAppear(); assert.equal(history().shouldAsk(now), false);
dialogs.at(-1).options.builder.onChoose('later'); assert.equal(systemRequests, 0);
p.taskCompleted('chat'); fireTimers(); assert.equal(dialogs.length, 1, 'Not now respects the persisted cooldown');
eligible(); p.taskCompleted('chat'); fireTimers(); dialogs.at(-1).options.onDidAppear();
dialogs.at(-1).options.builder.onChoose('never');
working = new Map(disk); assert.equal(history().shouldAsk(now + 100 * week), false);
eligible(); p.taskCompleted('chat'); p.foreground = false; p.foregroundChanged(); fireTimers();
assert.equal(timers.size, 0); p.foreground = true;
p.taskCompleted('chat'); fireTimers(); dialogs.at(-1).options.onDidAppear();
dialogs.at(-1).options.builder.onChoose('review'); assert.equal(systemRequests, 1, 'Acceptance opens system review after dismissal');
eligible(); p.taskCompleted('chat'); fireTimers();
const withdrawn = dialogs.at(-1); p.privacy.allowed = false; withdrawn.options.onDidAppear();
assert.equal(withdrawn.closed, true); assert.equal(history().shouldAsk(now), true); p.privacy.allowed = true;
eligible(); failOpen = true; p.taskCompleted('chat'); fireTimers(); failOpen = false;
assert.equal(p.reviewDialog, undefined); assert.equal(history().shouldAsk(now), true);
assert.ok(logs.some(log => log[2] === 'present_failed'));
console.log('PASS idle/task timing, competing flows, draft protection, deduplication, consent, dismissal, opt-out and window failure');

async function sessionSignals() {
  const { emptyData, parseAppData } = from('model/Conversation');
  const { defaultProductivity } = from('model/Productivity');
  const { defaultAssistantOptions } = from('model/AssistantOptions');
  const { modelConfig } = from('model/ProviderProfiles');
  const { ProviderRegistry } = from('services/providers/ProviderRegistry');
  const { AgentRuntime } = from('services/AgentRuntime');
  const { SessionService } = from('services/SessionService');
  let ids = 0, failure = false, failSave = false, failFinalSave = false, blocked;
  const data = emptyData(), profile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: '', noApiKey: true, enabled: true, models: ['model'], contextWindow: 32768 };
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions();
  data.productivity.options.autoMemory = false; data.productivity.options.saveSummary = false;
  data.providerProfiles = [profile]; data.config = modelConfig([profile], { providerId: 'test', modelId: 'model' }, data.config);
  data.threads = [{ id: 'chat', title: 'Test', titleEdited: true, updatedAt: 1, messages: [], draft: '',
    modelRef: { providerId: 'test', modelId: 'model' } }]; data.activeThreadId = 'chat';
  const repository = { load: async () => parseAppData(JSON.stringify(data)), save: async saved => {
    if (failSave || (failFinalSave && saved.threads[0].messages.at(-1)?.status === 'complete')) throw Error('disk');
  } };
  const keys = { read: async () => '', write: async () => {}, remove: async () => {} };
  const provider = { info: { id: 'test', name: 'Test', protocol: 'test' }, endpoint: url => url,
    stream: async (_request, signal) => {
      if (blocked) await blocked;
      signal.check(); if (failure) throw Error('provider failure'); return { content: 'done', toolCalls: [] };
    } };
  const registry = new ProviderRegistry(); registry.register(provider);
  const resources = { createId: () => 'id-' + ++ids, ensureWorkspace: async () => {}, configureProviders() {}, reportError() {},
    tools: () => ({ definitions: () => [], execute: async () => '' }) };
  const session = new SessionService(repository, new AgentRuntime(registry, keys), keys, resources), completed = [];
  session.subscribe(event => { if (event.kind === 'task-complete') completed.push(event); });
  await session.initialize(); assert.equal(completed.length, 0);
  session.setDraft('Hello'); await session.send(); assert.equal(completed.length, 1);
  assert.equal(completed[0].threadId, 'chat'); assert.ok(completed[0].messageId);
  failure = true; session.setDraft('Fail'); await session.send(); assert.equal(completed.length, 1);
  failure = false; failSave = true; session.setDraft('Save failure'); await session.send(); assert.equal(completed.length, 1);
  failSave = false; await session.retrySave();
  failFinalSave = true; session.setDraft('Final checkpoint failure'); await session.send(); assert.equal(completed.length, 1);
  failFinalSave = false; await session.retrySave();
  let release; blocked = new Promise(resolve => { release = resolve; });
  session.setDraft('Stop'); const stopped = session.send();
  for (let i = 0; i < 100 && session.state.phase !== 'running'; i++) await Promise.resolve();
  await session.stop(); release(); await stopped; assert.equal(completed.length, 1);
  console.log('PASS real session signals: only successful persisted user tasks count; initialization, failure, save failure and cancellation do not');
}
sessionSignals().catch(error => { console.error(error); process.exitCode = 1; });
