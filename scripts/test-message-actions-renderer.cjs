// Run devecocli build first. Exercise the emitted builder and its actual call sites
// with retained buttons and property-read tracking; this does not simulate native painting.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'entry/src/main/ets/views/MessageBubble.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MessageBubble.ts');
if (!fs.existsSync(emitted) || fs.statSync(source).mtimeMs > fs.statSync(emitted).mtimeMs) {
  throw Error('Build MessageBubble before this renderer test.');
}
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'MessageBubble');
const methods = ['actionButton', 'messageActions', 'selectText'].map(name =>
  component.members.find(node => node.name?.getText(tree) === name).getText(tree));

let current;
const effects = new Map(), buttons = new Map(), glyphs = new Map(), subscribers = new Set(), readingSubscribers = new Set();
class ViewPU {
  constructor() { this.branches = new Map(); }
  observeComponentCreation2(callback) {
    const id = effects.size;
    effects.set(id, callback);
    current = id; callback(id, true); current = undefined;
  }
  ifElseBranchUpdateFunction(branch, create) {
    const id = current;
    if (this.branches.get(id) !== branch) { this.branches.set(id, branch); create(); }
  }
}
const noUi = new Proxy({}, { get: () => () => {} });
const Button = new Proxy({}, { get: (_, method) => value => {
  if (current === undefined) return;
  const button = buttons.get(current) || {};
  button[method] = value; buttons.set(current, button);
} });
const SymbolGlyph = new Proxy({}, { get: (_, method) => method === 'create' ? value => glyphs.set(current, value) : () => {} });
const globals = { exports: {}, ViewPU, Button, Flex: noUi, FlexWrap: {}, FlexAlign: {}, SymbolGlyph, Text: noUi, Image: noUi, If: noUi,
  ButtonType: {}, Color: {}, Motion: {}, ImageFit: {}, t: text => text };
const probe = `class Probe extends ViewPU { ${methods.join('\n')} } exports.Probe = Probe;`;
vm.runInNewContext(ts.transpileModule(probe, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
function rerun(ids) {
  for (const id of ids) {
    current = id; effects.get(id)(id, false); current = undefined;
  }
}
for (const [role, content, expected] of [
  ['assistant', '回答 **文本**', ['copy', 'select-text', 'read-answer', 'regenerate', 'fork', 'remember']],
  ['user', '用户文本', ['copy', 'select-text', 'edit']],
  ['assistant', '', ['regenerate', 'fork']],
  ['user', '', ['edit']]
]) {
  effects.clear(); buttons.clear(); glyphs.clear(); subscribers.clear(); readingSubscribers.clear();
  const view = new globals.exports.Probe(), invoked = [];
  view.appearance = { fontFamily: '' };
  view.message = { id: 'message', role, content };
  view.onFork = id => invoked.push('fork:' + id);
  view.onRegenerate = id => invoked.push('regenerate:' + id);
  view.onRemember = id => invoked.push('remember:' + id);
  view.onRead = id => invoked.push('read:' + id);
  view.copy = () => invoked.push('copy');
  let allowed = false, readingId = '';
  Object.defineProperty(view, 'actionsEnabled', { get() {
    if (current !== undefined) subscribers.add(current);
    return allowed;
  } });
  Object.defineProperty(view, 'readingMessageId', { get() {
    if (current !== undefined) readingSubscribers.add(current);
    return readingId;
  } });
  view.messageActions();
  const allControls = [...buttons.values()].filter(button => button.id);
  const controls = new Map(allControls.map(button => [button.id, button]));
  assert.equal(controls.size, allControls.length, 'No duplicate controls');
  assert.deepEqual([...controls.keys()], expected.map(action => action + '-message'));
  const ids = [...effects.keys()];
  for (const next of [false, true, false, true]) {
    allowed = next; rerun(subscribers);
    for (const action of expected) {
      const button = controls.get(action + '-message');
      assert.equal(button.enabled, ['edit', 'regenerate', 'fork', 'remember'].includes(action) ? next : true);
      assert.equal(button.width, 36); assert.equal(button.height, 44);
      assert.ok(button.accessibilityText);
    }
    assert.deepEqual([...effects.keys()], ids, 'State transitions must not remount controls');
  }
  if (controls.has('read-answer-message')) {
    const before = [...glyphs.values()].map(icon => icon.id);
    readingId = 'another-message'; rerun(readingSubscribers);
    assert.equal(controls.get('read-answer-message').accessibilityText, '朗读回答');
    readingId = 'message'; rerun(readingSubscribers);
    assert.equal(controls.get('read-answer-message').accessibilityText, '停止朗读');
    assert.notDeepEqual([...glyphs.values()].map(icon => icon.id), before, 'Reading must switch the retained icon');
    readingId = ''; rerun(readingSubscribers);
    assert.equal(controls.get('read-answer-message').accessibilityText, '朗读回答');
    assert.deepEqual([...glyphs.values()].map(icon => icon.id), before);
    assert.deepEqual([...effects.keys()], ids);
  }
  view.message.content = '最新消息文本';
  for (const button of controls.values()) button.onClick();
  assert.deepEqual(invoked, expected.filter(action => action !== 'select-text').map(action =>
    action === 'copy' ? 'copy' : (action === 'edit' ? 'fork' : action === 'read-answer' ? 'read' : action) + ':message'));
  if (controls.has('select-text-message')) {
    assert.equal(view.documentOpen, true); assert.equal(view.selectingText, true);
    assert.equal(view.documentText, '最新消息文本', 'Selection opens the current full text');
  }
}
console.log('PASS compact message actions: unique assistant/user controls, empty content, live permissions, reading/stop icon, selection and callbacks');
