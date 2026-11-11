// Build first. Replay the real reference-button handler while native dismissal is still pending.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.join(root, 'entry/src/main/ets/views/ChatPanel.ets');
const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ChatPanel');
const tree = ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ChatPanel');
const names = ['fromSheet', 'dismissPlusMenu', 'finishPlusAction', 'cancelPlusAction', 'canAttach', 'endSpeech',
  'addThreadReference', 'expandDraft', 'showSpeechKeyboard', 'speechActive', 'aboutToDisappear', 'speechAvailabilityChanged', 'speechThreadChanged', 'afterRender'];
const methods = cls.members.filter(n => names.includes(n.name?.getText(tree)));
function find(node, predicate) {
  if (predicate(node)) return node;
  return ts.forEachChild(node, child => find(child, predicate));
}
function buttonClick(id) {
  const block = find(cls, n => ts.isBlock(n) && n.statements.some(s => ts.isExpressionStatement(s) &&
    ts.isCallExpression(s.expression) && s.expression.expression.getText(tree) === 'Button.id' &&
    s.expression.arguments[0]?.text === id));
  assert.ok(block, 'Missing emitted button ' + id);
  return find(block, n => ts.isCallExpression(n) && n.expression.getText(tree) === 'Button.onClick').arguments[0];
}
const click = buttonClick('add-thread-reference'), expandClick = buttonClick('phone-expand-draft');
const menuClick = find(cls, n => ts.isCallExpression(n) && n.expression.getText(tree) === 'this.plusMenuRow.bind(this)' &&
  n.arguments[2]?.getText(tree) === "'plus-menu-reference'").arguments.at(-1);
assert.ok(menuClick && ts.isArrowFunction(menuClick), 'Locate the emitted reference menu action');
const sheet = find(cls, n => ts.isCallExpression(n) && n.expression.getText(tree).endsWith('.bindSheet') &&
  n.arguments[0]?.getText(tree).includes('this.showPlus')).arguments[2];
