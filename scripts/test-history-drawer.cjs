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
for (const name of ['Alignment','Space','Font','FontWeight','TextOverflow','Color','ButtonType','Visibility','Motion',
  'Radius','SheetSize','SheetKeyboardAvoidMode']) {
  uiGlobals[name] = {};
}
const Pill = probe('common/SearchPill', 'SearchPill', ['launcher', 'initialRender'], {
  ...uiGlobals, Flex: uiGlobals.Row, FlexDirection: { Row: 'right', RowReverse: 'left' }, ItemAlign: {}, EnterKeyType: {}
});
uiGlobals.SearchPill = class extends Pill {
  constructor(parent, props) {
    super();
    Object.assign(this, props, { appearance: parent.appearance,
      observeComponentCreation2: parent.observeComponentCreation2, ifElseBranchUpdateFunction: parent.ifElseBranchUpdateFunction });
  }
};
uiGlobals.ViewPU.create = component => { if (component instanceof Pill) component.initialRender(); };
const Toolbar = probe('views/ThreadList', 'ThreadList', ['historyToolbar','scopeMenu','searchControl','searchRequested','closeSearch',
  'searchInputChanged','updateQuery','filtered','threadProject','setScope','endSelection','selectThread','selectAll','allSelected','searchHeight','modifySelection',
  'submitDeepSeekImport','deepSeekSheetClosed','importDeepSeek'],
  { ...uiGlobals, DEEPSEEK_IMPORT_GROUP: '@imported', chooseDeepSeekArchive: async () => 2 });
const focus = [], newChats = [];
let boardOpens = 0;
const toolbar = Object.assign(new Toolbar(), {
  active: true, mounted: true, foreground: true, searchOpen: false, toolbarWidth: 280, workbench: true,
  query: '', visibleCounts: {}, focusRequest: 0, searchInputRevision: 0, selecting: false, selectedIds: [], archived: false, projectFilter: null,
  appearance: {}, app: { ready: true, activeProject: { id: 'current' }, projects: [{ id: 'project', name: 'Project' }], threads: [], filteredThreads: () => [
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
const submitted = [];
const sheet = Object.assign(new Toolbar(), { mounted: true, deepSeekImportOpen: true, deepSeekLink: '  https://fixture.example/export  ',
  importDeepSeek: value => submitted.push(value), onProjectSheetVisibility: () => {} });
sheet.submitDeepSeekImport(true);
assert.equal(sheet.deepSeekImportOpen, false);
assert.deepEqual(submitted, [], 'Wait for the import sheet to close before starting the download');
assert.equal(sheet.deepSeekLink, '');
sheet.deepSeekSheetClosed();
assert.deepEqual(submitted, ['https://fixture.example/export']);
sheet.deepSeekLink = 'abandoned input';
sheet.deepSeekSheetClosed();
assert.equal(sheet.deepSeekLink, '');
assert.equal(submitted.length, 1, 'Dismissing without submitting cannot start a download');
sheet.submitDeepSeekImport(false); sheet.deepSeekSheetClosed();
assert.equal(submitted.at(-1), '', 'The same sheet can launch the local ZIP picker');
console.log('PASS DeepSeek sheet clears pasted links and starts the selected import only after closing');
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
assert.equal(toolbar.query, '', 'Search input must defer writes until the render callback returns');
icons.get('close-thread-search').onTap();
assert.equal(toolbar.searchOpen, false);
assert.equal(toolbar.query, '');
assert.equal(focus.at(-1), null);
inputChanged('late IME update');

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
toolbar.modifySelection('two', false, true, []);
assert.deepEqual(Array.from(toolbar.selectedIds), ['two']);
toolbar.modifySelection('old', true, false, ['one', 'two', 'old']);
assert.deepEqual(Array.from(toolbar.selectedIds), ['two', 'old']);
toolbar.modifySelection('two', false, true, []);
assert.deepEqual(Array.from(toolbar.selectedIds), ['old']);
toolbar.endSelection();
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
  await Promise.resolve();
  assert.equal(toolbar.query, '', 'A closed field must ignore late text updates');
  const imported = Object.assign(new Toolbar(), {
    mounted: true, archived: true, projectFilter: 'project', collapsedProjects: ['project', '@imported'],
    app: {}, appearance: {},
    getUIContext: () => ({ getHostContext: () => ({}), getPromptAction: () => ({ showToast() {} }) })
  });
  await imported.importDeepSeek('');
  assert.equal(imported.importError, '');
  assert.equal(imported.projectFilter, null, 'Successful import selects all projects');
  assert.equal(imported.archived, false);
  assert.deepEqual(Array.from(imported.collapsedProjects), ['project']);
  console.log('PASS import success shows all projects and expands only the imported group');
  let cleared = 0, drawerClosed = 0, detailClosed = 0, created = 0, destinations = 1;
  const toasts = [];
  const nav = Object.assign(new NavigationPage(), {paths: {clear(){cleared++; destinations=0;}, size: () => destinations}, appearance: {},
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }),
    app: {canNavigate:true,active:{id:'old'},async newThread(){created++;this.active.id='new';return true;}},
    workbench:()=>({expanded:true,docked:true}),setDrawer(open){assert.equal(open,false);drawerClosed++;},
    setDetailPane(open){assert.equal(open,false);detailClosed++;}});
  sidebarProps.call(nav,true).onSelected();
  assert.equal(cleared,1,'Selecting a visible conversation exits Settings');
  await nav.createChat();assert.equal(cleared,1);assert.equal(created,1);assert.equal(drawerClosed,2);
  nav.app.newThread=async()=>false;
  await nav.createChat();assert.equal(drawerClosed,2,'Failed creation leaves the current page intact');
  assert.deepEqual(toasts, ['无法创建新对话。']);
  nav.workbench = () => ({ expanded: false, docked: false });
  nav.revealChat(); assert.equal(detailClosed, 0, 'Keep a hidden detail pane out of the history close animation');
  nav.detailPaneOpen = true;
  nav.revealChat(); assert.equal(detailClosed, 1);
  console.log('PASS tablet sidebar survives destinations; selection and successful new chat return to chat');
})().catch(error=>{console.error(error);process.exitCode=1;});
