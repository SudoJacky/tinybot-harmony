// Regression coverage for native task ownership, cancellation latches and real request scopes.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map(), leases = new Map(), callbacks = new Map(), timers = new Map();
let sequence = 0, startCalls = 0, stopCalls = 0, acquireFailure, releaseFailure, now = 0, timerId = 0;
let beforeStart = async () => {}, beforeStop = async () => {}, beforeAck = async () => {};
const context = { abilityInfo: { bundleName: 'cn.tinybot.app', name: 'EntryAbility' } };
const noOp = () => {};
const backgroundTaskManager = {
  on(event, callback) { assert.equal(callbacks.has(event), false); callbacks.set(event, callback); },
  off(event, callback) { assert.equal(callbacks.get(event), callback); callbacks.delete(event); },
  async startBackgroundRunning(ctx, modes, agent) {
    assert.equal(ctx, context); assert.deepEqual(Array.from(modes), ['dataTransfer']); assert.ok(agent);
    startCalls++; await beforeStart(); if (acquireFailure) throw acquireFailure;
    assert.equal(leases.size, 0, 'Single-task API must not replace an existing or releasing task');
    const id = ++sequence; leases.set(id, true); await beforeAck(id);
    return { continuousTaskId: id, notificationId: id + 100 };
  },
  async stopBackgroundRunning(ctx) {
    assert.equal(ctx, context); stopCalls++; await beforeStop();
    if (releaseFailure) throw releaseFailure; // A failed stop does NOT remove the native task.
    assert.equal(leases.size, 1, 'Stop exactly the single owned task'); leases.clear();
  }
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
const settle = async () => {
  // Drain due checkpoint batches without advancing background lease deadlines.
  for (let quiet = 0; quiet < 2;) {
    await tick();
    const due = [...timers].filter(([, timer]) => timer.at <= now);
    if (!due.length) { quiet++; continue; }
    quiet = 0;
    for (const [id, timer] of due) { if (timers.delete(id)) timer.fn(); }
  }
};
async function advance(ms) {
  const target = now + ms;
  while (true) {
    const next = [...timers].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
    if (!next) break;
    const [id, timer] = next; timers.delete(id); now = timer.at; timer.fn(); await settle();
  }
  now = target; await settle();
}
(async () => {
  const { default: EntryAbility } = load(path.join(root, 'main/ets/entryability/EntryAbility'));
  const { backgroundGeneration } = load(path.join(root, 'main/ets/services/BackgroundGeneration'));
  const { NetworkTransfers } = load(path.join(root, 'main/ets/services/NetworkTransfers'));
  const { Cancellation, RunCancelledError } = load(path.join(root, 'main/ets/services/Cancellation'));
  const { Diagnostics } = load(path.join(root, 'main/ets/model/Diagnostics'));
  const { Fixture } = load(path.join(root, 'test/SessionService.test'));
  const logs = []; Diagnostics.configureLogSink(event => logs.push(event)); const ability = new EntryAbility();
  async function fixture(data) {
    ability.onForeground(); await settle();
    const f = new Fixture(data); await f.session.initialize(); backgroundGeneration.attach(f.session, context);
    f.resources.prepareGeneration = () => backgroundGeneration.beginTurn();
    const original = f.provider.stream.bind(f.provider);
    f.provider.stream = async (request, signal, ...args) => {
      const end = await NetworkTransfers.begin(signal);
      try { return await original(request, signal, ...args); } finally { await end(); }
    };
    f.provider.respond = (_index, signal) => new Promise((resolve, reject) => {
      f.complete = (content = 'done', toolCalls = []) => resolve({ content, toolCalls });
      signal.onCancel(() => reject(new RunCancelledError()));
    });
    return f;
  }
  async function send(f, text = 'hello') { f.session.setDraft(text); const pending = f.session.send(); await settle(); return { pending }; }
  async function stop(f, pending) { await f.session.stop(); await pending; await settle(); }
  async function cancelTask(reason = 1) {
    const id = [...leases.keys()][0]; assert.ok(id); leases.delete(id);
    callbacks.get('continuousTaskCancel')({ id, reason }); await settle(); return id;
  }

  let f = await fixture(), { pending } = await send(f);
  assert.equal(leases.size, 0); ability.onBackground(); await settle(); assert.equal(leases.size, 1);
  f.complete(); await pending; await settle(); assert.equal(leases.size, 0); assert.equal(timers.size, 0);
  assert.equal((await f.repository.load()).threads[0].messages.at(-1).status, 'complete');
  console.log('PASS actual model request admission owns dataTransfer only while backgrounded and releases before completion');

  f = await fixture(); let finishTool;
  f.resources.agentTools = {
    definitions: () => [{ type: 'function', function: { name: 'echo', description: 'test', parameters: { type: 'object', properties: {} } } }],
    execute: (_call, signal) => new Promise((resolve, reject) => { finishTool = () => resolve('ok'); signal.onCancel(() => reject(new RunCancelledError())); })
  };
  ({ pending } = await send(f)); ability.onBackground(); await settle(); const beforeTools = startCalls;
  f.complete('', [{ id: 'tool', type: 'function', function: { name: 'echo', arguments: '{}' } }]); await settle();
  assert.equal(typeof finishTool, 'function'); assert.equal(f.session.state.phase, 'running');
  assert.equal(leases.size, 0, 'Local tool/user/browser waits have no network lease'); assert.equal(timers.size, 0);
  ability.onForeground(); ability.onBackground(); await settle(); assert.equal(startCalls, beforeTools);
  finishTool(); await settle(); assert.equal(leases.size, 1); assert.equal(f.provider.requests.length, 2);
  f.complete(); await pending; await settle(); assert.equal(leases.size, 0);
  console.log('PASS real tool-loop releases before local work and admits a new task only when the next model request starts');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  f.session.setDraft('queued'); await f.session.enqueueInput('followUp'); const cancelledCalls = startCalls;
  const staleId = await cancelTask(); await pending; await settle();
  const stopped = (await f.repository.load()).threads[0];
  assert.match(stopped.messages.at(-1).error, /后台执行已被系统或用户中止/); assert.equal(stopped.queuePaused, true);
  assert.equal(stopped.pendingInputs.length, 1); ability.onForeground(); ability.onBackground(); await settle();
  await assert.rejects(backgroundGeneration.beginTurn(), /后台执行|CANCELLED/);
  assert.equal(startCalls, cancelledCalls); assert.equal(leases.size, 0);
  // A distinct foreground user send may clear the latch; foreground lifecycle alone never does.
  ability.onForeground(); f.session.setDraft('explicit new request'); pending = f.session.send(); await settle();
  ability.onBackground(); await settle(); assert.equal(leases.size, 1);
  callbacks.get('continuousTaskCancel')({ id: staleId, reason: 1 }); assert.equal(f.session.state.phase, 'running');
  await stop(f, pending);
  console.log('PASS cancellation persists the reason, pauses queued work and blocks reapplication until a new foreground user turn');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  let releaseStop; beforeStop = () => new Promise(resolve => { releaseStop = resolve; });
  ability.onForeground(); await settle(); const releasingId = backgroundGeneration.task.id;
  ability.onBackground(); await settle(); const racingCalls = startCalls;
  assert.equal(backgroundGeneration.task.id, releasingId, 'Keep identity while native stop is pending');
  await cancelTask(); releaseStop(); beforeStop = async () => {}; await pending; await settle();
  assert.equal(startCalls, racingCalls); assert.equal(leases.size, 0); assert.equal(backgroundGeneration.task, undefined);
  console.log('PASS cancellation during native release wins over a queued reapplication');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  const endedId = [...leases.keys()][0], callsBeforeDelayedCancel = startCalls;
  ability.onForeground(); await settle(); assert.equal(leases.size, 0);
  callbacks.get('continuousTaskCancel')({ id: endedId, reason: 1 }); await pending; await settle();
  ability.onBackground(); await settle(); assert.equal(startCalls, callsBeforeDelayedCancel);
  assert.match((await f.repository.load()).threads[0].messages.at(-1).error, /后台执行已被系统或用户中止/);
  console.log('PASS delayed cancellation after stop acknowledgment still blocks the same user turn');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  releaseFailure = Object.assign(Error('stop failed without removing the native task'), { code: 9800004 });
  f.complete(); await pending; await settle();
  assert.equal(leases.size, 1); const failedTask = backgroundGeneration.task;
  assert.ok(failedTask?.releaseError); const failedCalls = startCalls;
  ability.onForeground(); await settle(); ability.onBackground(); await settle();
  assert.equal(backgroundGeneration.task, failedTask); assert.equal(leases.size, 1); assert.equal(startCalls, failedCalls);
  assert.ok(logs.some(event => event.event === 'release_failed' && event.fields.errorCode === 9800004));
  releaseFailure = undefined; ability.onForeground(); await settle();
  assert.equal(leases.size, 0); assert.equal(backgroundGeneration.task, undefined);
  console.log('PASS true native stop failure retains ownership, blocks admission, reports its code and permits cleanup retry');

  f = await fixture(); ({ pending } = await send(f));
  beforeAck = async id => { leases.delete(id); callbacks.get('continuousTaskCancel')({ id, reason: 12 }); };
  ability.onBackground(); await pending; await settle(); beforeAck = async () => {};
  assert.equal(leases.size, 0); const ackCalls = startCalls;
  ability.onForeground(); ability.onBackground(); await settle(); assert.equal(startCalls, ackCalls);
  console.log('PASS cancellation received before native start acknowledgment is retained and cannot become an active lease');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  callbacks.get('continuousTaskSuspend')({ continuousTaskId: [...leases.keys()][0], suspendState: true, suspendReason: 1 });
  await pending; await settle(); const suspendedCalls = startCalls;
  ability.onForeground(); ability.onBackground(); await settle(); assert.equal(startCalls, suspendedCalls); assert.equal(leases.size, 0);
  console.log('PASS system suspension blocks further task admission and releases without retrying the model');

  f = await fixture(); ({ pending } = await send(f)); let releaseStart;
  beforeStart = () => new Promise(resolve => { releaseStart = resolve; });
  ability.onBackground(); await settle(); ability.onForeground(); releaseStart(); beforeStart = async () => {}; await settle();
  assert.equal(leases.size, 0); assert.equal(f.session.state.phase, 'running');
  ability.onBackground(); await settle(); assert.equal(leases.size, 1); await stop(f, pending);
  console.log('PASS late admission after foreground return is released before a later background request');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  const boundedCalls = startCalls; await advance(8 * 60 * 1000); assert.equal(f.session.state.phase, 'running');
  await advance(60 * 1000); await pending; await settle();
  assert.match((await f.repository.load()).threads[0].messages.at(-1).error, /后台流式传输已达到本次运行时限/);
  assert.equal(leases.size, 0); assert.equal(timers.size, 0); assert.equal(startCalls, boundedCalls); assert.equal(f.provider.requests.length, 1);
  assert.ok(logs.some(event => event.event === 'window_expired'));
  console.log('PASS unknown-length SSE expires at nine minutes without fake progress, lease renewal or request replay');

  f = await fixture(); ({ pending } = await send(f)); ability.onBackground(); await settle();
  const secondSignal = new Cancellation(), endSecond = await NetworkTransfers.begin(secondSignal);
  f.complete(); await pending; await settle(); assert.equal(leases.size, 0, 'Session ending releases even an abandoned child scope');
  assert.equal(secondSignal.cancelled, true, 'Session teardown cancels independent child network signals');
  await endSecond(); await endSecond(); assert.equal(leases.size, 0);
  console.log('PASS parallel request scopes and idempotent end callbacks do not lose native ownership');

  const saved = await new Fixture().repository.load();
  saved.threads[0].messages = [
    { id: 'user', role: 'user', content: 'form', status: 'complete', error: '' },
    { id: 'answer', role: 'assistant', content: '', status: 'stopped', error: '', steps: [{ content: '', tools: [
      { call: { id: 'form', type: 'function', function: { name: 'request_user_input', arguments: '{}' } }, status: 'cancelled', output: '' }
    ] }] }
  ];
  f = await fixture(saved); let finishForm;
  f.resources.agentTools = {
    definitions: () => [{ type: 'function', function: { name: 'request_user_input', description: 'test', parameters: { type: 'object', properties: {} } } }],
    execute: () => new Promise(resolve => { finishForm = () => resolve(JSON.stringify({ status: 'cancelled' })); })
  };
  pending = f.session.resumeForm('answer', 'form'); await settle(); assert.equal(f.session.state.phase, 'running');
  const formCalls = startCalls; ability.onBackground(); await settle();
  assert.equal(startCalls, formCalls); assert.equal(leases.size, 0, 'A resumed form is a running session without an active network transfer');
  finishForm(); await pending; await settle();
  console.log('PASS actual resumeForm wait remains running without applying for dataTransfer');

  f = await fixture(); ({ pending } = await send(f)); acquireFailure = Object.assign(Error('permission denied'), { code: 201 });
  ability.onBackground(); await pending; await settle(); acquireFailure = undefined;
  assert.equal(leases.size, 0); assert.ok(logs.some(event => event.event === 'transition_failed' && event.fields.errorCode === 201));
  ability.onDestroy(); await settle(); assert.equal(callbacks.size, 0); assert.equal(timers.size, 0);
  console.log('PASS admission failures stop observably and destruction removes observers after confirmed cleanup');

  const implementation = fs.readFileSync(path.join(root, 'main/ets/services/BackgroundGeneration.ets'), 'utf8');
  assert.doesNotMatch(implementation, /notificationManager|progressValue|downloadTemplate|ContinuousTaskRequest/);
  const manifest = fs.readFileSync(path.join(root, 'main/module.json5'), 'utf8');
  assert.match(manifest, /"backgroundModes": \["dataTransfer"\]/); assert.doesNotMatch(manifest, /KEEP_BACKGROUND_RUNNING_SYSTEM|taskKeeping/);
  console.log('PASS API 20 ordinary-permission configuration and removal of fabricated progress publishing');
})().catch(error => { console.error(error); process.exitCode = 1; });
