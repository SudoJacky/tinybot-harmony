// Build first. Exercise the emitted drawer animation lifecycle and inactive render branch.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function probe(file, name, methods, globals = {}) {
  const src = path.join(root, 'entry/src/main/ets', file + '.ets');
  const compiled = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(compiled).mtimeMs >= fs.statSync(src).mtimeMs, 'Build before testing ' + name);
  const tree = ts.createSourceFile(compiled, fs.readFileSync(compiled, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  const selected = cls.members.filter(n => methods.includes(n.name?.getText(tree)));
  assert.equal(selected.length, methods.length);
  const context = { exports: {}, ...globals };
  vm.runInNewContext(ts.transpileModule('class Probe {' + selected.map(n => n.getText(tree)).join('\n') + '} exports.Probe = Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, context);
  return context.exports.Probe;
}
const Page = probe('pages/Index', 'Index', ['setDrawer', 'startDrawerDrag', 'updateDrawerDrag', 'endDrawerDrag', 'cancelDrawerDrag'], {
  Motion: { drawer: 260, drawerCurve: 'ease' }
});
const animations = [];
const page = Object.assign(new Page(), { app: { ready: true }, drawerOpen: false, drawerDragging: false,
  drawerContentActive: false, drawerAnimation: 0, drawerReveal: 0, drawerWidth: 340,
  getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }),
    animateTo(options, update) { animations.push(options); update(); } }) });
page.setDrawer(true); assert.equal(page.drawerContentActive, true);
animations.at(-1).onFinish(); assert.equal(page.drawerContentActive, true);
page.setDrawer(false); assert.equal(page.drawerContentActive, true, 'Keep content through the closing animation');
animations.at(-1).onFinish(); assert.equal(page.drawerContentActive, false);
page.setDrawer(true); page.setDrawer(false); const oldClose = animations.at(-1);
page.setDrawer(true); oldClose.onFinish(); assert.equal(page.drawerContentActive, true, 'An interrupted close must not blank a reopened drawer');
page.setDrawer(false); const interrupted = animations.at(-1);
page.startDrawerDrag({ offsetX: 30, offsetY: 0 }); interrupted.onFinish();
assert.equal(page.drawerContentActive, true, 'Keep content while dragging');
page.endDrawerDrag({ offsetX: -20, offsetY: 0, velocityX: -700 });
assert.equal(page.drawerContentActive, true); animations.at(-1).onFinish(); assert.equal(page.drawerContentActive, false);
page.startDrawerDrag({ offsetX: 50, offsetY: 0 }, true);
assert.equal(page.drawerContentActive, true); page.cancelDrawerDrag(); animations.at(-1).onFinish();
assert.equal(page.drawerContentActive, false);
console.log('PASS drawer open, close completion, interruption, drag and cancel lifecycle');

const noop = new Proxy({}, { get: () => () => {} });
const List = probe('views/ThreadList', 'ThreadList', ['initialRender'], { Column: noop, If: noop });
let renders = 0;
const list = Object.assign(new List(), { active: false, query: 'retained query', visibleCounts: { ordinary: 40 },
  listContent() { renders++; }, observeComponentCreation2(callback) { callback(1, true); },
  ifElseBranchUpdateFunction(_branch, render) { render(); } });
Object.defineProperty(list, 'app', { get() { throw Error('Inactive content must not read chat state'); } });
list.initialRender(); assert.equal(renders, 0);
list.active = true; list.initialRender(); assert.equal(renders, 1);
list.active = false; list.initialRender(); assert.equal(renders, 1);
assert.equal(list.query, 'retained query'); assert.equal(list.visibleCounts.ordinary, 40);
console.log('PASS inactive history skips its content while preserving search and pagination state');
