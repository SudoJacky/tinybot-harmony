// Exercises the actual DevEco-emitted component callbacks with keyed ForEach reuse.
// Run devecocli build first. This checks data delivery/lifecycle, not native painting.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/InteractiveAnswer.ts');
if (!fs.existsSync(emitted)) throw Error('Run devecocli build before this renderer regression.');
const source = path.join(root, 'views/InteractiveAnswer.ets');
if (fs.statSync(source).mtimeMs > fs.statSync(emitted).mtimeMs) throw Error('Stale emitted component: rebuild first.');
let serial = 0;
const errors = [];
class Property {
  constructor(value, owner, name) { this.value = value; this.owner = owner; this.name = name; }
  get() { return this.value; }
  set(value) { const changed = value !== this.value; this.value = value; if (changed) this.owner.watches.get(this.name)?.call(this.owner); }
  reset(value) { this.set(value); }
}
class ViewPU {
  constructor(parent, storage, id) { this.parent = parent; this.id = id; this.watches = new Map(); this.effects = new Map(); this.childViews = new Map(); this.lists = new Map(); this.branches = new Map(); }
  finalizeConstruction() {}
  declareWatch(name, callback) { this.watches.set(name, callback); }
  observeComponentCreation2(callback) { const id = ++serial; this.effects.set(id, callback); this.current = id; callback(id, true); }
  forEachUpdateFunction(id, items, create, key) {
    const previous = this.lists.get(id) || new Set(); const next = new Set();
    items.forEach((item, index) => { const identity = key ? key(item, index) : JSON.stringify(item); next.add(identity); if (!previous.has(identity)) create(item, index); });
    this.lists.set(id, next);
  }
  ifElseBranchUpdateFunction(branch, create) { const id = this.current; if (this.branches.get(id) !== branch) { this.branches.set(id, branch); create(); } }
  updateStateVarsOfChildByElmtId(id, params) { this.childViews.get(id).updateStateVars(params); }
  static create(child) { child.parent.childViews.set(child.id, child); child.aboutToAppear?.(); }
  flush() { for (const [id, effect] of [...this.effects]) { this.current = id; effect(id, false); } }
}
class MarkdownView extends ViewPU {
  constructor(parent, params, storage, id) { super(parent, storage, id); Object.assign(this, params); }
  updateStateVars(params) { Object.assign(this, params); }
}
const noUi = new Proxy({}, { get: () => () => {} });
const cache = new Map();
function model(file) {
  file = path.resolve(file + '.ets'); if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText;
  vm.runInNewContext(js, { exports, Observed: cls => cls, require: id => model(path.resolve(path.dirname(file), id)) }); return exports;
}
const globals = { exports: {}, ViewPU, SynchedPropertySimpleOneWayPU: Property, SynchedPropertyObjectOneWayPU: Property,
  ObservedPropertySimplePU: Property, ObservedPropertyObjectPU: Property, ObservedObject: { GetRawObject: value => value },
  Column: noUi, Row: noUi, Text: noUi, Button: noUi, If: noUi, ForEach: noUi, LoadingProgress: noUi,
  HorizontalAlign: {}, FontWeight: {}, Color: {}, $r: () => '', setTimeout, clearTimeout,
  require: id => {
    if (id.includes('InteractiveUi&')) return model(path.join(root, 'model/InteractiveUi'));
    if (id.includes('I18n&')) return { t: text => text };
    if (id.includes('Theme&')) return { Space: {}, Radius: {}, Btn: {} };
    if (id.includes('MarkdownView&')) return { MarkdownView };
    if (id.includes('DataViewCard&')) return {};
    if (id.includes('UiSceneView&')) return {};
    if (id.includes('WebUiView&')) return {};
    if (id === '@ohos:arkui.node') return {};
    if (id === '@ohos:hilog') return { default: { error: (...args) => errors.push(args) } };
    throw Error('Unhandled dependency ' + id);
  }
};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted, 'utf8') + '\nexport { UiSurface, UiNodeView };', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
const { InteractiveAnswer, UiSurface, UiNodeView } = globals.exports;
const { uiParts } = model(path.join(root, 'model/InteractiveUi'));
const records = [
  { op: 'begin', version: 1, title: 'Counter', state: { count: 1 } },
  { op: 'node', node: { id: 'result', kind: 'text', text: 'First label' } },
  { op: 'node', node: { id: 'result', kind: 'text', text: 'Updated label {{count}}' } },
  { op: 'end' }
];
const wire = records.map(r => JSON.stringify(r)).join('\n') + '\n';
const answer = 'Before the interface.\n```tinybot-ui\n' + wire + '```\nAfter the interface, the complete explanation.';
function mounted(content, streaming) { const view = new InteractiveAnswer(null, { content, streaming, available: true }); view.aboutToAppear(); view.initialRender(); return view; }
function update(view, content, streaming) { view.updateStateVars({ content, streaming, available: true }); view.flush(); }
let failed = 0;
function test(name, fn) { try { fn(); console.log('PASS ' + name); } catch (error) { failed++; console.error('FAIL ' + name + '\n' + error.stack); } }
test('plain streaming response reaches full final text without remount', () => {
  const view = mounted('B', true); update(view, 'Before the complete explanation.', false);
  assert.equal([...view.childViews.values()][0].content, 'Before the complete explanation.');
});
test('mixed Markdown and UI completes at arbitrary chunk boundaries without remount', () => {
  for (const stride of [1, 7, 37, 96]) {
    const view = mounted('', true);
    for (let i = stride; i < answer.length; i += stride) update(view, answer.slice(0, i), true);
    update(view, answer, false);
    const parts = uiParts(answer, false); const children = [...view.childViews.values()];
    assert.equal(children.length, parts.length);
    children.forEach((child, i) => {
      if (parts[i].kind === 'text') assert.equal(child.content, parts[i].content);
      else { assert.equal(child.error, '', 'surface failure: ' + child.error); assert.equal(child.complete, true); assert.equal(child.nodes[0].text, 'Updated label {{count}}'); }
    });
  }
});
test('partial first JSON record is never finalized as the finished surface', () => {
  const view = mounted('\x60\x60\x60tinybot-ui\n' + wire.slice(0, 10), true);
  update(view, '\x60\x60\x60tinybot-ui\n' + wire + '\x60\x60\x60', false);
  const child = [...view.childViews.values()].find(v => v instanceof UiSurface);
  assert.equal(child.error, '', 'surface failure: ' + child.error);
  assert.equal(child.complete, true);
});
test('completed history mounts correctly as the differential control', () => {
  const view = mounted(answer, false); const child = [...view.childViews.values()].find(v => v instanceof UiSurface);
  assert.equal(child.complete, true); assert.equal(child.error, '');
});
test('same-id node upserts reach existing native child without resetting it', () => {
  const head = records.slice(0, 2).map(r => JSON.stringify(r)).join('\n') + '\n';
  const view = new UiSurface(null, { source: head, closed: false, streaming: true, available: true }); view.aboutToAppear(); view.initialRender();
  const child = [...view.childViews.values()].find(v => v instanceof UiNodeView); assert.ok(child);
  view.updateStateVars({ source: wire, closed: true, streaming: false, available: true }); view.flush();
  assert.equal([...view.childViews.values()].find(v => v instanceof UiNodeView), child);
  assert.equal(child.node.text, 'Updated label {{count}}');
});
test('nested node updates preserve the existing control and its live values', () => {
  const card = { id: 'card', kind: 'card' };
  const input = { id: 'amount', parent: 'card', kind: 'number', text: 'Old label', bind: 'count' };
  const view = new UiNodeView(null, { node: card, nodes: [card, input], values: { count: 1 }, interactive: true });
  view.childrenView();
  const child = [...view.childViews.values()][0];
  view.updateStateVars({ node: card, nodes: [card, { ...input, text: 'New label' }], values: { count: 7 }, interactive: true });
  view.flush();
  assert.equal([...view.childViews.values()][0], child);
  assert.equal(child.node.text, 'New label'); assert.equal(child.values.count, 7);
});
test('malformed finished JSON still reports failure rather than being ignored', () => {
  const view = mounted('\x60\x60\x60tinybot-ui\n{bad json}\n\x60\x60\x60', false);
  const child = [...view.childViews.values()].find(v => v instanceof UiSurface);
  assert.ok(child.error); assert.equal(child.complete, false);
});
if (failed) process.exitCode = 1;

