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
const methods = ['openTools', 'openSettings', 'openMiniApps', 'createChat', 'revealChat',
  'openFiles', 'openDetailTab', 'openHistorySearch', 'toggleHistory', 'setHistoryCollapsed'];
const body = methods.map(name => cls.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
const globals = { exports: {}, t: text => text, LaunchMode: { POP_TO_SINGLETON: 2 }, Diagnostics: { log() {} }, Motion: {} };
vm.runInNewContext(ts.transpileModule(`class Page { ${body} } exports.Page = Page;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, globals);
// Follow the actual sidebar binding so an inline push cannot bypass the controller guard.
const miniAppsCallbacks = [];
const miniAppsMenuCallbacks = [];
let miniAppsMenu = false;
function visit(node) {
  ts.forEachChild(node, visit);
  if (ts.isPropertyAssignment(node) && node.name.getText(tree) === 'onMiniApps') {
    miniAppsCallbacks.push(node.initializer.getText(tree));
  }
  if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
    if (node.expression.name.text === 'id' && node.arguments[0]?.text === 'open-mini-apps-menu') miniAppsMenu = true;
    if (miniAppsMenu && node.expression.name.text === 'onClick') {
      miniAppsMenuCallbacks.push(node.arguments[0].getText(tree));
      miniAppsMenu = false;
    }
  }
}
visit(tree);
assert.ok(miniAppsCallbacks.length > 0, 'Find the sidebar mini-app entry');
const miniAppsCallback = vm.runInNewContext(`(function() { return (${miniAppsCallbacks[0]}); })`);
assert.equal(miniAppsMenuCallbacks.length, 1, 'Find the mini-app entry in the more menu');
const miniAppsMenuCallback = vm.runInNewContext(`(function() { return (${miniAppsMenuCallbacks[0]}); })`);
function fixture() {
  const routes = [], toasts = [];
  let resets = 0;
  const page = Object.assign(new globals.exports.Page(), {
    app: { canNavigate: true, active: { id: 'chat' }, error: '', saveError: '',
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
    setDrawer(open) { this.drawerOpen = open; }, setDetailPane(open) { this.detailPaneOpen = open; },
    workbench() { return { docked: true, canExpand: true, expanded: !this.historyCollapsed }; },
    getUIContext: () => ({ animateTo(_options, update) { update(); }, getFocusController: () => ({ clearFocus() {} }),
      getPromptAction: () => ({ showToast(value) { toasts.push(value.message); } }) })
  });
  return { page, routes, toasts, resets: () => resets };
}
test('repeated taps on the actual sidebar mini-app entry keep one page', () => {
  const { page, routes } = fixture();
  const click = miniAppsCallback.call(page);
  for (let i = 0; i < 20; i++) click();
  assert.deepEqual(routes.map(route => route.name), ['mini-apps']);
  assert.equal(page.drawerOpen, false);
});
test('alternating all sidebar page entries cannot accumulate duplicate pages', () => {
  const { page, routes } = fixture();
  const click = miniAppsCallback.call(page);
  for (let i = 0; i < 20; i++) {
    click(); page.openTools('memory'); page.openSettings();
    assert.equal(routes.length, 3);
    assert.equal(new Set(routes.map(route => route.name)).size, 3);
  }
  click();
  assert.deepEqual(routes.map(route => route.name), ['mini-apps']);
});
test('sidebar and more-menu mini-app callbacks reuse the same page', () => {
  const { page, routes } = fixture();
  const sidebar = miniAppsCallback.call(page), menu = miniAppsMenuCallback.call(page);
  for (let i = 0; i < 20; i++) { sidebar(); menu(); }
  assert.deepEqual(routes.map(route => route.name), ['mini-apps']);
});
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
