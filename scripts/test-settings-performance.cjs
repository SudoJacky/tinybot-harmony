// Real session and view-model code; hold disk IO to inspect the settings page mid-save.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { performance } = require('node:perf_hooks');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
const sessionCases = [];
const hypium = { describe: (_name, run) => run(), it: (name, _flags, run) => sessionCases.push({ name, run }),
  expect: value => ({ assertTrue: () => assert.equal(value, true), assertFalse: () => assert.equal(value, false),
    assertEqual: expected => assert.equal(value, expected) }) };
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return hypium;
    if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const from = file => load(path.join(root, 'entry/src/main/ets', file));
const { Fixture, seed } = load(path.join(root, 'entry/src/test/SessionService.test'));
const { ChatViewModel } = from('viewmodel/ChatViewModel');
const { MessageViewModel } = from('viewmodel/SessionViewModels');
const { defaultAssistantOptions } = from('model/AssistantOptions');
const panelSource = path.join(root, 'entry/src/main/ets/views/SettingsPanel.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/SettingsPanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(panelSource).mtimeMs, 'Build before testing the UI callbacks');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const declaration = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'SettingsPanel');
const names = ['blocked', 'canEdit', 'resetAssistantDraft', 'saveToggle', 'setToggleDraft', 'savedToggleValue'];
const globals = { exports: {}, defaultAssistantOptions };
vm.runInNewContext(ts.transpileModule(`class Panel {
${declaration.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')}
} exports.Panel = Panel;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
function gate() { let open; const promise = new Promise(resolve => { open = resolve; }); return { promise, open }; }
async function settle() { for (let i = 0; i < 150; i++) await Promise.resolve(); }
function panel(app) {
  const toasts = [];
  const value = Object.assign(new globals.exports.Panel(), { app, settings: app.settings,
    pendingSave: Promise.resolve(), toggleRevisions: new Map(), appearance: {},
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }) });
  value.resetAssistantDraft(); return { value, toasts };
}
async function setup() {
  const f = new Fixture(), app = new ChatViewModel(); await app.initialize(f.session); app.openSettings();
  return { f, app, ...panel(app) };
}
(async () => {
  const data = seed();
  data.threads = Array.from({ length: 20 }, (_, index) => ({ ...data.threads[0], id: 'chat-' + index,
    messages: Array.from({ length: 50 }, (_, i) => ({ id: 'message-' + i, role: i % 2 ? 'assistant' : 'user',
      content: 'history '.repeat(256), status: 'complete', error: '' })) }));
  data.activeThreadId = 'chat-0';
  const f = new Fixture(data), app = new ChatViewModel(); await app.initialize(f.session); app.openSettings();
  const ui = panel(app), held = gate(); let snapshots = 0, messageUpdates = 0, contextMs = 0;
  const snapshot = f.session.snapshot.bind(f.session), refresh = f.session.refreshContext.bind(f.session);
  f.session.snapshot = () => { snapshots++; return snapshot(); };
  f.session.refreshContext = () => { const start = performance.now(); refresh(); contextMs += performance.now() - start; };
  const update = MessageViewModel.prototype.update;
  MessageViewModel.prototype.update = function(data) { messageUpdates++; return update.call(this, data); };
  f.repository.beforeSave = () => held.promise;
  const threadViews = app.threads, messages = app.active.messages, captureIds = [];
  const save = f.repository.save.bind(f.repository);
  f.repository.save = (data, ids) => { captureIds.push(ids); return save(data); };
  const start = performance.now(); ui.value.saveToggle('readOnly', true); await settle();
  const editableDuringSave = ui.value.canEdit();
  held.open(); await ui.value.pendingSave;
  console.log(JSON.stringify({ editableDuringSave, snapshots, messageUpdates, contextMs: Math.round(contextMs), saveMs: Math.round(performance.now() - start) }));
  assert.equal(editableDuringSave, true, 'Saving one toggle must leave unrelated settings editable');
  assert.equal(snapshots, 0, 'A preference change must not copy all transcripts');
  assert.equal(messageUpdates, 0, 'A preference change must not reproject historical messages');
  assert.equal(app.productivity.options.readOnly, true);
  assert.equal(app.threads, threadViews); assert.equal(app.active.messages, messages);
  assert.equal(captureIds.length, 1); assert.equal(captureIds[0].length, 0, 'Reuse unchanged transcript files');
  MessageViewModel.prototype.update = update;
  console.log('PASS responsive settings and transcript-independent preference saves');

  const rapid = await setup(), first = gate(); let attempts = 0;
  rapid.f.repository.beforeSave = async () => { if (++attempts === 1) await first.promise; };
  rapid.value.saveToggle('readOnly', true); await settle();
  rapid.value.saveToggle('autoMemory', true);
  rapid.value.saveToggle('readOnly', false);
  rapid.value.saveToggle('saveSummary', true);
  rapid.value.saveToggle('webEnabled', false);
  rapid.value.saveToggle('autoCompact', false);
  assert.equal(rapid.value.assistantDraft.readOnly, false);
  assert.equal(rapid.value.assistantDraft.autoMemory, true); assert.equal(rapid.app.settings.webEnabled, false);
  first.open(); await rapid.value.pendingSave;
  const saved = await rapid.f.repository.load();
  assert.equal(attempts, 6); assert.equal(saved.productivity.options.readOnly, false);
  assert.equal(saved.productivity.options.autoMemory, true); assert.equal(saved.productivity.options.saveSummary, true);
  assert.equal(saved.extensions.webEnabled, false); assert.equal(saved.config.autoCompact, false);
  assert.equal(rapid.app.currentConfig.autoCompact, false); assert.equal(rapid.toasts.length, 0);
  console.log('PASS rapid mixed toggles retain the latest values and preserve other fields');

  const failed = await setup(), lateFailure = gate(); let writes = 0;
  failed.f.repository.beforeSave = async () => { if (++writes === 1) { await lateFailure.promise; throw Error('disk unavailable'); } };
  failed.value.saveToggle('readOnly', true); await settle();
  failed.value.saveToggle('readOnly', false); failed.value.saveToggle('autoMemory', true);
  lateFailure.open(); await failed.value.pendingSave;
  assert.equal(failed.value.assistantDraft.readOnly, false); assert.equal(failed.app.productivity.options.readOnly, false);
  assert.equal(failed.value.assistantDraft.autoMemory, true); assert.equal(failed.app.productivity.options.autoMemory, true);
  assert.equal(failed.toasts.length, 1); assert.match(failed.toasts[0], /disk unavailable/);
  assert.ok(failed.f.resources.errors.some(message => message.includes('disk unavailable')));
  failed.f.repository.beforeSave = async () => { throw Error('still unavailable'); };
  failed.value.saveToggle('autoMemory', false); failed.value.saveToggle('webEnabled', false);
  await failed.value.pendingSave;
  assert.equal(failed.value.assistantDraft.autoMemory, true); assert.equal(failed.app.settings.webEnabled, true);
  failed.f.repository.beforeSave = async () => {};
  failed.value.saveToggle('saveSummary', true); await failed.value.pendingSave;
  assert.equal(failed.app.productivity.options.saveSummary, true, 'A failed save must not poison later saves');
  console.log('PASS failed saves report errors, roll back only their field and leave the queue usable');

  const drafts = await setup(), pendingDisk = gate(); let diskWrites = 0;
  drafts.f.session.setDraft('before save');
  const changed = [], originalSave = drafts.f.repository.save.bind(drafts.f.repository);
  drafts.f.repository.save = (data, ids) => { changed.push(ids); return originalSave(data); };
  drafts.f.repository.beforeSave = async () => { if (++diskWrites === 1) await pendingDisk.promise; };
  drafts.value.saveToggle('readOnly', true); await settle();
  drafts.f.session.setDraft('typed during save'); pendingDisk.open(); await drafts.value.pendingSave;
  assert.ok(changed[0].includes(drafts.app.active.id), 'Capture drafts already dirty before the preference save');
  assert.equal((await drafts.f.repository.load()).threads[0].draft, 'typed during save');
  assert.equal(drafts.app.draft, 'typed during save'); assert.equal(drafts.app.productivity.options.readOnly, true);
  assert.equal(drafts.app.busy, false);
  await drafts.app.saveSettings();
  assert.equal((await drafts.f.repository.load()).productivity.options.readOnly, true, 'USER.md saves retain assistant options');
  console.log('PASS preference saves preserve typing during disk IO and USER.md saves retain toggle choices');

  load(path.join(root, 'entry/src/test/SessionService.test')).default();
  const selected = sessionCases.filter(test => /UserDocument|SettingsCommit/.test(test.name));
  assert.ok(selected.length >= 4);
  for (const test of selected) { await test.run(); console.log('PASS ' + test.name); }
})().catch(error => { console.error(error); process.exitCode = 1; });