// ArkWeb lifecycle regression: loadData must wait for the initial blank document.
(async () => {
  const webEmitted = emitted.replace('InteractiveAnswer.ts', 'WebUiView.ts');
  if (fs.statSync(path.join(root, 'views/WebUiView.ets')).mtimeMs > fs.statSync(webEmitted).mtimeMs) throw Error('Rebuild WebUiView before testing.');
  const callbacks = {}, loads = [], sent = [];
  const port = { close() {}, onMessageEvent(fn) { this.receive = fn; }, postMessageEvent(value) { sent.push(JSON.parse(value)); } };
  class Controller {
    loadData(html) { loads.push(html); }
    async runJavaScript() { return 'true'; }
    createWebMessagePorts() { return [port, { close() {} }]; }
    postMessage() {}
  }
  const webGlobals = { ...globals, exports: {}, MessageLevel: { Error: 3 },
    Web: new Proxy({}, { get: (_, name) => (...args) => { if (name.startsWith('on')) callbacks[name] = args[0]; } }),
    require: id => {
      if (id === '@ohos:web.webview') return { default: { WebviewController: Controller } };
      if (id === '@ohos:hilog') return { default: { info() {}, warn() {}, error() {} } };
      if (id.includes('WebUi&')) return model(path.join(root, 'model/WebUi'));
      if (id.includes('WebUiAssets&')) return { webUiAssets: async () => ['', ''] };
      return globals.require(id);
    }
  };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(webEmitted, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, webGlobals, { filename: webEmitted });
  const view = new webGlobals.exports.WebUiView(null, { content: JSON.stringify({version:1,html:'',css:'',js:'',library:'none',height:200}), values:{count:0}, interactive:true,
    onSave: async values => values });
  view.getUIContext = () => ({ getHostContext: () => ({}) });
  const settle = () => new Promise(resolve => setImmediate(resolve));
  const intercept = (url, main = true) => callbacks.onLoadIntercept({data:{getRequestUrl:()=>url,isMainFrame:()=>main}});
  try {
    view.aboutToAppear(); view.initialRender(); callbacks.onControllerAttached(); await settle();
    assert.equal(loads.length,0,'initial navigation must finish before loadData');
    callbacks.onPageEnd({url:'about:blank'}); await settle(); assert.equal(loads.length,1);
    assert.equal(intercept('data:text/html;charset=UTF-8;base64,host',false),true);
    assert.equal(intercept('data:text/html;charset=UTF-8;base64,host'),false);
    assert.equal(intercept('data:text/html;charset=UTF-8;base64,another'),true);
    assert.equal(intercept('https://example.com'),true); assert.equal(intercept('file:///private'),true);
    callbacks.onPageEnd({url:'data:text/html,host'}); await settle();
    assert.equal(sent[0].type,'init'); await port.receive('{"type":"ready"}');
    assert.equal(view.ready,true); assert.equal(view.error,'');
    console.log('PASS ArkWeb waits for its initial document and permits exactly one native data load');
    await view.receive('{"type":"save","id":1,"values":{"count":1}}',view.generation);
    assert.equal(sent.at(-1).type,'ack'); assert.equal(sent.at(-1).values.count,1);
    view.onSave = async () => { throw new Error('Disk write failed'); };
    await view.receive('{"type":"save","id":2,"values":{"count":2}}',view.generation);
    assert.equal(sent.at(-1).error,'Disk write failed'); assert.equal(view.error,'Disk write failed');
    console.log('PASS ArkWeb state acknowledgements follow persistence and expose save failures');
    await view.restart(); assert.equal(loads.length,2); assert.equal(intercept('data:text/html,host'),false);
    callbacks.onPageEnd({url:'data:text/html,host'}); await settle();
    assert.equal(sent.at(-1).type,'init'); assert.equal(view.error,'');
    console.log('PASS explicit reload reconnects a new document and clears the prior error');
  } finally { view.aboutToDisappear(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
