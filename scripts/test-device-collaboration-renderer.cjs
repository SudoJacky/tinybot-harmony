// Build first. Execute the emitted message-card callbacks across empty, streaming and completed output.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const relative = 'entry/src/main/ets/views/DeviceCollaborationPanel';
const source = path.join(root, relative + '.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug', relative + '.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const card = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'CollaborationMessageCard');
let mount;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'this.observeComponentCreation2' &&
    node.arguments[1]?.getText(tree) === 'If' && /if \(this\.message\.content\)/.test(node.arguments[0].getText(tree))) {
    mount = node.arguments[0].getText(tree);
  }
  ts.forEachChild(node, visit);
}
assert.ok(card, 'Messages need their own reactive card'); visit(card); assert.ok(mount);
let rendered, childUpdate, branch;
const globals = { exports: {}, If: { create() {}, pop() {} }, ViewPU: { create() {} },
  MarkdownView: class { constructor(parent, options) { rendered = options; } } };
vm.runInNewContext(ts.transpileModule('exports.make = function() { return ' + mount + '; }', { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
const parent = { message: { content: '', status: 'generating' },
  ifElseBranchUpdateFunction(next, create) { if (branch !== next) { branch = next; create(); } },
  observeComponentCreation2(callback) { childUpdate = callback; callback.call(this, 2, true); },
  updateStateVarsOfChildByElmtId(id, options) { rendered = options; } };
const render = globals.exports.make.call(parent);
render(1, true); assert.equal(rendered, undefined);
parent.message.content = '首段输出'; render(1, false);
assert.equal(rendered.content, '首段输出'); assert.equal(rendered.streaming, true);
parent.message.content += '，后续输出'; childUpdate.call(parent, 2, false);
assert.equal(rendered.content, '首段输出，后续输出', 'Same row must receive subsequent tokens');
parent.message.status = 'complete'; childUpdate.call(parent, 2, false); assert.equal(rendered.streaming, false);
const status = tree.statements.find(node => ts.isFunctionDeclaration(node) && node.name.text === 'collaborationStatus');
const statusGlobals = { exports: {}, t: key => key };
vm.runInNewContext(ts.transpileModule(status.getText(tree), { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, statusGlobals);
assert.equal(statusGlobals.exports.collaborationStatus({ phase: 'idle', status: 'stopped', error: 'Cancelled by user' }), '已停止');
assert.equal(statusGlobals.exports.collaborationStatus({ phase: 'idle', status: 'failed', error: 'Network failure' }), '执行出错');
console.log('PASS compiled collaboration card: initially empty output, subsequent tokens, completion and user-stop status');
