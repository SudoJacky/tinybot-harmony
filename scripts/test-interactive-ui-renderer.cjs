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
