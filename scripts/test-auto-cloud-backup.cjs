// Drive real background backup and cancellation with controlled native task/cloud outcomes.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const file = path.resolve(__dirname, '../entry/src/main/ets/services/AutoCloudBackup.ets');
const id = '11111111-1111-4111-8111-111111111111';
const tick = async () => { for (let i = 0; i < 12; i++) await new Promise(resolve => setImmediate(resolve)); };
function checkCompiledPanel(f) {
  const source = path.resolve(__dirname, '../entry/src/main/ets/views/BackupPanel.ets');
  const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/BackupPanel.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild BackupPanel before UI checks');
  const tree = ts.createSourceFile('BackupPanel.ts', fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'BackupPanel');
  const methods = ['backupTab', 'locked'];
  const nodes = new Map(), texts = [], exports = {};
  const widget = new Proxy({}, { get: (_, key) => (...args) => { if (key === 'create' && typeof args[0] === 'string') texts.push(args[0]); return widget; } });
  class Child { constructor(_parent, props) { if (props.compId) nodes.set(props.compId, props); props.content?.(); } }
  vm.runInNewContext(ts.transpileModule('class Probe {' + methods.map(name => component.members.find(n => n.name?.getText(tree) === name).getText(tree)).join('\n') + '} exports.Probe=Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, { PageStyles: {form:{}}, exports, t: (s, args = []) => s.replace(/\{(\d+)\}/g, (_, i) => args[i]), getLocale: () => 'en-US',
    Scroll: widget, Column: widget, Text: widget, Row: widget, If: widget, ForEach: widget, SymbolGlyph: widget, LoadingProgress: widget, __Common__: widget,
    SectionHeader: Child, GroupCard: Child, SwitchRow: Child, NavRow: Child, RowDivider: Child, Banner: Child, IconButton: Child,
    ViewPU: { create() {} }, Space: {}, Radius: {}, BarState: { Off: 0 }, Alignment: { Top: 0 }, VerticalAlign: { Top: 0 } });
  const actions = [];
  const panel = Object.assign(new exports.Probe(), { automatic: f.service, app: { busy: false }, busy: false, status: '', error: '', backupDate: '', cloud: value => actions.push(value), appearance: {},
    observeComponentCreation2: callback => callback(1, true), ifElseBranchUpdateFunction: (_branch, callback) => callback(),
    forEachUpdateFunction: (_element, items, callback) => items.forEach(callback) });
  panel.backupTab();
  assert.deepEqual([...nodes.keys()].sort(), ['create-cloud-backup', 'restore-cloud-backup']); assert.ok(texts.includes(f.service.status));
  assert.equal(nodes.get('create-cloud-backup').title, '备份'); assert.equal(nodes.get('restore-cloud-backup').title, '恢复备份');
  nodes.get('create-cloud-backup').onTap(); nodes.get('restore-cloud-backup').onTap(); assert.deepEqual(actions, [false, true]);
  panel.busy = true; panel.backupTab(); assert.equal(nodes.get('create-cloud-backup').disabled, true); assert.equal(nodes.get('restore-cloud-backup').disabled, true);
  console.log('PASS compiled backup page has exactly two actions, one-step cloud restore, automatic status and busy guards');
}
function fixture() {
  let usable = true, ready = true, location = 1, failure, pending, writes = 0, uploads = 0, snapshots = 0, failFlush = false, leaseError, releaseError;
  const saved = new Map([['startupBackupState', 'done']]), prefs = new Map(saved), logs = [], calls = [], leases = [], released = [];
  const privacy = { allowed: true }, account = { signedIn: true }, workspace = { contentRevision: 0 };
  const changes = { revision: 0 };
  let data = { config: {}, threads: [{ messages: [{ content: 'record' }] }], providerProfiles: [], productivity: {} };
  const store = { getSync: (k, d) => prefs.has(k) ? prefs.get(k) : d, putSync: (k, v) => prefs.set(k, v),
    flushSync() { if (failFlush) throw Error('disk full'); for (const [k, v] of prefs) saved.set(k, v); } };
  const cloud = { busy: false, available: async () => usable,
    async create(context, snapshot, options) { writes++; calls.push({ context, snapshot, options }); if (failure) throw failure; if (pending) await pending; options.cancellation.check(); return location === 3; },
    async list() { return writes ? [{ name: 'tinybot-latest.tinybot', createdAt: 1000000, location }] : []; },
    async retryUpload(_context, cancellation) { return cloud.sync(cancellation); },
    async sync(cancellation) { uploads++; if (failure) throw failure; cancellation.check(); return location === 3; } };
  const cancelExports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(path.dirname(file), 'Cancellation.ets'), 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports: cancelExports, require: () => ({ ToolFailure: class extends Error { constructor(code, message) { super(message); this.code = code; } } }) });
  const imports = {
    '../model/BackupChanges': { BackupChanges: changes },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => store } }, '@kit.ArkTS': { util: { generateRandomUUID: () => id } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager: {
      requestSuspendDelay(_reason, callback) { if (leaseError) throw leaseError; leases.push(callback); return { requestId: leases.length, actualDelayTime: 180000 }; },
      cancelSuspendDelay(requestId) { if (releaseError) throw releaseError; released.push(requestId); }
    } },
    '../model/Diagnostics': { Diagnostics: { log: (...args) => logs.push(args) } },
    '../model/I18n': { getLocale: () => 'en-US', t: (s, args = []) => s.replace(/\{(\d+)\}/g, (_, i) => args[i]) },
    '../model/Onboarding': { isOnboardingCandidate: d => !d.threads.some(t => t.messages.length) && !d.providerProfiles.length },
    './CloudBackup': { CloudBackup: cloud, CLOUD_BACKUP_NAME: 'tinybot-latest.tinybot', cloudBackupError: e => e.message }, './HostedPrivacy': { hostedPrivacy: privacy },
    './HuaweiAccount': { huaweiAccount: account }, './NativeWorkspaceFiles': { NativeWorkspaceFiles: workspace }, './Cancellation': cancelExports
  };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: x => x,
    setTimeout: () => { throw Error('Automatic backup must not schedule periodic work'); },
    require: id => { if (!(id in imports)) throw Error(id); return imports[id]; } });
  const service = new exports.AutoCloudBackup(), context = {};
  const initialize = () => service.initialize(context, () => { snapshots++; return data; }, () => ready);
  initialize(); service.setForeground(true);
  return { service, cloud, privacy, account, workspace, changes, prefs, saved, logs, calls, initialize, leases, released,
    get writes() { return writes; }, get uploads() { return uploads; }, get snapshots() { return snapshots; },
    set usable(v) { usable = v; }, set ready(v) { ready = v; }, set location(v) { location = v; }, set failure(v) { failure = v; },
    set pending(v) { pending = v; }, set data(v) { data = v; }, set failFlush(v) { failFlush = v; },
    set leaseError(v) { leaseError = v; }, set releaseError(v) { releaseError = v; },
    async leave() { service.onBackground(); await tick(); } };
}
(async () => {
  for (const blocked of ['login', 'privacy', 'cloud', 'restoration', 'busy', 'empty']) {
    const f = fixture();
    if (blocked === 'login') f.account.signedIn = false;
    if (blocked === 'privacy') f.privacy.allowed = false;
    if (blocked === 'cloud') f.usable = false;
    if (blocked === 'restoration') f.prefs.set('startupBackupState', 'pending');
    if (blocked === 'busy') f.ready = false;
    if (blocked === 'empty') f.data = { config: {}, threads: [], providerProfiles: [], productivity: {} };
    await f.leave(); assert.equal(f.writes, 0, blocked); assert.equal(f.leases.length, f.released.length, blocked + ' releases any acquired task'); f.service.dispose();
  }
  let f = fixture(); assert.equal(f.service.enabled, true); f.service.changed(); await tick();
  assert.equal(f.writes, 0); assert.equal(f.leases.length, 0, 'Startup, foreground and edits do not start a backup');
  f.service.onBackground(); assert.equal(f.leases.length, 1, 'Lease is acquired synchronously before any async preparation'); await tick();
  assert.equal(f.writes, 1); assert.equal(f.service.state, 'pending'); assert.deepEqual(f.released, [1]);
  assert.equal(f.calls[0].options.interactive, false); assert.equal(f.calls[0].options.name, undefined, 'Automatic saves use the shared default cloud file');
  f.location = 3; await f.leave(); assert.equal(f.uploads, 1); assert.equal(f.writes, 1, 'Pending upload retries do not reserialize unchanged data');
  assert.equal(f.service.state, 'uploaded'); const leases = f.leases.length; await f.leave(); assert.equal(f.leases.length, leases, 'Unchanged uploaded data needs no task');
  f.workspace.contentRevision++; await f.leave(); assert.equal(f.writes, 2, 'Mini app/workspace writes also invalidate the snapshot');
  f.service.changed(); await tick(); assert.equal(f.writes, 2); await f.leave(); assert.equal(f.writes, 3);
  f.service.setEnabled(false); assert.equal(f.saved.get('autoCloudBackupEnabled'), false); await f.leave(); assert.equal(f.writes, 3);
  f.service.dispose(); f.initialize(); assert.equal(f.service.enabled, true, 'Single-backup mode keeps automatic backup enabled, including legacy opt-outs');
  f.failFlush = true; assert.throws(() => f.service.setEnabled(false), /disk full/); assert.equal(f.prefs.get('autoCloudBackupEnabled'), true); f.service.dispose();
  f = fixture(); f.location = 3; await f.leave(); assert.equal(f.writes, 1);
  f.changes.revision++; await f.leave(); assert.equal(f.writes, 2, 'Credential and usage-only changes invalidate automatic snapshots');
  f.prefs.set('language', 'en'); await f.leave(); assert.equal(f.writes, 3, 'Language-only edits invalidate automatic snapshots');
  f.prefs.set('appearance', '{"accent":"blue"}'); await f.leave(); assert.equal(f.writes, 4, 'Appearance-only edits invalidate automatic snapshots');
  f.prefs.set('seenReplies', '{"reply":"read"}'); await f.leave(); assert.equal(f.writes, 5, 'Feedback read state invalidates automatic snapshots');
  await f.leave(); assert.equal(f.writes, 5, 'Unchanged additional data does not serialize again'); f.service.dispose();
  f = fixture(); f.prefs.set('startupBackupState', 'pending'); f.prefs.set('onboardingComplete', true); await f.leave(); assert.equal(f.writes, 1); f.service.dispose();
  f = fixture(); f.leaseError = Error('quota exhausted'); await f.leave(); assert.equal(f.writes, 0); assert.equal(f.service.state, 'failed');
  f.leaseError = undefined; f.location = 3; await f.leave(); assert.equal(f.service.state, 'uploaded'); f.service.dispose();
  f = fixture(); f.failure = Error('network unavailable'); await f.leave(); assert.equal(f.service.state, 'failed'); assert.deepEqual(f.released, [1]);
  f.failure = undefined; f.location = 3; await f.leave(); assert.equal(f.service.state, 'uploaded'); f.service.dispose();
  f = fixture(); let finish; f.pending = new Promise(resolve => finish = resolve); await f.leave();
  f.service.onBackground(); assert.equal(f.leases.length, 1, 'One in-flight archive owns one short task');
  f.leases[0](); assert.equal(f.calls[0].options.cancellation.cancelled, true); assert.deepEqual(f.released, [1]);
  finish(); await tick(); assert.equal(f.service.state, 'failed'); assert.match(f.service.error, /后台备份时间已结束/); assert.deepEqual(f.released, [1]); f.service.dispose();
  f = fixture(); f.pending = new Promise(resolve => finish = resolve); await f.leave(); f.service.dispose(); f.initialize();
  finish(); await tick(); assert.equal(f.service.state, 'waiting', 'Old completion cannot update a new lifecycle'); f.service.dispose();
  f = fixture(); f.pending = new Promise(resolve => finish = resolve); await f.leave(); f.service.setEnabled(false);
  finish(); await tick(); assert.equal(f.service.state, 'disabled'); assert.deepEqual(f.released, [1]); f.service.dispose();
  f = fixture(); f.releaseError = Error('native cancellation failed'); await f.leave();
  assert.ok(f.logs.some(log => log[2] === 'auto_release_failed')); assert.equal(f.released.length, 0);
  f.releaseError = undefined; f.service.setForeground(true); assert.deepEqual(f.released, [1], 'Failed native cleanup remains retryable'); f.service.dispose();
  console.log('PASS background-only triggering, no periodic work, synchronous lease, change detection, pending sync, eligibility, quota failure, expiry cancellation, cleanup retries and stale completions');
  f = fixture(); await f.leave(); assert.equal(f.service.state, 'pending');
  const automaticName = 'tinybot-latest.tinybot';
  f.service.confirmUploaded([{ name: 'tinybot-auto-' + id + '.tinybot', location: 3, createdAt: 2000 }]);
  f.service.confirmUploaded([{ name: automaticName, location: 1, createdAt: 2000 }]);
  assert.equal(f.service.state, 'pending', 'Another snapshot or a local-only copy cannot confirm this upload');
  f.service.confirmUploaded([{ name: automaticName, location: 3, createdAt: 3000 }]);
  assert.equal(f.service.state, 'uploaded'); assert.equal(f.service.lastUploadedAt, 3000);
  assert.equal(f.writes, 1); assert.equal(f.leases.length, 1, 'A metadata refresh cannot start another archive or background task');
  f.service.setEnabled(false); f.service.confirmUploaded([{ name: automaticName, location: 3, createdAt: 4000 }]);
  assert.equal(f.service.state, 'disabled'); f.service.dispose();
  f = fixture(); f.failure = Error('network unavailable'); await f.leave();
  f.service.confirmUploaded([{ name: f.calls[0].options.name, location: 3, createdAt: 5000 }]);
  assert.equal(f.service.state, 'failed', 'A metadata refresh must preserve a failed backup for diagnosis'); f.service.dispose();
  console.log('PASS cloud metadata reconciles a completed pending upload without timers, repacking, or clearing failure/opt-out states');
  if (process.argv.includes('--ui')) { const ui = fixture(); checkCompiledPanel(ui); ui.service.dispose(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
