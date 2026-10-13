// Run after devecocli build. Exercise emitted ArkUI callbacks with keyed reuse.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src/main/ets');
const source = root + '/views/CustomToolsPanel.ets';
const emitted = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/CustomToolsPanel.ts');
assert.ok(fs.existsSync(emitted) && fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build CustomToolsPanel before this test.');
const groups = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(root + '/model/ToolGroups.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: groups });
let serial = 0, current;
class Property { constructor(value) { this.value = value; } get() { return this.value; } set(value) { this.value = value; } }
class ViewPU {
  constructor(parent, storage, id) { this.parent = parent; this.id = id; this.effects = new Map(); this.children = new Map(); this.lists = new Map(); this.branches = new Map(); }
  finalizeConstruction() {}
  observeComponentCreation2(callback) { const id = ++serial; this.effects.set(id, callback); this.currentElmt = id; current = this; callback(id, true); }
  forEachUpdateFunction(id, items, create, key) {
    const old = this.lists.get(id) || new Set(), next = new Set();
    items.forEach((item, index) => { const identity = key(item, index); next.add(identity); if (!old.has(identity)) create(item, index); }); this.lists.set(id, next);
  }
  ifElseBranchUpdateFunction(branch, create) { const id = this.currentElmt; if (this.branches.get(id) !== branch) { this.branches.set(id, branch); create(); } }
  updateStateVarsOfChildByElmtId(id, params) { Object.assign(this.children.get(id), params); }
  static create(child) { child.parent.children.set(child.id, child); if (child instanceof GroupCard) child.content(); }
  flush() { for (const [id, effect] of [...this.effects]) { this.currentElmt = id; current = this; effect(id, false); } }
}
class Child extends ViewPU { constructor(parent, params, storage, id) { super(parent, storage, id); Object.assign(this, params); } }
class GroupCard extends Child {}
class SwitchRow extends Child {}
const buttons = new Map(), texts = new Map();
const ui = kind => new Proxy({}, { get: (_, name) => value => {
  if (kind === 'Text' && name === 'create') texts.set(current.currentElmt, value);
  if (kind === 'Button') {
    let button = buttons.get(current.currentElmt); if (!button) { button = {}; buttons.set(current.currentElmt, button); }
    if (['id', 'onClick', 'enabled'].includes(name)) button[name] = value;
  }
} });
const globals = { exports: {}, ViewPU, SynchedPropertyNesedObjectPU: Property, BarState: {},
  require: id => {
    if (id.includes('I18n&')) return { t: (text, values) => values ? text + ':' + values.join('/') : text };
    if (id.includes('ToolGroups&')) return groups;
    if (id.includes('ToolPresentation&')) return { toolTitle: name => name, toolGroupTitle: name => name };
    if (id.includes('Widgets&')) return { GroupCard, SwitchRow, SectionHeader: Child, RowDivider: Child };
    if (id.includes('Theme&')) return { Btn: {}, Font: {}, Space: {} };
    throw Error('Unexpected import ' + id);
  }
};
for (const kind of ['Scroll', 'Column', 'Row', 'Text', 'Button', 'ForEach', 'If']) globals[kind] = ui(kind);
vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
const thread = { disabledTools: [], archived: false }, app = { busy: false, saveError: '',
  setToolEnabled: async (name, enabled) => { thread.disabledTools = thread.disabledTools.filter(item => item !== name); if (!enabled) thread.disabledTools.push(name); },
  setDisabledTools: async names => { thread.disabledTools = Array.from(names); }
};
const panel = new globals.exports.CustomToolsPanel(undefined, { app, thread }); panel.initialRender();
const rows = () => [...panel.children.values()].filter(child => child instanceof SwitchRow);
const row = name => rows().find(child => child.compId === 'custom-tool-' + name);
const button = id => [...buttons.values()].find(value => value.id === id);
(async () => {
  assert.equal(rows().length, 35);
  for (const name of groups.BASIC_FILE_TOOLS) { assert.equal(row(name), undefined); }
  assert.ok([...texts.values()].includes(Array.from(groups.BASIC_FILE_TOOLS).join('、')), 'mandatory tools use a compact read-only summary');
  const retained = row('read_web'); await retained.onChange(false); panel.flush();
  assert.equal(row('read_web'), retained); assert.equal(retained.isOn, false); assert.ok(thread.disabledTools.includes('read_web'));
  assert.ok([...texts.values()].some(text => text.endsWith(':34/35')));
  await retained.onChange(true); panel.flush(); assert.equal(retained.isOn, true);
  await button('disable-optional-tools').onClick(); panel.flush();
  assert.equal(thread.disabledTools.length, 35); assert.ok(rows().every(child => !child.isOn));
  await button('enable-optional-tools').onClick(); panel.flush(); assert.equal(thread.disabledTools.length, 0);
  app.busy = true; panel.flush(); assert.ok(rows().every(child => child.disabled)); assert.equal(button('enable-optional-tools').enabled, false);
  app.busy = false; thread.archived = true; panel.flush(); assert.ok(rows().every(child => child.disabled));
  thread.archived = false; app.saveError = 'save failed'; panel.flush(); assert.ok(rows().every(child => child.disabled));
  console.log('PASS emitted 35 keyed optional rows, compact mandatory files, on/off updates, enabled count, bulk controls and busy/archive/save-error restrictions');
})().catch(error => { console.error(error); process.exitCode = 1; });
