// Run after devecocli build: exercise the emitted page/controller methods at the navigation seam.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
let intent, foreground = true;
const launch = { take: () => { const result = intent; intent = undefined; return result; }, isForeground: () => foreground };
function controller(file, name, methods) {
  const source = path.join(root, 'entry/src/main/ets', file + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ' + file);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  const body = methods.map(method => component.members.find(node => node.name?.getText(tree) === method).getText(tree)).join('\n');
  const globals = { exports: {}, LaunchActions: launch, AppMaterials: { surface: {} }, t: text => text, Error };
  vm.runInNewContext(ts.transpileModule(`class Probe { ${body} } exports.Probe = Probe;`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, globals);
  return new globals.exports.Probe();
}
function page() {
  const page = controller('pages/Index', 'Index', ['receiveLaunch']);
  page.events = []; page.voiceRequest = '';
  page.app = { busy: false, saveError: '', error: '', active: { id: 'old', projectId: 'project' },
    flushDraft: async () => page.events.push('saved'),
    newThread: async project => { page.events.push(['new', project]); page.app.active.id = 'new'; return true; }
  };
  page.paths = { clear: () => page.events.push('navigation') };
  page.setDrawer = value => page.events.push(['drawer', value]);
  page.getUIContext = () => ({ getPromptAction: () => ({ showToast: value => page.events.push(['toast', value.message]) }) });
  return page;
}
(async () => {
  let view = page(); intent = 'voice-input'; await view.receiveLaunch();
  assert.deepEqual(view.events.slice(0, 2), ['saved', ['new', '']]);
  assert.equal(view.voiceRequest, 'new'); await view.receiveLaunch(); assert.equal(view.events.length, 4);
  console.log('PASS shortcut preserves old draft, creates a standalone chat and dispatches voice exactly once');

  view = page(); view.app.busy = true; intent = 'new-chat'; await view.receiveLaunch();
  assert.equal(view.events.length, 1); assert.equal(view.events[0][0], 'toast');
  view.app.busy = false; await view.receiveLaunch(); assert.equal(view.events.length, 1);
  view = page(); view.app.flushDraft = async () => { view.app.saveError = 'save failed'; };
  intent = 'voice-input'; await view.receiveLaunch();
  assert.deepEqual(view.events, [['toast', 'save failed']]); assert.equal(view.voiceRequest, '');
  console.log('PASS busy shortcuts do not run later; save failures do not create chats or open the microphone');

  view = page(); view.app.flushDraft = async () => { foreground = false; };
  intent = 'voice-input'; await view.receiveLaunch(); assert.equal(view.events.length, 0); foreground = true;
  console.log('PASS backgrounding during draft save cancels shortcut activation');

  const panel = controller('views/ChatPanel', 'ChatPanel', ['receiveVoiceShortcut', 'speechAvailabilityChanged', 'speechThreadChanged']);
  let starts = 0, stops = 0, consumed = 0;
  panel.reading = { stop: () => stops++ }; panel.endSpeech = () => {};
  panel.startSpeech = () => starts++; panel.onVoiceShortcutConsumed = () => consumed++;
  panel.voiceRequest = 'new'; panel.activeThreadId = 'old'; panel.thread = { id: 'old' }; panel.speechEnabled = false;
  panel.receiveVoiceShortcut(); assert.equal(starts, 0);
  panel.activeThreadId = 'new'; panel.thread.id = 'new'; panel.speechThreadChanged(); assert.equal(starts, 0);
  panel.speechEnabled = true; panel.speechAvailabilityChanged(); assert.equal(starts, 1); assert.equal(consumed, 1);
  panel.receiveVoiceShortcut(); panel.speechAvailabilityChanged(); assert.equal(starts, 1);
  panel.speechEnabled = false; panel.speechAvailabilityChanged(); assert.ok(stops >= 2);
  foreground = false; panel.voiceRequest = 'next'; panel.activeThreadId = 'next'; panel.thread.id = 'next';
  panel.speechEnabled = true; panel.receiveVoiceShortcut(); foreground = true; panel.receiveVoiceShortcut();
  assert.equal(starts, 1);
  console.log('PASS voice waits for the target chat and visible page; consumed or background requests cannot record again');
})().catch(error => { console.error(error); process.exitCode = 1; });
