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
  workbench: () => ({ historyWidth: 0 }),
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

// Exercise both initial and retained sidebar props emitted by ArkUI.
const compiledPage = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts');
const pageTree = ts.createSourceFile(compiledPage, fs.readFileSync(compiledPage, 'utf8'), ts.ScriptTarget.Latest, true);
let initialProps, updatedProps;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(pageTree) === 'this.observeComponentCreation2' &&
      node.arguments[1]?.getText(pageTree).includes('name: "ThreadList"')) {
    function child(n) {
      if (ts.isNewExpression(n) && n.expression.getText(pageTree) === 'ThreadList') initialProps = n.arguments[1].getText(pageTree);
      if (ts.isCallExpression(n) && n.expression.getText(pageTree) === 'this.updateStateVarsOfChildByElmtId') updatedProps = n.arguments[1].getText(pageTree);
      ts.forEachChild(n, child);
    }
    child(node.arguments[0]);
  }
  ts.forEachChild(node, visit);
}
visit(pageTree); assert.ok(initialProps && updatedProps);
const sidebarProps = vm.runInNewContext(`(function(initial) { return initial ? (${initialProps}) : (${updatedProps}); })`);
for (const initial of [true, false]) {
  const state = { app: {}, workbench: () => ({expanded: true}), onboardingActive: false, chatVisible: false, drawerContentActive: false };
  assert.equal(sidebarProps.call(state, initial).active, true, 'Settings must retain the expanded sidebar');
  state.workbench = () => ({expanded: false});
  assert.equal(sidebarProps.call(state, initial).active, false, 'A hidden phone drawer must stay inactive');
  state.drawerContentActive = true;
  assert.equal(sidebarProps.call(state, initial).active, true, 'An opened overlay or its exit animation retains content');
  state.onboardingActive = true;
  assert.equal(sidebarProps.call(state, initial).active, false, 'Initial setup keeps history inactive');
}
const NavigationPage = probe('pages/Index', 'Index', ['createChat', 'revealChat'], {t: value => value});
(async () => {
  let cleared = 0, drawerClosed = 0, created = 0;
  const nav = Object.assign(new NavigationPage(), {paths: {clear(){cleared++;}},
    app: {canNavigate:true,active:{id:'old'},async newThread(){created++;this.active.id='new';return true;}},
    workbench:()=>({expanded:true,docked:true}),setDrawer(open){assert.equal(open,false);drawerClosed++;}});
  sidebarProps.call(nav,true).onSelected();
  assert.equal(cleared,1,'Selecting a visible conversation exits Settings');
  await nav.createChat();assert.equal(cleared,2);assert.equal(created,1);assert.equal(drawerClosed,2);
  nav.app.newThread=async()=>false;
  await nav.createChat();assert.equal(cleared,2,'Failed creation leaves the current page intact');
  console.log('PASS tablet sidebar survives destinations; selection and successful new chat return to chat');
})().catch(error=>{console.error(error);process.exitCode=1;});
