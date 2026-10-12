// Build first. Exercise the emitted native component lifecycle with controllable animator frames.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.join(root, 'entry/src/main/ets/common/Widgets.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/common/Widgets.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ThinkingLine');
const names = ['aboutToAppear','aboutToDisappear','stopLoop','stopSettle','syncMotion','syncState','visibilityChanged'];
const globals = { exports: {} };
vm.runInNewContext(ts.transpileModule(`class Probe { ${component.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} }
exports.Probe = Probe;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, globals);
function mount(working, label) {
  const animations = [];
  const value = Object.assign(new globals.exports.Probe(), { working, label, mounted: false, visible: false,
    currentLabel: '', previousLabel: '', labelMix: 1, breath: 0.58, sweep: -100,
    getUIContext: () => ({ createAnimator: options => {
      const animator = { options, playing: false, cancelled: false, play() { this.playing = true; },
        cancel() { this.cancelled = true; this.playing = false; this.onFrame?.(1); }, frame(value) { this.onFrame(value); }, finish() { this.onFinish?.(); } };
      animations.push(animator); return animator;
    } }) });
  value.aboutToAppear(); value.visibilityChanged(true); return { value, animations };
}
const live = mount(true, 'Thinking');
assert.equal(live.animations.length, 1); assert.equal(live.animations[0].options.iterations, -1);
live.value.syncState(); assert.equal(live.animations.length, 1, 'Repeated streaming updates must not restart the loop');
live.animations[0].frame(0.5); assert.equal(live.value.breath, 1); assert.equal(live.value.sweep, 100);
live.value.working = false; live.value.label = 'Thought'; live.value.syncState();
assert.equal(live.animations[0].cancelled, true); assert.equal(live.value.breath, 1, 'Cancel callback must not overwrite the displayed frame');
assert.equal(live.value.previousLabel, 'Thinking'); assert.equal(live.value.currentLabel, 'Thought');
live.animations[1].frame(0.5); assert.equal(live.value.labelMix, 0.5);
live.animations[1].finish(); assert.equal(live.value.previousLabel, ''); assert.equal(live.value.labelMix, 1);
assert.equal(live.value.loop, undefined, 'Completed/history rows have no perpetual animation');
const history = mount(false, 'Thought'); assert.equal(history.animations.length, 0);
assert.equal(history.value.labelMix, 1, 'History must appear quietly without replaying completion');
const interrupted = mount(true, 'Thinking');
interrupted.value.label = 'Reading'; interrupted.value.syncState(); const previous = interrupted.value.settling;
interrupted.value.label = 'Writing'; interrupted.value.syncState(); previous.finish();
assert.equal(interrupted.value.currentLabel, 'Writing'); assert.equal(interrupted.value.previousLabel, 'Reading');
interrupted.value.visibilityChanged(false); const count = interrupted.animations.length;
assert.equal(interrupted.value.loop, undefined); assert.equal(interrupted.value.settling, undefined);
interrupted.value.label = 'Done'; interrupted.value.working = false; interrupted.value.syncState();
assert.equal(interrupted.animations.length, count, 'Hidden status changes must not animate');
interrupted.value.working = true; interrupted.value.label = 'Thinking again'; interrupted.value.syncState();
interrupted.value.visibilityChanged(true); assert.equal(interrupted.animations.length, count + 1);
const loop = interrupted.value.loop; interrupted.value.aboutToDisappear(); const sweep = interrupted.value.sweep;
loop.frame(0.7); assert.equal(interrupted.value.sweep, sweep, 'Detached callbacks must not mutate an unmounted row');
assert.equal(loop.cancelled, true);
console.log('PASS thinking motion: live loop, settled crossfade, quiet history, rapid labels, hidden rows, resume and unmount cancellation');
