// Exercise the actual adapters with controlled native callbacks and engine creation races.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map(), timers = new Map(), callbacks = new Set();
let timerId = 0, capability = true, create;
const app = { on: (_, cb) => callbacks.add(cb), off: (_, cb) => callbacks.delete(cb) };
const context = { getApplicationContext: () => app };
const kits = {
  '@kit.CoreSpeechKit': { textToSpeech: { createEngine: params => create(params) } },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } }
};
function load(relative) {
  const file = path.resolve(relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(compiled, { exports,
    require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id],
    Observed: value => value, canIUse: () => capability, Error,
    setTimeout: (fn, delay) => { timers.set(++timerId, { fn, delay }); return timerId; },
    clearTimeout: id => timers.delete(id)
  }, { filename: file });
  return exports;
}
const { AnswerSpeech } = load(path.join(root, 'services/AnswerSpeech'));
const { LaunchActions } = load(path.join(root, 'services/LaunchActions'));
const { answerSpeechText, answerSpeechChunks } = load(path.join(root, 'model/AnswerSpeechText'));
function engine() {
  return { spoken: [], closed: 0, stopped: 0,
    setListener(listener) { this.listener = listener; },
    speak(text, params) {
      assert.ok(text.length <= 10000); this.spoken.push({ text, id: params.requestId });
      this.listener.onStart(params.requestId, {});
    },
    stop() { this.stopped++; this.listener?.onStop(this.spoken.at(-1)?.id, {}); },
    shutdown() { this.closed++; },
    complete(type = 1, id = this.spoken.at(-1).id) { this.listener.onComplete(id, { type }); }
  };
}
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
async function drain() { for (let i = 0; i < 8; i++) await Promise.resolve(); }
const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('prose and tables are read; code, generated UI, image URLs and markdown syntax are omitted', () => {
  const text = answerSpeechText('# 标题\n**你好** [世界](https://example.com)\n![图](https://example.com/a.png)\n```tinybot-ui\n{"secret":"payload"}\n```\n```ts\nsecret()\n```\n| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 2 |');
  assert.match(text, /标题\n你好 世界/); assert.match(text, /苹果，2/);
  assert.doesNotMatch(text, /https|secret|payload|\*\*/);
  assert.equal(answerSpeechText('```tinybot-ui\n{}\n```'), '');
  const long = 'a'.repeat(8999) + '😀' + 'b'.repeat(14000);
  const chunks = answerSpeechChunks(long);
  assert.equal(chunks.join(''), long);
  for (const chunk of chunks) assert.ok(!/[\uD800-\uDBFF]$/.test(chunk));
});
test('long answers advance only after playback completion; duplicate callbacks cannot advance twice', async () => {
  const native = engine(); create = async params => { assert.equal(params.online, 1); return native; };
  const speech = new AnswerSpeech(); await speech.start(context, 'answer', '中'.repeat(19000));
  const first = native.spoken[0].id;
  native.complete(0); assert.equal(native.spoken.length, 1); assert.equal(speech.messageId, 'answer');
  native.complete(); assert.equal(native.spoken.length, 2);
  native.complete(1, first); assert.equal(native.spoken.length, 2);
  native.complete(); native.complete();
  assert.equal(native.spoken.map(x => x.text).join(''), '中'.repeat(19000));
  assert.equal(new Set(native.spoken.map(x => x.id)).size, 3);
  assert.equal(speech.messageId, ''); assert.equal(native.closed, 1);
});
test('cancelled initialization cannot play, and replacement waits for its cleanup', async () => {
  const pending = deferred(), old = engine(), next = engine(); let calls = 0;
  create = () => ++calls === 1 ? pending.promise : Promise.resolve(next);
  const speech = new AnswerSpeech(); const first = speech.start(context, 'old', '旧回答'); await drain();
  const second = speech.start(context, 'new', '新回答'); await drain(); assert.equal(calls, 1);
  pending.resolve(old); await first; await second;
  assert.equal(old.spoken.length, 0); assert.equal(old.closed, 1); assert.equal(speech.messageId, 'new');
  speech.stop(); assert.equal(next.closed, 1);
});
test('background stops playback and late errors cannot affect the next answer', async () => {
  const first = engine(), next = engine(); create = async () => first;
  const speech = new AnswerSpeech(); await speech.start(context, 'first', '你好'); const id = first.spoken[0].id;
  for (const cb of [...callbacks]) cb.onApplicationBackground();
  assert.equal(speech.messageId, ''); assert.equal(first.closed, 1);
  create = async () => next; await speech.start(context, 'next', '你好');
  first.listener.onError(id, 123, 'late'); first.complete(1, id);
  assert.equal(speech.messageId, 'next'); assert.equal(speech.error, ''); speech.stop();
});
test('creation errors, native playback errors and missing capabilities remain visible', async () => {
  const speech = new AnswerSpeech(); create = async () => { throw Object.assign(new Error('voice not installed'), { code: 123 }); };
  await speech.start(context, 'en', 'Hello'); assert.match(speech.error, /123.*voice not installed/);
  const native = engine(); create = async params => { assert.equal(params.language, 'en-US'); assert.equal(params.person, 8); return native; };
  await speech.start(context, 'en', 'Hello'); native.listener.onError(native.spoken[0].id, 456, 'play failed');
  assert.match(speech.error, /456.*play failed/); assert.equal(native.closed, 1);
  capability = false; await speech.start(context, 'a', '你好'); assert.match(speech.error, /不支持/);
  capability = true;
});
test('initialization timeout invalidates late engines', async () => {
  const pending = deferred(), native = engine(); create = () => pending.promise;
  const speech = new AnswerSpeech(); const started = speech.start(context, 'a', '你好'); await drain();
  [...timers.values()][0].fn(); assert.match(speech.error, /超时/);
  pending.resolve(native); await started; assert.equal(native.spoken.length, 0); assert.equal(native.closed, 1);
});
test('shortcut delivery waits for foreground and subscriber; invalid wants and repeated foreground do not replay', () => {
  const received = []; LaunchActions.setForeground(false);
  LaunchActions.receive({ parameters: { tinybotAction: 'voice-input' } });
  const unsubscribe = LaunchActions.subscribe(() => received.push(LaunchActions.take()));
  assert.equal(received.length, 0); LaunchActions.setForeground(true);
  assert.deepEqual(received, ['voice-input']); LaunchActions.setForeground(true);
  LaunchActions.receive({ parameters: { tinybotAction: 'unsupported' } });
  LaunchActions.receive({ action: 'ohos.want.action.home' }); assert.equal(received.length, 1);
  LaunchActions.receive({ parameters: { tinybotAction: 'new-chat' } });
  assert.deepEqual(received, ['voice-input', 'new-chat']); unsubscribe();
  LaunchActions.receive({ parameters: { tinybotAction: 'new-chat' } });
  const detach = LaunchActions.subscribe(() => received.push(LaunchActions.take()));
  assert.equal(received.length, 3); detach(); LaunchActions.setForeground(false);
  LaunchActions.receive({ parameters: { tinybotAction: 'continue-chat' } });
  assert.equal(LaunchActions.take(), undefined, 'Cold-start card intent waits for foreground');
  LaunchActions.setForeground(true);
  const stop = LaunchActions.subscribe(() => received.push(LaunchActions.take()));
  assert.equal(received.at(-1), 'continue-chat');
  assert.equal(LaunchActions.take(), undefined, 'Card intent is consumed exactly once');
  stop(); LaunchActions.setForeground(false);
});
(async () => {
  for (const { name, fn } of tests) {
    await fn(); assert.equal(callbacks.size, 0, 'no leaked application listeners');
    assert.equal(timers.size, 0, 'no leaked timers'); console.log('PASS ' + name);
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
