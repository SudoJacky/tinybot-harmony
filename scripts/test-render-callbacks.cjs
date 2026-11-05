// Run after a Debug build. Exercise emitted ArkUI methods at native callback boundaries.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio'),
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function methods(relative, names) {
  const file = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(root, 'entry/src/main/ets', relative + '.ets')).mtimeMs, 'Rebuild ' + relative);
  const tree = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === path.basename(relative));
  return names.map(name => { const method = cls.members.find(n => n.name?.getText(tree) === name); assert.ok(method, name); return method.getText(tree); }).join('\n');
}
function compile(source, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule('class Probe {' + source + '} exports.Probe = Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, ...globals });
  return exports.Probe;
}
const drain = async () => { await Promise.resolve(); await Promise.resolve(); };
(async () => {
  const editorEvents = [];
  const editor = new Proxy({}, { get: (_target, key) => (...args) => {
    if (key === 'create') editorEvents.push({ text: args[0].text });
    if (key === 'onChange' || key === 'onTextSelectionChange') editorEvents.at(-1)[key] = args[0];
  } });
  const Panel = compile(methods('views/ChatPanel', ['composerChanged', 'composerSelectionChanged', 'speechActive', 'composerEditor', 'updateScrollState', 'publishHeaderProgress',
    'afterRender', 'speechThreadChanged', 'receiveVoiceShortcut', 'syncMessages']), {
    TextArea: editor, Context: { animation() {} }, Motion: {}, Font: {}, Color: {}, Alignment: {}, Visibility: {},
    ATTACHMENT_DROP_TYPES: [], t: s => s
  });
  let building = false, changes = 0, selectionWrites = 0;
  const panel = Object.assign(new Panel(), { composerMounted: true, composerEditRevision: 0, composerSelectionRevision: 0,
    thread: { id: 'a' }, speech: { phase: 'idle' },
    app: { ready: true, active: { id: 'a' }, draft: 'saved', setDraft(value) {
      assert.equal(building, false, 'No model writes inside a render callback'); this.draft = value; changes++;
    } } });
  for (const key of ['composerSelectionStart', 'composerSelectionEnd']) {
    let value = -1;
    Object.defineProperty(panel, key, { get: () => value, set(next) { assert.equal(building, false); selectionWrites++; value = next; } });
  }
  building = true;
  panel.composerChanged('a', 'saved'); panel.composerSelectionChanged('a', 5, 5);
  assert.equal(changes, 0); assert.equal(selectionWrites, 0);
  building = false; await drain(); assert.equal(selectionWrites, 2);
  panel.composerSelectionChanged('a', 5, 5); await drain(); assert.equal(selectionWrites, 2, 'No duplicate state notifications');
  building = true;
  panel.composerChanged('a', 'first'); panel.composerChanged('a', 'last');
  building = false; await drain(); assert.equal(panel.app.draft, 'last'); assert.equal(changes, 1);
  panel.composerChanged('a', 'stale'); panel.thread.id = panel.app.active.id = 'b'; panel.app.draft = 'other chat';
  await drain(); assert.equal(panel.app.draft, 'other chat');
  panel.composerChanged('a', 'late native callback'); await drain(); assert.equal(panel.app.draft, 'other chat');
  panel.composerChanged('b', 'typing'); panel.app.draft = 'programmatic update'; await drain();
  assert.equal(panel.app.draft, 'programmatic update', 'A queued edit cannot undo sending, dictation or a restored draft');
  panel.composerChanged('b', 'cancelled edit'); panel.composerChanged('b', panel.app.draft); await drain();
  assert.equal(panel.app.draft, 'programmatic update');
  panel.composerChanged('b', 'gone'); panel.composerSelectionChanged('b', 1, 1); panel.composerMounted = false;
  await drain(); assert.equal(panel.app.draft, 'programmatic update'); assert.equal(selectionWrites, 2);
  panel.composerMounted = true; panel.speech.phase = 'listening'; panel.composerChanged('b', 'native preview');
  await drain(); assert.equal(panel.app.draft, 'programmatic update');
  Object.assign(panel, { appearance: {}, composerExpanded: () => true,
    observeComponentCreation2: callback => callback(1, true) });
  panel.speech.phase = 'idle'; panel.composerEditor('b'); const oldEditor = editorEvents.at(-1);
  panel.thread.id = panel.app.active.id = 'c'; panel.app.draft = ''; panel.composerEditor('c');
  editorEvents.at(-1).onChange('new chat draft'); oldEditor.onChange('old chat native event');
  await drain(); assert.equal(panel.app.draft, 'new chat draft', 'A stale editor must not even cancel the current editor update');
  let atEnd = false, bottom = true, follow = false, headerUpdates = 0;
  Object.defineProperty(panel, 'atBottom', { get: () => bottom, set(value) { assert.equal(building, false); bottom = value; } });
  Object.defineProperty(panel, 'followOutput', { get: () => follow, set(value) { assert.equal(building, false); follow = value; } });
  panel.scroller = { isAtEnd: () => atEnd }; panel.updateHeaderProgress = () => { assert.equal(building, false); headerUpdates++; };
  building = true; panel.updateScrollState(); assert.equal(bottom, true);
  building = false; await drain(); assert.equal(bottom, false);
  atEnd = true; building = true; panel.updateScrollState(true); assert.equal(follow, false);
  building = false; await drain(); assert.equal(bottom, true); assert.equal(follow, true);
  panel.updateScrollState(); panel.thread.id = 'different'; await drain(); assert.equal(headerUpdates, 2);
  let published = 0; panel.onHeaderProgress = () => { assert.equal(building, false); published++; };
  panel.thread.id = panel.app.active.id = 'c'; building = true; panel.publishHeaderProgress(0);
  assert.equal(published, 0); building = false; await drain(); assert.equal(published, 1);
  panel.publishHeaderProgress(1); panel.composerMounted = false; await drain(); assert.equal(published, 1);
  Object.assign(panel, { composerMounted: true, lifecycle: 0, activeThreadId: 'c', speechThreadId: 'c', voiceRequest: '',
    focusOwner: 0, messageSyncRevision: 0, sendingMessageId: '',
    cancelPlusAction() { assert.equal(building, false); }, cancelAttachmentDrop() { assert.equal(building, false); },
    reading: { stop() { assert.equal(building, false); } },
    messageSource: { update() { assert.equal(building, false); } } });
  panel.thread.id = panel.app.active.id = 'c'; panel.app.visibleMessages = [];
  building = true; panel.speechThreadChanged(); panel.syncMessages();
  assert.equal(panel.composerSelectionStart, 5, 'Prop watches cannot synchronously reset selection during a render');
  building = false; await drain(); assert.equal(panel.composerSelectionStart, -1);
  let late = 0; panel.afterRender(() => late++); panel.lifecycle++; await drain(); assert.equal(late, 0);
  console.log('PASS emitted composer: render-safe edits, no-op notifications, latest input, stale thread, external draft change, disposal and dictation');

  const nodes = new Map(); let current, requests = 0, exits = 0;
  const widget = new Proxy({}, { get: (_target, key) => (...args) => {
    if (key === 'create' || key === 'createWithLabel') current = { label: args[0] };
    if (key === 'id') nodes.set(args[0], current);
    if (key === 'onClick' || key === 'enabled') current[key] = args[0];
    if (key === 'canRetake') return false;
  } });
  const Gate = compile(methods('pages/Index', ['initialRender']), { Stack: widget, Column: widget, Text: widget, Button: widget, If: widget,
    t: s => s, Space: {}, Radius: {}, FontWeight: {}, TextAlign: {}, FlexAlign: {}, Btn: {}, SheetSize: {}, SheetType: {} });
  const gate = Object.assign(new Gate(), { privacyAllowed: false, appearance: {}, app: { active: {} },
    privacy: { simulatorDebug: false, error: '', busy: false, requestConsent() { requests++; }, exit() { exits++; } },
    observeComponentCreation2: callback => callback(1, true), ifElseBranchUpdateFunction: (_id, callback) => callback() });
  gate.initialRender();
  assert.equal(nodes.get('retry-privacy').label, '继续授权'); assert.equal(nodes.get('retry-privacy').enabled, true);
  assert.match(nodes.get('privacy-status').label, /系统弹窗/);
  nodes.get('retry-privacy').onClick(); assert.equal(requests, 1);
  nodes.get('exit-privacy').onClick(); assert.equal(exits, 1);
  gate.privacy.error = '无法确认系统隐私授权（1006700003），请重试。'; gate.privacy.busy = true; gate.initialRender();
  assert.equal(nodes.get('retry-privacy').label, '重试'); assert.equal(nodes.get('retry-privacy').enabled, false);
  assert.match(nodes.get('privacy-status').label, /1006700003/);
  console.log('PASS emitted startup gate: an empty signing record has a system-consent action; failures stay visible and in-flight requests disable the button');
})().catch(error => { console.error(error); process.exitCode = 1; });
