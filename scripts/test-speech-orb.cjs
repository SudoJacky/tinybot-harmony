// Run after devecocli build. Exercise the emitted Orb and start/stop button lifecycles.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'entry/src/main/ets/common/SpeechOrb.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/common/SpeechOrb.ts');
assert.ok(fs.existsSync(emitted) && fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build SpeechOrb before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'SpeechOrb');
const names = ['aboutToDisappear', 'active', 'stop', 'rgb', 'syncAnimation', 'orbPath', 'wash', 'draw', 'label'];
const methods = component.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n');
let now = 1000;
class Clock extends Date { static now() { return now; } }
const scope = { exports: {}, Date: Clock, t: text => text,
  ColorMetrics: { resourceColor: () => ({ red: 33, green: 100, blue: 81 }) } };
vm.runInNewContext(ts.transpileModule(`class Orb { ${methods} } exports.Orb = Orb;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, scope);
function orb() {
  const frames = [], paint = { clears: 0, gradients: 0, depth: 0, points: [] };
  const finite = (...args) => args.forEach(n => assert.ok(Number.isFinite(n), 'Finite drawing coordinates'));
  const canvas = { width: 144, height: 112,
    clearRect: () => paint.clears++, fillRect: finite, beginPath() {}, closePath() {}, clip() {}, stroke() {},
    save: () => paint.depth++, restore: () => { paint.depth--; assert.ok(paint.depth >= 0); },
    moveTo: (...args) => { finite(...args); paint.points.push(args); }, lineTo: finite,
    createRadialGradient(...args) { finite(...args); paint.gradients++; return { addColorStop: finiteStop }; },
    createLinearGradient(...args) { finite(...args); paint.gradients++; return { addColorStop: finiteStop }; } };
  function finiteStop(offset, color) { finite(offset); assert.ok(!color.includes('NaN')); }
  const value = Object.assign(new scope.exports.Orb(), { ready: true, visible: true, foreground: true,
    phase: 'listening', speaking: false, canvas, appearance: { effectStrength: 1 }, lastFrame: 0, born: 1000, activity: 0 });
  value.getUIContext = () => ({ createAnimator() { const a = { played: 0, cancelled: 0, play() { this.played++; }, cancel() { this.cancelled++; } }; frames.push(a); return a; } });
  return { value, frames, paint };
}
const live = orb(); live.value.syncAnimation();
assert.equal(live.frames.length, 1); assert.equal(live.frames[0].played, 1);
const animator = live.frames[0];
now += 100; animator.onFrame(); const painted = live.paint.clears;
now += 10; animator.onFrame(); assert.equal(live.paint.clears, painted, 'Throttle repaint work');
live.value.speaking = true; now += 50; animator.onFrame();
assert.ok(live.value.activity > 0, 'Native VAD increases activity');
live.value.speaking = false; const activity = live.value.activity; now += 100; animator.onFrame();
assert.ok(live.value.activity < activity, 'Activity settles when speech stops');
assert.equal(live.paint.depth, 0, 'Balanced canvas state');
live.value.visible = false; live.value.syncAnimation();
assert.equal(animator.cancelled, 1); assert.equal(live.frames.length, 1, 'Invisible Orb does not animate');
const stopped = live.paint.clears; animator.onFrame(); assert.equal(live.paint.clears, stopped, 'Ignore stale frames');
live.value.visible = true; live.value.foreground = false; live.value.syncAnimation();
assert.equal(live.frames.length, 1, 'Background Orb does not animate');
live.value.foreground = true; live.value.syncAnimation(); assert.equal(live.frames.length, 2);
live.value.aboutToDisappear(); assert.equal(live.frames[1].cancelled, 1); assert.equal(live.value.ready, false);
for (const phase of ['idle', 'error', 'complete']) {
  const item = orb(); item.value.phase = phase; item.value.syncAnimation();
  assert.equal(item.frames.length, 0); assert.equal(item.paint.gradients, 0, phase + ' clears visual feedback');
}
for (const phase of ['preparing', 'listening', 'finishing']) {
  const item = orb(); item.value.phase = phase; item.value.syncAnimation();
  assert.equal(item.frames.length, 1); assert.ok(item.value.label().length > 0);
}
const quiet = orb(); quiet.value.appearance.effectStrength = 0; quiet.value.syncAnimation();
assert.equal(quiet.frames.length, 0, 'Effects off produces a static Orb');
const before = quiet.paint.points.at(-1); now += 800; quiet.value.speaking = true; quiet.value.draw(now, 100);
assert.deepEqual(quiet.paint.points.at(-1), before, 'Static geometry remains still');
const mounting = orb(); mounting.value.ready = false; mounting.value.syncAnimation(); assert.equal(mounting.frames.length, 0);
const empty = orb(); empty.value.canvas.width = 0; empty.value.draw(now, 33); assert.equal(empty.paint.clears, 0);
console.log('PASS native speech Orb: phases, VAD smoothing, frame throttling, theme effects off, visibility, foreground, teardown');

// Exercise the actual click action and clock; ArkUI handles taps and accessibility activation.
const buttonSource = path.join(root, 'entry/src/main/ets/common/VoiceInputButton.ets');
const buttonEmitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/common/VoiceInputButton.ts');
assert.ok(fs.existsSync(buttonEmitted) && fs.statSync(buttonEmitted).mtimeMs >= fs.statSync(buttonSource).mtimeMs, 'Build VoiceInputButton before testing');
const buttonTree = ts.createSourceFile(buttonEmitted, fs.readFileSync(buttonEmitted, 'utf8'), ts.ScriptTarget.Latest, true);
const buttonClass = buttonTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'VoiceInputButton');
const buttonNames = ['aboutToAppear', 'aboutToDisappear', 'active', 'availabilityChanged', 'syncClock', 'activate'];
const buttonMethods = buttonClass.members.filter(n => buttonNames.includes(n.name?.getText(buttonTree))).map(n => n.getText(buttonTree)).join('\n');
const timers = new Map(); let timerId = 0;
scope.setTimeout = (callback, delay) => { assert.equal(delay, 1000); timers.set(++timerId, callback); return timerId; };
scope.clearTimeout = id => timers.delete(id);
vm.runInNewContext(ts.transpileModule(`class Button { ${buttonMethods} } exports.Button = Button;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, scope);
const button = Object.assign(new scope.exports.Button(), { phase: 'idle', disabled: false, startedAt: 0,
  elapsed: '0:00', clockTimer: -1, mounted: false });
let starts = 0, finishes = 0;
button.onStart = () => { starts++; button.phase = 'preparing'; };
button.onFinish = () => { finishes++; };
button.aboutToAppear(); assert.equal(timers.size, 0);
button.activate(); assert.equal(starts, 1); assert.equal(timers.size, 0);
button.activate(); assert.equal(finishes, 1, 'A second tap can stop preparation');
button.phase = 'listening'; button.startedAt = 1000; now = 62000; button.syncClock();
assert.equal(button.elapsed, '1:01'); assert.equal(timers.size, 1);
const tick = timers.get(button.clockTimer); timers.delete(button.clockTimer); now += 1000; tick();
assert.equal(button.elapsed, '1:02'); assert.equal(timers.size, 1);
button.activate(); assert.equal(finishes, 2, 'Tap the same button to finish recording');
button.phase = 'finishing'; button.syncClock(); button.activate();
assert.equal(finishes, 2, 'Ignore repeated taps while waiting for final recognition');
assert.equal(timers.size, 0); assert.equal(button.elapsed, '1:02', 'Freeze capture duration during finalization');
button.phase = 'listening'; button.disabled = true; button.availabilityChanged(); assert.equal(finishes, 3);
button.activate(); assert.equal(finishes, 3, 'Disabled control cannot toggle recording');
button.disabled = false; button.syncClock(); const lateTick = timers.get(button.clockTimer);
button.aboutToDisappear(); assert.equal(timers.size, 0); lateTick(); assert.equal(timers.size, 0, 'No clock can restart after unmount');
button.phase = 'complete'; button.aboutToAppear(); assert.equal(button.elapsed, '0:00'); assert.equal(timers.size, 0);
button.activate(); assert.equal(starts, 2, 'Completed input can begin another recording');
button.aboutToDisappear(); assert.equal(timers.size, 0);
console.log('PASS voice input button: tap start/stop, preparation, finalization, disabled state, one-second clock, teardown');
