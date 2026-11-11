// Run after a Debug build. Exercise emitted ArkUI methods at native callback boundaries.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio'),
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function methods(relative, names, className = path.basename(relative)) {
  const file = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(root, 'entry/src/main/ets', relative + '.ets')).mtimeMs, 'Rebuild ' + relative);
  const tree = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === className);
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
  const Panel = compile(methods('views/ChatPanel', ['composerChanged', 'composerSelectionChanged', 'speechActive', 'composerEditor', 'updateScrollState',
    'afterRender', 'speechThreadChanged', 'receiveVoiceShortcut', 'syncMessages', 'scrollToLatest']), {
    TextArea: editor, Context: { animation() {} }, Motion: {}, Font: {}, Color: {}, Alignment: {}, Visibility: {},
    ATTACHMENT_DROP_TYPES: [], t: s => s, clearTimeout, ScrollAlign: { END: 'end' }, Diagnostics: { recording: false },
    ChatLayoutFrame: class { constructor(action) { this.action = action; } onIdle() { this.action(); } }
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
  let atEnd = false, bottom = true, follow = false;
  Object.defineProperty(panel, 'atBottom', { get: () => bottom, set(value) { assert.equal(building, false); bottom = value; } });
  Object.defineProperty(panel, 'followOutput', { get: () => follow, set(value) { assert.equal(building, false); follow = value; } });
  panel.scroller = { isAtEnd: () => atEnd };
  building = true; panel.updateScrollState(); assert.equal(bottom, true);
  building = false; await drain(); assert.equal(bottom, false);
  atEnd = true; building = true; panel.updateScrollState(true); assert.equal(follow, false);
  building = false; await drain(); assert.equal(bottom, true); assert.equal(follow, true);
  atEnd = false; panel.updateScrollState(); panel.thread.id = 'different'; await drain(); assert.equal(bottom, true);
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

  const frames = [], jumps = [];
  let sourceReady = false, layoutReady = false;
  Object.assign(panel, { positionedThreadId: '', followOutput: true,
    getUIContext: () => ({ postFrameCallback: frame => frames.push(frame) }),
    messageSource: { update() { assert.equal(building, false); sourceReady = true; } },
    scroller: { scrollToIndex(...args) {
      assert.ok(sourceReady && layoutReady, 'Position only after data reload and native layout'); jumps.push(args);
    } } });
  const render = () => { layoutReady = true; frames.splice(0).forEach(frame => frame.onIdle()); };
  panel.thread.messages = Array.from({ length: 120 }, (_, id) => ({ id }));
  Object.assign(panel.app, { visibleMessages: panel.thread.messages.slice(-60), visibleMessageCount: 60, teams: [], searchMessageId: '' });
  building = true; panel.syncMessages(); panel.syncMessages(); building = false;
  await drain(); assert.equal(jumps.length, 0); assert.equal(frames.length, 1);
  render(); assert.deepEqual(jumps.pop(), [60, false, 'end'], 'Cold start targets the unmounted tail, accounting for the earlier-messages row');
  assert.equal(panel.followOutput, true);
  panel.followOutput = false; panel.app.visibleMessageCount = 120; panel.app.visibleMessages = panel.thread.messages;
  panel.syncMessages(); await drain(); render(); assert.equal(jumps.length, 0, 'Loading history preserves the reading position');
  const open = async id => { panel.thread.id = panel.app.active.id = id; panel.syncMessages(); await drain(); };
  panel.app.teams = [{ ownerMessageId: '' }];
  await open('with-team'); render(); assert.deepEqual(jumps.pop(), [120, false, 'end'], 'Include a trailing team card');
  await open('touched'); panel.followOutput = false; render(); assert.equal(jumps.length, 0, 'Touch cancels pending initial positioning');
  panel.app.searchMessageId = 'match'; await open('search'); render(); assert.equal(jumps.length, 0, 'Search owns its initial position');
  panel.app.searchMessageId = ''; await open('late-search'); panel.app.searchMessageId = 'match';
  render(); assert.equal(jumps.length, 0);
  panel.app.searchMessageId = ''; await open('stale'); panel.thread.id = 'different'; render(); assert.equal(jumps.length, 0);
  await open('disposed'); panel.lifecycle++; render(); assert.equal(jumps.length, 0, 'Disposal cancels pending positioning');
  panel.app.visibleMessages = []; panel.thread.messages = []; panel.app.teams = [];
  await open('empty'); assert.equal(frames.length, 0);
  panel.thread.messages = panel.app.visibleMessages = [{ id: 'first' }];
  panel.syncMessages(); await drain(); assert.equal(frames.length, 0, 'First send remains owned by send motion');
  await open('short'); render(); assert.deepEqual(jumps.pop(), [0, false, 'end']);
  panel.scrollToLatest(); assert.deepEqual(jumps.pop(), [0, true, 'end']); assert.equal(panel.followOutput, false);
  console.log('PASS emitted chat positioning: cold start, lazy tail, history, team card, touch, search, stale callbacks, empty chat and manual jump');

  const ResponsiveIcon = compile(methods('common/Widgets', ['updateStateVars'], 'IconButton'));
  let diameter = 44;
  const icon = Object.assign(new ResponsiveIcon(), { __diameter: { reset(value) { diameter = value; } } });
  for (const key of ['icon', 'tint', 'fill', 'disabled', 'label']) { icon['__' + key] = { reset() {} }; }
  for (const next of [36, 44, 36, 36]) {
    icon.updateStateVars({ diameter: next });
    assert.equal(diameter, next, 'A retained icon button must follow phone/tablet sizing updates');
  }
  console.log('PASS emitted icon button: retained instances accept responsive diameter updates');

  let addButton, updateAddButton;
  const AddButton = compile(methods('views/ChatPanel', ['composerAddButton']), {
    IconButton: class extends ResponsiveIcon {
      constructor(_parent, params) {
        super(); addButton = this; this.diameter = params.diameter;
        this.__diameter = { reset: value => { this.diameter = value; } };
        for (const key of ['icon', 'tint', 'fill', 'disabled', 'label']) { this['__' + key] = { reset() {} }; }
      }
    },
    __Common__: { create() {}, bindPopup() {}, pop() {} }, ViewPU: { create() {} },
    Placement: { TopLeft: 0 }, BlurStyle: { NONE: 0 }, t: value => value
  });
  const composer = Object.assign(new AddButton(), { workbench: false, thread: {}, app: { saveError: '' },
    speechActive: () => false, plusMenu() {},
    observeComponentCreation2(callback, component) {
      if (component.name === 'IconButton') { updateAddButton = () => callback(1, false); }
      callback(1, true);
    },
    updateStateVarsOfChildByElmtId(_id, params) { addButton.updateStateVars(params); }
  });
  composer.composerAddButton(); assert.equal(addButton.diameter, 44);
  for (const workbench of [true, false, true, true]) {
    composer.workbench = workbench; updateAddButton();
    assert.equal(addButton.diameter, workbench ? 36 : 44, 'The emitted composer must forward sizing to its existing button');
  }
  console.log('PASS emitted composer button: layout changes propagate through parent and retained child');

  let settingsParams, settingsUpdate;
  const Settings = compile(methods('pages/Index', ['settingsContent']), {
    SettingsPanel: class { constructor(_parent, params) { settingsParams = params; } }, ViewPU: { create() {} },
    __Common__: { create() {}, layoutWeight() {}, pop() {} }
  });
  const settings = Object.assign(new Settings(), { app: { settings: {} }, settingsSection: 'models', settingsActive: true, foreground: true,
    observeComponentCreation2(callback, component) {
      if (component.name === 'SettingsPanel') { settingsUpdate = () => callback(1, false); }
      callback(1, true);
    },
    updateStateVarsOfChildByElmtId(_id, params) { settingsParams = { ...settingsParams, ...params }; }
  });
  settings.settingsContent();
  assert.equal(settingsParams.section, 'models');
  for (const section of ['account', 'assistant', 'tools', 'appearance', 'data', 'help', 'models']) {
    settings.settingsSection = section; settingsUpdate();
    assert.equal(settingsParams.section, section, 'An existing tablet panel must receive the current category');
  }
  settings.foreground = false; settingsUpdate(); assert.equal(settingsParams.active, false);
  console.log('PASS emitted settings: categories update without rebuilding the panel');

  const nodes = new Map(); let current, requests = 0, exits = 0;
  const widget = new Proxy({}, { get: (_target, key) => (...args) => {
    if (key === 'create' || key === 'createWithLabel') current = { label: args[0] };
    if (key === 'id') nodes.set(args[0], current);
    if (key === 'onClick' || key === 'enabled') current[key] = args[0];
    if (key === 'canRetake') return false;
  } });
  const Gate = compile(methods('pages/Index', ['initialRender']), { Stack: widget, Column: widget, Text: widget, Button: widget, If: widget,
    t: s => s, Space: {}, Radius: {}, FontWeight: {}, TextAlign: {}, FlexAlign: {}, Btn: {}, SheetSize: {}, SheetType: {},
    SafeAreaType: { SYSTEM: 0 }, SafeAreaEdge: { TOP: 0, BOTTOM: 1 }, HitTestMode: { None: 0 } });
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
