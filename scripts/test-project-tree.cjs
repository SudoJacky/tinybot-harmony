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
const indexSource = path.join(root, 'entry/src/main/ets/pages/Index.ets');
const indexEmitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts');
assert.ok(fs.statSync(indexEmitted).mtimeMs >= fs.statSync(indexSource).mtimeMs, 'Build Index before testing');
const indexTree = ts.createSourceFile(indexEmitted, fs.readFileSync(indexEmitted, 'utf8'), ts.ScriptTarget.Latest, true);
const indexClass = indexTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'Index');
const createChat = indexClass.members.find(n => n.name?.getText(indexTree) === 'createChat').getText(indexTree);
const revealChat = indexClass.members.find(n => n.name?.getText(indexTree) === 'revealChat').getText(indexTree);
vm.runInNewContext(ts.transpileModule(`class Header { ${createChat} ${revealChat} } exports.Header = Header;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, globals);
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

  const empty = seed(); empty.threads[0].title = '新对话';
  const headerFixture = new Fixture(empty), headerApp = new ChatViewModel(); await headerApp.initialize(headerFixture.session);
  const toasts = [];
  const header = Object.assign(new globals.exports.Header(), { app: headerApp, appearance: { surface: {} },
    paths: {clear(){}},setDrawer(){},workbench:()=>({docked:true}),
    getUIContext: () => ({ getPromptAction: () => ({ showToast: value => toasts.push(value.message) }) }) });
  const initialWrites = headerFixture.repository.writes.length;
  await header.createChat(); await header.createChat();
  assert.deepEqual(toasts, ['已在新对话中', '已在新对话中']);
  assert.equal(headerApp.active.id, 'thread-1'); assert.equal(headerApp.threads.length, 1);
  assert.equal(headerFixture.repository.writes.length, initialWrites, 'An untouched chat requires no extra persistence');
  headerApp.setDraft('Keep this unsent draft'); await header.createChat();
  assert.notEqual(headerApp.active.id, 'thread-1'); assert.equal(headerApp.threads.length, 2);
  assert.equal(toasts.length, 2, 'Creating a new chat never claims the previous chat was empty');
  assert.equal(JSON.parse(headerFixture.repository.saved).threads.find(item => item.id === 'thread-1').draft, 'Keep this unsent draft');
  await header.createChat(); assert.equal(toasts.length, 3); assert.equal(headerApp.threads.length, 2);
  const oldHeaderApp = header.app;
  header.app = app; // Reuse the real project/session fixture from above.
  await app.newThread('alpha'); const emptyProjectId = app.active.id;
  await header.createChat(); assert.equal(app.active.id, emptyProjectId); assert.equal(toasts.length, 4);
  app.setDraft('Project draft'); await header.createChat();
  assert.notEqual(app.active.id, emptyProjectId); assert.equal(app.active.projectId, 'alpha'); assert.equal(toasts.length, 4);
  header.app = oldHeaderApp;
  headerApp.setDraft('Must survive a save failure');
  headerFixture.repository.beforeSave = async () => { throw Error('Disk unavailable'); };
  await header.createChat(); assert.equal(toasts.length, 4, 'A failed creation cannot show an already-new toast');
  assert.ok(headerApp.saveError); await header.createChat(); assert.equal(toasts.length, 4);
  assert.equal(headerFixture.provider.requests.length, 0);
  console.log('PASS actual header with real sessions: untouched toast, repeated taps, draft persistence, project membership and save failure');
})().catch(error => { console.error(error); process.exitCode = 1; });
