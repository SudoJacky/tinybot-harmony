// Exercise the built sidebar against real session/view-model data; rendering is checked on device.
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
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const source = path.join(root, 'entry/src/main/ets/views/ThreadList.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ThreadList.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const cls = name => tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
const methods = ['filtered', 'sections', 'sectionThreads', 'sectionTitle', 'groupOpen', 'visibleCount', 'loadMore', 'toggleGroup', 'onActivePath', 'lastBranch'];
const globals = { exports: {}, t: key => key, Motion: { medium: 220, standard: 'ease' } };
vm.runInNewContext(ts.transpileModule(`${cls('ThreadSection').getText(tree)}
class Sidebar { ${cls('ThreadList').members.filter(n => methods.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} }
exports.Sidebar = Sidebar;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
const { Fixture, seed } = load(path.join(root, 'entry/src/test/SessionService.test'));
const { ChatViewModel } = load(path.join(root, 'entry/src/main/ets/viewmodel/ChatViewModel'));
(async () => {
  const data = seed();
  data.projects = ['alpha', 'beta', 'empty'].map(id => ({ id, name: 'Same name', instructions: '', workspaceId: 'project-' + id, createdAt: 1, updatedAt: 1 }));
  const original = data.threads[0];
  data.threads = [
    { ...original, id: 'a1', projectId: 'alpha', title: 'Find this', pinned: false, updatedAt: 200 },
    { ...original, id: 'a2', projectId: 'alpha', title: 'Pinned', pinned: true, updatedAt: 100 },
    { ...original, id: 'b1', projectId: 'beta', title: 'Second', updatedAt: 300 },
    { ...original, id: 'ordinary', title: 'Standalone', updatedAt: 400 },
    { ...original, id: 'archive', projectId: 'alpha', archived: true, title: 'Archived' }
  ];
  data.activeThreadId = 'a1';
  const f = new Fixture(data), app = new ChatViewModel(); await app.initialize(f.session);
  const sidebar = Object.assign(new globals.exports.Sidebar(), { app, query: '', archived: false, visibleCounts: {}, collapsedProjects: [],
    getUIContext: () => ({ animateTo: (_, apply) => apply() }) });
  const groups = () => Array.from(sidebar.sections(sidebar.filtered()));
  const ids = group => Array.from(group.threads, item => item.id);
  assert.deepEqual(groups().map(g => g.id), ['alpha', 'beta', 'empty', ''], 'Duplicate names must remain distinct and empty projects retained');
  assert.deepEqual(ids(groups()[0]), ['a2', 'a1'], 'Keep pin ordering within each project');
  assert.deepEqual(ids(groups()[3]), ['ordinary']);
  assert.equal(groups()[3].title, '普通聊天');
  sidebar.toggleGroup('alpha'); assert.equal(sidebar.groupOpen('alpha'), false); assert.equal(sidebar.groupOpen('beta'), true);
  sidebar.query = 'Find this'; assert.equal(sidebar.groupOpen('alpha'), true, 'Search reveals collapsed matches');
  assert.deepEqual(groups().map(g => g.id), ['alpha']); assert.deepEqual(ids(groups()[0]), ['a1']);
  sidebar.query = 'no matching title'; assert.equal(groups().length, 0);
  sidebar.query = ''; assert.equal(sidebar.groupOpen('alpha'), false, 'Clearing search restores collapse choice');
  sidebar.archived = true; assert.deepEqual(groups().map(g => g.id), ['alpha']); assert.deepEqual(ids(groups()[0]), ['archive']);
  sidebar.archived = false; sidebar.loadMore('alpha'); assert.equal(sidebar.visibleCount('alpha'), 40); assert.equal(sidebar.visibleCount('beta'), 20);
  sidebar.loadMore('beta'); assert.equal(sidebar.visibleCount('alpha'), 40); assert.equal(sidebar.visibleCount('beta'), 40);
  assert.equal(sidebar.onActivePath('alpha', 'a2'), true); assert.equal(sidebar.onActivePath('beta', 'b1'), false);
  assert.equal(sidebar.lastBranch('alpha', 'a1'), true); assert.equal(sidebar.lastBranch('alpha', 'a2'), false);
  assert.equal(await app.newThread('beta'), true); assert.equal(app.active.projectId, 'beta');
  const projectThreadId = app.active.id;
  assert.equal(await app.newThread(''), true); assert.equal(app.active.projectId, undefined, 'Ordinary new-chat must not inherit the active project');
  assert.ok(ids(groups().find(g => g.id === 'beta')).includes(projectThreadId));
  assert.ok(ids(groups().find(g => g.id === '')).includes(app.active.id));
  assert.equal(f.provider.requests.length, 0);
  const shared = { id: 'mount-one', name: 'Documents', uri: 'file://docs/shared', addedAt: 1 };
  const revoked = [];
  f.resources.persistProjectFolders = async () => {};
  f.resources.revokeProjectFolders = async folders => { revoked.push(...folders); };
  assert.equal(await app.saveProject('Alpha', '', 'alpha', [shared]), true);
  assert.equal(await app.saveProject('Beta', '', 'beta', [{ ...shared, id: 'mount-two' }]), true);
  assert.equal(await app.saveProject('Alpha', '', 'alpha', []), true);
  assert.equal(revoked.length, 0, 'Removing one project mount preserves another project using the same URI');
  assert.equal(await app.saveProject('Beta', '', 'beta', []), true);
  assert.equal(revoked.length, 1, 'The final project removal revokes the unused system grant');
  console.log('PASS project tree: membership, ordinary chats, duplicate names, empty projects, pin order, search, archive, collapse, independent pagination and new-chat destinations');
})().catch(error => { console.error(error); process.exitCode = 1; });
