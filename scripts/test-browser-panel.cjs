// Run after devecocli build; exercise the actual emitted address callbacks and system-back handler.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
function emitted(relative) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing ' + relative);
  return ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
}
const panelTree = emitted('views/BrowserPanel'), handlers = {};
function visit(node) {
  if (ts.isCallExpression(node)) {
    const name = node.expression.getText(panelTree);
    if (['TextInput.onFocus', 'TextInput.onBlur', 'TextInput.onChange', 'TextInput.create', 'Web.onPageEnd'].includes(name)) handlers[name] = node.arguments[0].getText(panelTree);
  }
  ts.forEachChild(node, visit);
}
visit(panelTree);
const indexTree = emitted('pages/Index');
const index = indexTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'Index');
const back = index.members.find(n => n.name?.getText(indexTree) === 'onBackPress').body.getText(indexTree);
const panelClass = panelTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'BrowserPanel');
const navigate = panelClass.members.find(n => n.name?.getText(panelTree) === 'navigate').body.getText(panelTree);
const compiled = {};
vm.runInNewContext(ts.transpileModule(`export function callbacks() {
  return { focus: ${handlers['TextInput.onFocus']}, blur: ${handlers['TextInput.onBlur']},
    change: ${handlers['TextInput.onChange']}, loaded: ${handlers['Web.onPageEnd']}, display: () => (${handlers['TextInput.create']}).text };
}
export function back() ${back}
export function navigate() ${navigate}`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
  { exports: compiled, t: value => value, validateWebAddress: value => value });
const browser = { url: 'https://example.com/', editingAddress: false, takeovers: 0, takeOver() { this.takeovers++; } };
let navigated;
const panel = { browser, address: '', addressDirty: false,
  driver: { userNavigate(url) { navigated = url; }, pageEnd(url) { browser.url = url; } },
  getUIContext() { return { getFocusController() { return { clearFocus() { browser.editingAddress = false; } }; } }; } },
  events = compiled.callbacks.call(panel);
events.change(browser.url);
assert.equal(browser.takeovers, 0, 'Programmatic URL updates must not take control');
events.focus(); assert.equal(events.display(), browser.url);
events.change(browser.url); assert.equal(browser.takeovers, 0, 'Focus and unchanged values remain viewing');
events.blur(); assert.equal(browser.takeovers, 0);
browser.url = 'https://example.com/redirect'; events.change(browser.url);
assert.equal(browser.takeovers, 0, 'Redirects while not editing remain viewing');
events.focus(); events.change('');
assert.equal(browser.takeovers, 1, 'Real editing takes control');
assert.equal(events.display(), '', 'Clearing an address must not restore the old URL');
events.blur(); assert.equal(events.display(), '', 'Blur preserves an unsent empty draft');
events.focus(); assert.equal(events.display(), '', 'Refocusing does not replace the draft');
events.change('https://example.com/edited'); events.blur(); compiled.navigate.call(panel);
assert.equal(navigated, 'https://example.com/edited', 'The Go button must use the draft even after blur');
events.loaded({ url: navigated }); assert.equal(panel.addressDirty, false); assert.equal(events.display(), navigated);
let backwards = 0, collapsed = 0, cleared = 0;
const view = { browserExpanded: true, browser: { editingAddress: false, owner: 'agent', userBack() { backwards++; return true; } },
  setBrowserExpanded() { collapsed++; }, getUIContext() { return { getFocusController() { return { clearFocus() { cleared++; } }; } }; } };
assert.equal(compiled.back.call(view), true); assert.equal(backwards, 0); assert.equal(collapsed, 1);
view.browser.owner = 'user'; compiled.back.call(view);
assert.equal(backwards, 1); assert.equal(collapsed, 1, 'User history is navigated before collapsing');
view.browser.userBack = () => false; compiled.back.call(view);
assert.equal(collapsed, 2, 'At the start of history, back collapses the viewer');
view.browser.editingAddress = true; compiled.back.call(view);
assert.equal(cleared, 1); assert.equal(collapsed, 2, 'Back dismisses address editing before navigation');
console.log('PASS emitted browser address callbacks: programmatic changes/focus/copy keep control, editing and empty drafts work');
console.log('PASS emitted system back: dismiss editing, navigate user history, collapse agent viewing without takeover');
