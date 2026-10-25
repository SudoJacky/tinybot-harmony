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
const mode = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(root + '/model/AgentMode.ets', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: mode, require: id => id.includes('ToolGroups') ? groups : { t: text => text } });
let serial = 0, current;
class Property { constructor(value) { this.value = value; } get() { return this.value; } set(value) { this.value = value; } }
class ViewPU {
  constructor(parent, storage, id) { this.parent = parent; this.id = id; this.effects = new Map(); this.children = new Map(); this.lists = new Map(); this.branches = new Map(); }
  finalizeConstruction() {}
  createStorageProp() { return new Property({ fontFamily: '' }); }
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
class NavRow extends Child {}
const buttons = new Map(), texts = new Map();
const ui = kind => new Proxy({}, { get: (_, name) => value => {
  if (kind === 'Text' && name === 'create') texts.set(current.currentElmt, value);
  if (kind === 'Button') {
    let button = buttons.get(current.currentElmt); if (!button) { button = {}; buttons.set(current.currentElmt, button); }
    if (['id', 'onClick', 'enabled'].includes(name)) button[name] = value;
  }
} });
const globals = { exports: {}, ViewPU, SynchedPropertyNesedObjectPU: Property, ObservedPropertySimplePU: Property, BarState: {},
  require: id => {
    if (id.includes('I18n&')) return { t: (text, values) => values ? text + ':' + values.join('/') : text };
    if (id.includes('ToolGroups&')) return groups;
    if (id.includes('AgentMode&')) return mode;
    if (id.includes('ToolPresentation&')) return { toolTitle: name => name, toolGroupTitle: name => name, toolCapabilityDescription: name => 'Description: ' + name };
    if (id.includes('Widgets&')) return { GroupCard, SwitchRow, NavRow, SectionHeader: Child, RowDivider: Child };
    if (id.includes('Theme&')) return { Btn: {}, Font: {}, Space: {} };
    if (id.includes('AppearanceStyle&')) return { AppearanceStyle: class {} };
    throw Error('Unexpected import ' + id);
  }
};
for (const kind of ['Scroll', 'Column', 'Row', 'Text', 'Button', 'ForEach', 'If', 'Blank', '__Common__']) globals[kind] = ui(kind);
vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
const thread = { agentMode: 'custom', disabledTools: [], archived: false }, app = { busy: false, saveError: '',
  setToolEnabled: async (name, enabled) => {
    const members = groups.TOOL_CAPABILITIES.find(capability => capability.tools.includes(name)).tools;
    thread.disabledTools = thread.disabledTools.filter(item => !members.includes(item));
    if (!enabled) thread.disabledTools.push(...members);
  },
  setDisabledTools: async names => { thread.disabledTools = Array.from(mode.normalizeDisabledTools(names)); }
};
const panel = new globals.exports.CustomToolsPanel(undefined, { app, thread }); panel.initialRender();
const rows = () => [...panel.children.values()].filter(child => child instanceof SwitchRow);
const row = name => rows().find(child => child.compId === 'custom-capability-' + name);
const button = id => [...buttons.values()].find(value => value.id === id);
(async () => {
  assert.equal(rows().length, 12);
  for (const name of ['memory','skill-read','skill-manage','image']) assert.equal(row(name),undefined);
  assert.equal(button('enable-optional-tools').enabled,false);
  assert.equal(button('disable-optional-tools').enabled,true);
  for (const name of groups.BASIC_FILE_TOOLS) { assert.equal(row(name), undefined); }
  assert.ok([...texts.values()].includes(Array.from(groups.BASIC_FILE_TOOLS).join('、')), 'mandatory tools use a compact read-only summary');
  const retained = row('browser'); await retained.onChange(false); panel.flush();
  assert.equal(row('browser'), retained); assert.equal(retained.isOn, false);
  assert.ok(groups.TOOL_CAPABILITIES.find(capability => capability.id === 'browser').tools.every(name => thread.disabledTools.includes(name)));
  assert.ok([...texts.values()].some(text => text.endsWith(':11/12')));
  await retained.onChange(true); panel.flush(); assert.equal(retained.isOn, true);
  for (const id of ['preview','team','mcp']) {
    await row(id).onChange(false); panel.flush();
    assert.equal(row(id).isOn, false);
    assert.ok(groups.TOOL_CAPABILITIES.find(capability => capability.id === id).tools.every(name => thread.disabledTools.includes(name)));
    await row(id).onChange(true); panel.flush(); assert.equal(row(id).isOn, true);
  }
  assert.ok(rows().every(child => child.subtitle.startsWith('Description: ')), 'Capability descriptions replace raw tool names');
  await button('disable-optional-tools').onClick(); panel.flush();
  assert.deepEqual([...thread.disabledTools].sort(), Array.from(groups.OPTIONAL_TOOL_NAMES).sort()); assert.ok(rows().every(child => !child.isOn));
  assert.equal(button('disable-optional-tools').enabled,false);
  assert.equal(button('enable-optional-tools').enabled,true);
  await button('enable-optional-tools').onClick(); panel.flush(); assert.equal(thread.disabledTools.length, 0);
  app.busy = true; panel.flush(); assert.ok(rows().every(child => child.disabled)); assert.equal(button('enable-optional-tools').enabled, false);
  app.busy = false; thread.archived = true; panel.flush(); assert.ok(rows().every(child => child.disabled));
  thread.archived = false; app.saveError = 'save failed'; panel.flush(); assert.ok(rows().every(child => child.disabled));
  console.log('PASS emitted 12 capability rows without memory/Skills, atomic toggles, count, state-aware bulk actions and busy/archive/save-error restrictions');

  const scopeSource = root + '/views/ToolScopePanel.ets';
  const scopeEmitted = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ToolScopePanel.ts');
  assert.ok(fs.statSync(scopeEmitted).mtimeMs >= fs.statSync(scopeSource).mtimeMs, 'Build ToolScopePanel before testing');
  const originalRequire = globals.require;
  const scopeGlobals = { ...globals, exports: {}, require: id => {
    if (id.includes('AgentMode&')) return { AGENT_MODES: ['full', 'custom'], agentModeName: value => value };
    if (id.includes('CustomToolsPanel&')) return { CustomToolsPanel: Child };
    return originalRequire(id);
  } };
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(scopeEmitted, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, scopeGlobals, { filename: scopeEmitted });
  const currentThread = { id: 'current', agentMode: 'full', archived: false, disabledTools: ['read_web'] };
  const calls = [];
  const scopeApp = { ready: true, busy: false, saveError: '', active: currentThread,
    setAgentMode: async mode => { calls.push(mode); currentThread.agentMode = mode; return true; } };
  const scope = new scopeGlobals.exports.ToolScopePanel(undefined, { app: scopeApp, thread: currentThread }); scope.initialRender();
  const modeRows = () => [...scope.children.values()].filter(child => child instanceof NavRow);
  assert.equal(modeRows().length, 2);
  const custom = modeRows().find(row => row.compId === 'conversation-tool-scope-custom');
  await custom.onTap(); scope.flush();
  assert.equal(currentThread.agentMode, 'custom'); assert.equal(custom.active, true);
  assert.equal(currentThread.disabledTools[0], 'read_web', 'Opening custom mode retains the prior selection');
  assert.ok([...scope.children.values()].some(child => child.constructor === Child && child.thread === currentThread), 'Custom tools open for the displayed conversation');
  const retainedCustom = custom;
  await modeRows().find(row => row.compId === 'conversation-tool-scope-full').onTap(); scope.flush();
  assert.equal(modeRows().find(row => row.compId === 'conversation-tool-scope-custom'), retainedCustom);
  for (const lock of ['busy', 'archived', 'saveError', 'other-thread']) {
    scopeApp.busy = lock === 'busy'; currentThread.archived = lock === 'archived';
    scopeApp.saveError = lock === 'saveError' ? 'save failed' : '';
    scopeApp.active = lock === 'other-thread' ? { id: 'other' } : currentThread;
    scope.flush(); assert.ok(modeRows().every(row => row.disabled));
    const count = calls.length; await custom.onTap(); assert.equal(calls.length, count, 'A stale or locked control cannot change another conversation');
  }
  console.log('PASS conversation tool scope, keyed selection updates, custom controls and stale/busy/archive/save-error restrictions');
})().catch(error => { console.error(error); process.exitCode = 1; });
