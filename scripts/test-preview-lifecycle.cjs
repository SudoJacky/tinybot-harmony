// Build first: exercise the emitted ArkUI lifecycle methods, with deterministic visibility and timers.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const srcRoot = path.join(root, 'entry/src/main/ets'), cache = new Map();
function load(name) {
  const file = path.resolve(name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: c => c, require: id => load(path.resolve(path.dirname(file), id)) });
  return exports;
}
const from = name => load(path.join(srcRoot, name));
function native(file, name, methods, context) {
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views', file + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(path.join(srcRoot, 'views', file + '.ets')).mtimeMs, 'Build before testing ' + file);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  assert.ok(component, 'Missing emitted component ' + name);
  const selected = component.members.filter(n => methods.includes(n.name?.getText(tree)));
  assert.equal(selected.length, methods.length);
  context.exports = {};
  vm.runInNewContext(ts.transpileModule('class Probe {' + selected.map(n => n.getText(tree)).join('\n') + '} exports.Probe = Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, context);
  return context.exports.Probe;
}
const { uiParts, UiCompiler, copyUiValues, validateUiState } = from('model/InteractiveUi');
const { stepDisplayContent, latestPreviewIds, stepPreviews } = from('model/PublishedPreview');
const { ThreadViewModel } = from('viewmodel/SessionViewModels');
const { MessageListSource } = from('viewmodel/MessageListSource');
const { UiPresentation } = from('model/UiPresentation');
const surface = title => '```tinybot-ui\n' + [
  { op: 'begin', version: 1, title, state: { count: 1 } },
  { op: 'node', node: { id: 'count', kind: 'stepper', text: 'Count', bind: 'count', min: 0, max: 100 } }, { op: 'end' }
].map(x => JSON.stringify(x)).join('\n') + '\n```';
const publication = (id, file, content, status = 'complete') => ({ call: { id, type: 'function', function: {
  name: 'publish_preview', arguments: JSON.stringify({ path: file })
} }, status, output: JSON.stringify({ published: true, path: file, title: file }), previewContent: content });
const messages = [
  { id: 'a', steps: [{ content: surface('Inline'), tools: [publication('v1', 'art.svg', surface('One') + '\n\n' + surface('Two')), publication('other', 'other.svg', surface('Other'))] }] },
  { id: 'b', steps: [{ content: '', tools: [publication('v2', 'art.svg', surface('New'))] }] },
  { id: 'c', steps: [{ content: '', tools: [publication('v3', 'art.svg', surface('Failed'), 'failed')] }] }
];
const latest = latestPreviewIds(messages);
assert.deepEqual(Array.from(latest), ['b:v2', 'a:other']);
const previews = stepPreviews('a', messages[0].steps[0], 0, latest);
assert.equal(previews[0].superseded, true); assert.equal(previews[1].superseded, false);
assert.deepEqual(Array.from(previews, p => p.surfaceOffset), [1, 3]);
const originalParts = uiParts(stepDisplayContent(messages[0].steps[0]), false).filter(p => p.kind === 'ui');
for (const preview of previews) {
  const parts = uiParts(preview.content, false).filter(p => p.kind === 'ui');
  for (const part of parts) assert.equal(originalParts[Number(part.key) + preview.surfaceOffset].content, part.content);
}
const revisions = Array.from({ length: 40 }, (_, i) => ({ id: 'r' + i, steps: [{ content: '', tools: [publication('call' + i, 'art.svg', surface('Revision'))] }] }));
assert.equal(latestPreviewIds(revisions).length, 1);
assert.equal(revisions.flatMap(m => stepPreviews(m.id, m.steps[0], 0, latestPreviewIds(revisions))).filter(p => !p.superseded).length, 1);
assert.equal(stepPreviews('c', messages[2].steps[0], 0, latest).length, 0);
console.log('PASS repeated and failed publications, distinct artifacts, immutable history and original multi-surface state keys');

const data = { id: 'thread', title: 'Test', updatedAt: 0, messages: messages.map(m => ({ ...m, role: 'assistant', content: '', status: 'complete', error: '' })) };
const thread = new ThreadViewModel(data), source = new MessageListSource();
let reloads = 0; const listener = { onDataReloaded() { reloads++; } };
source.registerDataChangeListener(listener); source.update(thread.id, thread.messages);
source.update(thread.id, thread.messages.slice()); assert.equal(reloads, 1, 'Streaming must not reload identical lazy rows');
const retained = source.getData(0); retained.disclosures.get('preview').open = true;
retained.uiPresentation.webHeights.set('0:1/web', 640);
thread.update(data); source.update(thread.id, thread.messages);
assert.equal(reloads, 1); assert.equal(source.getData(0), retained); assert.equal(retained.uiPresentation.webHeights.get('0:1/web'), 640);
assert.equal(retained.disclosures.get('preview').open, true);
source.update('other-thread', thread.messages); assert.equal(reloads, 2);
source.unregisterDataChangeListener(listener); source.update('third-thread', []); assert.equal(reloads, 2);
console.log('PASS lazy row identity, retained disclosure/height state, thread switch and listener cleanup');

let now = 0, sequence = 0, controllers = 0; const timers = new Map();
const logs = [], context = { Diagnostics: from('model/Diagnostics').Diagnostics,
  activeWebViews: 0,
  ...from('model/WebUi'), hilog: { info: (...args) => logs.push(args), error: (...args) => logs.push(args) }, t: x => x,
  webview: { WebviewController: class { constructor() { controllers++; this.activations = 0; this.pauses = 0; }
    onActive() { this.activations++; } onInactive() { this.pauses++; }
    loadData() { this.loads = (this.loads || 0) + 1; } } },
  webUiAssets: async () => ['fixture runtime', ''],
  setTimeout(fn, delay) { const id = ++sequence; timers.set(id, { fn, at: now + delay }); return id; },
  clearTimeout(id) { timers.delete(id); }
};
function advance(ms) { now += ms; for (const [id, timer] of [...timers]) if (timer.at <= now) { timers.delete(id); timer.fn(); } }
const Web = native('WebUiView', 'WebUiView', ['aboutToAppear', 'aboutToDisappear', 'releaseWeb', 'visibilityChanged', 'foregroundChanged', 'syncActivity', 'closePorts', 'sync', 'report', 'receive', 'restart'], context);
const spec = JSON.stringify({ version: 1, html: '<p>Preview</p>', css: '', js: '', library: 'none', height: 400, autoHeight: true });
const make = (extra = {}) => Object.assign(new Web(), { content: spec, mounted: false, visible: false, foreground: true, scrolling: false, preflight: false,
  renderWeb: false, saving: false, error: '', generation: 0, ports: [], timer: -1, releaseTimer: -1, retainedHeight: 650, reloadPending: false,
  onHeight() {}, onValidation() {}, ...extra });
const web = make(); web.aboutToAppear(); assert.equal(controllers, 0); assert.equal(web.heightValue, 650);
web.visible = true; web.visibilityChanged(); assert.equal(controllers, 1);
web.visibilityChanged(); assert.equal(controllers, 1, 'Do not duplicate an active Web');
const port = { closed: false, messages: [], close() { this.closed = true; }, postMessageEvent(m) { this.messages.push(JSON.parse(m)); } };
web.ports = [port]; web.interactive = true; web.values = { count: 7 };
web.attached = true; web.syncActivity(); assert.equal(web.controller.activations, 1);
web.scrolling = true; web.visibilityChanged();
assert.equal(web.renderWeb, true); assert.equal(web.controller.pauses, 1); assert.equal(port.messages.at(-1).active, false);
web.scrolling = false; web.visibilityChanged();
assert.equal(web.controller.activations, 2); assert.equal(port.messages.at(-1).active, true);
for (let pass = 0; pass < 6; pass++) {
  web.visible = false; web.visibilityChanged(); advance(800);
  web.visible = true; web.visibilityChanged();
}
assert.equal(controllers, 1, 'Quick repeated scroll reversals must reuse the same native Web');
assert.equal(port.closed, false);
web.visible = false; web.visibilityChanged(); assert.equal(port.messages.at(-1).active, false);
advance(599); assert.equal(web.renderWeb, true);
web.visible = true; web.visibilityChanged(); advance(1); assert.equal(web.renderWeb, true); assert.equal(port.closed, false);
web.visible = false; web.visibilityChanged(); advance(4999); assert.equal(web.renderWeb, true);
web.scrolling = true; web.visibilityChanged();
advance(1); assert.equal(web.renderWeb, false); assert.equal(port.closed, true);
web.scrolling = false;
const detachedGeneration = web.generation;
web.visible = true; web.visibilityChanged(); assert.equal(controllers, 2); assert.equal(web.heightValue, 650);
web.visible = false; web.visibilityChanged(); advance(1000);
web.foreground = false; web.foregroundChanged(); advance(600); assert.equal(web.renderWeb, false);
web.visible = true;
web.foreground = true; web.visibilityChanged(); assert.equal(controllers, 3);
web.saving = true; web.visible = false; web.visibilityChanged(); advance(600); assert.equal(web.renderWeb, true, 'Finish pending saves before releasing Web');
web.saving = false; web.visibilityChanged(); advance(5000); assert.equal(web.renderWeb, false);
web.visible = true; web.visibilityChanged(); web.aboutToDisappear(); advance(1000); assert.equal(web.mounted, false); assert.equal(web.renderWeb, false);
const check = make({ preflight: true, foreground: false }); check.aboutToAppear();
assert.equal(check.renderWeb, true, 'Hidden validation must still render'); check.visibilityChanged(); advance(1000); assert.equal(check.renderWeb, true);
check.aboutToDisappear(); assert.equal(check.renderWeb, false); assert.equal(timers.size, 0); assert.equal(context.activeWebViews, 0);
const scrolling = make({ visible: true, scrolling: true }); const beforeScroll = controllers;
scrolling.aboutToAppear(); assert.equal(controllers, beforeScroll); assert.equal(scrolling.renderWeb, false);
scrolling.scrolling = false; scrolling.visibilityChanged(); assert.equal(controllers, beforeScroll + 1);
scrolling.aboutToDisappear();
const preflight = make({ preflight: true, scrolling: true }); preflight.aboutToAppear(); assert.equal(preflight.renderWeb, true);
preflight.aboutToDisappear(); assert.equal(context.activeWebViews, 0);
console.log('PASS native pause/resume, repeated reversals without cold loads, cold activation after scrolling stops, bounded offscreen/background release and hidden validation');

// Follow the actual List event callbacks into the storage observed by WebUiView.
const scrollState = new Map(), scrollChanges = [];
const Chat = native('ChatPanel', 'ChatPanel', ['setScrollActivity', 'stopScrollActivity', 'aboutToDisappear'], {
  Diagnostics: context.Diagnostics, clearTimeout: context.clearTimeout, setTimeout: context.setTimeout,
  AppStorage: { get: key => scrollState.get(key), setOrCreate(key, value) { scrollState.set(key, value); scrollChanges.push(value); } }
});
const chat = Object.assign(new Chat(), { scrollStopTimer: -1, viewport: { dispose() {} }, endSpeech() {}, reading: { stop() {} } });
const chatFile = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
const chatTree = ts.createSourceFile(chatFile, fs.readFileSync(chatFile, 'utf8'), ts.ScriptTarget.Latest, true);
const scrollCallbacks = {};
(function visit(node) {
  if (ts.isCallExpression(node) && ['List.onScrollStart', 'List.onScrollStop'].includes(node.expression.getText(chatTree))) {
    const callback = { exports: {} };
    vm.runInNewContext('exports.run = function() { return (' + node.arguments[0].getText(chatTree) + ')(); };', callback);
    scrollCallbacks[node.expression.getText(chatTree)] = callback.exports.run;
  }
  ts.forEachChild(node, visit);
})(chatTree);
assert.ok(scrollCallbacks['List.onScrollStart'] && scrollCallbacks['List.onScrollStop']);
scrollCallbacks['List.onScrollStart'].call(chat); scrollCallbacks['List.onScrollStart'].call(chat);
assert.equal(scrollState.get('tinybot.chat.scrolling'), true);
scrollCallbacks['List.onScrollStop'].call(chat); advance(199); assert.equal(scrollState.get('tinybot.chat.scrolling'), true);
scrollCallbacks['List.onScrollStart'].call(chat); advance(1); assert.equal(scrollState.get('tinybot.chat.scrolling'), true, 'A new gesture cancels the pending resume');
scrollCallbacks['List.onScrollStop'].call(chat); advance(199); assert.equal(scrollState.get('tinybot.chat.scrolling'), true);
advance(1); assert.equal(scrollState.get('tinybot.chat.scrolling'), false);
scrollCallbacks['List.onScrollStart'].call(chat); scrollCallbacks['List.onScrollStop'].call(chat); chat.aboutToDisappear(); advance(200);
assert.deepEqual(scrollChanges, [true, false, true, false]);
assert.equal(timers.size, 0);
console.log('PASS emitted List callbacks wait for 200ms of rest, cancel on a new gesture and clear pending work when leaving chat');

(async () => {
  const deferred = make({ visible: true, attached: true, initialPageLoaded: true,
    getUIContext: () => ({ getHostContext: () => ({}) }) });
  deferred.aboutToAppear();
  let assetsReady;
  context.webUiAssets = () => new Promise(resolve => { assetsReady = resolve; });
  const preparing = deferred.restart();
  for (let i = 0; i < 4; i++) { await Promise.resolve(); }
  assert.ok(assetsReady);
  deferred.scrolling = true; deferred.visibilityChanged();
  assetsReady(['fixture runtime', '']); await preparing;
  assert.equal(deferred.controller.loads || 0, 0, 'Scrolling that starts during asset IO must defer loadData');
  assert.equal(deferred.reloadPending, true);
  context.webUiAssets = async () => ['fixture runtime', ''];
  deferred.scrolling = false; deferred.visibilityChanged();
  for (let i = 0; i < 8; i++) { await Promise.resolve(); }
  assert.equal(deferred.controller.loads, 1); assert.equal(deferred.reloadPending, false);
  deferred.aboutToDisappear(); assert.equal(context.activeWebViews, 0);
  console.log('PASS async resource reads recheck scrolling and resume one page load only after rest');
  await web.receive(JSON.stringify({ type: 'resize', height: 123 }), detachedGeneration);
  assert.equal(web.heightValue, 650, 'Late events cannot mutate a disposed/recreated Web');
  const savingWeb = make({ visible: true, interactive: true }); savingWeb.aboutToAppear();
  let finishSave;
  savingWeb.ports = [{ close() {}, postMessageEvent() {} }];
  savingWeb.onSave = () => new Promise(resolve => { finishSave = resolve; });
  const pendingSave = savingWeb.receive(JSON.stringify({ type: 'save', id: 1, values: { count: 7 } }), savingWeb.generation);
  savingWeb.visible = false; savingWeb.visibilityChanged(); advance(1000);
  assert.equal(savingWeb.renderWeb, true); assert.equal(savingWeb.saving, true);
  finishSave({ count: 7 }); await pendingSave; advance(5000);
  assert.equal(savingWeb.renderWeb, false); assert.equal(context.activeWebViews, 0);
  const Ui = native('InteractiveAnswer', 'UiSurface', ['aboutToAppear', 'aboutToDisappear', 'refresh', 'report', 'saveWeb'], {
    UiCompiler, copyUiValues, validateUiState, hilog: context.hilog, t: x => x, clearTimeout: context.clearTimeout
  });
  const presentation = new UiPresentation(), content = uiParts(surface('Saved inputs'), false)[0].content;
  const makeUi = () => Object.assign(new Ui(), { presentation, surfaceKey: '0:3', source: content, closed: true, streaming: false,
    initialized: false, failed: false, saved: [{ key: '0:3', values: { count: 7 } }], compiler: new UiCompiler(),
    dirty: false, invalid: [], mounted: false, available: true, busy: false });
  const ui = makeUi(); ui.aboutToAppear(); assert.equal(ui.values.count, 7);
  ui.values = { count: 8 }; ui.dirty = true; ui.aboutToDisappear();
  const reopened = makeUi(); reopened.aboutToAppear(); assert.equal(reopened.values.count, 8); assert.equal(reopened.dirty, true);
  reopened.onInteract = async (key, values) => { assert.equal(key, '0:3'); return values; };
  await reopened.saveWeb({ count: 9 }); assert.equal(presentation.drafts.has('0:3'), false); assert.equal(reopened.values.count, 9);
  const Card = native('PublishedPreviewCard', 'PublishedPreviewCard', ['aboutToAppear', 'revisionChanged', 'thumbnailSize'], {});
  const card = Object.assign(new Card(), { preview: { superseded: false } }); card.aboutToAppear(); assert.equal(card.expanded, true);
  card.preview = { superseded: true }; card.revisionChanged(); assert.equal(card.expanded, false);
  card.expanded = true; card.revisionChanged(); assert.equal(card.expanded, true, 'Updates must preserve explicitly opened history');
  card.preview.screenshot = { width: 719, height: 1600 };
  assert.ok(card.thumbnailSize().width <= 264); assert.equal(card.thumbnailSize().height, 192);
  card.preview.screenshot = { width: 1600, height: 400 };
  assert.equal(card.thumbnailSize().width, 264); assert.equal(card.thumbnailSize().height, 66);
  console.log('PASS lazy form draft restoration, saved revision identity, obsolete Web events and superseded card lifecycle');
})().catch(error => { console.error(error); process.exitCode = 1; });
