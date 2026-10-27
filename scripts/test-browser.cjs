// Run the actual browser module and agent loop with controlled, observable browser effects.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src'), cache = new Map();
const nativeResult = { type: 3, value: '' };
const captureResult = { released: 0, before: async () => {} };
const capturedPixel = { getImageInfo: async () => ({ size: { width: 900, height: 1200 } }), release: async () => { captureResult.released++; } };
const TouchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
const nativeWebview = { JsMessageType: { STRING: 3, NONE: 0 }, WebviewController: class {
  backAvailable = false; forwardAvailable = false; effects = [];
  url = 'about:blank';
  accessBackward() { return this.backAvailable; }
  accessForward() { return this.forwardAvailable; }
  backward() { this.effects.push('back'); }
  forward() { this.effects.push('forward'); }
  refresh() { this.effects.push('reload'); }
  getUrl() { return this.url; }
  clearHistory() { this.effects.push('clearHistory'); this.backAvailable = false; this.forwardAvailable = false; }
  loadUrl(url) { this.url = url; this.effects.push('navigate'); }
  getTitle() { return 'Native browser'; }
  getSurfaceId() { return 'browser-surface'; }
  async runJavaScript() { return JSON.stringify(nativeResult.value); }
  async runJavaScriptExt(source) {
    const value = nativeResult.execute ? await nativeResult.execute(source) : nativeResult.value;
    return { getType: () => nativeResult.type, getString: () => JSON.stringify(value) };
  }
} };
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, TouchType, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (id === '@kit.ArkWeb') return { webview: nativeWebview };
    if (id === '@kit.ImageKit') return { image: { createPixelMapFromSurface: async id => {
      assert.equal(id, 'browser-surface'); await captureResult.before(); return capturedPixel;
    } } };
    if (!id.startsWith('.')) throw Error('Unexpected platform dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
const { BrowserSession } = load(path.join(root, 'main/ets/services/BrowserSession'));
const { BrowserTools } = load(path.join(root, 'main/ets/services/BrowserTools'));
const { Cancellation } = load(path.join(root, 'main/ets/services/Cancellation'));
const { executeToolBatch } = load(path.join(root, 'main/ets/services/ToolExecution'));
const { runAgentLoop } = load(path.join(root, 'main/ets/services/AgentLoop'));
const { AgentRuntime } = load(path.join(root, 'main/ets/services/AgentRuntime'));
const { ToolSet } = load(path.join(root, 'main/ets/services/ToolSet'));
const { Fixture, seed } = load(path.join(root, 'test/SessionService.test'));
const gate = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const settle = () => new Promise(resolve => setTimeout(resolve, 0));
const call = (name, args = {}) => ({ id: name, type: 'function', function: { name, arguments: JSON.stringify(args) } });
function fixture(policy = 'enabled') {
  const browser = new BrowserSession(), cancellation = new Cancellation();
  const driver = { effects: [], page: 'Initial page', hold: undefined, acted: gate(),
    async open(url) { this.effects.push('open'); this.url = url; },
    async act(action) { this.effects.push(action.action); this.acted.resolve(); if (this.hold) await this.hold.promise; },
    async snapshot(id) { return { snapshotId: id, url: this.url, title: this.page, text: this.page,
      elements: [{ id: 1, role: 'button', label: 'Submit', type: '' }], truncated: false, embeddedFrames: 0, trust: 'untrusted' }; },
    close() { this.effects.push('close'); },
    userBack() { return false; }
  };
  const saved = [], logs = [];
  browser.attach(driver); browser.configure(async value => { saved.push(value); }, (event, fields, error) => logs.push({ event, fields, error }));
  browser.updatePolicy(policy);
  return { browser, cancellation, driver, saved, logs, tools: new BrowserTools(browser, 'thread', false) };
}
async function acquired() {
  const f = fixture(); const receipt = await f.browser.acquire('thread', 'https://example.com', 'Interactive page', f.cancellation);
  return { ...f, receipt };
}
(async () => {
  {
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const f = await acquired(), driver = new NativeBrowserDriver(f.browser), calls = [];
    driver.controller.url = 'https://example.com'; driver.pageEnd(driver.controller.url); driver.setFeedbackVisible(true);
    nativeResult.execute = async source => {
      const preview = source.includes('const preview = true;'); calls.push(preview ? 'preview' : 'effect');
      return JSON.stringify(preview ? { ok: true, target: { x: 0.25, y: 0.5 } } : { ok: true });
    };
    const action = { action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 };
    const acting = driver.act(action); await settle();
    assert.deepEqual(calls, ['preview']); assert.equal(f.browser.actionFeedback.x, 0.25); assert.equal(f.browser.actionFeedback.y, 0.5);
    await acting; assert.deepEqual(calls, ['preview', 'effect']);
    driver.setFeedbackVisible(false); assert.equal(f.browser.actionFeedback, undefined);
    calls.length = 0; await driver.act(action); assert.deepEqual(calls, ['effect'], 'Collapsed browsing skips visual preview and its delay');
    driver.setFeedbackVisible(true); calls.length = 0;
    const interrupted = driver.act(action); await settle();
    f.browser.takeOver(); f.browser.handoff();
    await assert.rejects(interrupted, error => error.code === 'STALE_BROWSER_SNAPSHOT');
    assert.deepEqual(calls, ['preview'], 'Taking over and handing back during preview must not issue the old action');
    assert.equal(f.browser.actionFeedback, undefined);
    const fresh = await f.browser.snapshot(f.cancellation); calls.length = 0;
    nativeResult.execute = async () => { calls.push('invalid-preview'); return JSON.stringify({ ok: true, target: { x: 2, y: 0.5 } }); };
    await assert.rejects(driver.act({ ...action, snapshotId: fresh.snapshotId }), error => error.code === 'INVALID_RESPONSE');
    assert.deepEqual(calls, ['invalid-preview']); assert.equal(f.browser.actionFeedback, undefined);
    f.browser.showActionFeedback(0.25, 0.5); const previousId = f.browser.actionFeedback.id;
    f.browser.showActionFeedback(0.75, 0.5); assert.ok(f.browser.actionFeedback.id > previousId);
    await new Promise(resolve => setTimeout(resolve, 510)); assert.equal(f.browser.actionFeedback, undefined, 'Operation cues expire automatically');
    nativeResult.execute = undefined; f.browser.release(f.cancellation);
    console.log('PASS visible actions preview their target before a single effect, hidden browsing skips preview, and takeover invalidates pending clicks');
  }
  {
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const f = await acquired(), driver = new NativeBrowserDriver(f.browser); let effects = 0;
    driver.controller.url = 'https://example.com'; driver.pageEnd(driver.controller.url); driver.setFeedbackVisible(true);
    nativeResult.execute = async source => {
      if (source.includes('const preview = true;')) return JSON.stringify({ ok: true, target: { x: 0.5, y: 0.5 } });
      effects++; return JSON.stringify({ ok: true });
    };
    f.driver.act = action => driver.act(action);
    const action = f.browser.act({ action: 'type', snapshotId: f.receipt.page.snapshotId, elementId: 1, text: 'edited' }, f.cancellation);
    const rejected = assert.rejects(action, error => error.code === 'STALE_BROWSER_SNAPSHOT');
    await settle(); await f.browser.pauseForAnnotation();
    assert.equal(f.browser.owner, 'user'); assert.equal(effects, 0);
    f.browser.handoff(); await rejected;
    f.browser.showActionFeedback(0.5, 0.5); driver.pageBegin(); assert.equal(f.browser.actionFeedback, undefined);
    f.browser.showActionFeedback(0.5, 0.5); f.browser.close(); assert.equal(f.browser.actionFeedback, undefined);
    f.browser.release(f.cancellation); nativeResult.execute = undefined;
    console.log('PASS annotation takeover cancels the unissued preview action without blocking capture; page loads and close clear indicators');
  }
  {
    const f = await acquired(); f.driver.hold = gate();
    let operationDone = false, annotationReady = false;
    const operating = f.browser.act({ action: 'reload' }, f.cancellation).then(() => { operationDone = true; });
    await settle();
    const preparing = f.browser.pauseForAnnotation().then(() => { annotationReady = true; });
    await settle(); assert.equal(annotationReady, false); assert.equal(f.browser.owner, 'user');
    f.driver.hold.resolve(); await preparing;
    assert.equal(annotationReady, true); assert.equal(operationDone, false); assert.equal(f.cancellation.cancelled, false);
    f.browser.handoff(); await operating;
    assert.equal(f.driver.effects.filter(value => value === 'reload').length, 1);
    console.log('PASS annotation takeover drains the issued action before capture and keeps the agent paused until explicit handoff');
  }
  {
    for (const policy of ['unset', 'disabled']) {
      const f = fixture(policy);
      const effects = [...f.driver.effects];
      assert.throws(() => f.browser.openForUser(), error => error.code === 'PERMISSION_DENIED');
      assert.equal(f.browser.open, false); assert.equal(f.browser.policy, policy);
      assert.deepEqual(f.saved, []); assert.deepEqual(f.driver.effects, effects);
    }
    const missing = new BrowserSession(); missing.updatePolicy('enabled');
    assert.throws(() => missing.openForUser(), error => error.code === 'BROWSER_UNAVAILABLE');
    assert.equal(missing.open, false);
    const f = fixture();
    f.browser.url = 'https://example.com/old'; f.browser.title = 'Old page'; f.browser.error = 'Old error';
    f.browser.openForUser();
    assert.equal(f.browser.open, true); assert.equal(f.browser.owner, 'user');
    assert.equal(f.browser.url, ''); assert.equal(f.browser.title, ''); assert.equal(f.browser.error, '');
    assert.equal(f.browser.hasTask, false); assert.equal(f.browser.paused, false);
    assert.deepEqual(f.driver.effects, []); assert.ok(f.logs.some(log => log.event === 'opened_by_user'));
    f.browser.pageChanged('about:blank', ''); assert.equal(f.browser.url, '');
    const acquiring = f.browser.acquire('thread', 'https://example.com', 'Use the shared browser', f.cancellation);
    await settle(); assert.equal(f.browser.paused, true);
    f.browser.handoff(); await acquiring;
    assert.equal(f.browser.owner, 'agent');
    f.browser.openForUser();
    assert.equal(f.browser.owner, 'agent'); assert.equal(f.browser.paused, false);
    assert.equal(f.browser.url, 'https://example.com'); assert.deepEqual(f.driver.effects, ['open']);
    f.browser.close(); f.browser.openForUser();
    assert.equal(f.browser.owner, 'user'); assert.equal(f.browser.paused, true);
    f.browser.handoff(); assert.equal(f.browser.paused, false);
    f.browser.release(f.cancellation);
    console.log('PASS manual browser respects permission, opens a fresh user session, shares the agent host and preserves existing control');
  }
  {
    const f = fixture('unset'); const save = gate(); let durable = false;
    f.browser.configure(async value => { await save.promise; f.saved.push(value); durable = true; }, () => {});
    let returned = false;
    const opening = f.tools.execute(call('browser_open', { url: 'https://example.com', reason: 'Login required' }), f.cancellation).then(value => { returned = true; return value; });
    await settle(); assert.equal(f.browser.permissionPending, true); assert.equal(f.browser.paused, true);
    assert.deepEqual(f.driver.effects, []); assert.equal(returned, false);
    const saving = f.browser.setEnabled(true); await settle(); assert.equal(f.browser.permissionPending, true);
    assert.deepEqual(f.driver.effects, []); save.resolve(); await saving; await opening;
    assert.equal(durable, true); assert.deepEqual(f.saved, ['enabled']); assert.deepEqual(f.driver.effects, ['open']);
    assert.equal(f.browser.owner, 'agent');
    f.browser.release(f.cancellation);
    console.log('PASS first browser call waits for durable permission before opening; release preserves the page');
  }
  {
    const f = fixture('unset'); const opening = f.tools.execute(call('browser_open', { url: 'https://example.com', reason: 'Login' }), f.cancellation);
    const rejected = assert.rejects(opening, error => error.code === 'USER_DENIED');
    await settle(); await f.browser.setEnabled(false); await rejected;
    assert.deepEqual(f.saved, ['disabled']); assert.equal(f.tools.definitions().length, 0);
    await assert.rejects(f.tools.execute(call('browser_open', { url: 'https://example.com', reason: 'Again' }), f.cancellation), error => error.code === 'PERMISSION_DENIED');
    assert.equal(f.browser.permissionPending, false); assert.ok(!f.driver.effects.includes('open'));
    const failed = fixture('unset'); failed.browser.configure(async () => { throw Error('disk failure'); }, () => {});
    const pending = failed.browser.acquire('thread', 'https://example.com', 'Login', failed.cancellation);
    const cancelled = assert.rejects(pending, error => error.code === 'CANCELLED');
    await settle(); await assert.rejects(failed.browser.setEnabled(true), /disk failure/);
    assert.equal(failed.browser.policy, 'unset'); assert.equal(failed.browser.permissionPending, true);
    assert.equal(failed.browser.error, 'disk failure'); failed.cancellation.cancel(); await cancelled;
    assert.equal(failed.browser.permissionPending, false);
    console.log('PASS explicit disable suppresses future prompts; save failure keeps permission unset and retryable');
  }
  {
    const f = await acquired(); f.driver.hold = gate(); let nextTool = 0;
    const browserCall = call('browser_action', { action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 });
    const nextCall = call('write_file');
    const tools = { definitions: () => f.tools.definitions().concat([{ function: { name: 'write_file' }, executionMode: 'sequential' }]),
      execute: async (value, signal) => { if (value.function.name === 'write_file') { nextTool++; return 'written'; } return f.tools.execute(value, signal); } };
    const step = { content: '', tools: [browserCall, nextCall].map(value => ({ call: value, status: 'pending', output: '' })) };
    let finished = false;
    const batch = executeToolBatch(step, 0, tools, tools.definitions(), f.cancellation,
      { checkpoint: async () => {}, event: () => {}, waitForExecution: signal => f.browser.wait(signal) }).then(() => { finished = true; });
    await f.driver.acted.promise; assert.deepEqual(f.driver.effects, ['open', 'click']);
    f.browser.takeOver(); f.driver.page = 'User edited page'; f.driver.hold.resolve(); await settle();
    assert.equal(f.cancellation.cancelled, false); assert.equal(finished, false); assert.equal(nextTool, 0);
    assert.equal(step.tools[0].output, ''); assert.equal(step.tools[0].status, 'running');
    f.browser.handoff(); await batch;
    const output = JSON.parse(step.tools[0].output);
    assert.equal(output.completed, true); assert.equal(output.userIntervened, true); assert.equal(output.page.text, 'User edited page');
    assert.equal(nextTool, 1); assert.equal(f.driver.effects.filter(value => value === 'click').length, 1);
    await assert.rejects(f.browser.act({ action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 }, f.cancellation), error => error.code === 'STALE_BROWSER_SNAPSHOT');
    console.log('PASS takeover drains the issued action, withholds its receipt and later tools, refreshes on handoff and never replays');
  }
  {
    const f = await acquired(); let next = 0; const entered = gate();
    const step = { content: '', tools: ['first', 'second'].map(name => ({ call: call(name), status: 'pending', output: '' })) };
    const tools = { definitions: () => [], execute: async value => { if (value.function.name === 'first') { f.browser.takeOver(); entered.resolve(); return 'already finished'; } next++; return 'next'; } };
    const batch = executeToolBatch(step, 0, tools, [], f.cancellation,
      { checkpoint: async () => {}, event: () => {}, waitForExecution: signal => f.browser.wait(signal) }, 'sequential');
    await entered.promise; assert.equal(step.tools[0].output, ''); assert.equal(next, 0);
    f.browser.handoff(); await batch; assert.equal(step.tools[0].output, 'already finished'); assert.equal(next, 1);
    console.log('PASS runtime gate also holds non-browser tool results at the completion boundary');
  }
  {
    const f = await acquired(); let checkpoints = 0, requests = 0; const turn = { content: '', steps: [] }; const persisted = gate();
    const model = { stream: async messages => {
      requests++;
      if (requests === 1) return { content: '', toolCalls: [call('browser_snapshot')] };
      const output = JSON.parse(messages.find(message => message.toolCallId === 'browser_snapshot').content);
      assert.equal(output.page.text, 'Changed after the tool completed'); assert.equal(output.userIntervened, true);
      return { content: 'Done', toolCalls: [] };
    } };
    const running = runAgentLoop({ model, messages: [], tools: f.tools, turn, maxSteps: 3 }, f.cancellation,
      { event: () => {}, checkpoint: async () => { if (++checkpoints === 2) { f.browser.takeOver(); f.driver.page = 'Changed after the tool completed'; persisted.resolve(); } },
        waitForExecution: signal => f.browser.wait(signal), refreshToolResult: (value, output, signal) => f.browser.refreshResult(value, output, signal) });
    await persisted.promise; assert.equal(requests, 1); assert.equal(f.browser.paused, true);
    f.browser.handoff(); await running; assert.equal(requests, 2);
    console.log('PASS takeover during receipt persistence refreshes the completed page result before the next model request');
  }
  {
    const f = await acquired(); const requested = gate(), response = gate(); let requests = 0;
    const turn = { content: '', steps: [] };
    const model = { stream: async () => { requests++; requested.resolve(); await response.promise; return { content: 'Done', toolCalls: [] }; } };
    const running = runAgentLoop({ model, messages: [], tools: { definitions: () => [], execute: async () => '' }, turn, maxSteps: 3 },
      f.cancellation, { event: () => {}, checkpoint: async () => {}, waitForExecution: signal => f.browser.wait(signal) });
    await requested.promise; f.browser.takeOver(); response.resolve(); await settle();
    assert.equal(requests, 1); assert.equal(turn.content, ''); assert.equal(turn.steps[0].content, '');
    f.browser.handoff(); await running; assert.equal(turn.content, 'Done'); assert.equal(requests, 1);
    console.log('PASS an in-flight model request completes naturally and its response stays pending until handoff');
  }
  {
    const f = await acquired(); f.browser.takeOver(); let waiting = true;
    const wait = f.browser.wait(f.cancellation).then(() => { waiting = false; });
    const rejected = assert.rejects(wait, error => error.code === 'CANCELLED');
    f.cancellation.cancel(); await rejected; assert.equal(waiting, true); assert.equal(f.browser.hasTask, false);
    const next = new Cancellation(); await f.browser.wait(next); assert.equal(f.browser.open, true);
    const g = await acquired(); g.driver.hold = gate();
    const operation = g.browser.act({ action: 'click', snapshotId: g.receipt.page.snapshotId, elementId: 1 }, g.cancellation);
    const closed = assert.rejects(operation, error => error.code === 'BROWSER_CLOSED');
    await settle(); g.browser.takeOver(); g.browser.close(); g.driver.hold.resolve(); await closed;
    assert.equal(g.browser.paused, false); assert.equal(g.driver.effects.filter(value => value === 'click').length, 1);
    console.log('PASS stop releases pending waits; closing the browser ends the wait without replaying committed effects');
  }
  {
    const f = await acquired(); f.driver.hold = gate();
    const step = { content: '', tools: [{ call: call('browser_action', { action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 }), status: 'pending', output: '' }] };
    const batch = executeToolBatch(step, 0, f.tools, f.tools.definitions(), f.cancellation,
      { event: () => {}, checkpoint: async () => {}, waitForExecution: signal => f.browser.wait(signal), refreshToolResult: (value, output, signal) => f.browser.refreshResult(value, output, signal) });
    const stopped = assert.rejects(batch, error => error.code === 'CANCELLED');
    await f.driver.acted.promise; f.browser.takeOver(); f.driver.hold.resolve(); await settle(); f.cancellation.cancel(); await stopped;
    assert.equal(step.tools[0].status, 'complete'); assert.equal(JSON.parse(step.tools[0].output).completed, true);
    assert.equal(f.driver.effects.filter(value => value === 'click').length, 1);
    console.log('PASS stopping a pending task still checkpoints an already completed browser action');
  }
  {
    const f = fixture(); const entered = gate(), release = gate(); let requests = 0;
    const model = { stream: async () => { requests++; if (requests === 1) { entered.resolve(); await release.promise; } return { content: 'Done', toolCalls: [] }; } };
    const runtime = new AgentRuntime({ bind: () => model }, {}, undefined, undefined, undefined, f.browser);
    const running = runtime.run({ sessionId: 'thread', config: seed().config, messages: [], tools: f.tools },
      { checkpoint: async () => {}, prepare: async signal => { await f.browser.acquire('thread', 'https://example.com', 'Dynamic page', signal); },
        prepareContext: async (boundModel, messages, signal) => { await boundModel.stream([], [], signal, () => {}); return messages; } });
    await entered.promise; f.browser.takeOver(); release.resolve(); await settle();
    assert.equal(requests, 1); assert.equal(runtime.isRunning, true);
    f.browser.handoff(); const result = await running;
    assert.equal(result.status, 'complete'); assert.equal(requests, 2); assert.equal(f.browser.hasTask, false);
    assert.equal(f.browser.open, true); assert.equal(f.browser.owner, 'user');
    console.log('PASS runtime gates preflight summary requests as well as the main model and releases control after completion');
  }
  {
    const f = await acquired(); const readOnly = new BrowserTools(f.browser, 'thread', true);
    await assert.rejects(readOnly.execute(call('browser_action', { action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 }), f.cancellation), error => error.code === 'PERMISSION_DENIED');
    await assert.rejects(f.browser.act({ action: 'reload' }, new Cancellation()), error => error.code === 'BROWSER_NOT_OWNED');
    await assert.rejects(f.tools.execute(call('browser_open', { url: 'https://user:password@example.com', reason: 'Login' }), f.cancellation), error => error.code === 'INVALID_ARGUMENTS');
    await assert.rejects(f.tools.execute(call('browser_action', { action: 'eval', text: 'alert(1)' }), f.cancellation), error => error.code === 'INVALID_ARGUMENTS');
    console.log('PASS ownership, read-only tasks, URL validation and fixed browser action schemas');
  }
  {
    const f = fixture('disabled'); const tools = new ToolSet([f.tools]);
    assert.equal(tools.definitions().length, 0);
    await f.browser.setEnabled(true); assert.equal(tools.definitions().length, 5);
    await f.browser.setEnabled(false); assert.equal(tools.definitions().length, 0);
    await assert.rejects(tools.execute(call('browser_open', { url: 'https://example.com', reason: 'Disabled' }), f.cancellation), error => error.code === 'TOOL_UNAVAILABLE');
    assert.equal(f.browser.permissionPending, false);
    console.log('PASS live permission changes update both the model catalog and dispatch, including enable during a running task');
  }
  {
    const f = await acquired();
    const { ToolFailure } = load(path.join(root, 'main/ets/model/ToolFailure'));
    f.driver.act = async () => { throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Viewing changed the page.', 'read_browser_snapshot'); };
    await assert.rejects(f.browser.act({ action: 'click', snapshotId: f.receipt.page.snapshotId, elementId: 1 }, f.cancellation),
      error => error.code === 'STALE_BROWSER_SNAPSHOT');
    assert.equal(f.browser.error, '', 'A stale observation must not turn normal viewing into a page-loading error');
    assert.equal(f.browser.paused, false); assert.equal(f.browser.owner, 'agent');
    assert.notEqual((await f.browser.snapshot(f.cancellation)).snapshotId, f.receipt.page.snapshotId);
    assert.ok(f.logs.some(log => log.event === 'observation_changed' && log.error.code === 'STALE_BROWSER_SNAPSHOT'));
    console.log('PASS stale viewing observations remain explicit tool failures, refresh without taking control and do not show a loading error');
  }
  {
    const f = await acquired();
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const driver = new NativeBrowserDriver(f.browser);
    const touch = (type, x, y, count = 1, id = 1) => driver.userTouch({ type,
      changedTouches: [{ id, screenX: x, screenY: y }], touches: Array.from({ length: count }, (_, i) => ({ id: i + 1 })) });
    touch(TouchType.Down, 100, 100);
    assert.equal(f.browser.paused, false, 'Pressing down to begin viewing must not take control');
    touch(TouchType.Move, 100, 150); touch(TouchType.Move, 100, 100); touch(TouchType.Up, 100, 100);
    assert.equal(f.browser.paused, false, 'A drag remains viewing even when it returns to its origin');
    touch(TouchType.Down, 100, 100); touch(TouchType.Down, 200, 100, 2, 2);
    touch(TouchType.Up, 200, 100, 2, 2); touch(TouchType.Up, 100, 100);
    assert.equal(f.browser.paused, false, 'Pinch gestures must not take control');
    touch(TouchType.Down, 100, 100); touch(TouchType.Cancel, 100, 100); touch(TouchType.Up, 100, 100);
    assert.equal(f.browser.paused, false, 'A cancelled gesture cannot become a click');
    touch(TouchType.Down, 100, 100); touch(TouchType.Up, 102, 102);
    assert.equal(f.browser.paused, true, 'A tap transfers control before continuing page interaction');
    f.browser.handoff();
    assert.equal(driver.userBack(), false); assert.equal(driver.userForward(), false);
    assert.equal(f.browser.paused, false, 'Empty history must not pause a task');
    assert.deepEqual(driver.controller.effects, []);
    driver.controller.backAvailable = true; driver.historyChanged();
    assert.equal(f.browser.canGoBack, true); assert.equal(f.browser.canGoForward, false);
    assert.equal(driver.userBack(), true); assert.equal(f.browser.paused, true);
    assert.deepEqual(driver.controller.effects, ['back']);
    f.browser.handoff(); driver.controller.forwardAvailable = true; driver.historyChanged();
    assert.equal(driver.userForward(), true); assert.equal(f.browser.paused, true);
    driver.close(); assert.equal(f.browser.canGoBack, false); assert.equal(f.browser.canGoForward, false);
    driver.pageEnd('about:blank');
    const first = driver.open('https://example.com'); await settle();
    driver.controller.backAvailable = true; driver.pageEnd('https://example.com'); await first;
    assert.equal(f.browser.canGoBack, false, 'The internal blank page must not become user history');
    assert.ok(driver.controller.effects.includes('clearHistory'));
    driver.controller.effects = [];
    const second = driver.open('https://example.com/next'); await settle();
    driver.controller.backAvailable = true; driver.pageEnd('https://example.com/next'); await second;
    assert.equal(f.browser.canGoBack, true, 'Subsequent browser_open calls preserve real history');
    assert.deepEqual(driver.controller.effects, ['navigate']);
    console.log('PASS native viewing gestures keep the task running; taps and available navigation take control; empty history does not');
  }
  {
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const f = fixture(); f.browser.openForUser();
    const driver = new NativeBrowserDriver(f.browser);
    driver.pageEnd('about:blank');
    driver.userNavigate('https://example.com'); driver.controller.backAvailable = true;
    driver.pageEnd('https://example.com');
    assert.equal(f.browser.canGoBack, false); assert.equal(f.browser.url, 'https://example.com');
    assert.deepEqual(driver.controller.effects, ['navigate', 'clearHistory']);
    driver.userNavigate('https://example.com/next'); driver.controller.backAvailable = true;
    driver.pageEnd('https://example.com/next');
    assert.equal(f.browser.canGoBack, true);
    assert.deepEqual(driver.controller.effects, ['navigate', 'clearHistory', 'navigate']);
    console.log('PASS manual navigation removes the internal blank page from history and preserves subsequent pages');
  }
  {
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const f = fixture(); f.browser.openForUser();
    const driver = new NativeBrowserDriver(f.browser);
    driver.controller.url = 'https://example.com/current'; driver.pageEnd(driver.controller.url);
    const capture = await driver.capture();
    assert.equal(capture.pixel, capturedPixel); assert.equal(capture.url, 'https://example.com/current');
    assert.equal(capture.width, 900); assert.equal(capture.height, 1200);
    captureResult.before = async () => { driver.controller.url = 'https://example.com/redirect'; };
    await assert.rejects(driver.capture(), error => error.code === 'STALE_BROWSER_SNAPSHOT');
    assert.equal(captureResult.released, 1, 'Discarded captures release their native surface pixels');
    captureResult.before = async () => {};
    console.log('PASS native annotation captures the Web surface and rejects page changes with pixel cleanup');
  }
  {
    const { NativeBrowserDriver } = load(path.join(root, 'main/ets/services/NativeBrowserDriver'));
    const browser = new BrowserSession(); browser.open = true;
    const driver = new NativeBrowserDriver(browser); driver.pageEnd('https://example.com');
    const page = { snapshotId: 'native-1', url: 'https://example.com', title: 'Native browser', text: 'Quoted "text" and 中文',
      elements: [], truncated: false, embeddedFrames: 0, trust: 'untrusted' };
    nativeResult.value = JSON.stringify(page);
    const observed = await driver.snapshot('native-1');
    assert.equal(observed.text, page.text); assert.equal(observed.snapshotId, page.snapshotId);
    nativeResult.value = JSON.stringify({ ok: true });
    await driver.act({ action: 'scroll', deltaY: 20 });
    nativeResult.type = nativeWebview.JsMessageType.NONE;
    await assert.rejects(driver.snapshot('native-1'), error => error.code === 'INVALID_RESPONSE');
    console.log('PASS native ArkWeb string transport preserves JSON text and rejects missing script results');
  }
  {
    const f = new Fixture(seed()); await f.session.initialize();
    await f.session.setBrowserPolicy('enabled');
    assert.equal((await f.repository.load()).extensions.browserPolicy, 'enabled');
    const data = f.session.snapshot();
    assert.equal(await f.session.saveSettings('User document', false, false), true);
    assert.equal(f.session.snapshot().extensions.browserPolicy, 'enabled');
    assert.equal(f.session.snapshot().extensions.skills.length, data.extensions.skills.length);
    const hold = gate(), entered = gate();
    f.repository.beforeSave = async () => { entered.resolve(); await hold.promise; };
    const saving = f.session.setBrowserPolicy('disabled'); await entered.promise;
    f.session.setDraft('Typed while permission saves'); hold.resolve(); await saving;
    assert.equal(f.session.snapshot().threads[0].draft, 'Typed while permission saves');
    assert.equal((await f.repository.load()).threads[0].draft, 'Typed while permission saves');
    f.repository.beforeSave = async () => { throw Error('permission disk error'); };
    await assert.rejects(f.session.setBrowserPolicy('enabled'), /permission disk error/);
    assert.equal(f.session.snapshot().extensions.browserPolicy, 'disabled');
    console.log('PASS permission persists independently, survives ordinary settings saves and preserves concurrent drafts');
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
