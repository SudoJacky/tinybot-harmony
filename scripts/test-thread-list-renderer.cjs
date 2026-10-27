// Run after devecocli build. Retain keyed groups and execute the actual emitted update callbacks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.join(root, 'entry/src/main/ets/views/ThreadList.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ThreadList.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const cls = name => tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
let mount, saveProject;
const rowUpdates = [];
let checkboxUpdate, rowClick;
function visit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'this.observeComponentCreation2' &&
      node.arguments[1]?.getText(tree) === 'ForEach' && node.arguments[0].getText(tree).includes('ListItemGroup.create')) mount = node.getText(tree);
  ts.forEachChild(node, visit);
}
visit(cls('ThreadList')); assert.ok(mount, 'Locate the actual project list renderer');
function editorVisit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'Button.onClick') saveProject = node.arguments[0].getText(tree);
  ts.forEachChild(node, editorVisit);
}
editorVisit(cls('ThreadList').members.find(n => n.name?.getText(tree) === 'projectEditor'));
function rowVisit(node) {
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'this.observeComponentCreation2' &&
    node.arguments[1]?.getText(tree) === 'Text' && node.arguments[0].getText(tree).includes('Text.create(this.thread.displayTitle)')) rowUpdates.push(node.getText(tree));
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'this.observeComponentCreation2' &&
    node.arguments[1]?.getText(tree) === 'Checkbox') checkboxUpdate = node.getText(tree);
  if (ts.isCallExpression(node) && node.expression.getText(tree) === 'Row.onClick' &&
    node.arguments[0].getText(tree).includes('this.onSelectionChanged')) rowClick = node.arguments[0].getText(tree);
  ts.forEachChild(node, rowVisit);
}
rowVisit(cls('ThreadRow')); assert.equal(rowUpdates.length, 1);
assert.ok(checkboxUpdate && rowClick, 'Locate real checkbox and selection click callbacks');
let serial = 0, current, initial;
const effects = new Map(), lists = new Map(), branches = new Map(), texts = new Map(), groups = new Set(), readers = new Set(), menuItems = new Map();
let checkboxSelected, checkboxChange;
class ViewPU {
  finalizeConstruction() {}
  observeComponentCreation2(callback) { const id = ++serial; effects.set(id, callback); this.run(id, true); }
  run(id, first) { const before = [current, initial]; current = id; initial = first; effects.get(id)(id, first); [current, initial] = before; }
  forEachUpdateFunction(id, items, create, key) {
    const previous = lists.get(id) || []; const next = items.map((item, i) => key(item, i));
    lists.set(id, next); items.forEach((item, i) => { if (!previous.includes(next[i])) create(item, i); });
  }
  ifElseBranchUpdateFunction(branch, create) { if (branches.get(current) !== branch) { branches.set(current, branch); create(); } }
  updateStateVarsOfChildByElmtId() {}
  static create() {}
  flush() { for (const id of [...effects.keys()]) if (readers.has(id)) this.run(id, false); }
}
const noop = new Proxy({}, { get: () => () => {} });
const globals = { exports: {}, ViewPU, ObservedObject: { GetRawObject: value => value }, t: key => key, Motion: {}, Space: {}, Btn: {}, AppMaterials: {},
  IconButton: class {}, SymbolGlyphModifier: class { fontColor() { return this; } }, Context: noop,
  TransitionEffect: { OPACITY: { animation() { return this; } } },
  ListItemGroup: { create(options) { if (initial) { groups.add(current); options.header(); } }, pop() {} },
  Text: new Proxy({}, { get: (_, key) => key === 'create' ? value => texts.set(current, value) : () => {} }) };
for (const name of ['ForEach','If','ListItem','Row','Stack','SymbolGlyph','Button','Menu','MenuItem']) globals[name] = noop;
globals.MenuItem = new Proxy({}, { get: (_, key) => key === 'create' ? value => menuItems.set(current, value) : () => {} });
for (const name of ['ButtonType','Color','Alignment','FontWeight','TextOverflow','Visibility']) globals[name] = {};
globals.CheckBoxShape = {};
globals.Checkbox = new Proxy({}, { get: (_, key) => key === 'select' ? value => { checkboxSelected = value; } :
  key === 'onChange' ? callback => { checkboxChange = callback; } : () => {} });
