// Build first. Exercise the emitted page methods and actual bindSheet callbacks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'entry/src/main/ets/views/UsagePanel.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/UsagePanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build UsagePanel before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'UsagePanel');
const names = ['openFilter', 'closeFilter', 'filterDidClose', 'chooseFilter', 'filterOptions', 'moveFilter', 'aboutToDisappear'];
const methods = names.map(name => component.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
let sheetCall;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'List.bindSheet') sheetCall = node.getText(tree);
  ts.forEachChild(node, visit);
}
visit(component);
assert.ok(sheetCall);
let binding;
const sandbox = { exports: {}, clearTimeout, SheetSize: { FIT_CONTENT: 0 }, List: {
  bindSheet: (visible, builder, options) => { binding = { visible, options }; }
} };
vm.runInNewContext(ts.transpileModule(`class Page { ${methods}
  bind() { ${sheetCall}; }
} exports.Page = Page;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, sandbox);
function page() {
  return Object.assign(new sandbox.exports.Page(), {
    mounted: true, showFilter: false, filterClosing: false, pendingFilter: '', filterKind: 'provider',
    provider: '', model: '', threadFilter: '', providers: ['service'], models: ['model'], sessionOptions: [{ key: 'thread' }],
    appearance: {}, filterTitle() { return this.filterKind; }, filterSheet() {}, filter() { this.refreshes++; },
    refreshes: 0, generation: 0, detailGeneration: 0, refreshTimer: -1
  });
}
const live = page();
live.openFilter('provider'); live.bind();
assert.equal(binding.visible, true, 'one-way binding prevents a departing sheet from writing into a newer opening');
const firstSheet = binding.options;
firstSheet.onWillDismiss(); live.openFilter('model');
assert.equal(live.showFilter, false, 'the old sheet finishes dismissing before the next opening');
assert.equal(live.filterKind, 'provider', 'closing content keeps its original option meanings');
firstSheet.onDisappear(); live.bind();
assert.equal(binding.visible, true); assert.equal(live.filterKind, 'model');
assert.equal(live.filterItems.join(','), ',model');
binding.options.onWillDismiss(); live.openFilter('provider'); live.openFilter('thread');
binding.options.onDisappear(); live.bind();
assert.equal(live.filterKind, 'thread', 'the latest requested filter wins while dismissing');
assert.equal(binding.visible, true);
live.chooseFilter('thread');
assert.equal(live.threadFilter, 'thread'); assert.equal(live.refreshes, 1); assert.equal(live.showFilter, false);
live.openFilter('provider'); binding.options.onDisappear(); live.bind();
assert.equal(live.filterKind, 'provider'); assert.equal(binding.visible, true);
binding.options.onWillDismiss(); binding.options.onDisappear();
assert.equal(live.showFilter, false, 'outside/back/close dismissal stays closed without a pending request');
live.openFilter('provider'); live.bind(); binding.options.onWillDismiss(); live.openFilter('model');
live.aboutToDisappear(); binding.options.onDisappear();
assert.equal(live.showFilter, false, 'leaving the page cancels any queued opening');
assert.equal(live.pendingFilter, '');
console.log('PASS emitted filter sheet: rapid switching, latest request, selection, dismissal and page disposal');
