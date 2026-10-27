// Real session -> repository contract -> view-model projection; selections commit with submitted messages.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
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
const { Fixture, seed } = load(path.join(root, 'test/SessionService.test'));
const { ChatViewModel, MessageViewModel } = load(path.join(root, 'main/ets/viewmodel/ChatViewModel'));
const gate = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
// Authorized team tools are declared directly from the initial request.
const teamAvailable = request => request.tools.some(tool => tool.function.name === 'team_recruit');
(async () => {
  const data = seed();
  data.projects = [{ id: 'project', name: 'Project', instructions: '', workspaceId: 'project-workspace', createdAt: 1, updatedAt: 1 }];
  data.threads[0].projectId = 'project';
  data.threads[0].draft = 'Keep this draft';
  data.threads.push({ ...data.threads[0], id: 'history', messages: Array.from({ length: 100 }, (_, i) => ({
    id: 'm-' + i, role: i % 2 ? 'assistant' : 'user', content: 'Historical message '.repeat(200), status: 'complete', error: ''
  })) });
  const f = new Fixture(data), app = new ChatViewModel();
  await app.initialize(f.session);
  const events = [], saves = [];
  f.session.subscribe(event => events.push(event));
  const save = f.repository.save.bind(f.repository);
  f.repository.save = (next, ids) => { saves.push(ids && Array.from(ids)); return save(next); };
  let messageUpdates = 0;
  const update = MessageViewModel.prototype.update;
  MessageViewModel.prototype.update = function (next) { messageUpdates++; update.call(this, next); };
  assert.equal(await app.setTeamEnabled(true), true);
  assert.equal(app.active.teamEnabled, true);
  assert.equal(app.active.projectId, 'project', 'metadata updates must preserve workspace membership');
  assert.equal(app.draft, 'Keep this draft');
  assert.deepEqual(saves, [], 'a mode selection must not write to storage');
  assert.equal(app.busy, false);
  assert.ok(events.every(event => event.state.phase === 'idle'), 'toggle must not disable controls by entering saving');
  assert.equal(messageUpdates, 0, 'a local mode change must not reproject unrelated message history');
  assert.equal(events.some(event => event.kind === 'snapshot'), false);
  assert.equal(events.filter(event => event.kind === 'thread').length, 1);
  assert.equal(f.provider.requests.length, 0, 'enabling team mode does not invoke a model');
  assert.ok(app.contextItems.some(item => item.name === 'team'), 'context estimate includes team instructions');
  assert.equal(await app.setTeamEnabled(false), true);
  assert.equal(app.active.teamEnabled, false);
  assert.equal(app.contextItems.some(item => item.name === 'team'), false);
  assert.equal(await app.setTeamEnabled(true), true);
  assert.equal(saves.length, 0, 'rapid toggles stay entirely in memory');
  console.log('PASS immediate on/off, context estimates and metadata updates without IO, busy state or model requests');

  await f.session.flushDraft();
  assert.notEqual(JSON.parse(f.repository.saved).threads[0].teamEnabled, true, 'draft autosave must not commit mode');
  await f.session.renameThread('thread-1', 'Renamed');
  assert.equal(app.active.teamEnabled, true, 'snapshot projection retains pending selection');
  await f.session.selectThread('history');
  assert.equal(app.active.teamEnabled, false, 'selection belongs to one conversation');
  await f.session.selectThread('thread-1');
  assert.equal(app.active.teamEnabled, true);
  const restored = new Fixture(await f.repository.load()), restoredApp = new ChatViewModel();
  await restoredApp.initialize(restored.session);
  assert.equal(restoredApp.active.teamEnabled, false, 'restart restores last sent mode');
  console.log('PASS autosave, full saves and thread switching preserve the boundary; unsent selections do not survive restart');

  f.session.setDraft('');
  saves.length = 0;
  await f.session.send();
  assert.equal(saves.length, 0, 'empty send does not commit mode');
  f.session.setDraft('/skill:missing invalid task');
  await f.session.send();
  assert.equal(saves.length, 0, 'invalid task does not commit mode');
  assert.equal(app.active.teamEnabled, true);

  const entered = gate(), release = gate(); let first = true;
  f.repository.beforeSave = async snapshot => { if (first) {
    first = false;
    assert.equal(snapshot.threads[0].teamEnabled, true);
    assert.equal(snapshot.threads[0].messages[0].content, 'Team task');
    entered.resolve(); await release.promise;
  } };
  f.session.setDraft('Team task');
  const sending = f.session.send(); await entered.promise;
  assert.equal(f.provider.requests.length, 0, 'mode and message must be saved before model request');
  assert.equal(await app.setTeamEnabled(false), false, 'running turn keeps its selected mode');
  release.resolve(); await sending;
  assert.equal(teamAvailable(f.provider.requests[0]), true);
  assert.equal(JSON.parse(f.repository.saved).threads[0].teamEnabled, true);
  const sent = new Fixture(await f.repository.load()), sentApp = new ChatViewModel();
  await sentApp.initialize(sent.session); assert.equal(sentApp.active.teamEnabled, true);

  f.repository.beforeSave = async () => {};
  saves.length = 0;
  await app.setTeamEnabled(false);
  assert.equal(saves.length, 0);
  await f.session.flushDraft();
  assert.equal(JSON.parse(f.repository.saved).threads[0].teamEnabled, true, 'pending disable must not leak into autosave');
  f.session.setDraft('Ordinary task'); await f.session.send();
  assert.equal(teamAvailable(f.provider.requests[1]), false);
  assert.equal(JSON.parse(f.repository.saved).threads[0].teamEnabled, false);
  console.log('PASS both enable and disable commit with the submitted message before the model runs');

  await app.setTeamEnabled(true);
  const requests = f.provider.requests.length;
  f.repository.beforeSave = async () => { throw Error('Injected save failure'); };
  f.session.setDraft('Cannot save'); await f.session.send();
  assert.equal(f.provider.requests.length, requests, 'failed initial save must prevent a model request');
  assert.ok(app.saveError.includes('Injected save failure'));
  assert.equal(app.busy, false);
  assert.equal(await app.setTeamEnabled(false), false, 'an unsaved state blocks further changes');
  f.repository.beforeSave = async () => {};
  await f.session.retrySave();
  assert.equal(app.saveError, '');
  assert.equal(JSON.parse(f.repository.saved).threads[0].teamEnabled, true);
  console.log('PASS send-time persistence errors remain visible and retry preserves the submitted choice');

  const slash = new Fixture(); await slash.session.initialize();
  const writes = slash.repository.writes.length;
  slash.session.setDraft('/team'); await slash.session.send();
  assert.equal(slash.repository.writes.length, writes);
  assert.equal(slash.provider.requests.length, 0);
  slash.session.setDraft('Task after command'); await slash.session.send();
  assert.equal(teamAvailable(slash.provider.requests[0]), true);
  console.log('PASS bare /team uses the same memory-only selection');
})().catch(error => { console.error(error); process.exitCode = 1; });
