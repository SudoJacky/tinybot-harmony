// Build first: exercise the emitted controllers across settings subpage boundaries.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: value => value, require: id => {
    if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const model = name => load(path.join(root, 'entry/src/main/ets', name));
const { t } = model('model/I18n');
const { defaultProductivity, validateProductivity } = model('model/Productivity');
const { ProviderEditorViewModel } = model('viewmodel/ProviderEditorViewModel');
function controller(name, names, globals = {}) {
  const relative = 'entry/src/main/ets/views/' + name;
  const source = path.join(root, relative + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug', relative + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build ' + name + ' before testing');
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  const sandbox = { exports: {}, t, ...globals };
  vm.runInNewContext(ts.transpileModule(`class Page {
    ${component.members.filter(node => names.includes(node.name?.getText(tree))).map(node => node.getText(tree)).join('\n')}
  } exports.Page = Page;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, sandbox);
  return sandbox.exports.Page;
}
const ui = { getFocusController: () => ({ clearFocus() {} }), getPromptAction: () => ({ showToast() {} }) };
const Forms = controller('ProductivityPanel', ['aboutToAppear', 'aboutToDisappear', 'reset', 'locked', 'openEditor', 'snapshot', 'save', 'toast'],
  { validateProductivity, util: { generateRandomUUID: () => 'new-record' } });
function form(app, tab, entryId = '') {
  const closed = [];
  const value = Object.assign(new Forms(), { app, tab, entryId, editorOnly: true, busy: false,
    appearance: {}, cancellation: { cancel() { this.cancelled = true; } },
    getUIContext: () => ui, onClose: warning => closed.push(warning) });
  value.aboutToAppear(); return { value, closed };
}
(async () => {
  const app = { busy: false, active: { id: 'chat' }, productivity: defaultProductivity(), error: 'disk unavailable' };
  app.productivity.servers.push({ id: 'server', name: 'MCP', url: 'https://example.com/mcp', credentialAlias: 'saved-alias', enabled: true });
  let fail = true;
  app.saveProductivity = async data => { if (fail) return false; app.productivity = data; return true; };
  const template = form(app, 'templates', 'summarize');
  template.value.content = 'edited draft';
  assert.notEqual(app.productivity.templates[0].content, 'edited draft', 'Opening and typing cannot mutate the saved record');
  await template.value.save();
  assert.equal(template.value.error, app.error); assert.equal(template.closed.length, 0);
  fail = false; await template.value.save();
  assert.equal(app.productivity.templates[0].content, 'edited draft'); assert.equal(template.closed.length, 1);
  const memory = form(app, 'memory'); memory.value.content = 'local preference'; memory.value.scoped = true;
  await memory.value.save(); assert.equal(app.productivity.memories[0].threadId, 'chat');
  console.log('PASS editor drafts, failed save/retry, successful return and memory scope');

  let returned, route;
  const list = form(app, 'mcp');
  list.value.onEdit = (tab, id, onReturn) => { route = { tab, id }; returned = onReturn; };
  list.value.openEditor('server');
  assert.equal(route.tab, 'mcp'); assert.equal(route.id, 'server');
  const mcp = form(app, 'mcp', 'server');
  assert.equal(mcp.value.noAuth, false); assert.equal(mcp.value.token, '');
  const requests = [];
  app.changeMcp = async request => { requests.push(request); return { warning: 'credential cleanup pending' }; };
  await mcp.value.save();
  assert.equal(requests[0].auth, 'keep'); assert.equal(requests[0].token, undefined);
  returned(mcp.closed[0]); assert.equal(list.value.error, 'credential cleanup pending');
  mcp.value.token = 'test-only-token'; await mcp.value.save();
  assert.equal(requests[1].auth, 'bearer'); assert.equal(mcp.value.token, '');
  mcp.value.token = 'discarded-test-token'; mcp.value.aboutToDisappear();
  assert.equal(mcp.value.token, ''); assert.equal(mcp.value.cancellation.cancelled, true);
  console.log('PASS MCP saved-credential retention, warning return and raw-token disposal');

  const Provider = controller('ProviderEditorPanel', ['aboutToAppear', 'aboutToDisappear', 'locked', 'discover'],
    { discoverModels: async () => ['discovered-model'] });
  const editor = new ProviderEditorViewModel(); editor.reset();
  editor.baseUrl = 'https://example.com/v1'; editor.apiKey = 'test-only-key';
  let discoveries = 0;
  const provider = Object.assign(new Provider(), { app: { busy: false, providerProfiles: [] }, editor,
    page: 'service', initialModelError: '', discovering: false, getUIContext: () => ui,
    onDiscovered: models => { discoveries++; assert.equal(models[0], 'discovered-model'); } });
  provider.aboutToAppear(); await provider.discover();
  assert.equal(discoveries, 1);
  for (const page of ['models', 'discovery']) {
    const child = Object.assign(new Provider(), { editor, page, initialModelError: '' });
    child.aboutToAppear(); editor.addModels('manual-model'); child.aboutToDisappear();
    assert.equal(editor.apiKey, 'test-only-key', 'Returning from model pages must retain the service draft key');
  }
  assert.ok(editor.modelList.includes('manual-model'));
  provider.aboutToDisappear(); assert.equal(editor.apiKey, '');
  console.log('PASS model subpages share the draft and clear its raw key only when leaving the service');

  let writes = 0, pops = 0, reject = true;
  const Appearance = controller('AppearancePanel', ['save'], { AppearancePreferences: { select() {
    if (reject) throw Error('storage unavailable'); writes++;
  } } });
  const appearance = Object.assign(new Appearance(), { choice: 'mode', error: '', onDone: () => pops++ });
  appearance.save({ mode: 'dark' }); assert.equal(pops, 0); assert.match(appearance.error, /storage unavailable/);
  reject = false; appearance.save({ mode: 'dark' }); assert.equal(pops, 1); assert.equal(writes, 1);
  appearance.choice = ''; appearance.save({ accent: 'green' }); assert.equal(pops, 1);
  console.log('PASS appearance subpage returns only after a successful save; inline changes stay on the main page');
})().catch(error => { console.error(error); process.exitCode = 1; });
