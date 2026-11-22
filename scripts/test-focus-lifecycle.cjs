// Build first. Drive emitted callbacks with independent native-render, timer and navigation clocks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function fixture(name, names, state) {
  const file = `entry/src/main/ets/views/${name}`;
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug', file + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(path.join(root, file + '.ets')).mtimeMs, 'Rebuild ' + name);
  const tree = ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  const helpers = tree.statements.filter(n => ts.isClassDeclaration(n) && n.heritageClauses?.some(h => h.getText(tree).includes('FrameCallback')));
  const frames = [], timers = [], focus = [], logs = [], exports = {};
  let ready = false;
  vm.runInNewContext(ts.transpileModule(helpers.map(n => n.getText(tree)).join('\n') +
    `class Probe { ${cls.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} } exports.Probe = Probe;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, {
    exports, FrameCallback: class {}, Edge: { Top: 0, Bottom: 1 }, t: text => text,
    Diagnostics: { acceptsLog: () => true, log: (...args) => logs.push(args) },
    setTimeout: action => timers.push(action), clearTimeout() {},
    skillDraft: () => ({ text: '/skill:test ', caret: 12 })
  });
  const panel = Object.assign(new exports.Probe(), state, {
    getUIContext: () => ({ postFrameCallback: frame => frames.push(frame),
      getPromptAction: () => ({ showToast() {} }), getFocusController: () => ({
        clearFocus() {}, requestFocus(id) { assert.ok(ready, '150003: focus requested before native render'); focus.push(id); }
      }) })
  });
  return { panel, frames, focus, logs, nativeReady() { ready = true; },
    timers() { timers.splice(0).forEach(fn => fn()); },
    render() { ready = true; frames.splice(0).forEach(frame => frame.onIdle()); } };
}
const checks = [];
function check(name, action) { checks.push({ name, action }); }
const searchMethods = ['searchRequested', 'searchAvailabilityChanged', 'searchVisibilityChanged', 'aboutToAppear', 'aboutToDisappear', 'closeCloudPicker', 'locked'];
function search() { return fixture('ThreadList', searchMethods, { mounted: true, foreground: true, active: true,
  searchOpen: false, focusRequest: 0, searchRequest: 0, app: { canNavigate: true } }); }
check('search waits for render instead of a timer and does not swallow failures', () => {
  const f = search(); f.panel.searchRequested(); f.timers(); assert.deepEqual(f.focus, []);
  f.render(); assert.deepEqual(f.focus, ['search-threads']);
  const bad = search(); bad.panel.searchRequested();
  bad.panel.getUIContext = () => ({ getFocusController: () => ({ requestFocus() { throw Error('native failure'); } }) });
  assert.throws(() => bad.render(), /native failure/);
});
check('search cancels locked, hidden, destroyed and close/reopen callbacks', () => {
  for (const change of [p => { p.app.canNavigate = false; }, p => { p.active = false; },
    p => p.aboutToDisappear(), p => { p.searchOpen = false; p.searchVisibilityChanged(); p.searchOpen = true; },
    p => { p.active = false; p.searchAvailabilityChanged(); p.active = true; }]) {
    const f = search(); f.nativeReady(); f.panel.searchRequested(); change(f.panel); f.timers(); f.render(); assert.deepEqual(f.focus, []);
  }
});
const providerMethods = ['save', 'locked', 'focusField', 'focusAvailabilityChanged', 'advancedChanged', 'aboutToDisappear'];
function provider(field = 'context') { return fixture('ProviderEditorPanel', providerMethods, {
  alive: true, active: true, foreground: true, page: 'service', advanced: false, focusRequest: 0,
  app: { sharedBusy: false }, discovering: false, appearance: {}, scroller: { scrollEdge() {} },
  editor: { modelInput: '', noApiKey: false, canKeepKey: false, fieldError: name => name === field ? 'invalid' : '' }
}); }
check('provider validation waits for the expanded field render', async () => {
  const f = provider(); await f.panel.save(); f.timers(); assert.deepEqual(f.focus, []);
  f.render(); assert.deepEqual(f.focus, ['context-window']);
});
check('provider cancels collapsed, locked, covered and disposed targets', async () => {
  for (const change of [p => { p.advanced = false; }, p => { p.app.sharedBusy = true; }, p => { p.active = false; },
    p => p.aboutToDisappear(), p => { p.active = false; p.focusAvailabilityChanged(); p.active = true; }]) {
    const f = provider(); f.nativeReady(); await f.panel.save(); change(f.panel); f.timers(); f.render(); assert.deepEqual(f.focus, []);
  }
  const key = provider('key'); key.nativeReady(); await key.panel.save(); key.panel.editor.noApiKey = true;
  key.timers(); key.render(); assert.deepEqual(key.focus, []);
});
function onboarding(field = 'key') { return fixture('OnboardingProviderForm', ['focusInvalidField', 'invalidateFocus', 'aboutToDisappear'], {
  invalidField: field, focusRevision: 0, locked: false, custom: true, advanced: false, manualModel: false,
  editor: { noApiKey: false }
}); }
check('onboarding opens and renders invalid fields before requesting focus', () => {
  for (const field of ['name', 'url', 'key', 'model-id']) {
    const f = onboarding(field); f.panel.focusInvalidField();
    assert.equal(f.panel.advanced, field === 'name' || field === 'url');
    assert.equal(f.panel.manualModel, field === 'model-id');
    assert.deepEqual(f.focus, []);
    f.render(); assert.deepEqual(f.focus, ['onboarding-provider-' + field]);
  }
  for (const change of [p => { p.locked = true; }, p => p.aboutToDisappear(), p => { p.editor.noApiKey = true; },
    p => { p.invalidField = ''; p.focusInvalidField(); }, p => p.invalidateFocus()]) {
    const stale = onboarding(); stale.panel.focusInvalidField(); change(stale.panel); stale.render(); assert.deepEqual(stale.focus, []);
  }
  const absent = onboarding('context'); absent.panel.focusInvalidField(); absent.render(); assert.deepEqual(absent.focus, []);
});
function chat() { return fixture('ChatPanel', ['fork', 'showSpeechKeyboard', 'speechActive', 'selectSkill', 'dismissPlusMenu',
  'queueComposerFocus', 'composerActionCurrent', 'speechAvailabilityChanged', 'focusForegroundChanged', 'afterRender'], {
  focusOwner: 0, foreground: true, speechEnabled: true, keyboardFocusRequest: 0, composerMounted: true, lifecycle: 0,
  thread: { id: 'source', messages: [{ id: 'user', role: 'user' }], archived: false },
  app: { active: { id: 'source' }, draft: '', forkThread: async () => true, useSkill() { this.draft = '/skill:test '; return true; } },
  appearance: {}, speech: { phase: 'idle' }, voiceMode: false, composerController: { caretPosition() {} },
  currentSkillQuery: () => ({}), skillSuggested: () => true, cancelPlusAction() {},
  endSpeech() { this.keyboardFocusRequest++; }, reading: { stop() {} }, receiveVoiceShortcut() {}
}); }
check('fork waits for render and rejects completion after leaving the chat', async () => {
  const normal = chat();
  normal.panel.app.forkThread = async () => { normal.panel.app.active = { id: 'branch' }; return true; };
  await normal.panel.fork('user'); assert.deepEqual(normal.focus, []);
  normal.panel.thread = { id: 'branch', archived: false }; normal.panel.endSpeech(); normal.render(); normal.render();
  assert.deepEqual(normal.focus, ['composer']);
  const f = chat(); let release;
  f.panel.app.forkThread = () => new Promise(resolve => { release = resolve; });
  const work = f.panel.fork('user'); f.panel.speechEnabled = false; f.panel.speechAvailabilityChanged();
  f.panel.speechEnabled = true; f.nativeReady(); release(true); await work; f.render(); assert.deepEqual(f.focus, []);
});
check('composer and Skill focus reject covered/background/overlay targets', () => {
  for (const method of ['showSpeechKeyboard', 'selectSkill']) {
    for (const change of [p => { p.speechEnabled = false; }, p => { p.foreground = false; },
      ...['showPlus', 'showPlusMenu', 'showDrawing', 'previewing', 'showContext', 'showQueue', 'showSummary',
        'showMemoryDraft', 'showModelMenu', 'showToolApprovalMode'].map(key => p => { p[key] = true; })]) {
      const f = chat(); f.panel[method]('test'); change(f.panel); f.render(); assert.deepEqual(f.focus, []);
    }
  }
});
check('tablet menu action cannot run after a thread switch or navigation', () => {
  for (const change of [p => { p.thread.id = 'other'; }, p => { p.speechEnabled = false; p.speechAvailabilityChanged(); }]) {
    const f = chat(); let calls = 0; f.panel.dismissPlusMenu(() => calls++); change(f.panel); f.timers(); assert.equal(calls, 0);
  }
});
check('native route visibility is wired to the retained service editor', () => {
  const relative = 'entry/src/main/ets/pages/Index';
  const source = path.join(root, relative + '.ets');
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug', relative + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild Index');
  const tree = ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
  const callbacks = {};
  function visit(node) {
    if (ts.isCallExpression(node) && ['NavDestination.onWillShow', 'NavDestination.onWillHide'].includes(node.expression.getText(tree)) &&
      node.arguments[0].getText(tree).includes('providerEditorActive')) callbacks[node.expression.name.text] = node.arguments[0].getText(tree);
    ts.forEachChild(node, visit);
  }
  visit(tree);
  const state = { providerEditorActive: false };
  for (const [event, expected] of [['onWillShow', true], ['onWillHide', false], ['onWillShow', true]]) {
    assert.ok(callbacks[event], 'Missing native navigation event ' + event);
    vm.runInNewContext(`(function() { (${callbacks[event]})(); }).call(state)`, { state }); assert.equal(state.providerEditorActive, expected);
  }
  const code = fs.readFileSync(built, 'utf8');
  assert.match(code, /active: this\.providerEditorActive/);
  // Sidebar visibility across destinations is covered behaviorally by
  // test-history-drawer: the persistent tablet list stays active on Settings.
});
(async () => { for (const item of checks) { try { await item.action(); console.log('PASS ' + item.name); }
  catch (error) { console.error('FAIL ' + item.name + ': ' + error.message); process.exitCode = 1; } } })();
