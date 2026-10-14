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
const builder = component.members.find(node => node.name?.getText(tree) === 'actionButton');
const calls = [];
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'this.actionButton.bind(this)') {
    calls.push(node.getText(tree));
  }
  ts.forEachChild(node, visit);
}
visit(component);
assert.equal(calls.length, 4, 'Exercise edit, copy, regenerate and fork from the emitted call sites');

let current;
const effects = new Map(), buttons = new Map(), subscribers = new Set();
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
const globals = { exports: {}, ViewPU, Button, Row: noUi, SymbolGlyph: noUi, Text: noUi, Image: noUi, If: noUi,
  ButtonType: {}, Color: {}, Motion: {}, ImageFit: {}, t: text => text };
const probe = `class Probe extends ViewPU { ${builder.getText(tree)}
  mount() { ${calls.join(';\n')}; }
} exports.Probe = Probe;`;
vm.runInNewContext(ts.transpileModule(probe, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
const view = new globals.exports.Probe();
view.appearance = { fontFamily: '' };
let allowed = false;
Object.defineProperty(view, 'actionsEnabled', { get() {
  if (current !== undefined) subscribers.add(current);
  return allowed;
} });
const invoked = [];
view.message = { id: 'message' };
view.onFork = id => invoked.push('fork:' + id);
view.onRegenerate = id => invoked.push('regenerate:' + id);
view.copy = () => invoked.push('copy');
view.mount();
const controls = new Map([...buttons.values()].filter(button => button.id).map(button => [button.id, button]));
const ids = [...effects.keys()];
function check(expected) {
  for (const action of ['edit', 'regenerate', 'fork']) {
    assert.equal(controls.get(action + '-message').enabled, expected, action + ' must follow the current session state');
  }
  assert.equal(controls.get('copy-message').enabled, true, 'Copy stays available during a run or save error');
  assert.deepEqual([...effects.keys()], ids, 'State transitions must not remount controls');
}
function update(value) {
  allowed = value;
  for (const id of subscribers) {
    current = id; effects.get(id)(id, false); current = undefined;
  }
}
check(false);
update(true); check(true); // The answer finishes and final persistence returns to idle.
update(false); check(false); // A new task or a persistence error blocks mutations again.
update(true); check(true); // Completion or successful save retry restores the same buttons.
for (const button of controls.values()) button.onClick();
assert.deepEqual(invoked, ['fork:message', 'copy', 'regenerate:message', 'fork:message']);
console.log('PASS retained message actions react to completion, renewed busy/error state and recovery; copy and callbacks remain intact');
