// Run the real ArkTS adapter with controlled native permission, engine and lifecycle callbacks.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map(), timers = new Map(), callbacks = new Set();
let capability, permission, setting, create, engines, timerId = 0, permissionCalls, settingCalls;
const appContext = { on: (event, cb) => { assert.equal(event, 'applicationStateChange'); callbacks.add(cb); },
  off: (event, cb) => { assert.equal(event, 'applicationStateChange'); callbacks.delete(cb); } };
const context = { getApplicationContext: () => appContext };
const kits = {
  '@kit.AbilityKit': { abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
    requestPermissionsFromUser: async (ctx, permissions) => {
      assert.equal(ctx, context); assert.deepEqual(Array.from(permissions), ['ohos.permission.MICROPHONE']);
      permissionCalls++; return permission();
    },
    requestPermissionOnSetting: async (ctx, permissions) => {
      assert.equal(ctx, context); assert.deepEqual(Array.from(permissions), ['ohos.permission.MICROPHONE']);
      settingCalls++; return setting();
    }
  }) } },
  '@kit.CoreSpeechKit': { speechRecognizer: { createEngine: params => {
    assert.equal(params.language, 'zh-CN'); assert.equal(params.online, 1);
    assert.equal(params.extraParams.recognizerMode, 'long'); return create();
  } } },
  '@kit.PerformanceAnalysisKit': { hilog: { warn: () => {} } }
};
function load(relative) {
  const file = path.resolve(relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(compiled, { exports, require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id],
    Observed: value => value, canIUse: cap => { assert.equal(cap, 'SystemCapability.AI.SpeechRecognizer'); return capability; },
    setTimeout: (fn, delay) => { timers.set(++timerId, { fn, delay }); return timerId; }, clearTimeout: id => timers.delete(id), Error }, { filename: file });
  return exports;
}
const { SpeechInput } = load(path.join(root, 'services/SpeechInput'));
const { DictationDraft } = load(path.join(root, 'model/DictationDraft'));
const { VoicePillGesture } = load(path.join(root, 'common/VoicePillGesture'));
function engine() {
  const item = { started: 0, cancelled: 0, closed: 0, finished: 0,
    setListener(listener) { this.listener = listener; },
    startListening(params) {
      this.started++; this.id = params.sessionId;
      assert.equal(params.extraParams.recognitionMode, 0);
      assert.equal(params.extraParams.maxAudioDuration, 600000);
      assert.equal(params.audioInfo.sampleRate, 16000);
      this.listener.onStart(this.id, 'started');
    },
    finish(id) { assert.equal(id, this.id); this.finished++; },
    cancel(id) { assert.equal(id, this.id); this.cancelled++; },
    shutdown() { this.closed++; },
    result(text, isFinal = false, isLast = false) { this.listener.onResult(this.id, { result: text, isFinal, isLast }); },
    complete() { this.listener.onComplete(this.id, 'complete'); },
    fail(code) { this.listener.onError(this.id, code, 'native failure'); }
  };
  engines.push(item); return item;
}
function reset() {
  assert.equal(callbacks.size, 0, 'no leaked lifecycle registration');
  assert.equal(timers.size, 0, 'no leaked timer');
  engines = []; capability = true; permissionCalls = 0; settingCalls = 0; setting = async () => [0];
  permission = async () => ({ authResults: [0] }); create = async () => engine();
}
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function drain() { for (let i = 0; i < 8; i++) await Promise.resolve(); }
function fire(delay) {
  const entry = [...timers.entries()].find(([, timer]) => timer.delay === delay);
  assert.ok(entry, `timer ${delay} exists`); timers.delete(entry[0]); entry[1].fn();
}
const cases = [];
const test = (name, run) => cases.push({ name, run });

