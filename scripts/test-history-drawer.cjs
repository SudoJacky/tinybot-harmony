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

const Chat = probe('views/ChatPanel', 'ChatPanel', ['chatBody']);
const chatBody = Chat.prototype.chatBody.toString();
const composer = chatBody.search(/this\.composer\b/);
const swipeSpaces = Array.from(chatBody.matchAll(/this\.historySwipeSpace/g), match => match.index);
assert.equal(swipeSpaces.length, 2);
assert.ok(swipeSpaces[0] < composer && composer < swipeSpaces[1], 'The history gesture covers blank space above and below the composer');
console.log('PASS blank space above and below the composer mounts the history swipe gesture');

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

// Run the emitted toolbar through its collapsed, expanded and multiselect states.
const icons = new Map(), buttonActions = new Map(), widths = new Map(), labels = [], menuChoices = [];
let buttonId, rowId, inputChanged, requestFrame;
const uiGlobals = {
  t: (value, args = []) => value.replace(/\{(\d+)\}/g, (_, index) => args[index]),
  ViewPU: { create() {} }, Context: noop, SEARCH_HEIGHT: 44, IS_LARGE_SCREEN: true, Diagnostics: { log() {} },
  ThreadSearchFrame: class { constructor(action) { this.action = action; } },
  IconButton: class { constructor(_parent, props) { icons.set(props.compId, props); } },
  Row: new Proxy({}, { get: (_, key) => key === 'create' ? () => { rowId = undefined; } :
    key === 'id' ? id => { rowId = id; } :
    key === 'width' ? width => { if (rowId) widths.set(rowId, width); } : () => {} }),
  Button: new Proxy({}, { get: (_, key) => key === 'id' ? id => { buttonId = id; } :
    key === 'onClick' ? action => { buttonActions.set(buttonId, action); } : () => {} }),
  TextInput: new Proxy({}, { get: (_, key) => key === 'onChange' ? handler => { inputChanged = handler; } : () => {} }),
  Text: new Proxy({}, { get: (_, key) => key === 'create' ? value => labels.push(value) : () => {} }),
  MenuItem: new Proxy({}, { get: (_, key) => key === 'create' ? item => { if (typeof item === 'function') item(); } : () => {} }),
  materialMenuContent(options) {
    assert.equal(typeof this.observeComponentCreation2, 'function', 'Custom menu content must bind the ArkUI component');
    menuChoices.push(options);
  },
  SymbolGlyphModifier: class {}
};
for (const name of ['If','Stack','Blank','SymbolGlyph','__Common__','ViewStackProcessor','Menu','MenuItemGroup','ForEach']) uiGlobals[name] = noop;
for (const name of ['Alignment','Space','Font','FontWeight','TextOverflow','Color','ButtonType','Visibility','Motion']) {
  uiGlobals[name] = {};
}
const Toolbar = probe('views/ThreadList', 'ThreadList', ['historyToolbar','scopeMenu','searchControl','searchRequested','closeSearch',
  'updateQuery','filtered','threadProject','setScope','endSelection','selectThread','selectAll','allSelected'], uiGlobals);
