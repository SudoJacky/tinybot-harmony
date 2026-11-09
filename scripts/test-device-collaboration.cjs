// Real session/runtime and collaboration controllers; framed, ordered links replace the device service.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
const kitMocks = {};
function load(name) {
  const file = path.resolve(name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true,
  } }).outputText, { exports, console, setTimeout, clearTimeout, Observed: x => x,
    require: id => id.startsWith('@kit.') ? (kitMocks[id] || {}) : load(path.resolve(path.dirname(file), id)) }, { filename: file });
  return exports;
}
const from = name => load(path.join(root, name));
const { collaborationFrames, CollaborationReceiver, collaborationBytes, collaborationUpdate, applyCollaborationUpdate } = from('model/DeviceCollaboration');
const { DeviceCollaboration } = from('services/DeviceCollaboration');
const { SessionService } = from('services/SessionService');
const { AgentRuntime } = from('services/AgentRuntime');
const { ProviderRegistry } = from('services/providers/ProviderRegistry');
const { RunCancelledError } = from('services/Cancellation');
const { emptyData, parseAppData } = from('model/Conversation');
const { modelConfig } = from('model/ProviderProfiles');
const { defaultProductivity } = from('model/Productivity');
const { defaultAssistantOptions } = from('model/AssistantOptions');
async function until(check) {
  for (let i = 0; i < 500; i++) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  assert.ok(check(), 'Asynchronous condition was not reached');
}
async function fixture(name) {
  const data = emptyData(), requests = [], errors = [];
  const profile = { id: 'test', name: 'Test', protocol: 'chat-completions', baseUrl: 'https://example.com/v1',
    credentialAlias: 'private-credential', noApiKey: false, enabled: true, models: ['model-a'], contextWindow: 32768 };
  data.productivity = defaultProductivity(); data.productivity.options = defaultAssistantOptions(); data.productivity.options.autoMemory = false;
  data.providerProfiles = [profile]; data.config = modelConfig([profile], { providerId: 'test', modelId: 'model-a' }, data.config);
  data.threads = ['a', 'b'].map(id => ({ id: name + '-' + id, title: name + id, titleEdited: true, updatedAt: 1,
    messages: [], draft: '', pendingInputs: [], modelRef: { providerId: 'test', modelId: 'model-a' } }));
  data.activeThreadId = name + '-a';
  const repository = { saved: JSON.stringify(data), fail: false, load: async () => parseAppData(repository.saved),
    save(value) { if (repository.fail) return Promise.reject(new Error('Injected disk failure')); repository.saved = JSON.stringify(value); return Promise.resolve(); } };
  const provider = { info: { id: 'test', name: 'Test', protocol: 'test', defaultBaseUrl: '', defaultModel: 'model-a' },
    endpoint: () => 'https://example.com', stream(request, cancellation, onText) {
      return new Promise((resolve, reject) => {
        const remove = cancellation.onCancel(() => reject(new RunCancelledError()));
        requests.push({ request, text: onText, cancellation, finish(content, toolCalls = []) { remove(); resolve({ content, toolCalls }); } });
      });
    } };
  let sequence = 0;
  const providers = new ProviderRegistry(); providers.register(provider);
  const credentials = { read: async () => '', write: async () => {}, remove: async () => {} };
  const resources = { createId: () => name + '-id-' + ++sequence, ensureWorkspace: async () => {}, configureProviders: () => {},
    reportError: (event, error) => errors.push({ event, error }), tools: () => ({ definitions: () => [], execute: async () => 'ok' }) };
  const session = new SessionService(repository, new AgentRuntime(providers, credentials), credentials, resources);
  await session.initialize();
  const model = new DeviceCollaboration(() => name + '-command-' + ++sequence); model.attach(session);
  return { session, model, requests, repository, resources, errors };
}
function connect(a, b, dropFirstHello = false) {
  let seqA = 0, seqB = 0, alive = true;
  const receiverA = new CollaborationReceiver(), receiverB = new CollaborationReceiver(), packets = [];
  const link = (destination, receiver, next) => ({ async send(packet) {
    await Promise.resolve(); if (!alive) throw new Error('Disconnected');
    if (dropFirstHello && packet.kind === 'hello') { dropFirstHello = false; return; }
    packets.push(JSON.parse(JSON.stringify(packet)));
    for (const frame of collaborationFrames(packet, next())) {
      assert.ok(Buffer.byteLength(frame, 'utf8') <= 1024);
      const received = receiver.receive(frame); if (received) destination.receive(received);
    }
  }, close() { alive = false; a.model.disconnected(); b.model.disconnected(); } });
  const linkA = link(b.model, receiverB, () => seqA++), linkB = link(a.model, receiverA, () => seqB++);
  a.model.opened(linkA, 'Phone'); b.model.opened(linkB, 'Tablet');
  return { packets, close: () => linkA.close() };
}
async function main() {
  for (const text of ['中文🙂'.repeat(4000), '\u0000\\\n\t\"'.repeat(4000), 'x'.repeat(25000), '\ud800'.repeat(1000)]) {
    const packet = { version: 1, kind: 'command', requestId: 'test', action: 'send', threadId: 'a', text };
    const receiver = new CollaborationReceiver(); let result;
    for (const frame of collaborationFrames(packet, 1)) {
      assert.equal(collaborationBytes(frame), Buffer.byteLength(frame, 'utf8'));
      assert.ok(Buffer.byteLength(frame, 'utf8') <= 1024); result = receiver.receive(frame);
    }
    assert.equal(result.text, text);
  }
  const missing = collaborationFrames({ version: 1, kind: 'hello', name: 'a'.repeat(2000) }, 2);
  assert.throws(() => new CollaborationReceiver().receive(missing[1]), /Stale/);
  const duplicate = new CollaborationReceiver(); duplicate.receive(missing[0]); assert.throws(() => duplicate.receive(missing[0]), /sequence/);
  const summary = { id: 'a', title: 'a', updatedAt: 1, phase: 'running', error: '', queued: 0, model: 'test' };
  const message = { id: 'answer', role: 'assistant', content: 'history'.repeat(10000), status: 'generating', error: '', thinking: false, tools: [] };
  const previous = { thread: summary, messages: [message] };
  const next = { thread: summary, messages: [{ ...message, content: message.content + '新输出' }] };
  const delta = collaborationUpdate(previous, next);
  assert.ok(JSON.stringify(delta).length < 500, 'A new token must not retransmit prior output');
  assert.equal(applyCollaborationUpdate(previous, delta).messages[0].content, next.messages[0].content);
  assert.throws(() => applyCollaborationUpdate(undefined, delta), /sequence mismatch/);

  const phone = await fixture('phone'), tablet = await fixture('tablet');
  const wire = connect(phone, tablet, true);
  try {
    await until(() => phone.model.peerThreads.length === 2 && tablet.model.peerThreads.length === 2).catch(error => {
      console.error({ phone: phone.session.state, tablet: tablet.session.state, errors: phone.errors, packets: wire.packets,
        collaborationError: phone.model.error }); throw error;
    });
    assert.equal(phone.model.peerName, 'Tablet'); assert.equal(tablet.model.peerName, 'Phone');
    tablet.session.setDraft('private tablet draft');
    const threadId = tablet.session.snapshot().activeThreadId;
    phone.model.select('peer', 'tablet-b');
    await until(() => phone.model.output?.thread.id === 'tablet-b');
    phone.model.draft = 'run on tablet'; await phone.model.submit();
    await until(() => tablet.requests.length === 1);
    assert.equal(tablet.session.snapshot().activeThreadId, threadId);
    assert.equal(tablet.session.snapshot().threads.find(t => t.id === threadId).draft, 'private tablet draft');
    assert.equal(phone.requests.length, 0);
    tablet.requests[0].text('实时输出🙂');
    await until(() => phone.model.output?.messages.some(m => m.content.includes('实时输出🙂')));
    const observedAnswer = phone.model.messages.find(m => m.role === 'assistant');
    const observedThread = phone.model.peerThreads.find(t => t.id === 'tablet-b');
    tablet.requests[0].text('实时输出🙂继续');
    await until(() => observedAnswer.content.includes('继续'));
    assert.equal(phone.model.messages.find(m => m.id === observedAnswer.id), observedAnswer, 'Keep the same observable message while tokens arrive');
    assert.equal(phone.model.output.thread.phase, 'running', 'Use target state, not selected local chat state');
    phone.model.draft = 'tablet-only draft'; phone.model.select('local', 'phone-a');
    assert.equal(phone.model.draft, ''); phone.model.draft = 'phone-only draft';
    phone.model.select('peer', 'tablet-b'); assert.equal(phone.model.draft, 'tablet-only draft');
    const beforeStale = phone.model.output;
    phone.model.receive({ version: 1, kind: 'output', watchId: 'old-watch', output: next, from: 0 });
    assert.equal(phone.model.output, beforeStale, 'Late output from an old watch must be ignored');
    await until(() => phone.model.output?.thread.id === 'tablet-b');
    assert.ok(!JSON.stringify(wire.packets).includes('private-credential'));
    assert.ok(!JSON.stringify(wire.packets).includes('private tablet draft'));

    tablet.model.select('peer', 'phone-b'); await until(() => tablet.model.output?.thread.id === 'phone-b');
    tablet.model.draft = 'run on phone'; await tablet.model.submit(); await until(() => phone.requests.length === 1);
    assert.equal(phone.session.runningThreadIds[0], 'phone-b'); assert.equal(tablet.session.runningThreadIds[0], 'tablet-b');

    phone.model.draft = 'queued remotely'; await phone.model.submit();
    await tablet.session.submitCollaborationInput('tablet-b', 'queued locally');
    tablet.requests[0].finish('tablet complete'); await until(() => tablet.requests.length === 2);
    tablet.requests[1].finish('remote queue complete'); await until(() => tablet.requests.length === 3);
    tablet.requests[2].finish('local queue complete'); await until(() => !tablet.session.hasActiveRuns);
    await until(() => observedThread.phase === 'idle' && observedThread.status === 'complete');
    assert.equal(phone.model.peerThreads.find(t => t.id === 'tablet-b'), observedThread, 'Keep the observable row as status changes');
    const users = tablet.session.collaborationOutput('tablet-b').messages.filter(m => m.role === 'user').map(m => m.content);
    assert.equal(JSON.stringify(users), JSON.stringify(['run on tablet', 'queued remotely', 'queued locally']));
    const saved = JSON.parse(tablet.repository.saved).threads.find(t => t.id === 'tablet-b');
    assert.equal(saved.messages.at(-1).content, 'local queue complete');

    await tablet.model.stop(); await until(() => !phone.session.hasActiveRuns);
    assert.ok(phone.requests[0].cancellation.cancelled);
    const beforeCreate = tablet.session.snapshot().threads.length;
    await phone.model.create('peer');
    assert.equal(tablet.session.snapshot().threads.length, beforeCreate + 1);
    assert.equal(tablet.session.snapshot().activeThreadId, threadId, 'Remote create must not navigate the peer UI');

    const command = { version: 1, kind: 'command', requestId: 'duplicate-command', action: 'create' };
    tablet.model.receive(command); tablet.model.receive(command);
    await until(() => wire.packets.filter(p => p.requestId === command.requestId).length >= 2);
    assert.equal(tablet.session.snapshot().threads.length, beforeCreate + 2, 'Duplicate command executes once');

    tablet.repository.fail = true;
    await assert.rejects(tablet.session.submitCollaborationInput('tablet-a', 'must not execute'), /尚未保存/);
    assert.equal(tablet.requests.length, 3, 'A failed checkpoint must not start the model');
    tablet.repository.fail = false;
    wire.close(); assert.equal(phone.model.connected, false);
    phone.model.draft = 'offline input'; await phone.model.submit();
    assert.ok(phone.model.error.includes('未连接')); assert.equal(phone.model.draft, 'offline input');
  } finally {
    await phone.session.stopAll(); await tablet.session.stopAll(); phone.model.dispose(); tablet.model.dispose();
  }
  const waitingPhone = await fixture('waiting-phone'), waitingTablet = await fixture('waiting-tablet');
  const waitingWire = connect(waitingPhone, waitingTablet);
  try {
    let release, authorizing = false;
    waitingTablet.resources.authorizeGeneration = () => { authorizing = true; return new Promise(resolve => { release = resolve; }); };
    const pending = waitingPhone.model.request('send', 'waiting-tablet-b', 'must not start after disconnect');
    const rejected = assert.rejects(pending, /未收到执行端确认/);
    await until(() => authorizing); waitingWire.close(); release(); await rejected;
    await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(waitingTablet.requests.length, 0, 'Disconnect cancels admission still awaiting execution-device authorization');
  } finally { waitingPhone.model.dispose(); waitingTablet.model.dispose(); }

  // Native adapter: opt-in, same-app validation, late events and permission/lifecycle races.
  let nativeSequence = 0, permission = async () => ({ authResults: [0] }), connectionResult = { isConnected: true };
  const handlers = new Map(), destroyed = [], nativeFrames = [], nativeOperations = [], rejections = [];
  const nativeCreations = [];
  let failUnregister = false;
  const manager = { getLocalDeviceName: () => 'Phone', getAvailableDeviceListSync: () => [{ networkId: 'tablet', deviceName: 'Tablet' }] };
  kitMocks['@kit.ArkTS'] = { util: { generateRandomUUID: () => 'native-' + ++nativeSequence } };
  kitMocks['@kit.AbilityKit'] = { AbilityConstant: { CollaborateResult: { ACCEPT: 0, REJECT: 1 } },
    abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: () => permission() }) } };
  kitMocks['@kit.DistributedServiceKit'] = {
    distributedDeviceManager: { createDeviceManager: () => manager, releaseDeviceManager: () => {} },
    abilityConnectionManager: { StartOptionParams: { START_IN_FOREGROUND: 0 }, ConnectErrorCode: { SYSTEM_INTERNAL_ERROR: 5 },
      createAbilityConnectionSession: () => { const id = ++nativeSequence; nativeCreations.push(id); return id; },
      on: (type, id, cb) => handlers.set(id + ':' + type, cb), off: (type, id) => {
        nativeOperations.push('off:' + type);
        if (failUnregister && type === 'connect') throw new Error('Injected unregister failure');
        handlers.delete(id + ':' + type);
      },
      acceptConnect: async () => {}, reject: (token, reason) => rejections.push({ token, reason }),
      connect: async () => connectionResult,
      sendMessage: async (id, frame) => { nativeFrames.push(frame); },
      destroyAbilityConnectionSession: id => { nativeOperations.push('destroy'); destroyed.push(id); } }
  };
  const { NativeDeviceCollaboration } = from('services/NativeDeviceCollaboration');
  const native = new NativeDeviceCollaboration(); native.initialize({});
  const want = { 'ohos.extra.param.key.supportCollaborateIndex': {
    PeerInfo: { bundleName: 'com.sudojacky.tinybot', moduleName: 'entry', abilityName: 'EntryAbility', deviceId: 'tablet' },
    ConnectOption: { parameters: { protocol: 'tinybot.sessions.v1' } }, 'ohos.dms.collabToken': 'private-token'
  } };
  try {
    assert.equal(native.accept({}, want), 1, 'Incoming collaboration requires prior opt-in');
    assert.equal(rejections.at(-1).reason, 'tinybot.sessions.v1:disabled');
    await native.setEnabled(true); assert.equal(native.devices.length, 1);
    assert.equal(native.accept({}, want), 0);
    await new Promise(resolve => setTimeout(resolve, 5));
    assert.equal(native.model.connected, false, 'Accepting a request does not mean its transport is connected');
    assert.equal(native.busy, true);
    assert.equal(nativeFrames.length, 0, 'Do not publish business messages before the native connect event');
    assert.equal(native.accept({}, want), 1, 'Reject a second request while the first is still connecting');
    assert.equal(rejections.at(-1).reason, 'tinybot.sessions.v1:busy');
    const earlyMessage = [...handlers.entries()].find(([key]) => key.endsWith(':receiveMessage'))[1];
    for (const frame of collaborationFrames({ version: 1, kind: 'hello', name: 'Tablet' }, 0)) { earlyMessage({ msg: frame }); }
    assert.equal(native.model.connected, false, 'Receiving an early packet cannot bypass the native connect event');
    const acceptedConnect = [...handlers.entries()].find(([key]) => key.endsWith(':connect'))[1];
    acceptedConnect({}); await until(() => native.model.connected);
    assert.equal(native.busy, false);
    assert.ok(nativeFrames.every(frame => Buffer.byteLength(frame, 'utf8') <= 1024));
    const oldDisconnect = [...handlers.entries()].find(([key]) => key.endsWith(':disconnect'))[1];
    native.disconnect(); assert.equal(native.model.connected, false); assert.equal(destroyed.length, 1);
    assert.equal(nativeOperations.at(-1), 'destroy');
    await native.connect(native.devices[0]); assert.equal(native.model.connected, true);
    oldDisconnect({ reason: 1 }); assert.equal(native.model.connected, true, 'Old session events cannot tear down a new connection');
    native.disconnect(); const otherApp = JSON.parse(JSON.stringify(want));
    otherApp['ohos.extra.param.key.supportCollaborateIndex'].PeerInfo.bundleName = 'other.app';
    assert.equal(native.accept({}, otherApp), 1, 'Reject connections from other applications');
    await native.connect(native.devices[0]);
    nativeOperations.length = 0; failUnregister = true; native.disconnect(); failUnregister = false;
    assert.equal(nativeOperations.join(','), 'off:connect,off:disconnect,off:receiveMessage,destroy',
      'A listener cleanup failure cannot strand the native session');
    native.lan.invitation = 'temporary-invitation';
    await native.connect(native.devices[0]); nativeOperations.length = 0;
    assert.equal(native.lan.invitation, '', 'Starting native collaboration revokes an earlier LAN invitation, including after reopening the panel');
    const currentDisconnect = [...handlers.entries()].find(([key]) => key.endsWith(':disconnect'))[1];
    currentDisconnect({ reason: 2 });
    assert.equal(native.model.connected, false);
    assert.equal(nativeOperations.at(-1), 'destroy');
    const nativeLogs = []; from('model/Diagnostics').Diagnostics.configureLogSink(log => nativeLogs.push(log));
    connectionResult = { isConnected: false, errorCode: 5 }; await native.connect(native.devices[0]);
    assert.ok(nativeLogs.some(log => log.event === 'connect_failed' && log.fields.nativeCode === 5),
      'Preserve the native connection error code in sanitized diagnostics');
    assert.ok(native.error.includes('局域网直连'), 'Explain the available recovery path without claiming the system failure is fixed');
    connectionResult = { isConnected: false, errorCode: 5, reason: 'tinybot.sessions.v1:disabled' };
    await native.connect(native.devices[0]);
    assert.ok(native.error.includes('另一台设备开启'), 'Keep an explicit peer rejection actionable even when the system reports code 5');
    let finishConnect;
    connectionResult = new Promise(resolve => { finishConnect = resolve; });
    const unfinished = native.connect(native.devices[0]);
    const unfinishedId = nativeCreations.at(-1);
    [...handlers.entries()].find(([key]) => key.endsWith(':connect'))[1]({});
    native.disconnect(); finishConnect({ isConnected: true }); await unfinished;
    assert.equal(native.model.connected, false, 'A late source result cannot reopen a cancelled connection');
    assert.ok(destroyed.includes(unfinishedId), 'A cancelled connection must release its native resources');
    connectionResult = { isConnected: true };
    await native.connect(native.devices[0]);
    const disabledId = nativeCreations.at(-1);
    await native.setEnabled(false);
    assert.ok(destroyed.includes(disabledId), 'Disabling collaboration releases its native session');
    let grant; permission = () => new Promise(resolve => { grant = resolve; });
    const enabling = native.setEnabled(true); await native.setEnabled(false); grant({ authResults: [0] }); await enabling;
    assert.equal(native.enabled, false, 'A late permission result cannot re-enable collaboration');
  } finally { native.dispose(); }
  assert.ok(nativeCreations.every(id => destroyed.includes(id)), 'Every created native session is eventually destroyed');
  console.log('Device collaboration passed: UTF-8 framing, two-way streaming, concurrent execution, ordered queues, persistence, deduplication, targeted stop and offline input.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
