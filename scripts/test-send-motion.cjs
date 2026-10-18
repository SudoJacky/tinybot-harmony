// Exercise the compiled lifecycle and send callback; native rendering is checked on device.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function methods(file, component, names) {
  const source = path.join(root, 'entry/src/main/ets', file + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const declaration = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === component);
  return declaration.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n');
}
class SendFrame { constructor(action) { this.action = action; } onFrame() { this.action(); } }
const globals = { exports: {}, SendFrame, Set, clearTimeout, Edge: { Bottom: 'bottom' }, curves: { springMotion: (...args) => args } };
vm.runInNewContext(ts.transpileModule(`
class Bubble { ${methods('common/SendBubbleMotion', 'SendBubbleMotion', ['aboutToAppear', 'aboutToDisappear', 'launch'])} }
class Panel { ${methods('views/ChatPanel', 'ChatPanel', ['send', 'finishSendFlight'])} }
exports.Bubble = Bubble; exports.Panel = Panel;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
function bubble(origin) {
  const frames = [], animations = [];
  const value = Object.assign(new globals.exports.Bubble(), { origin, bubbleId: 'bubble', started: false,
    shiftX: 0, shiftY: 0, bubbleScale: 1, alpha: 1, ready: 0, finished: 0,
    onReady() { this.ready++; }, onFinish() { this.finished++; } });
  value.rect = { windowOffset: { x: 600, y: 200 }, size: { width: 200, height: 100 } };
  value.getUIContext = () => ({ px2vp: px => px / 2, postFrameCallback: frame => frames.push(frame),
    getComponentUtils: () => ({ getRectangleById: () => value.rect }),
    animateTo: (options, update) => { animations.push({ options, start: [value.shiftX, value.shiftY, value.bubbleScale, value.alpha] }); update(); } });
  value.aboutToAppear();
  return { value, frames, animations, flush() { while (frames.length) frames.shift().onFrame(); } };
}
const origin = { x: 200, y: 600, height: 44, viewportHeight: 700 };
const live = bubble(origin);
live.value.launch(); live.value.launch(); live.flush();
assert.equal(live.value.ready, 1, 'Layout changes must not relaunch');
assert.equal(live.animations.length, 1);
assert.deepEqual(live.animations[0].start, [-150, 475, 0.88, 0.72], 'Launch from measured composer center after px/vp conversion');
assert.deepEqual([live.value.shiftX, live.value.shiftY, live.value.bubbleScale, live.value.alpha], [0, 0, 1, 1]);
live.animations[0].options.onFinish(); assert.equal(live.value.finished, 1);
const history = bubble(undefined); history.value.launch(); history.flush();
assert.equal(history.value.alpha, 1); assert.equal(history.animations.length, 0);
const gone = bubble(origin); gone.value.launch(); gone.value.aboutToDisappear(); gone.flush();
assert.equal(gone.animations.length, 0, 'Navigation cancels pending frame work');
const tall = bubble(origin); tall.value.rect.size.height = 1600; tall.value.launch(); tall.flush();
assert.deepEqual(tall.animations[0].start, [0, 20, 1, 0.72], 'Oversized content uses a small entrance');

function panel(messages = []) {
  let update;
  const value = Object.assign(new globals.exports.Panel(), { thread: { id: 'thread', messages }, sendingMessageId: '',
    keyboardFocusRequest: 0, composerFocused: true, clearedFocus: 0,
    speechActive: () => false, scroller: { scrollEdge() {} }, follow() {},
    getUIContext: () => ({ px2vp: x => x, postFrameCallback() {},
      getFocusController: () => ({ clearFocus() { value.clearedFocus++; } }), getComponentUtils: () => ({
      getRectangleById: () => ({ windowOffset: { x: 0, y: 500 }, size: { width: 320, height: 44 } }) }) }),
    app: { send: cb => { update = cb; } } });
  value.send(); return { value, update: () => update() };
}
const first = panel(); first.update(); assert.equal(first.value.sendingMessageId, '', 'Validation failure/commands do not fly');
assert.equal(first.value.clearedFocus, 0, 'Rejected sends keep the keyboard and input focus');
assert.equal(first.value.composerFocused, true);
first.value.thread.messages.push({ id: 'first', role: 'user' }); first.update();
assert.equal(first.value.sendingMessageId, 'first', 'First message in an empty thread must fly');
assert.equal(first.value.clearedFocus, 1, 'An accepted message dismisses the keyboard');
assert.equal(first.value.composerFocused, false);
assert.equal(first.value.keyboardFocusRequest, 1, 'Invalidate any pending composer focus request');
first.value.finishSendFlight('first');
first.value.composerFocused = true;
first.value.thread.messages.push({ id: 'queued', role: 'user' }); first.update();
assert.equal(first.value.sendingMessageId, '', 'Queue/output updates do not replay a completed send');
assert.equal(first.value.clearedFocus, 1, 'Streaming and queued output do not dismiss a reopened keyboard');
assert.equal(first.value.composerFocused, true);
const switched = panel([{ id: 'old', role: 'user' }]); switched.value.thread.id = 'other';
switched.value.thread.messages.push({ id: 'elsewhere', role: 'user' }); switched.update();
assert.equal(switched.value.sendingMessageId, '', 'A different thread cannot inherit a pending send');
assert.equal(switched.value.clearedFocus, 0, 'Late updates from another thread do not change keyboard focus');
console.log('PASS send origin, landing, one-shot lifecycle, history, navigation, tall content, accepted-send keyboard dismissal, rejected send and queued output');