const names = ['filtered','sections','sectionThreads','sectionTitle','groupOpen','visibleCount','onActivePath','lastBranch','loadMore','toggleGroup','sectionHeader','projectActions',
  'locked','endSelection','selectThread','allSelected','selectAll','archiveSelected','confirmDeleteSelected'];
vm.runInNewContext(ts.transpileModule(`${cls('ThreadSection').getText(tree)}
class Sidebar extends ViewPU { ${cls('ThreadList').members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')}
mount() { ${mount}; } saveFromEditor() { return (${saveProject})(); } }
class RowProbe extends ViewPU {
${cls('ThreadRow').members.filter(n => ['active', 'actions', 'locked'].includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')}
mount() { ${rowUpdates.join(';')}; this.actions(); }
mountSelection() { ${checkboxUpdate}; } selectFromRow() { return (${rowClick})(); }
}
exports.Sidebar = Sidebar; exports.RowProbe = RowProbe;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let content = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) content += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(content, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText,
    { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
      if (id === '@ohos/hypium') return {};
      if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file }); return exports;
}
const { Fixture, seed } = load(path.join(root, 'entry/src/test/SessionService.test'));
const { ChatViewModel } = load(path.join(root, 'entry/src/main/ets/viewmodel/ChatViewModel'));
(async () => {
  const data = seed();
  data.projects = [{ id: 'project', name: 'Original project', instructions: '', workspaceId: 'project-workspace', createdAt: 1, updatedAt: 1 }];
  data.threads = ['one','two','three'].map((id, i) => ({ ...data.threads[0], id, titleEdited: true, updatedAt: 3-i }));
  data.activeThreadId = 'three';
  const f = new Fixture(data), app = new ChatViewModel(); await app.initialize(f.session);
  const observedApp = new Proxy(app, { get(target, key, receiver) {
    if (current !== undefined && ['threads','projects','active'].includes(key)) readers.add(current);
    return Reflect.get(target, key, receiver);
  } });
  const sidebar = Object.assign(new globals.exports.Sidebar(), { app: observedApp, appearance: { fontFamily: 'system' }, query: '', archived: false, visibleCounts: {}, collapsedProjects: [] });
  sidebar.selecting = false; sidebar.selectedIds = [];
  sidebar.mount(); const groupIds = [...groups];
  const countId = [...texts].find(([, value]) => value === '3')[0];
  const rowListId = [...lists].find(([, ids]) => ids.includes('one'))[0];
  const rows = () => Array.from(lists.get(rowListId));
  assert.deepEqual(rows(), ['one','two','three']);
  const row = Object.assign(new globals.exports.RowProbe(), { app: observedApp, appearance: { fontFamily: 'system' }, thread: new Proxy(app.threads.find(t => t.id === 'three'), {
    get(target, key, receiver) { if (current !== undefined) readers.add(current); return Reflect.get(target, key, receiver); }
  }) });
  row.mount(); const titleId = [...texts].find(([, value]) => value === 'Test')[0];
  const pinMenuId = [...menuItems].find(([, value]) => value.content === '置顶')[0];
  assert.equal(await app.renameThread('three', 'Renamed chat'), true); sidebar.flush();
  assert.equal(texts.get(titleId), 'Renamed chat', 'Retained row must display renamed title immediately');
  assert.equal(await app.deleteThread('one'), true); sidebar.flush();
  assert.deepEqual(rows(), ['two','three'], 'Deleting must remove the retained row without switching tabs');
  assert.equal(texts.get(countId), '2', 'Counts must immediately follow membership changes');
  assert.equal(await app.archiveThread('two'), true); sidebar.flush();
  assert.deepEqual(rows(), ['three'], 'Archiving must immediately remove the row');
  assert.equal(await app.archiveThread('two'), true); sidebar.flush();
  assert.deepEqual(rows(), ['two','three'], 'Restoring must immediately reinsert the row');
  assert.equal(await app.pinThread('three'), true); sidebar.flush();
  assert.deepEqual(rows(), ['three','two'], 'Pinning must reorder the retained group');
  assert.equal(menuItems.get(pinMenuId).content, '取消置顶', 'Menu must reflect the new pinned state');
  assert.equal(await app.pinThread('three'), true); sidebar.flush();
  assert.deepEqual(rows(), ['two','three'], 'Unpinning must restore chronological order');
  assert.equal(menuItems.get(pinMenuId).content, '置顶');
  assert.equal(await app.newThread(''), true); sidebar.flush();
  assert.ok(rows().includes(app.active.id), 'New chats must appear in the retained group');
  assert.equal(await app.saveProject('Renamed project', '', 'project'), true); sidebar.flush();
  assert.ok([...texts.values()].includes('Renamed project'), 'Project headers must read current names');
  assert.deepEqual([...groups], groupIds, 'Updates must preserve group identity and collapse state');
  sidebar.query = 'no matches'; sidebar.archived = true;
  sidebar.projectId = ''; sidebar.projectName = 'Created from filtered view'; sidebar.projectInstructions = '';
  sidebar.projectEditing = true; sidebar.projectFolders = [];
  await sidebar.saveFromEditor(); sidebar.flush();
  const projectId = app.active.projectId;
  assert.ok(projectId && projectId !== 'project');
  assert.equal(sidebar.archived, false, 'New projects must be revealed outside the archived filter');
  assert.equal(sidebar.query, '', 'New projects must not remain hidden by a previous search');
  assert.equal(sidebar.projectEditing, false);
  assert.ok([...texts.values()].includes('Created from filtered view'));
  assert.ok([...lists.values()].some(ids => ids.includes(app.active.id)), 'New project must immediately contain its starter chat');
  assert.equal(groups.size, groupIds.length + 1, 'Only the new project mounts; existing groups remain');
  sidebar.query = 'Renamed chat'; sidebar.archived = true;
  sidebar.projectId = projectId; sidebar.projectName = 'Edited project'; sidebar.projectEditing = true;
  await sidebar.saveFromEditor();
  assert.equal(sidebar.query, 'Renamed chat', 'Editing a project must preserve filters');
  assert.equal(sidebar.archived, true);
  assert.equal(app.error, '');
  const widgetSource = path.join(root, 'entry/src/main/ets/common/Widgets.ets');
  const widgetEmitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/common/Widgets.ts');
  assert.ok(fs.statSync(widgetEmitted).mtimeMs >= fs.statSync(widgetSource).mtimeMs, 'Build Widgets before testing');
  const widgetTree = ts.createSourceFile(widgetEmitted, fs.readFileSync(widgetEmitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const icon = widgetTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'IconButton');
  let accessibilityLabel, buttonBackground, buttonBorder, buttonAnimation, backgroundAnimation;
  const materialAttributes = { exports: {} };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,
    'entry/src/main/ets/common/MaterialAttributes.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, materialAttributes);
  class Property {
    constructor(value) { this.value = value; }
    get() { if (current !== undefined) readers.add(current); return this.value; }
    set(value) { this.value = value; }
    reset(value) { this.value = value; }
  }
  const widgets = { ...globals, exports: {}, Color: { Transparent: 'transparent' },
    Context: { animation: value => { buttonAnimation = value; } },
    systemMaterialAttribute: materialAttributes.exports.systemMaterialAttribute,
    AppearanceStyle: class { controlBackground = 'transparent'; materialAvailable = true; },
    ViewPU: class extends ViewPU { createStorageProp(_key, value) { return new Property(value); } },
    SynchedPropertySimpleOneWayPU: Property, SynchedPropertyObjectOneWayPU: Property, ObservedObject: { GetRawObject: v => v },
    Button: new Proxy({}, { get: (_, key) => key === 'accessibilityText' ? value => { accessibilityLabel = value; } :
      key === 'backgroundColor' ? value => { buttonBackground = value; backgroundAnimation = buttonAnimation; } :
      key === 'border' ? value => { buttonBorder = value; } : () => {} }) };
  vm.runInNewContext(ts.transpileModule(icon.getText(widgetTree), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText, widgets);
  const button = new widgets.exports.IconButton(undefined, { label: '新对话 · Original' }); button.initialRender();
  assert.equal(accessibilityLabel, '新对话 · Original');
  assert.equal(buttonBackground, 'transparent', 'Supported devices retain the material background');
  assert.ok(backgroundAnimation, 'Material-capable devices retain their existing color animation');
  assert.equal(buttonBorder.width, 0);
  button.appearance = { controlBackground: 'plain-control', materialAvailable: false }; button.flush();
  assert.equal(buttonBackground, 'plain-control', 'API 20 circular buttons have an opaque background');
  assert.equal(backgroundAnimation, null, 'API 20 repaint applies explicit fills without interpolating native theme defaults');
  assert.equal(buttonBorder.width, 0.5, 'A thin outline preserves the circle on similar page colors');
  button.updateStateVars({ icon: button.icon, tint: button.tint, fill: '#216451', disabled: false, label: button.label }); button.flush();
  assert.equal(buttonBackground, '#216451', 'Explicit primary/action fills remain intact');
  assert.equal(buttonBorder.width, 0);
  button.updateStateVars({ icon: button.icon, tint: button.tint, fill: button.fill, disabled: false, label: '新对话 · Renamed' }); button.flush();
  assert.equal(accessibilityLabel, '新对话 · Renamed', 'Retained project buttons must update their accessibility names');
  console.log('PASS retained sidebar: rename, pin/unpin labels and ordering, delete/archive/restore, new chat, project create/edit and filtered-view creation');

  const batchData = seed();
  batchData.threads = Array.from({ length: 25 }, (_, i) => ({ ...batchData.threads[0], id: 'batch-' + i, title: i < 2 ? 'Match' : 'Other', draft: '' }));
  batchData.activeThreadId = 'batch-0';
  const batch = new Fixture(batchData), batchApp = new ChatViewModel(); await batchApp.initialize(batch.session);
  const selection = Object.assign(new globals.exports.Sidebar(), { app: batchApp, appearance: { fontFamily: 'system' }, query: '', archived: false,
    selecting: true, selectedIds: [], visibleCounts: {}, collapsedProjects: [''] });
  selection.selectAll();
  assert.equal(selection.selectedIds.length, 25, 'Select all includes collapsed groups and unloaded rows');
  selection.selectAll(); assert.equal(selection.selectedIds.length, 0);
  selection.query = 'Match'; selection.selectAll();
  assert.deepEqual(Array.from(selection.selectedIds), ['batch-0', 'batch-1'], 'Select all respects search');
  const selectionRow = Object.assign(new globals.exports.RowProbe(), { app: batchApp, appearance: { fontFamily: 'system' }, thread: batchApp.threads[0], selecting: true,
    onSelectionChanged: value => selection.selectThread('batch-0', value) });
  Object.defineProperty(selectionRow, 'selected', { get() { if (current !== undefined) readers.add(current); return selection.selectedIds.includes('batch-0'); } });
  selectionRow.mountSelection(); assert.equal(checkboxSelected, true);
  await selectionRow.selectFromRow(); selectionRow.flush();
  assert.equal(checkboxSelected, false, 'Tapping a selected row updates its retained checkbox');
  assert.equal(batchApp.active.id, 'batch-0', 'Selection never navigates away');
  checkboxChange(true); selectionRow.flush(); assert.equal(checkboxSelected, true);
  await selection.archiveSelected();
  assert.equal(selection.selecting, false); assert.equal(selection.selectedIds.length, 0);
  assert.equal(batchApp.filteredThreads('Match', false).length, 0);
  assert.equal(batchApp.filteredThreads('Match', true).length, 2);
  assert.ok(!['batch-0', 'batch-1'].includes(batchApp.active.id));
  selection.archived = true; selection.selecting = true; selection.selectAll(); await selection.archiveSelected();
  assert.equal(batchApp.filteredThreads('Match', false).length, 2, 'Archive tab batch action restores selected chats');
  selection.archived = false; selection.selecting = true; selection.selectAll();
  const selectedBeforeFailure = Array.from(selection.selectedIds), savedBeforeFailure = batch.repository.saved;
  batch.repository.beforeSave = async () => { throw Error('batch save failure'); };
  await selection.archiveSelected();
  assert.equal(selection.selecting, true); assert.deepEqual(Array.from(selection.selectedIds), selectedBeforeFailure);
  assert.equal(batch.repository.saved, savedBeforeFailure);
  batch.repository.beforeSave = async () => {};
  let dialog;
  selection.getUIContext = () => ({ showAlertDialog: value => { dialog = value; } });
  selection.confirmDeleteSelected();
  assert.ok(dialog); assert.equal(batchApp.filteredThreads('Match', false).length, 2, 'Delete requires confirmation');
  dialog.primaryButton.action(); assert.equal(batchApp.filteredThreads('Match', false).length, 2, 'Cancelling keeps chats');
  await dialog.secondaryButton.action();
  assert.equal(batchApp.filteredThreads('Match', false).length, 0); assert.equal(selection.selecting, false);
  assert.equal(batchApp.threads.length, 23);
  console.log('PASS batch selection: retained checkbox, row taps, filtered/all/unloaded selection, archive, restore, delete confirmation and retry after save failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
