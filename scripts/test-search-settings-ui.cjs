// Build first. Exercise emitted ArkUI bindings and controllers without installing a HAP.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..'), cache = new Map(), plain = v => JSON.parse(JSON.stringify(v));
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, require: id => {
    assert.ok(id.startsWith('.')); return load(path.resolve(path.dirname(file), id));
  } }, { filename: file }); return exports;
}
const from = name => load(path.join(root, 'entry/src/main/ets', name));
const editor = from('model/SearchEditor'), search = from('model/WebSearch');
let nodes = [], components = [], stack = [];
function native(kind) {
  return new Proxy({}, { get: (_, method) => (...args) => {
    if (method === 'canRetake') return false;
    if (['create', 'createWithLabel', 'createWithChild'].includes(method)) {
      const node = { kind, args, ancestors: stack.map(n => n.kind) }; nodes.push(node); stack.push(node);
    } else if (method === 'pop') stack.pop();
    else { const node = [...stack].reverse().find(n => n.kind === kind); if (node) node[method] = args[0]; }
  } });
}
function custom(kind) {
  return class { constructor(parent, props) { this.kind = kind; this.props = props; components.push(this); }
    render() { if (this.props.content) { stack.push({ kind }); this.props.content(); stack.pop(); } } };
}
const globals = { ...editor, ...search, t: from('model/I18n').t, exports: {},
  ViewPU: { create: component => component.render() },
  Alignment: { Top: 0 }, HorizontalAlign: { Start: 0 }, InputType: { Password: 0 },
  Space: {}, Btn: {}, systemMaterialAttribute() {}, menuMaterialAttribute() {},
  ...Object.fromEntries(['Column','Row','Scroll','Text','Button','Select','TextInput','If','ForEach','__Common__'].map(k => [k, native(k)])),
  ...Object.fromEntries(['GroupCard','BottomBar','SectionHeader','NavRow','RowDivider','Banner','SwitchRow'].map(k => [k, custom(k)]))
};
function emitted(relative) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const file = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(source).mtimeMs, 'Build ' + relative + ' first');
  return ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
}
function controller(name) {
  const tree = emitted('views/' + name), component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  const methods = component.members.filter(n => ts.isMethodDeclaration(n) && !['rerender','aboutToBeDeleted','setInitiallyProvidedValue','updateStateVars','purgeVariableDependenciesOnElmtId'].includes(n.name.getText(tree)));
  const sandbox = { ...globals, exports: {} };
  vm.runInNewContext(ts.transpileModule(`class Page { ${methods.map(n => n.getText(tree)).join('\n')} } exports.Page = Page;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, sandbox);
  return sandbox.exports.Page;
}
const List = controller('SearchSettingsPanel'), Detail = controller('SearchProviderPanel');
function view(page) {
  return Object.assign(page, { appearance: {}, observeComponentCreation2: fn => fn(1, true),
    ifElseBranchUpdateFunction: (_, fn) => fn(), forEachUpdateFunction: (_, items, fn) => items.forEach(fn),
    getUIContext: () => ({ getPromptAction: () => ({ showToast() {} }) }) });
}
function render(page) { nodes = []; components = []; stack = []; page.initialRender(); }
const component = id => { const found = components.find(c => c.props.compId === id); assert.ok(found, id); return found.props; };
const node = id => { const found = nodes.find(n => n.id === id); assert.ok(found, id); return found; };
(async () => {
  const app = { busy: false, saveError: '', error: '', providerProfiles: [], extensions: { webEnabled: true, browserPolicy: 'enabled' },
    productivity: { options: { search: { provider: 'bing-browser', enabled: true } } } };
  let writes = 0, fail = true, returned, request;
  app.saveSearch = async draft => {
    writes++; if (fail) { app.error = 'Disk failure'; return false; }
    app.error = ''; app.productivity.options.search = { provider: draft.provider, enabled: draft.enabled,
      tavily: { baseUrl: draft.tavily.baseUrl, credentialAlias: 'saved' }, deepseek: draft.deepseek }; return true;
  };
  const list = view(Object.assign(new List(), { app, initialized: false, saving: false, error: '',
    onEdit: (r, callback) => { request = r; returned = callback; } }));
  list.aboutToAppear(); render(list);
  assert.equal(component('search-provider-bing-browser').active, true);
  assert.equal(component('search-provider-deepseek').trailing, 'select');
  assert.equal(node('save-search-settings').enabled, false);
  assert.ok(!nodes.some(n => n.kind === 'TextInput' || n.kind === 'Select'));
  assert.ok(!components.some(c => c.props.compId === 'search-web-disabled'));
  assert.ok(!node('save-search-settings').ancestors.includes('Scroll'), 'Save remains outside the scrollable list');
  component('search-provider-tavily').onAction();
  assert.equal(list.draft.provider, 'bing-browser', 'Configure does not select'); assert.equal(writes, 0);
  const detail = view(Object.assign(new Detail(), { app, request, onDone: value => returned(value) }));
  detail.aboutToAppear(); render(detail);
  node('search-api-key').onChange('draft-secret'); node('search-base-url').onChange('https://custom.example');
  assert.equal(list.draft.apiKey, '', 'Detail edits are isolated until Done');
  node('search-provider-done').onClick(); detail.aboutToDisappear();
  assert.equal(list.draft.apiKey, 'draft-secret'); assert.equal(detail.draft.apiKey, ''); assert.equal(request.draft.apiKey, '');
  assert.equal(list.draft.provider, 'bing-browser'); assert.equal(writes, 0);
  list.aboutToAppear(); assert.equal(list.draft.apiKey, 'draft-secret', 'Returning must not reload saved data');
  render(list); assert.ok(node('search-unsaved-changes'));
  component('search-provider-deepseek').onTap(); assert.equal(list.draft.provider, 'deepseek');
  component('search-provider-bing-browser').onTap();
  assert.equal(list.draft.apiKey, 'draft-secret', 'Selection changes keep other provider drafts');
  await list.save(); assert.equal(writes, 1); assert.equal(list.error, 'Disk failure');
  assert.equal(list.draft.apiKey, 'draft-secret'); assert.equal(list.dirty(), true);
  fail = false; await list.save(); assert.equal(writes, 2); assert.equal(list.draft.apiKey, ''); assert.equal(list.dirty(), false);
  console.log('PASS emitted list selection, configure action, isolated details, Done, dirty notice and failed-save retry');

  list.edit('tavily'); const cancelled = view(Object.assign(new Detail(), { app, request, onDone: returned }));
  cancelled.aboutToAppear(); cancelled.draft.apiKey = 'discard'; cancelled.aboutToDisappear(); returned(undefined);
  assert.equal(list.draft.apiKey, ''); assert.equal(list.dirty(), false);
  app.extensions.webEnabled = false; render(list); assert.ok(component('search-web-disabled'));
  app.busy = true; render(list); assert.equal(component('search-provider-tavily').disabled, true);
  const provider = list.draft.provider; list.select('tavily'); assert.equal(list.draft.provider, provider); app.busy = false;
  list.edit('bing-browser'); const bing = view(Object.assign(new Detail(), { app, request })); bing.aboutToAppear(); render(bing);
  assert.ok(node('search-browser-web-status')); assert.ok(node('search-browser-permission-status'));
  assert.ok(node('search-browser-description')); assert.ok(!nodes.some(n => n.kind === 'TextInput'));
  app.productivity.options.search = { provider: 'future-search', enabled: true }; list.reset(); render(list);
  assert.equal(component('search-provider-unknown').active, true); assert.equal(node('save-search-settings').enabled, false);
  component('search-provider-unknown').onAction();
  const unknown = view(Object.assign(new Detail(), { app, request })); unknown.aboutToAppear(); render(unknown);
  assert.ok(component('search-provider-unsupported')); assert.ok(!nodes.some(n => n.kind === 'TextInput' || n.kind === 'Select'));
  console.log('PASS cancelled details, prerequisites, busy locks, Bing status and selected unknown-provider explanation');

  // Use the actual Index route callbacks rather than recreating their behavior in the fixture.
  const tree = emitted('pages/Index'); let listProps, detailProps;
  function visit(n) {
    if (ts.isNewExpression(n) && n.expression.getText(tree) === 'SearchSettingsPanel' && !listProps) listProps = n.arguments[1].getText(tree);
    if (ts.isNewExpression(n) && n.expression.getText(tree) === 'SearchProviderPanel' && !detailProps) detailProps = n.arguments[1].getText(tree);
    ts.forEachChild(n, visit);
  }
  visit(tree); assert.ok(listProps && detailProps);
  const routeContext = { exports: {} };
  vm.runInNewContext(ts.transpileModule(`class Routes { list() { return ${listProps}; } detail(param) { return ${detailProps}; } } exports.Routes = Routes;`,
    { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, routeContext);
  let route, result; const routes = Object.assign(new routeContext.exports.Routes(), { app, paths: {
    pushPath: value => route = value, pop: value => route.onPop({ result: value })
  } });
  const input = { provider: 'tavily', draft: editor.searchEditorDraft() };
  routes.list().onEdit(input, value => result = value); assert.equal(route.name, 'search-provider'); assert.equal(route.param, input);
  routes.detail(route.param).onDone({ ...input.draft, apiKey: 'returned' }); assert.equal(result.apiKey, 'returned');
  route.onPop({}); assert.equal(result, undefined);
  console.log('PASS Index search-provider navigation and onPop result/cancellation flow');
})().catch(error => { console.error(error); process.exitCode = 1; });