test('dictation writes each partial directly to composer, replaces the current clause and waits for final text on stop', async () => {
  const speech = new SpeechInput(); let draft = '原草稿', completed = 0;
  const transaction = new DictationDraft(draft);
  speech.onResult = text => { draft = transaction.update(draft, text); };
  speech.onComplete = () => { completed++; };
  await speech.start(context); const native = engines[0];
  assert.equal(speech.phase, 'listening');
  native.result('你'); assert.equal(draft, '原草稿\n你');
  native.result('你好'); assert.equal(draft, '原草稿\n你好'); native.result('你好。', true);
  native.result('接'); native.result('接下来');
  assert.equal(speech.text, '你好。接下来'); assert.equal(draft, '原草稿\n你好。接下来');
  speech.finish();
  assert.equal(speech.phase, 'finishing'); assert.equal(completed, 0);
  native.result('接下来。', true, true); native.complete(); native.complete();
  assert.equal(draft, '原草稿\n你好。接下来。'); assert.equal(completed, 1);
  assert.equal(native.closed, 1); assert.equal(native.cancelled, 0);
});
test('equal consecutive sentences are not incorrectly deduplicated', async () => {
  const speech = new SpeechInput(); await speech.start(context);
  engines[0].result('好的。', true); engines[0].result('好的。', true, true); engines[0].complete();
  assert.equal(speech.text, '好的。好的。');
});
test('cancel discards preview and ignores late native callbacks', async () => {
  const speech = new SpeechInput(); let completed = false; speech.onComplete = () => { completed = true; };
  await speech.start(context); const native = engines[0]; native.result('取消的文字'); speech.cancel();
  native.result('迟到的文字', true, true); native.complete(); native.fail(1002200011);
  assert.equal(speech.phase, 'idle'); assert.equal(speech.text, ''); assert.equal(speech.error, '');
  assert.equal(completed, false); assert.equal(native.cancelled, 1); assert.equal(native.closed, 1);
});
test('permission denial never creates an engine and can be retried', async () => {
  permission = async () => ({ authResults: [-1] }); const speech = new SpeechInput(); await speech.start(context);
  assert.equal(engines.length, 0); assert.match(speech.error, /麦克风权限/); assert.equal(speech.phase, 'error');
  permission = async () => ({ authResults: [0] }); await speech.start(context); assert.equal(speech.phase, 'listening'); speech.cancel();
});
test('missing system capability is explicit and does not request permission', async () => {
  capability = false; const speech = new SpeechInput(); await speech.start(context);
  assert.match(speech.error, /不支持/); assert.equal(permissionCalls, 0); assert.equal(engines.length, 0);
});
test('denied microphone permission opens settings only on an explicit subsequent action', async () => {
  permission = async () => ({ authResults: [-1] }); const speech = new SpeechInput(); await speech.start(context);
  assert.equal(speech.permissionDenied, true); assert.equal(settingCalls, 0);
  await speech.start(context, true); assert.equal(settingCalls, 1); assert.equal(speech.phase, 'listening'); speech.cancel();
});
test('cancel during permission settings cannot start recording after permission resolves', async () => {
  permission = async () => ({ authResults: [-1] }); const pending = deferred(); setting = () => pending.promise;
  const speech = new SpeechInput(), start = speech.start(context, true); await drain(); speech.cancel();
  pending.resolve([0]); await start; assert.equal(engines.length, 0); assert.equal(speech.phase, 'idle');
});
test('closing during permission request cannot start recording after permission resolves', async () => {
  const pending = deferred(); permission = () => pending.promise;
  const speech = new SpeechInput(), start = speech.start(context); speech.cancel();
  pending.resolve({ authResults: [0] }); await start;
  assert.equal(speech.phase, 'idle'); assert.equal(engines.length, 0);
});
test('closing during engine creation releases the late engine without recording', async () => {
  const pending = deferred(); create = () => pending.promise;
  const speech = new SpeechInput(), start = speech.start(context); await drain(); speech.cancel();
  const native = engine(); pending.resolve(native); await start;
  assert.equal(native.started, 0); assert.equal(native.closed, 1); assert.equal(speech.phase, 'idle');
});
test('an old start resolving cannot disturb a new session', async () => {
  const pending = deferred(); create = () => pending.promise;
  const speech = new SpeechInput(), oldStart = speech.start(context); await drain();
  create = async () => engine(); await speech.start(context); const current = engines[0];
  const old = engine(); pending.resolve(old); await oldStart;
  assert.equal(old.started, 0); assert.equal(old.closed, 1); assert.equal(current.closed, 0);
  current.result('新会话', true, true); current.complete(); assert.equal(speech.text, '新会话');
});
test('background cancels recording and notifies the panel to close', async () => {
  const speech = new SpeechInput(); let closed = 0; speech.onBackground = () => closed++;
  await speech.start(context); [...callbacks][0].onApplicationBackground();
  assert.equal(closed, 1); assert.equal(engines[0].closed, 1); assert.equal(speech.phase, 'idle');
});
test('native error retains recognized text for explicit recovery and releases capture', async () => {
  const speech = new SpeechInput(); await speech.start(context); engines[0].result('已识别'); engines[0].fail(1002200011);
  assert.equal(speech.text, '已识别'); assert.equal(speech.phase, 'error'); assert.match(speech.error, /1002200011/);
  assert.equal(engines[0].closed, 1);
});
test('engine creation errors expose the actual error code', async () => {
  create = async () => { throw Object.assign(new Error('unavailable'), { code: 1002200001 }); };
  const speech = new SpeechInput(); await speech.start(context);
  assert.equal(speech.phase, 'error'); assert.match(speech.error, /1002200001/);
});
test('empty recognition completes without an error and preserves the existing draft', async () => {
  const speech = new SpeechInput(); let draft = '原草稿', completed = 0;
  const transaction = new DictationDraft(draft);
  speech.onResult = text => { draft = transaction.update(draft, text); };
  speech.onComplete = () => { completed++; };
  await speech.start(context); speech.finish(); engines[0].result('', true, true); engines[0].complete();
  assert.equal(speech.phase, 'complete'); assert.equal(speech.error, ''); assert.equal(speech.text, '');
  assert.equal(draft, '原草稿'); assert.equal(completed, 1); assert.equal(engines[0].closed, 1);
});
test('engine initialization timeout releases a late engine', async () => {
  const pending = deferred(); create = () => pending.promise;
  const speech = new SpeechInput(), start = speech.start(context); await drain(); fire(15000);
  assert.match(speech.error, /超时/); const native = engine(); pending.resolve(native); await start;
  assert.equal(native.started, 0); assert.equal(native.closed, 1);
});
test('finish timeout stops capture and retains text', async () => {
  const speech = new SpeechInput(); await speech.start(context); engines[0].result('保留'); speech.finish(); fire(10000);
  assert.equal(speech.text, '保留'); assert.match(speech.error, /超时/); assert.equal(engines[0].closed, 1);
});
test('duration limit finishes recording and waits for the last clause', async () => {
  const speech = new SpeechInput(); await speech.start(context); fire(600000);
  assert.equal(speech.phase, 'finishing'); assert.equal(engines[0].finished, 1);
  engines[0].result('最后一句', true, true); engines[0].complete(); assert.equal(speech.text, '最后一句');
});
test('draft bounds reject without truncation and keep transcript available', async () => {
  const speech = new SpeechInput(); await speech.start(context); engines[0].result('完整识别文字', true, true); engines[0].complete();
  const draft = new DictationDraft('x'.repeat(24000));
  assert.throws(() => draft.update('x'.repeat(24000), speech.text), /24000/);
  assert.equal(speech.text, '完整识别文字'); assert.equal(new DictationDraft('原文\n').update('原文\n', '文字'), '原文\n文字');
});
test('cancel restores the original draft and late recognition cannot reinsert it', async () => {
  const speech = new SpeechInput(); let current = '原有文字'; const draft = new DictationDraft(current);
  speech.onResult = text => { current = draft.update(current, text); };
  await speech.start(context); engines[0].result('本次听写');
  assert.equal(current, '原有文字\n本次听写'); current = draft.cancel(current); speech.cancel();
  engines[0].result('迟到结果', true, true); assert.equal(current, '原有文字');
});
test('external edits win over both dictation updates and rollback', async () => {
  const draft = new DictationDraft('原文'); draft.update('原文', '听写');
  assert.throws(() => draft.update('外部修改', '继续听写'), /草稿已修改/);
  assert.equal(draft.cancel('外部修改'), '外部修改');
});
test('background keeps words already written into composer and ignores subsequent text', async () => {
  const speech = new SpeechInput(); let current = ''; const draft = new DictationDraft(current);
  speech.onResult = text => { current = draft.update(current, text); };
  await speech.start(context); engines[0].result('已经写入'); [...callbacks][0].onApplicationBackground();
  engines[0].result('迟到结果'); assert.equal(current, '已经写入'); assert.equal(speech.phase, 'idle');
});
test('native voice activity drives the visual state and stops when capture ends', async () => {
  const speech = new SpeechInput(); await speech.start(context); const native = engines[0];
  assert.ok(speech.startedAt > 0); assert.equal(speech.speaking, false);
  native.listener.onEvent(native.id, 1, 'speech started'); assert.equal(speech.speaking, true);
  native.listener.onEvent(native.id, 3, 'speech stopped'); assert.equal(speech.speaking, false);
  native.listener.onEvent(native.id, 1, 'speech started'); speech.cancel();
  native.listener.onEvent(native.id, 1, 'late event'); assert.equal(speech.speaking, false);
});
test('a tap starts on release and a second tap finishes', () => {
  const gesture = new VoicePillGesture(); assert.equal(gesture.down(1, 300, false), true);
  assert.equal(gesture.up(1), 'start'); gesture.down(2, 300, true); assert.equal(gesture.up(2), 'finish');
});
test('a hold starts once and release finishes without a second toggle', () => {
  const gesture = new VoicePillGesture(); gesture.down(1, 300, false);
  assert.equal(gesture.hold(), 'start'); assert.equal(gesture.hold(), 'none');
  assert.equal(gesture.up(1), 'finish'); assert.equal(gesture.up(1), 'none');
});
test('left swipe cancels once, reversals below threshold preserve the active recording', () => {
  const gesture = new VoicePillGesture(); gesture.down(1, 300, true);
  assert.equal(gesture.move(1, 250, true), 'none'); assert.equal(gesture.pull, 50);
  gesture.move(1, 295, true); assert.equal(gesture.pull, 5);
  assert.equal(gesture.move(1, 236, true), 'cancel'); assert.equal(gesture.move(1, 220, true), 'none');
  assert.equal(gesture.up(1), 'none');
});
test('extra fingers and interrupted presses cannot start or stop another gesture', () => {
  const gesture = new VoicePillGesture(); gesture.down(1, 300, false);
  assert.equal(gesture.down(2, 100, false), false); assert.equal(gesture.up(2), 'none');
  assert.equal(gesture.move(2, 0, true), 'none'); assert.equal(gesture.interrupt(), 'none');
  assert.equal(gesture.hold(), 'none'); assert.equal(gesture.up(1), 'none');
  gesture.down(3, 300, false); gesture.hold(); assert.equal(gesture.interrupt(), 'cancel');
});
(async () => {
  for (const { name, run } of cases) { reset(); await run(); console.log('PASS ' + name); }
  reset(); console.log(`Passed ${cases.length} speech input adapter tests.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
