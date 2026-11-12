// Exercise the real page controllers without a full ArkUI build.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const original = path.join(__dirname, '../entry/src/main/ets/pages/Index.ets');
const file = process.argv.includes('--built') ? path.join(__dirname,
  '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts') : original;
if (file !== original) assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(original).mtimeMs, 'Build Index before testing');
const source = fs.readFileSync(file, 'utf8').replace('struct Index {', 'class Index {');
const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
const cls = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Index');
const methods = ['openTools', 'openSettings', 'createChat', 'revealChat',
  'openFiles', 'openDetailTab', 'openHistorySearch', 'toggleHistory', 'setHistoryCollapsed',
  'confirmProviderDiscard', 'confirmRootNavigation', 'returnFromSettings', 'selectSettingsSection', 'swipeSettingsSection'];
const body = methods.map(name => cls.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
const globals = { exports: {}, t: text => text, $r: value => value, LaunchMode: { POP_TO_SINGLETON: 2 }, Diagnostics: { log() {} }, Motion: {} };
const categoryFile = path.join(__dirname, '../entry/src/main/ets/views/SettingsNavigation.ets');
const categoryTree = ts.createSourceFile(categoryFile, fs.readFileSync(categoryFile, 'utf8'), ts.ScriptTarget.Latest, true);
const categorySource = categoryTree.statements.filter(node => ts.isVariableStatement(node) ||
  (ts.isFunctionDeclaration(node) && node.name?.text === 'settingsCategoryForSwipe')).map(node => node.getText(categoryTree)).join('\n');
vm.runInNewContext(ts.transpileModule(categorySource, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, globals);
globals.settingsCategoryForSwipe = globals.exports.settingsCategoryForSwipe;
vm.runInNewContext(ts.transpileModule(`class Page { ${body} } exports.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, globals);
function fixture() {
  const routes = [], toasts = [], dialogs = [];
  let resets = 0;
  const page = Object.assign(new globals.exports.Page(), {
    app: { canNavigate: true, active: { id: 'chat' }, error: '', saveError: '', busy: false, providerEditor: { hasChanges: false },
      openSettings() { resets++; }, async newThread() { return true; } },
    paths: {
      getAllPathName: () => routes.map(route => route.name), size: () => routes.length,
      pushPath(route, options) {
        const at = routes.findIndex(item => item.name === route.name);
        if (options?.launchMode === 2 && at >= 0) routes.splice(at + 1);
        else routes.push(route);
      },
      clear() { routes.length = 0; }
    },
    appearance: {}, detailTabs: [], workspaceRequest: 0, historySearchRequest: 0, historyCollapsed: false,
    toolsTab: 'memory', toolsTabRequest: 0,
    setDrawer(open) { this.drawerOpen = open; }, setDetailPane(open) { this.detailPaneOpen = open; },
    workbench() { return { docked: true, canExpand: true, expanded: !this.historyCollapsed }; },
    getUIContext: () => ({ showAlertDialog(value) { dialogs.push(value); },
      animateTo(_options, update) { update(); }, getFocusController: () => ({ clearFocus() {} }),
      getPromptAction: () => ({ showToast(value) { toasts.push(value.message); } }) })
  });
  return { page, routes, toasts, dialogs, resets: () => resets };
}
test('files, search and sidebar expansion never add navigation pages', () => {
  const { page, routes } = fixture();
  page.openSettings();
  for (let i = 0; i < 20; i++) {
    page.openFiles(); page.openHistorySearch(); page.toggleHistory();
  }
  assert.deepEqual(routes.map(route => route.name), ['settings']);
  assert.deepEqual(Array.from(page.detailTabs), ['files']);
  assert.equal(page.workspaceOpen, true);
  assert.equal(page.detailPaneOpen, true);
  assert.equal(page.drawerOpen, true);
});
test('repeated sidebar tools taps require only one back', () => {
  const { page, routes } = fixture();
  for (let i = 0; i < 20; i++) page.openTools('memory');
  assert.equal(routes.length, 1);
  assert.equal(routes[0].name, 'productivity');
});
test('repeated settings taps preserve the current settings draft', () => {
  const { page, routes, resets } = fixture();
  for (let i = 0; i < 20; i++) page.openSettings();
  assert.equal(routes.length, 1);
  assert.equal(resets(), 1);
});
test('settings swipes move one category, stop at the ends and keep the settings route', () => {
  const { page, routes, resets } = fixture();
  page.openSettings();
  Object.assign(page, { settingsSection: 'models', settingsActive: true, foreground: true });
  const swipe = (offsetX, offsetY = 0) => page.swipeSettingsSection({ offsetX, offsetY });
  for (const [x, y] of [[-30, 0], [-50, 40], [15, 120]]) swipe(x, y);
  assert.equal(page.settingsSection, 'models', 'Short, diagonal and vertical gestures leave the selection in place');
  for (const section of ['assistant', 'tools', 'appearance', 'data', 'help', 'help']) {
    swipe(-80); assert.equal(page.settingsSection, section);
  }
  for (const section of ['data', 'appearance', 'tools', 'assistant', 'models', 'account', 'account']) {
    swipe(80); assert.equal(page.settingsSection, section);
  }
  assert.deepEqual(routes.map(route => route.name), ['settings']);
  assert.equal(resets(), 1);
  page.settingsActive = false;
  routes.push({ name: 'provider' });
  swipe(-80);
  assert.equal(page.settingsSection, 'account', 'Settings subpages do not react to the swipe');
  assert.equal(routes.at(-1).name, 'provider');
});
test('switching sidebar destinations reuses existing roots', () => {
  const { page, routes } = fixture();
  page.openTools('memory');
  routes.push({ name: 'productivity-editor' });
  page.openTools('memory');
  assert.deepEqual(routes.map(route => route.name), ['productivity']);
  for (let i = 0; i < 20; i++) { page.openSettings(); page.openTools('memory'); }
  assert.deepEqual(routes.map(route => route.name), ['productivity']);
});
test('returning from a settings child preserves its existing draft', () => {
  const { page, routes, resets } = fixture();
  page.openSettings();
  routes.push({ name: 'user-document' });
  page.openSettings();
  assert.deepEqual(routes.map(route => route.name), ['settings']);
  assert.equal(resets(), 1);
});
test('new chat reveals chat even when the empty conversation is reused', async () => {
  const { page, routes } = fixture();
  for (let i = 0; i < 20; i++) page.openTools('memory');
  await page.createChat();
  assert.equal(routes.length, 0);
});
test('failed new chat reports the error above the covering destination', async () => {
  const { page, routes, toasts } = fixture();
  page.openTools('memory');
  page.app.error = 'Disk write failed';
  page.app.newThread = async () => false;
  await page.createChat();
  assert.equal(routes.length, 1);
  assert.deepEqual(toasts, ['Disk write failed']);
});
test('blocked new chat reports the save error without discarding the current page', async () => {
  const { page, routes, toasts } = fixture();
  page.openTools('memory');
  page.app.canNavigate = false;
  page.app.saveError = 'Unsaved changes';
  page.app.newThread = async () => { assert.fail('Blocked creation must not run'); };
  await page.createChat();
  assert.equal(routes.length, 1);
  assert.deepEqual(toasts, ['Unsaved changes']);
});

const panelOriginal = path.join(__dirname, '../entry/src/main/ets/views/ProductivityPanel.ets');
const panelFile = file === original ? panelOriginal : path.join(path.dirname(file), '../views/ProductivityPanel.ts');
if (panelFile !== panelOriginal) assert.ok(fs.statSync(panelFile).mtimeMs >= fs.statSync(panelOriginal).mtimeMs);
const panelSource = fs.readFileSync(panelFile, 'utf8').replace('struct ProductivityPanel {', 'class ProductivityPanel {');
const panelTree = ts.createSourceFile(panelFile, panelSource, ts.ScriptTarget.Latest, true);
const panelClass = panelTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ProductivityPanel');
const panelBody = ['applyRequestedTab', 'selectTab'].map(name => panelClass.members.find(node => node.name?.getText(panelTree) === name).getText(panelTree)).join('\n');
const panelGlobals = { exports: {}, TABS: ['memory', 'mcp'] };
vm.runInNewContext(ts.transpileModule(`class Panel { ${panelBody} } exports.Panel = Panel;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, panelGlobals);
assert.match(panelSource, file === original ? /@Watch\('applyRequestedTab'\)/ : /declareWatch\(["']tabRequest["'], this.applyRequestedTab\)/);
const bindings = {};
function findBindings(node) {
  ts.forEachChild(node, findBindings);
  if (ts.isPropertyAssignment(node) && ['requestedTab', 'tabRequest'].includes(node.name.getText(tree))) {
    bindings[node.name.getText(tree)] = vm.runInNewContext(`(function() { return ${node.initializer.getText(tree)}; })`);
  }
}
findBindings(tree);
test('settings shortcuts synchronize the retained tools panel and repeated requests', () => {
  const { page, routes } = fixture();
  const indexes = [];
  const panel = Object.assign(new panelGlobals.exports.Panel(), { tab: 'memory', editorOnly: false, tabs: { changeIndex: index => indexes.push(index) } });
  const update = () => {
    panel.requestedTab = bindings.requestedTab.call(page);
    const request = bindings.tabRequest.call(page);
    if (panel.tabRequest !== request) { panel.tabRequest = request; panel.applyRequestedTab(); }
  };
  page.openTools('memory'); update();
  for (const [tab, index] of [['mcp', 1], ['memory', 0]]) {
    page.openSettings(); page.openTools(tab); update();
    assert.equal(panel.tab, tab); assert.equal(indexes.at(-1), index);
    assert.deepEqual(routes.map(route => route.name), ['productivity']);
  }
  panel.selectTab(1);
  page.openTools('memory'); update();
  assert.equal(panel.tab, 'memory', 'Repeat request must override manual tab selection');
});

for (const destination of ['settings', 'productivity']) {
  const navigate = page => destination === 'settings' ? page.openSettings() : page.openTools('mcp');
  test(`${destination} singleton reuse confirms before removing a provider draft`, () => {
    const { page, routes, dialogs } = fixture();
    routes.push({ name: destination }, { name: 'provider' }, { name: 'provider-models' });
    page.app.providerEditor.hasChanges = true;
    navigate(page);
    assert.equal(routes.length, 3);
    assert.equal(dialogs.length, 1);
    dialogs[0].primaryButton.action();
    assert.equal(routes.length, 3, 'Continue editing retains the editor and its children');
    navigate(page); dialogs[1].secondaryButton.action();
    assert.deepEqual(routes.map(route => route.name), [destination]);
  });
  test(`${destination} singleton reuse is blocked during provider operations`, () => {
    const { page, routes, dialogs } = fixture();
    routes.push({ name: destination }, { name: 'provider' });
    page.app.busy = true;
    navigate(page);
    assert.equal(routes.length, 2); assert.equal(dialogs.length, 0);
  });
}

test('opening a new root above the provider retains its draft without a discard prompt', () => {
  const { page, routes, dialogs } = fixture();
  routes.push({ name: 'settings' }, { name: 'provider' });
  page.app.providerEditor.hasChanges = true;
  page.openTools('mcp');
  assert.deepEqual(routes.map(route => route.name), ['settings', 'provider', 'productivity']);
  assert.equal(dialogs.length, 0);
});


test('tablet settings categories and return-to-chat protect unsaved provider configuration', () => {
  const {page,routes,dialogs}=fixture();page.openSettings();routes.push({name:'provider'});
  page.app.providerEditor.hasChanges=true;
  page.selectSettingsSection('appearance');assert.equal(dialogs.length,1);assert.equal(routes.length,2);
  dialogs[0].secondaryButton.action();assert.equal(page.settingsSection,'appearance');assert.equal(routes.length,1);
  routes.push({name:'provider'});page.returnFromSettings();assert.equal(dialogs.length,2);assert.equal(routes.length,2);
  dialogs[1].secondaryButton.action();assert.equal(routes.length,0);assert.equal(page.rootSection,'');
});

test('tools opened from settings retain the settings navigation; sidebar tools keep their own selection', () => {
 const {page}=fixture();page.openSettings();page.openTools('mcp');assert.equal(page.rootSection,'settings');
 page.rootSection='';page.openTools('memory');assert.equal(page.rootSection,'productivity');
});