const focus = [], newChats = [];
let boardOpens = 0;
const toolbar = Object.assign(new Toolbar(), {
  active: true, mounted: true, foreground: true, searchOpen: false, toolbarWidth: 280,
  query: '', visibleCounts: {}, focusRequest: 0, selecting: false, selectedIds: [], archived: false, projectFilter: null,
  appearance: {}, app: { ready: true, activeProject: { id: 'current' }, projects: [{ id: 'project', name: 'Project' }], filteredThreads: () => [
    { id: 'one', projectId: 'project' }, { id: 'two' }, { id: 'old', projectId: 'deleted' }
  ] },
  locked: () => false, onNewChat: projectId => newChats.push(projectId), onLifePanels: () => boardOpens++,
  getUIContext: () => ({
    postFrameCallback(frame) { requestFrame = frame.action; },
    getFocusController: () => ({ requestFocus: id => focus.push(id), clearFocus: () => focus.push(null) })
  }),
  forEachUpdateFunction(_id, items, render) { items.forEach(render); },
  observeComponentCreation2(callback) { callback(1, true); },
  ifElseBranchUpdateFunction(_branch, render) { render(); }
});
function renderToolbar() {
  icons.clear(); buttonActions.clear(); widths.clear(); labels.length = 0;
  toolbar.historyToolbar();
}
renderToolbar();
assert.equal(widths.get('thread-search-pill'), 44);
assert.deepEqual([...icons.keys()], ['open-life-panels', 'workbench-new-chat']);
icons.get('workbench-new-chat').onTap();
assert.deepEqual(newChats, ['current']);
assert.equal(labels.includes('对话'), false);
icons.get('open-life-panels').onTap();
assert.equal(boardOpens, 1);
buttonActions.get('thread-search-toggle')();
renderToolbar();
assert.equal(widths.get('thread-search-pill'), 280);
assert.equal(buttonActions.has('thread-search-toggle'), false);
requestFrame();
assert.deepEqual(focus, ['search-threads']);
inputChanged('test');
assert.equal(toolbar.query, 'test');
icons.get('close-thread-search').onTap();
assert.equal(toolbar.searchOpen, false);
assert.equal(toolbar.query, '');
assert.equal(focus.at(-1), null);
inputChanged('late IME update');
assert.equal(toolbar.query, '', 'A closed field must ignore late text updates');

toolbar.setScope(false, 'project');
assert.deepEqual(toolbar.filtered().map(thread => thread.id), ['one']);
toolbar.scopeMenu();
assert.deepEqual(menuChoices.filter(item => item.selected).map(item => item.label), ['对话','Project']);
assert.ok(menuChoices.some(item => item.label === '已归档 · 3'));
renderToolbar();
icons.get('workbench-new-chat').onTap();
assert.deepEqual(newChats, ['current', 'project']);
toolbar.setScope(true, '');
assert.deepEqual(toolbar.filtered().map(thread => thread.id), ['two','old']);
toolbar.selecting = true;
toolbar.selectThread('two', true);
renderToolbar();
assert.ok(labels.includes('已选中 1 个会话'));
toolbar.selectAll();
assert.deepEqual(Array.from(toolbar.selectedIds), ['two','old']);
toolbar.selectAll();
assert.equal(toolbar.selectedIds.length, 0);
icons.get('thread-selection-cancel').onTap();
assert.equal(toolbar.selecting, false);
console.log('PASS search morph, focus and close, project scope, scoped new chat and multiselect');

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
const sidebarProps = vm.runInNewContext(ts.transpileModule(
  `(function(initial) { return initial ? (${initialProps}) : (${updatedProps}); })`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }
).outputText);
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
const NavigationPage = probe('pages/Index', 'Index', ['createChat', 'revealChat'], {t: value => value, Diagnostics: { log() {} }});
(async () => {
  let cleared = 0, drawerClosed = 0, created = 0;
  const toasts = [];
  const nav = Object.assign(new NavigationPage(), {paths: {clear(){cleared++;}, size: () => 0}, appearance: {},
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }),
    app: {canNavigate:true,active:{id:'old'},async newThread(){created++;this.active.id='new';return true;}},
    workbench:()=>({expanded:true,docked:true}),setDrawer(open){assert.equal(open,false);drawerClosed++;}});
  sidebarProps.call(nav,true).onSelected();
  assert.equal(cleared,1,'Selecting a visible conversation exits Settings');
  await nav.createChat();assert.equal(cleared,2);assert.equal(created,1);assert.equal(drawerClosed,2);
  nav.app.newThread=async()=>false;
  await nav.createChat();assert.equal(cleared,2,'Failed creation leaves the current page intact');
  assert.deepEqual(toasts, ['无法创建新对话。']);
  console.log('PASS tablet sidebar survives destinations; selection and successful new chat return to chat');
})().catch(error=>{console.error(error);process.exitCode=1;});
