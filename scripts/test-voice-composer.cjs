// Run after devecocli build. Exercise the emitted composer at the recognition callback seam.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const scope = { Diagnostics: require('./load-diagnostics.cjs').Diagnostics, exports: {}, t: text => text, hilog: { info() {}, error() {} }, Error,
  systemInsets: () => Promise.resolve([0, 0]) };
for (const file of ['model/DictationDraft', 'model/VoiceGesture']) {
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets', file + '.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS,
    target: ts.ScriptTarget.ES2021 } }).outputText, { ...scope, require: () => ({ t: scope.t }) });
}
scope.DictationDraft = scope.exports.DictationDraft;
scope.voiceActionAtPoint = scope.exports.voiceActionAtPoint;
scope.FrameCallback = class { onFrame() {} onIdle() {} };
const frameFile = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/common/SendBubbleMotion.ts');
const frameTree = ts.createSourceFile(frameFile, fs.readFileSync(frameFile, 'utf8'), ts.ScriptTarget.Latest, true);
const sendFrame = frameTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'SendFrame');
vm.runInNewContext(ts.transpileModule(`${sendFrame.getText(frameTree)}; exports.SendFrame = SendFrame;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, scope);
scope.SendFrame = scope.exports.SendFrame;
const source = path.join(root, 'entry/src/main/ets/views/ChatPanel.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ChatPanel');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ChatPanel');
for (const helper of tree.statements.filter(n => ts.isClassDeclaration(n) && n.name.text !== 'ChatPanel')) {
  vm.runInNewContext(ts.transpileModule(`${helper.getText(tree)}; exports.${helper.name.text} = ${helper.name.text};`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText, scope);
  scope[helper.name.text] = scope.exports[helper.name.text];
}
const names = ['aboutToAppear', 'speechActive', 'voiceOverlayVisible', 'canRecordSpeech', 'enterVoiceMode',
  'showSpeechKeyboard', 'startSpeech', 'moveSpeech', 'cancelSpeechHold', 'releaseSpeech', 'applySpeechDraft', 'completeSpeech', 'endSpeech'];
const methods = names.map(name => component.members.find(n => n.name?.getText(tree) === name).getText(tree)).join('\n');
vm.runInNewContext(ts.transpileModule(`class Panel { ${methods} } exports.Panel = Panel;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, scope);
function panel() {
  const events = [], frames = [];
  let nativeReady = true;
  const value = new scope.exports.Panel();
  Object.assign(value, { speechEnabled: true, importing: false, speechHolding: false, voiceMode: false, speechTarget: 'send',
    keyboardFocusRequest: 0,
    thread: { id: 'chat', archived: false }, appearance: {}, viewport: { observe() {} },
    reading: { stop() {} }, syncMessages() {}, receiveVoiceShortcut() {}, follow() {},
    app: { active: { id: 'chat' }, draft: '原草稿', ready: true, busy: false, canQueueInput: false,
      setDraft(text) { this.draft = text; }, flushDraft() { events.push('saved'); },
      enqueueInput(kind) { events.push(['queue', kind, this.draft]); this.draft = ''; } },
    speech: { phase: 'idle', text: '', permissionSettingsPending: false,
      start() { this.text = ''; this.phase = 'preparing'; },
      finish() { events.push('finish'); this.phase = 'finishing'; },
      cancel() { this.phase = 'idle'; this.text = ''; this.error = ''; } },
    composerController: { caretPosition(position) { events.push(['caret', position]); } },
    canSend() { return !this.app.busy && !this.app.generating; },
    send() { events.push(['send', this.app.draft]); this.app.draft = ''; } });
  value.getUIContext = () => ({ getHostContext: () => ({}), postFrameCallback: frame => frames.push(frame),
    getFocusController: () => ({ clearFocus() {}, requestFocus: id => {
      assert.ok(nativeReady, '150003: composer is still hidden or disabled before the render flush');
      events.push(['focus', id]);
    } }),
    getPromptAction: () => ({ showToast: options => events.push(['toast', options.message]) }) });
  value.aboutToAppear();
  const result = text => { value.speech.text = text; value.speech.onResult(text); };
  const complete = () => { value.speech.phase = 'complete'; value.speech.onComplete(); };
  const hold = () => { assert.equal(value.startSpeech(), true); value.speech.phase = 'listening'; };
  const render = () => { nativeReady = !value.voiceMode && !value.speechActive() && !value.thread.archived; };
  const renderFrame = () => {
    const posted = frames.splice(0);
    // ArkUI calls onFrame before applying dirty component properties and onIdle after rendering.
    posted.forEach(frame => frame.onFrame()); render(); posted.forEach(frame => frame.onIdle());
  };
  return { value, events, frames, result, complete, hold, render, renderFrame };
}
let p = panel(); p.value.enterVoiceMode();
assert.equal(p.value.voiceMode, true); assert.equal(p.value.speech.phase, 'idle', 'Switching mode never opens microphone');
p.render(); p.value.showSpeechKeyboard(); p.renderFrame();
assert.deepEqual(p.events.slice(-2), [['focus', 'composer'], ['caret', p.value.app.draft.length]]);
console.log('PASS keyboard switch requests focus after native visibility and focusability are applied');
p = panel(); p.value.enterVoiceMode(); p.render(); p.value.showSpeechKeyboard();
p.value.enterVoiceMode(); p.value.showSpeechKeyboard(); p.renderFrame();
assert.equal(p.events.filter(e => e[0] === 'focus').length, 1, 'Rapid switching cancels outdated focus requests');
for (const change of [view => view.enterVoiceMode(), view => { view.speechEnabled = false; },
  view => { view.thread.id = 'other'; }, view => { view.thread.archived = true; }, view => view.endSpeech()]) {
  p = panel(); p.value.enterVoiceMode(); p.render(); p.value.showSpeechKeyboard(); change(p.value); p.renderFrame();
  assert.deepEqual(p.events, [], 'A stale request must not focus a hidden, disabled or departed editor');
}
console.log('PASS queued keyboard focus is cancelled on mode change, navigation, thread change, archiving and teardown');
p = panel();
p.hold(); p.result('初步文字'); assert.equal(p.value.app.draft, '原草稿', 'Partials stay outside composer');
p.value.releaseSpeech(); assert.deepEqual(p.events, ['finish'], 'Release waits for final recognition');
p.result('完整的最后一句。'); p.complete(); p.complete();
assert.deepEqual(p.events, ['finish', ['send', '原草稿\n完整的最后一句。']], 'Send final text once');
assert.equal(p.value.voiceOverlayVisible(), false);

p = panel(); p.hold(); p.result('取消的内容');
p.value.cancelVoiceRect = { x: 10, y: 500, width: 80, height: 60 };
p.value.editVoiceRect = { x: 250, y: 500, width: 80, height: 60 };
p.value.moveSpeech(40, 520); assert.equal(p.value.speechTarget, 'cancel');
p.value.moveSpeech(160, 700); assert.equal(p.value.speechTarget, 'send', 'Sliding back restores send');
p.value.moveSpeech(40, 520); p.value.releaseSpeech(); p.complete();
assert.equal(p.value.app.draft, '原草稿'); assert.deepEqual(p.events, []);

p = panel(); p.hold(); p.result('待编辑'); p.value.releaseSpeech('edit'); p.result('待编辑的最终文字'); p.complete();
assert.equal(p.value.app.draft, '原草稿\n待编辑的最终文字'); assert.equal(p.value.voiceMode, false);
assert.equal(p.events.some(e => Array.isArray(e) && e[0] === 'send'), false);
p.renderFrame(); assert.deepEqual(p.events.slice(-2), [['focus', 'composer'], ['caret', p.value.app.draft.length]]);

p = panel(); p.value.startSpeech(); p.value.releaseSpeech();
assert.equal(p.value.speech.phase, 'idle'); assert.deepEqual(p.events, [], 'Release during preparation cancels');
p.value.startSpeech(); p.value.releaseSpeech('edit'); assert.equal(p.value.voiceMode, false);
p = panel(); p.hold(); p.result('已完成'); p.complete(); assert.deepEqual(p.events, [], 'Natural completion waits for release');
p.value.releaseSpeech(); assert.deepEqual(p.events, [['send', '原草稿\n已完成']]);
p = panel(); p.hold(); p.value.releaseSpeech(); p.complete();
assert.equal(p.value.app.draft, '原草稿'); assert.equal(p.events.at(-1)[0], 'toast');
p = panel(); p.hold(); p.value.releaseSpeech('edit'); p.complete();
assert.equal(p.value.voiceMode, false); assert.equal(p.value.app.draft, '原草稿');

p = panel(); p.hold(); p.result('后台内容'); p.value.speech.onBackground(); p.complete();
assert.equal(p.value.app.draft, '原草稿'); assert.deepEqual(p.events, []);
p = panel(); p.hold(); p.result('其他会话'); p.value.app.active.id = 'other'; p.value.releaseSpeech(); p.complete();
assert.equal(p.value.app.draft, '原草稿'); assert.equal(p.events.some(e => Array.isArray(e) && e[0] === 'send'), false);
p = panel(); p.hold(); p.result('冲突内容'); p.value.app.draft = '外部改动'; p.value.releaseSpeech(); p.complete();
assert.equal(p.value.app.draft, '外部改动'); assert.equal(p.value.unwrittenSpeech, '冲突内容');
assert.equal(p.value.speech.phase, 'error');
p = panel(); p.hold(); p.result('可恢复内容'); p.value.speech.phase = 'error'; p.value.speech.onError();
assert.equal(p.value.app.draft, '原草稿\n可恢复内容'); assert.deepEqual(p.events, ['saved']);
p.value.speech.error = 'native failure'; p.value.cancelSpeechHold();
assert.equal(p.value.speech.error, 'native failure', 'Unmounting the hold button after an error preserves its message');
p = panel(); p.hold(); p.result('系统取消'); p.value.cancelSpeechHold();
assert.equal(p.value.speech.phase, 'idle'); assert.equal(p.value.app.draft, '原草稿');
p = panel(); p.hold(); p.value.app.generating = true; p.value.app.canQueueInput = true;
p.result('下一条'); p.value.releaseSpeech(); p.complete();
assert.deepEqual(p.events, ['finish', ['queue', 'followUp', '原草稿\n下一条']]);
console.log('PASS voice composer: final result, cancel, slide back, edit and keyboard, preparation, empty speech, background, thread switch, draft conflict, error recovery, queued input');