function fixture() {
  const timers = [], frames = [], focus = [], logs = [], exports = {};
  let dismissed = false;
  const helpers = tree.statements.filter(n => ts.isClassDeclaration(n) && n.name.text === 'ChatLayoutFrame');
  vm.runInNewContext(ts.transpileModule(helpers.map(n => n.getText(tree)).join('\n') +
    `class Panel { ${methods.map(n => n.getText(tree)).join('\n')} }
     exports.Panel = Panel; exports.click = function() { return (${click.getText(tree)})(); };
     exports.menuClick = function() { return (${menuClick.getText(tree)})(); };
     exports.expandClick = function() { return (${expandClick.getText(tree)})(); };
     exports.options = function() { return (${sheet.getText(tree)}); };`,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText,
    { exports, FrameCallback: class {}, setTimeout: fn => timers.push(fn), clearTimeout() {},
      Diagnostics: { acceptsLog: () => true, log: (...args) => logs.push(args) },
      Radius: { sheet: {} }, SheetSize: {}, Placement: {}, BlurStyle: {}, referenceQuery: text => text.includes('@') ? '' : undefined });
  const panel = Object.assign(new exports.Panel(), { speechEnabled: true, foreground: true, focusOwner: 0, keyboardFocusRequest: 0,
    composerMounted: true, lifecycle: 0, composerSelectionStart: -1, composerSelectionEnd: -1,
    thread: { id: 'chat', archived: false }, activeThreadId: 'chat', speechThreadId: 'chat', speech: { phase: 'idle', cancel() {} },
    app: { active: { id: 'chat' }, draft: '', busy: false, saveError: '', setDraft(text) { this.draft = text; } },
    showPlus: true, showPlusMenu: false, voiceMode: false, importing: false, writingExpanded: false,
    composerController: { caretPosition() {} },
    cancelAttachmentDrop() {}, setScrollActivity() {}, viewport: { dispose() {} },
    reading: { stop() {} }, receiveVoiceShortcut() {},
    getUIContext: () => ({ postFrameCallback: frame => frames.push(frame), getFocusController: () => ({
      clearFocus() {},
      requestFocus(id) {
        assert.ok(dismissed, '150003: composer unavailable while the native overlay is dismissing');
        assert.ok(!panel.voiceMode && !panel.speechActive() && !panel.thread.archived, '150003: composer hidden or disabled');
        focus.push(id);
      }
    }) }) });
  const options = exports.options.call(panel);
  return { panel, focus, logs, frames, click: () => exports.click.call(panel), menuClick: () => exports.menuClick.call(panel), expandClick: () => exports.expandClick.call(panel),
    advanceTime() { timers.splice(0).forEach(fn => fn()); },
    dismiss() { dismissed = true; options.onDisappear?.(); },
    render() { frames.splice(0).forEach(frame => frame.onIdle()); } };
}
{
  const expanded = fixture(); expanded.panel.app.draft = 'An unsent long message';
  expanded.expandClick(); expanded.advanceTime();
  assert.equal(expanded.panel.writingExpanded, false, 'Do not open a cover over a dismissing sheet');
  expanded.dismiss();
  assert.equal(expanded.panel.writingExpanded, true);
  assert.equal(expanded.panel.app.draft, 'An unsent long message', 'Expanding retains the same conversation draft');
  const staleExpanded = fixture(); staleExpanded.expandClick(); staleExpanded.panel.app.active.id = 'other'; staleExpanded.dismiss();
  assert.equal(staleExpanded.panel.writingExpanded, false, 'Never open an editor for a conversation left during dismissal');
  console.log('PASS phone expanded editor waits for native sheet dismissal and retains its draft owner');
  const f = fixture(); f.click(); f.advanceTime();
  assert.deepEqual(f.focus, [], 'Elapsed time does not imply native dismissal');
  assert.equal(f.panel.app.draft, '', 'Do not mutate a draft before dismissal');
  f.dismiss(); assert.deepEqual(f.focus, [], 'Wait for the editor render after dismissal');
  f.render(); assert.deepEqual(f.focus, ['composer']); assert.equal(f.panel.app.draft, '@');
  f.dismiss(); f.render(); assert.equal(f.focus.length, 1, 'Consume the action once');
  for (const cancel of [p => p.aboutToDisappear(), p => { p.speechEnabled = false; p.speechAvailabilityChanged(); },
    p => { p.thread = { id: 'other' }; p.app.active = p.thread; p.activeThreadId = 'other'; p.speechThreadChanged(); }]) {
    const stale = fixture(); stale.click(); cancel(stale.panel); stale.dismiss(); stale.advanceTime(); stale.render();
    assert.equal(stale.panel.app.draft, ''); assert.deepEqual(stale.focus, []);
  }
  const voice = fixture(); voice.panel.voiceMode = true; voice.click(); voice.dismiss(); voice.render();
  assert.equal(voice.panel.voiceMode, false); assert.deepEqual(voice.focus, ['composer']);
  const disposedFrame = fixture(); disposedFrame.click(); disposedFrame.dismiss(); disposedFrame.panel.aboutToDisappear(); disposedFrame.render();
  assert.deepEqual(disposedFrame.focus, [], 'Disposal also invalidates already-posted focus work');
  for (const invalidate of [p => { p.thread.archived = true; }, p => { p.app.busy = true; },
    p => { p.app.saveError = 'disk full'; }, p => { p.showPlus = true; }]) {
    const stale = fixture(); stale.click(); invalidate(stale.panel); stale.dismiss(); stale.render();
    assert.equal(stale.panel.app.draft, ''); assert.deepEqual(stale.focus, []);
  }
  const passive = fixture(); passive.dismiss(); passive.render(); assert.deepEqual(passive.focus, []);
  const picker = fixture(); let calls = 0;
  picker.panel.fromSheet(() => calls++); picker.advanceTime(); assert.equal(calls, 0);
  picker.dismiss(); picker.dismiss(); assert.equal(calls, 1, 'System picker actions use the same dismissal boundary');
  const broken = fixture(), failure = new Error('action failed');
  broken.panel.fromSheet(() => { throw failure; }); assert.throws(() => broken.dismiss(), error => error === failure);
  broken.dismiss();
  assert.ok(f.logs.some(log => log[2] === 'sheet_action_queued'));
  assert.ok(f.logs.some(log => log[2] === 'sheet_action_dispatched'));
  console.log('PASS sheet: actual reference handler waits for dismissal/render and cancels stale actions');
  const menu = fixture(); menu.panel.showPlus = false; menu.panel.voiceMode = true; menu.panel.showPlusMenu = true;
  menu.menuClick(); menu.dismiss(); menu.advanceTime();
  assert.deepEqual(menu.focus, []); menu.render();
  assert.equal(menu.panel.voiceMode, false); assert.equal(menu.panel.app.draft, '@'); assert.deepEqual(menu.focus, ['composer']);
  console.log('PASS tablet reference action restores the hidden voice-mode editor before requesting focus');
}
