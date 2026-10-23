// Local lifecycle regression: a pending model turn must remain runnable after backgrounding.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map(), leases = new Map(), callbacks = new Map(), timers = new Map();
let sequence = 0, acquireFailure, releaseFailure, supported = true, now = 0, timerId = 0;
let beforeStart = async () => {};
const context = { abilityInfo: { bundleName: 'cn.tinybot.app', name: 'EntryAbility' } };
const noOp = () => {};
const backgroundTaskManager = {
  ContinuousTaskRequest: class { isModeSupported() { return supported; } },
  BackgroundTaskMode: { MODE_TASK_KEEPING: 9 }, BackgroundTaskSubmode: { SUBMODE_NORMAL_NOTIFICATION: 1 },
  on(event, callback) { assert.equal(callbacks.has(event), false); callbacks.set(event, callback); },
  off(event, callback) { assert.equal(callbacks.get(event), callback); callbacks.delete(event); },
  async startBackgroundRunning(ctx, request) {
    assert.equal(ctx, context); assert.deepEqual(Array.from(request.backgroundTaskModes), [9]);
    assert.deepEqual(Array.from(request.backgroundTaskSubmodes), [1]); assert.ok(request.wantAgent);
    await beforeStart(); if (acquireFailure) throw acquireFailure;
    const id = ++sequence; leases.set(id, true); return { continuousTaskId: id, notificationId: id + 100 };
  },
  async stopBackgroundRunning(ctx, id) { assert.equal(ctx, context); assert.ok(leases.delete(id), 'Release only the owned background task'); if (releaseFailure) throw releaseFailure; }
};
const mocks = {
  '@kit.AbilityKit': { UIAbility: class {}, wantAgent: {
    OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 2 },
    async getWantAgent(info) { assert.equal(info.wants[0].bundleName, context.abilityInfo.bundleName); return { notification: true }; }
  } }, '@kit.BackgroundTasksKit': { backgroundTaskManager }, '@ohos/hypium': {},
  '@kit.ArkWeb': { webview: { WebviewController: { initializeWebEngine: noOp } } },
  '../services/NativeActions': { ShareInbox: { receive: noOp } },
  '../services/LanguagePreferences': { LanguagePreferences: { initialize: noOp, refresh: noOp } },
  '../services/AppearancePreferences': { AppearancePreferences: { initialize: noOp, refresh: noOp } },
  '../services/McpOAuth': { McpOAuth: { receive: noOp } },
  '../services/LaunchActions': { LaunchActions: { receive: noOp, setForeground: noOp } },
  '../services/DeveloperDiagnostics': { DeveloperDiagnostics: { initialize: noOp, stop: noOp, setForeground: noOp } },
  '../services/HuaweiAccount': { huaweiAccount: { refresh: noOp } },
  '../services/HostedPrivacy': { hostedPrivacy: { allowed: true, initialize: noOp, refresh: noOp, dispose: noOp } }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText,
  { exports, Observed: cls => cls, AppStorage: { setOrCreate: noOp, get: noOp }, console,
    setTimeout: (fn, ms) => { const id = ++timerId; timers.set(id, { fn, at: now + ms }); return id; },
    clearTimeout: id => timers.delete(id),
    require: id => {
      if (id in mocks) return mocks[id];
      if (!id.startsWith('.')) throw Error('Unexpected dependency: ' + id);
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file });
  return exports;
}
const tick = () => new Promise(setImmediate);
(async () => {
  const { default: EntryAbility } = load(path.join(root, 'main/ets/entryability/EntryAbility'));
  const { backgroundGeneration } = load(path.join(root, 'main/ets/services/BackgroundGeneration'));
  const { RunCancelledError } = load(path.join(root, 'main/ets/services/Cancellation'));
  const { Diagnostics } = load(path.join(root, 'main/ets/model/Diagnostics'));
  const logs = []; Diagnostics.configureLogSink(event => logs.push(event));
  const ability = new EntryAbility();
  ability.onForeground();
  const { Fixture } = load(path.join(root, 'test/SessionService.test'));
  async function fixture() {
    const f = new Fixture(); await f.session.initialize(); backgroundGeneration.attach(f.session, context);
    f.resources.prepareGeneration = () => backgroundGeneration.waitForReady();
    f.provider.respond = (_index, signal) => new Promise((resolve, reject) => {
      f.complete = () => resolve({ content: 'done', toolCalls: [] });
      signal.onCancel(() => reject(new RunCancelledError()));
    });
    return f;
  }
  let f = await fixture();
  assert.equal(leases.size, 0, 'Idle application has no background lease');
  f.session.setDraft('hello'); let pending = f.session.send();
  await tick(); assert.equal(f.session.state.phase, 'running');
  assert.equal(leases.size, 1, 'Acquire before asynchronous work can outlive the foreground');
  const oldId = [...leases.keys()][0];
  ability.onBackground();
  assert.equal(leases.size, 1, 'A running model turn needs a system background task before the app can suspend');
  ability.onBackground(); assert.equal(leases.size, 1, 'Do not stack leases');
  now += 30 * 60 * 1000;
  for (const [id, timer] of [...timers]) if (timer.at <= now) { timers.delete(id); timer.fn(); }
  await tick(); assert.equal(f.session.state.phase, 'running'); assert.equal(leases.size, 1);
  f.complete(); await pending; assert.equal(leases.size, 0);
  assert.equal((await f.repository.load()).threads[0].messages.at(-1).status, 'complete');
  console.log('PASS actual ability lifecycle uses taskKeeping, survives 30 virtual minutes, then releases after durable completion');

  ability.onForeground(); f = await fixture();
  f.session.setDraft('next'); pending = f.session.send(); await tick();
  ability.onBackground(); callbacks.get('continuousTaskCancel')({ id: oldId, reason: 1 });
  assert.equal(f.session.state.phase, 'running', 'A stale cancellation cannot stop a later turn');
  assert.equal(leases.size, 1); assert.equal(leases.has(oldId), false);
  f.session.setDraft('queued'); await f.session.enqueueInput('followUp');
  const id = [...leases.keys()][0]; leases.delete(id); callbacks.get('continuousTaskCancel')({ id, reason: 1 });
  await pending; await tick();
  const stopped = (await f.repository.load()).threads[0];
  assert.equal(stopped.messages.at(-1).status, 'stopped');
  assert.match(stopped.messages.at(-1).error, /后台执行已被系统或用户中止/);
  assert.equal(stopped.queuePaused, true); assert.equal(stopped.pendingInputs.length, 1);
  assert.equal(f.provider.requests.length, 1, 'Cancellation never replays requests or queued work');
  assert.equal(leases.size, 0);
  console.log('PASS system/user cancellation persists its reason, pauses queued work and ignores stale callbacks');

  ability.onForeground(); f = await fixture();
  acquireFailure = Object.assign(Error('ACL denied'), { code: 201 });
  f.session.setDraft('no ACL'); pending = f.session.send(); await tick();
  assert.equal(f.session.state.phase, 'running', 'Foreground generation remains available without the ACL');
  ability.onBackground(); await pending; await tick();
  assert.match((await f.repository.load()).threads[0].messages.at(-1).error, /未获得长时后台执行权限/);
  assert.ok(logs.some(event => event.event === 'acquire_failed' && event.fields.errorCode === 201));
  assert.equal(leases.size, 0); acquireFailure = undefined;
  console.log('PASS denied ACL leaves foreground generation available and persists an explicit reason on background entry');

  ability.onForeground(); f = await fixture();
  f.session.setDraft('stop'); pending = f.session.send(); await tick();
  releaseFailure = Error('injected release failure');
  await f.session.stop(); await pending; await tick(); releaseFailure = undefined;
  assert.equal(leases.size, 0);
  assert.ok(logs.some(event => event.event === 'release_failed'));
  ability.onDestroy(); assert.equal(leases.size, 0);
  console.log('PASS manual stop and ability destruction release the task; release failures remain observable');

  ability.onForeground(); f = await fixture();
  let releaseStart; beforeStart = () => new Promise(resolve => { releaseStart = resolve; });
  f.session.setDraft('slow start'); pending = f.session.send(); await tick();
  assert.equal(f.provider.requests.length, 0, 'Model dispatch waits for background admission');
  const stopping = f.session.stop(); releaseStart();
  await stopping; await pending; await tick(); beforeStart = async () => {};
  assert.equal(leases.size, 0); assert.equal(f.provider.requests.length, 0);
  console.log('PASS stop during asynchronous admission releases the late task and never dispatches the model');

  ability.onForeground(); f = await fixture();
  f.session.setDraft('suspended'); pending = f.session.send(); await tick(); ability.onBackground();
  callbacks.get('continuousTaskSuspend')({ continuousTaskId: [...leases.keys()][0], suspendState: true, suspendReason: 1 });
  await pending; await tick();
  assert.equal((await f.repository.load()).threads[0].messages.at(-1).status, 'stopped');
  assert.equal(leases.size, 0);
  ability.onDestroy(); assert.equal(callbacks.size, 0);
  console.log('PASS system suspension stops and persists the turn; destruction removes both subscriptions');

  ability.onForeground(); f = await fixture(); supported = false;
  f.session.setDraft('unsupported mode'); pending = f.session.send(); await tick();
  assert.equal(leases.size, 0); assert.equal(f.provider.requests.length, 1);
  ability.onBackground(); await pending; await tick(); supported = true;
  assert.match((await f.repository.load()).threads[0].messages.at(-1).error, /未获得长时后台执行权限/);
  ability.onDestroy(); assert.equal(callbacks.size, 0);
  console.log('PASS an unsupported taskKeeping mode cannot claim background support');

  // Keep the native composition root wired to the service exercised above.
  assert.match(fs.readFileSync(path.join(root, 'main/ets/services/NativeSessionService.ets'), 'utf8'), /backgroundGeneration\.attach\(session, context\)/);
  const manifest = fs.readFileSync(path.join(root, 'main/module.json5'), 'utf8');
  assert.match(manifest, /"backgroundModes": \["taskKeeping"\]/); assert.match(manifest, /ohos\.permission\.KEEP_BACKGROUND_RUNNING_SYSTEM/);
})().catch(error => { console.error(error); process.exitCode = 1; });
