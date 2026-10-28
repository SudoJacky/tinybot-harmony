// Exercise real preference persistence and emitted native UI/controller lifecycles.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const compile = source => ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
} }).outputText;
let disk = new Map(), working = new Map(), failFlush = false;
const store = { getSync: (key, fallback) => working.has(key) ? working.get(key) : fallback,
  putSync: (key, value) => working.set(key, value), flushSync() {
    if (failFlush) throw Error('preference write failed'); disk = new Map(working);
  } };
const loaded = new Map();
function load(relative) {
  const file = path.resolve(root, 'entry/src/main/ets', relative.endsWith('.ets') ? relative : relative + '.ets');
  if (loaded.has(file)) return loaded.get(file);
  const exports = {}; loaded.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, require: id => {
    if (id === '@kit.ArkData') return { preferences: { getPreferencesSync: () => store } };
    if (id.startsWith('.')) return load(path.relative(path.join(root, 'entry/src/main/ets'), path.resolve(path.dirname(file), id)));
    throw Error('Unexpected dependency: ' + id);
  } }, { filename: file });
  return exports;
}
const model = load('model/Onboarding'), locale = load('model/I18n');
assert.deepEqual(JSON.parse(JSON.stringify(model.onboardingProviders())), [
  { preset: 'deepseek', name: 'DeepSeek' }, { preset: 'zai', name: 'Z.ai' }, { preset: 'ollama', name: 'Ollama' }
]);
const Preferences = load('services/OnboardingPreferences').OnboardingPreferences;
const fresh = () => ({ config: { configured: false }, threads: [], projects: [], providerProfiles: [] });
let preferences = new Preferences({});
assert.equal(preferences.shouldShow(fresh()), true);
for (const data of [
  { ...fresh(), config: { configured: true } }, { ...fresh(), providerProfiles: [{ id: 'saved' }] },
  { ...fresh(), projects: [{ id: 'project' }] },
  { ...fresh(), threads: [{ messages: [{ content: 'saved chat' }] }] },
  { ...fresh(), threads: [{ messages: [], draft: 'unsent thought' }] },
  { ...fresh(), threads: [{ messages: [], attachments: [{ id: 'photo' }] }] },
  { ...fresh(), threads: [{ messages: [], pendingInputs: [{ text: 'queued' }] }] },
  ...['archived', 'pinned', 'titleEdited', 'parentThreadId'].map(key => ({ ...fresh(), threads: [{ messages: [], [key]: true }] })),
  { ...fresh(), threads: [{ messages: [], references: [{ threadId: 'source' }] }] },
  { ...fresh(), threads: [{ messages: [] }, { messages: [] }] }
]) assert.equal(preferences.shouldShow(data), false, 'Returning users and unsent work must not be interrupted');
failFlush = true; assert.throws(() => preferences.complete(), /preference write failed/);
assert.equal(preferences.shouldShow(fresh()), true, 'Failed persistence must not silently complete onboarding');
failFlush = false; preferences.complete(); working = new Map(disk); preferences = new Preferences({});
assert.equal(preferences.shouldShow(fresh()), false, 'Completion survives a native preference reload');
locale.setLocale('en'); assert.equal(model.onboardingTasks()[0].title, 'Untangle an idea');
locale.setLocale('zh-CN'); assert.equal(model.onboardingTasks()[0].title, '理清一个想法');
console.log('PASS first-use eligibility, returning-user/draft protection, durable skip/completion, failed-write rollback and localized task drafts');

function probe(relative, name, methods, globals = {}) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ' + relative);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  const exports = {};
  vm.runInNewContext(compile('class Probe {\n' + methods.map(method => {
    const member = component.members.find(node => node.name?.getText(tree) === method);
    assert.ok(member, 'Missing compiled method: ' + method); return member.getText(tree);
  }).join('\n') + '\n} exports.Probe = Probe;'), { exports, t: value => value, ...globals });
  return new exports.Probe();
}
const idleTimers = new Map(); let idleTimerId = 0;
const animations = [], TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
const mascot = Object.assign(probe('views/OnboardingMascot', 'OnboardingMascot',
  ['aboutToAppear', 'aboutToDisappear', 'visibilityChanged', 'syncPlayback', 'lift', 'eyeHeight', 'look',
    'clamp', 'startDrag', 'moveDrag', 'springBack', 'endDrag', 'cancelDrag', 'react', 'hello',
    'moodChanged', 'moodTilt', 'isSleepy', 'eyeScaleX', 'eyeScaleY', 'eyeMoodY', 'moodGazeX', 'moodGazeY', 'smileOpacity', 'unit', 'smilePath',
    'wakeChanged', 'sleepAmount', 'sleepBreath', 'sleepDrift', 'bodyScaleX', 'bodyScaleY', 'bodyAngle',
    'cancelPeek', 'coverChanged', 'resetCover', 'cancelIdle', 'scheduleBlink', 'scheduleGlance', 'resetAttention',
    'cancelWakeMotion', 'playWakeBeat', 'expression', 'followSpark', 'keyInputChanged',
    'connectedChanged', 'farewellChanged', 'speechChanged', 'dreamChanged', 'sparkScale', 'sparkOpacity'],
  { TouchType, Curve: { EaseOut: {}, EaseInOut: {} }, curves: { springMotion: () => ({}) },
    setTimeout: (callback, delay) => { const id = ++idleTimerId; idleTimers.set(id, { callback, delay }); return id; },
    clearTimeout: id => idleTimers.delete(id) }), {
  mounted: false, visible: false, playing: false, foreground: true, active: true, phase: 0, diameter: 220, feedbackRevision: 0,
  mood: 'neutral', moodVisual: 'neutral', sleepy: false, waking: false, lookX: 0, lookY: 0,
  blink: 0, idleX: 0, idleY: 0, idleRevision: 0, glanceRevision: 0, blinkTimer: -1, glanceTimer: -1, wakeTimers: [], wakeRevision: 0, wakeBeat: 0,
  reaction: 0, feedback: 0, dragX: 0, dragY: 0, sparkX: 0, sparkY: 0, sparkReaction: 0,
  coverEyes: false, peekProgress: 0, peekRevision: 0, peekTimer: -1,
  appearance: { effectStrength: 1 }, getUIContext: () => ({ createAnimator: options => {
    const animator = { options, plays: 0, pauses: 0, cancelled: false,
      play() { this.plays++; }, pause() { this.pauses++; }, cancel() { this.cancelled = true; this.onFrame?.(0.9); } };
    animations.push(animator); return animator;
  } })
});
mascot.aboutToAppear(); mascot.syncPlayback(); assert.equal(animations.length, 0);
mascot.visible = true; mascot.syncPlayback(); const animator = animations[0];
animator.onFrame(0.25); assert.equal(mascot.phase, 0.25); assert.equal(mascot.lift(), 5);
mascot.foreground = false; mascot.syncPlayback(); animator.onFrame(0.5); assert.equal(mascot.phase, 0.25);
mascot.foreground = true; mascot.syncPlayback(); mascot.visible = false; mascot.syncPlayback();
animator.onFrame(0.6); assert.equal(mascot.phase, 0.25);
mascot.visible = true; mascot.appearance.effectStrength = 0; mascot.syncPlayback();
assert.equal(mascot.playing, false); assert.equal(mascot.lift(), 0);
mascot.appearance.effectStrength = 1; mascot.syncPlayback(); assert.equal(animations.length, 1);
mascot.phase = 0.58; assert.equal(mascot.eyeHeight(), 1, 'Blink no longer follows the float phase');
assert.ok(idleTimers.get(mascot.blinkTimer).delay >= 2500 && idleTimers.get(mascot.blinkTimer).delay <= 6000);
mascot.blink = 1; assert.ok(mascot.eyeHeight() < 0.11); mascot.blink = 0;
mascot.look({ type: TouchType.Down, touches: [{ x: 1000, y: -100 }] });
assert.equal(mascot.gazeX, 7); assert.equal(mascot.gazeY, -5);
mascot.look({ type: TouchType.Cancel, touches: [] }); assert.equal(mascot.gazeX, 0);
mascot.diameter = 110; mascot.look({ type: TouchType.Down, touches: [{ x: 55, y: 55 }] });
assert.equal(mascot.gazeX, 0); assert.equal(mascot.gazeY, 0, 'A resized mascot still looks at the touch point');
mascot.active = false; mascot.syncPlayback(); animator.onFrame(0.7); assert.equal(mascot.phase, 0.58);
mascot.active = true; mascot.syncPlayback();
const returns = [];
mascot.getUIContext = () => ({ animateTo: (options, action) => { action(); if (options.onFinish) returns.push(options.onFinish); },
  vp2px: value => value * 3.5 });
mascot.diameter = 220; assert.equal(mascot.smilePath(), 'M 7 10.5 Q 31.5 45.5 56 10.5');
mascot.diameter = 110; assert.equal(mascot.smilePath(), 'M 3.5 5.25 Q 15.75 22.75 28 5.25',
  'The smile must use physical pixels and scale with the character instead of collapsing to a dot');
const oldGlance = idleTimers.get(mascot.glanceTimer).callback;
mascot.resetAttention(); oldGlance();
assert.equal(mascot.idleX, 0, 'Interaction invalidates a pending idle glance');
mascot.allowDrag = true; mascot.startDrag({ offsetX: 1000, offsetY: -1000 });
assert.equal(mascot.dragX, 64); assert.equal(mascot.dragY, -44); assert.equal(mascot.lift(), 0);
mascot.moveDrag({ offsetX: -1000, offsetY: 1000 }); assert.equal(mascot.dragX, -64); assert.equal(mascot.dragY, 44);
mascot.visibilityChanged(0.9987872242927551);
assert.equal(mascot.visible, true); assert.equal(mascot.dragging, true);
assert.equal(mascot.dragX, -64); assert.equal(mascot.dragY, 44,
  'A shrinking but still visible mascot must not snap home while the finger is down');
mascot.mood = 'curious'; mascot.moodChanged();
assert.equal(mascot.moodGazeX(), 0); assert.equal(mascot.moodGazeY(), 0);
assert.equal(mascot.dragging, true); assert.equal(mascot.dragX, -64,
  'Expression changes must preserve a held gesture and the same animation instance');
mascot.mood = 'surprised'; mascot.moodChanged(); const wideEye = mascot.eyeScaleY();
mascot.mood = 'focused'; mascot.moodChanged(); assert.equal(mascot.expression(), 'surprised', 'Dragging takes precedence over the background mood');
mascot.mood = 'happy'; mascot.moodChanged(); assert.equal(mascot.smileOpacity(), 0, 'Held drag keeps its surprised expression');
mascot.mood = 'neutral'; mascot.moodChanged(); assert.equal(mascot.smileOpacity(), 0);
assert.equal(animations.length, 1, 'A mood change must not recreate the continuous animator');
mascot.moveDrag({ offsetX: 52, offsetY: 24 }); assert.equal(mascot.dragX, 52); assert.equal(mascot.dragY, 24);
mascot.cancelDrag(); assert.equal(mascot.dragX, 0); assert.equal(mascot.dragY, 0); returns.shift()();
assert.equal(mascot.settling, false);
mascot.appearance.effectStrength = 0; mascot.startDrag({ offsetX: 20, offsetY: 10 });
mascot.visibilityChanged(0.97); assert.equal(mascot.dragging, true); assert.equal(mascot.dragX, 20);
mascot.endDrag({ offsetX: 25, offsetY: 12 }); assert.equal(mascot.dragX, 0); assert.equal(mascot.settling, false);
assert.equal(returns.length, 0, 'Motion-off drag return must be immediate');
mascot.startDrag({ offsetX: 30, offsetY: 16 }); mascot.visibilityChanged(0);
assert.equal(mascot.dragging, false); assert.equal(mascot.dragX, 0); assert.equal(mascot.dragY, 0);
assert.equal(mascot.visible, false, 'Only a fully hidden mascot should clear an active drag');
mascot.visibilityChanged(1);
mascot.sleepy = true; assert.equal(mascot.eyeHeight(), 0.12);
assert.ok(mascot.bodyScaleX() > mascot.bodyScaleY(), 'A sleeping Tiny rests in a relaxed, flattened pose');
assert.ok(mascot.sleepDrift(0) < mascot.sleepDrift(1) && mascot.sleepDrift(1) < mascot.sleepDrift(2),
  'Motion-off sleep letters remain separated and visible');
mascot.appearance.effectStrength = 1; mascot.syncPlayback();
const originalUi = mascot.getUIContext, wakeAnimations = [];
mascot.getUIContext = () => ({ animateTo: (options, action) => { wakeAnimations.push(options); action(); } });
mascot.waking = true; mascot.wakeChanged();
assert.equal(wakeAnimations[0].duration, 120, 'A wake starts with an immediate startle');
assert.equal(mascot.wakeBeat, 1);
const beats = mascot.wakeTimers.map(id => idleTimers.get(id));
assert.deepEqual(Array.from(beats, item => item.delay), [150, 300, 450, 800, 1050, 1300]);
beats[0].callback(); assert.equal(mascot.wakeProgress, 0.38);
beats[1].callback(); assert.equal(mascot.wakeProgress, 0);
beats[2].callback(); assert.equal(mascot.expression(), 'surprised'); assert.equal(mascot.sleepAmount(), 0);
beats[3].callback(); assert.equal(mascot.moodGazeX(), -7);
beats[4].callback(); assert.equal(mascot.moodGazeX(), 7);
beats[5].callback(); assert.equal(mascot.expression(), 'happy'); assert.equal(mascot.moodGazeX(), 0);
assert.ok(mascot.smileOpacity() > 0, 'The final wake beat recognizes the user with a smile');
assert.equal(animations.length, 1, 'Waking reuses the continuous idle animator');
mascot.waking = false; mascot.wakeChanged(); assert.equal(mascot.eyeHeight(), 0.12);
const wakeCount = wakeAnimations.length;
mascot.appearance.effectStrength = 0; mascot.waking = true; mascot.wakeChanged();
assert.equal(mascot.eyeHeight(), 1); assert.equal(wakeAnimations.length, wakeCount, 'Motion-off wake must be immediate');
beats[2].callback(); assert.equal(mascot.wakeBeat, 7, 'Cancelled wake callbacks cannot restore an old beat');
mascot.getUIContext = originalUi; mascot.sleepy = false; mascot.waking = false;
mascot.appearance.effectStrength = 1; mascot.tapCount = 0; mascot.reacting = false; mascot.react();
const feedbackEnd = returns.shift(); assert.equal(mascot.reaction, 1);
mascot.active = false; mascot.syncPlayback(); feedbackEnd();
assert.equal(mascot.reaction, 0); assert.equal(returns.length, 0, 'A covered route must not start a follow-up tap animation');
mascot.active = true; mascot.syncPlayback();
const finishReaction = () => { while (returns.length) { returns.shift()(); } };
mascot.speechLine = 0; mascot.speechChanged(); assert.equal(mascot.feedback, 3);
assert.equal(mascot.reaction, 1); finishReaction(); assert.equal(mascot.reaction, 0);
assert.equal(mascot.bodyAngle(), 0, 'A greeting returns to its neutral pose without a second click');
mascot.connected = true; mascot.energized = true; mascot.connectedChanged();
assert.equal(mascot.checkProgress, 1); assert.equal(mascot.feedback, 0);
assert.equal(mascot.reaction, 1); assert.ok(mascot.sparkScale() > 1);
finishReaction(); assert.equal(mascot.reaction, 0); assert.ok(mascot.sparkOpacity() >= 0.84);
mascot.mood = 'oops'; mascot.moodChanged(); assert.equal(mascot.feedback, 2); finishReaction();
mascot.appearance.effectStrength = 0; mascot.syncPlayback(); mascot.connected = false; mascot.connectedChanged();
assert.equal(mascot.checkProgress, 0); assert.equal(mascot.reaction, 0);
mascot.aboutToDisappear(); animator.onFrame(0.8); assert.equal(mascot.phase, 0.58); assert.ok(animator.cancelled);
assert.equal(idleTimers.size, 0, 'Hidden/disposed actors retain no blink, glance or wake timers');
console.log('PASS mascot touch feedback, blink/float, single animation, background/offscreen pause, effects-off mode and disposal');

const peeks = new Map(), handMotions = []; let peekId = 0;
const shy = Object.assign(probe('views/OnboardingMascot', 'OnboardingMascot',
  ['attentionChanged', 'coverChanged', 'resetCover', 'keyInputChanged', 'cancelPeek', 'moodGazeX', 'moodGazeY', 'syncPlayback', 'aboutToDisappear'],
  { Curve: { EaseOut: {}, EaseInOut: {} },
    setTimeout: (callback, delay) => { const id = ++peekId; peeks.set(id, { callback, delay }); return id; },
    clearTimeout: id => peeks.delete(id) }), {
  mounted: true, visible: true, playing: true, foreground: true, active: true, scene: 3,
  coverEyes: false, coverProgress: 0, peekProgress: 0, peekRevision: 0, peekTimer: -1, feedbackRevision: 0,
  lookX: -5, lookY: 4, attentionX: 0, attentionY: 0, idleX: 0, idleY: 0,
  expression: () => 'neutral', resetAttention() {}, cancelIdle() {}, cancelWakeMotion() {}, scheduleBlink() {}, scheduleGlance() {}, appearance: { effectStrength: 1 },
  animator: { pause() {}, play() {}, cancel() {} },
  getUIContext: () => ({ animateTo: (options, action) => { handMotions.push(options); action(); } })
});
shy.attentionChanged(); assert.equal(shy.moodGazeX(), -5); assert.equal(shy.moodGazeY(), 4);
shy.lookX = 5; shy.attentionChanged(); assert.equal(shy.moodGazeX(), 5, 'Attention follows the selected service');
shy.coverEyes = true; shy.coverChanged();
assert.equal(shy.coverProgress, 1); assert.equal(shy.peekProgress, 0);
assert.equal(peeks.get(shy.peekTimer).delay, 850, 'Cover the eye first, then peek after a pause');
const coveredPeek = peeks.get(shy.peekTimer).callback;
shy.active = false; shy.syncPlayback(); assert.equal(peeks.size, 0);
shy.active = true; shy.syncPlayback(); coveredPeek();
assert.equal(shy.peekProgress, 0); assert.equal(peeks.size, 1, 'A covered-route callback cannot advance a new peek');
const peek = peeks.get(shy.peekTimer); peeks.delete(shy.peekTimer); peek.callback();
assert.equal(shy.peekProgress, 1); assert.equal(shy.moodGazeX(), 4);
shy.keyInputChanged(); assert.equal(shy.peekProgress, 0, 'Typing catches Tiny peeking');
assert.equal(peeks.get(shy.peekTimer).delay, 1000);
const caughtPeek = peeks.get(shy.peekTimer).callback; shy.keyInputChanged(); caughtPeek();
assert.equal(shy.peekProgress, 0, 'Continued typing keeps the hands closed');
shy.coverEyes = false; shy.coverChanged(); assert.equal(shy.coverProgress, 0); assert.equal(shy.moodGazeX(), 5);
shy.coverEyes = true; shy.coverChanged(); const blurredPeek = peeks.get(shy.peekTimer).callback;
shy.coverEyes = false; shy.coverChanged(); blurredPeek();
assert.equal(shy.peekProgress, 0); assert.equal(peeks.size, 0, 'Blur cancels delayed peeking');
shy.coverEyes = true; shy.appearance.effectStrength = 0; shy.syncPlayback(); shy.coverChanged();
assert.equal(shy.coverProgress, 1); assert.equal(shy.peekProgress, 0); assert.equal(peeks.size, 0);
shy.appearance.effectStrength = 1; shy.syncPlayback();
const detachedPeek = peeks.get(shy.peekTimer).callback; shy.aboutToDisappear(); detachedPeek();
assert.equal(peeks.size, 0); assert.equal(shy.peekProgress, 0);
console.log('PASS service gaze, cover-before-peek timing, blur/hidden/stale cancellation, reduced motion and disposal');

function page() {
  const events = [], paths = [];
  const view = Object.assign(probe('pages/Index', 'Index', ['offerOnboarding', 'finishOnboarding', 'openSupport', 'connectOnboardingProvider'],
    { ShareInbox: { peek: () => undefined } }), {
    onboardingChecked: false, onboardingDraftThread: '', onboardingFinishing: false, onboardingActive: true, receiving: false, launching: false,
    app: { ready: true, canNavigate: true, busy: false, saveError: '', error: '', draft: 'Keep my draft',
      active: { id: 'old', messages: [{ id: 'old-message' }], attachments: [], projectId: 'project' },
      exportSnapshot: fresh, flushDraft: async () => events.push('flush'),
      newThread: async project => { events.push(['new', project]); view.app.active = { id: 'new', messages: [], attachments: [] }; return true; },
      setDraft: value => { view.app.draft = value; events.push(['draft', value]); },
      send: () => { throw Error('Onboarding must never send a model request'); }
    },
    onboardingPreferences: () => ({ shouldShow: data => model.isOnboardingCandidate(data), complete() { events.push('complete'); } }),
    paths: { size: () => paths.length, pushPath: value => paths.push(value), pop: () => paths.pop(), clear: () => { paths.length = 0; events.push('clear'); } },
    setDrawer: value => events.push(['drawer', value]), openSettings: () => events.push('settings'), events, pathEntries: paths
  });
  return view;
}
(async () => {
  let view = page(); view.offerOnboarding(); view.offerOnboarding(); assert.equal(view.pathEntries.length, 1);
  view = page(); view.app.exportSnapshot = () => ({ ...fresh(), providerProfiles: [{ id: 'saved' }] }); view.offerOnboarding();
  assert.equal(view.pathEntries.length, 0);
  view = page(); view.receiving = true; view.offerOnboarding(); assert.equal(view.pathEntries.length, 0);
  view = page(); await view.openSupport('guide'); assert.equal(view.pathEntries[0].name, 'onboarding');
  view = page(); await view.finishOnboarding('start', 'Try this task');
  assert.deepEqual(view.events.slice(0, 4), ['flush', ['new', ''], ['draft', 'Try this task'], 'flush']);
  assert.ok(view.events.includes('complete')); assert.equal(view.app.active.id, 'new');
  view = page(); view.app.busy = true; await view.finishOnboarding('skip', '');
  assert.deepEqual(view.events, ['complete']); assert.equal(view.app.draft, 'Keep my draft');
  view = page(); view.app.saveError = 'draft write failed';
  await assert.rejects(view.finishOnboarding('start', 'Task'), /draft write failed/); assert.deepEqual(view.events, ['flush']);
  view = page(); view.onboardingPreferences = () => ({ complete() { throw Error('preference write failed'); } });
  await assert.rejects(view.finishOnboarding('connect', 'Task'), /preference write failed/);
  assert.equal(view.events.includes('settings'), false); assert.equal(view.events.includes('clear'), false);
  await assert.rejects(view.finishOnboarding('connect', 'Task'), /preference write failed/);
  assert.equal(view.events.filter(value => Array.isArray(value) && value[0] === 'new').length, 1, 'Retry must reuse the prepared draft');
  view = page(); await view.finishOnboarding('connect', 'Task'); assert.equal(view.events.at(-1), 'settings');
  view = page(); view.app.beginProvider = (preset, id) => { view.events.push(['provider', preset, id]); return true; };
  view.connectOnboardingProvider('deepseek');
  assert.equal(view.pathEntries[0].name, 'provider'); assert.equal(view.events.includes('complete'), false,
    'Configuring a provider must return to the still-incomplete onboarding route');
  view.connectOnboardingProvider('openai'); assert.equal(view.pathEntries.length, 1, 'Repeated taps cannot stack provider editors');
  view = page(); view.app.beginProvider = () => false;
  assert.throws(() => view.connectOnboardingProvider('deepseek'), /请先完成/); assert.equal(view.pathEntries.length, 0);
  for (const extra of [{ references: [{ threadId: 'source' }] }, { pendingInputs: [{ text: 'queued' }] }, { archived: true }]) {
    view = page(); view.app.draft = ''; view.app.active = { id: 'old', messages: [], attachments: [], ...extra };
    await view.finishOnboarding('start', 'Task');
    assert.equal(view.app.active.id, 'new', 'Even an empty-looking chat must go through the session new-chat policy');
  }
  view = page(); view.app.newThread = async () => false;
  await assert.rejects(view.finishOnboarding('start', 'Task'), /无法创建新对话/);
  assert.equal(view.events.includes('complete'), false); assert.equal(view.onboardingFinishing, false);
  view = page(); let releaseSave;
  view.app.flushDraft = () => new Promise(done => { releaseSave = done; });
  const saving = view.finishOnboarding('start', 'Task');
  await view.finishOnboarding('skip', ''); assert.equal(view.events.includes('complete'), false, 'System back must not finish while a draft is saving');
  view.app.flushDraft = async () => {}; releaseSave(); await saving;
  assert.equal(view.events.filter(value => value === 'complete').length, 1); assert.equal(view.onboardingFinishing, false);
  console.log('PASS emitted first-run/replay routing, duplicate-open guard, shared-intent protection, draft preservation, explicit connect and failure-safe retry without model calls');

  let resolve, calls = 0;
  const scheduled = new Map(), delays = new Map(), prepared = [], focusedFields = []; let timerId = 0, providerSaves = 0, scrolls = 0;
  let keyboardMode = 7;
  const keyboardModes = [];
  const panel = Object.assign(probe('views/OnboardingPanel', 'OnboardingPanel',
    ['aboutToAppear', 'aboutToDisappear', 'activeChanged', 'foregroundChanged', 'connectionChanged', 'animate',
      'cancelWake', 'cancelTyping', 'cancelFeedback', 'sayGoodbye', 'actorMood', 'greetActor', 'wake', 'continueWake', 'finish', 'move', 'selectTask', 'onMessageChange', 'currentPrompt',
      'primaryEnabled', 'primaryAvailable', 'primaryLabel', 'primaryAction', 'connectSelected', 'connectProvider', 'settleTransition',
      'selectProvider', 'providerSelectionChanged', 'taskSelectionChanged', 'signInAccount',
      'providerLookX', 'connectionDiameter', 'setConnectionFocus', 'endConnectionEditing', 'keepConnectionInputVisible'],
    { onboardingTasks: model.onboardingTasks, onboardingProviders: model.onboardingProviders,
      Motion: { fast: 160, medium: 220, standard: {} }, Edge: { Top: 0, Bottom: 1 }, KeyboardAvoidMode: { NONE: 4 },
      setTimeout: (callback, delay) => { const id = ++timerId; scheduled.set(id, callback); delays.set(id, delay); return id; },
      clearTimeout: id => scheduled.delete(id) }), {
    hasWoken: false, typing: false, typingRevision: 0, typingTimer: -1, farewell: false, farewellTimer: -1,
    saving: false, busy: false, step: 0, selectedTask: 1, message: model.onboardingTasks()[1].prompt,
    active: true, foreground: true, configured: false, transitioning: false, transitionRevision: 0,
    providerEditing: false, connectionAttempted: false, keyFocused: false, connectionEditing: false, focusedConnectionField: '', bodyHeight: 560,
    keyboardViewport: { keyboardHeight: 0, bottom: 0, observe() {}, dispose() {} }, previousKeyboardMode: undefined,
    connectionScroller: { scrollBy: () => { scrolls++; }, scrollTo() {} },
    app: { providerProfiles: [], active: {}, error: '',
      providerEditor: { apiKey: '', error: '', fieldError: () => '', reset(profile) { this.id = profile.id; this.apiKey = ''; } },
      beginProvider(preset, id) {
        prepared.push({ preset, id }); this.providerEditor.apiKey = ''; return true;
      },
      async saveProvider() {
        providerSaves++;
        if (!this.providerProfiles.some(profile => profile.presetId === panel.selectedPreset)) {
          this.providerProfiles.push({ id: 'saved-' + panel.selectedPreset, presetId: panel.selectedPreset, models: ['example-model'] });
        }
        panel.configured = true; panel.connectedPreset = panel.selectedPreset; panel.connectionChanged(); return true;
      },
      async selectModel(providerId, modelId) { this.active.modelRef = { providerId, modelId }; return true; }
    },
    connectedPreset: '', selectedPreset: '', waking: false, wakeReady: false, wakeTimer: -1, wakeRevision: 0,
    agreed: false, account: { signedIn: false, ready: true, busy: false, error: '', signIn: async () => {
      panel.account.signedIn = true;
    } },
    appearance: { effectStrength: 1 },
    getUIContext: () => ({ animateTo: (options, action) => { action(); options.onFinish?.(); },
      getKeyboardAvoidMode: () => keyboardMode,
      setKeyboardAvoidMode: mode => { keyboardMode = mode; keyboardModes.push(mode); },
      px2vp: value => value, vp2px: value => value,
      getComponentUtils: () => ({ getRectangleById: id => id === 'onboarding-inline-key' ?
        { windowOffset: { y: 200 }, size: { height: 44 } } : id === 'onboarding-panel' ?
        { windowOffset: { y: 0 }, size: { height: 800 } } : { windowOffset: { y: 100 }, size: { height: 100 } } }),
      getFocusController: () => ({ requestFocus: id => focusedFields.push(id), clearFocus() {} }) }),
    onFinish: () => { calls++; return new Promise(done => { resolve = done; }); }
  });
  panel.aboutToAppear(); panel.move(-1); assert.equal(panel.step, 0); panel.move(9); assert.equal(panel.step, 4);
  panel.step = 0;
  assert.equal(panel.primaryLabel(), '华为账号登录');
  assert.equal(panel.primaryAvailable(), false, 'Consent is required before native sign-in');
  panel.agreed = true; assert.equal(panel.primaryAvailable(), true);
  await panel.signInAccount(); assert.equal(panel.account.signedIn, true);
  assert.equal(panel.primaryLabel(), '继续', 'A verified account can continue past the first step');
  panel.account.signedIn = false; panel.account.ready = false; await panel.signInAccount();
  assert.match(panel.error, /确认登录状态/);
  panel.account.ready = true; panel.agreed = false; await panel.signInAccount();
  assert.match(panel.error, /同意/);
  panel.agreed = true; panel.account.busy = true; assert.equal(panel.primaryAvailable(), false);
  assert.equal(panel.primaryLabel(), '正在登录…');
  panel.account.busy = false;
  panel.account.signedIn = false; panel.agreed = false; panel.step = 0; panel.move(1);
  assert.equal(panel.step, 1, 'Sign-in can be deferred without leaving onboarding');
  panel.account.signedIn = true; panel.agreed = true; panel.step = 0; panel.primaryAction(); assert.equal(panel.step, 1);
  const finishing = panel.finish('start'); await panel.finish('skip'); assert.equal(calls, 1);
  resolve(); await finishing; assert.equal(panel.saving, false);
  panel.onFinish = async () => { throw Error('save failed'); }; await panel.finish('connect');
  assert.equal(panel.error, 'save failed'); assert.equal(panel.saving, false);
  panel.step = 1; panel.waking = false; panel.wake(); panel.wake(); assert.equal(scheduled.size, 1);
  assert.equal(delays.get(panel.wakeTimer), 1800, 'The wake must settle before the introduction opens');
  const coveredWake = scheduled.get(panel.wakeTimer);
  panel.active = false; panel.activeChanged(); assert.equal(scheduled.size, 0); assert.equal(panel.step, 1);
  panel.active = true; assert.equal(panel.wakeReady, true); panel.continueWake(); assert.equal(panel.step, 2);
  panel.move(-1); assert.equal(panel.wakeReady, true); panel.wake(); assert.equal(scheduled.size, 0, 'Returning to an awake Tiny does not restart the wake');
  panel.hasWoken = false; panel.wake(); coveredWake();
  assert.equal(panel.step, 1); assert.equal(scheduled.size, 1, 'An old wake callback must not navigate or clear the new timer');
  panel.foreground = false; panel.foregroundChanged();
  assert.equal(scheduled.size, 0); assert.equal(panel.step, 1);
  panel.foreground = true; panel.continueWake(); panel.move(-1); panel.hasWoken = false; panel.wake();
  const wakeId = panel.wakeTimer, completedWake = scheduled.get(wakeId);
  scheduled.delete(wakeId); completedWake();
  assert.equal(panel.step, 2, 'A completed foreground wake opens the introduction');
  assert.equal(panel.waking, false); assert.equal(scheduled.size, 0);
  panel.move(-1); panel.hasWoken = false; panel.wake();
  const detachedWake = scheduled.values().next().value; panel.aboutToDisappear(); detachedWake();
  assert.equal(scheduled.size, 0, 'Leaving the panel must clear pending wake navigation');
  assert.equal(panel.step, 1, 'A detached wake callback must not navigate');
  panel.aboutToAppear();
  panel.step = 4; panel.selectTask(2); assert.equal(panel.message, model.onboardingTasks()[2].prompt);
  panel.onMessageChange('  My own first idea  '); assert.equal(panel.selectedTask, -1);
  assert.equal(panel.currentPrompt(), 'My own first idea'); assert.equal(panel.primaryEnabled(), true);
  panel.onMessageChange(' '); assert.equal(panel.primaryEnabled(), false);
  panel.step = 3;
  panel.providerSelectionChanged('deepseek', true);
  assert.equal(panel.providerEditing, true); assert.equal(panel.providerLookX(), -5);
  panel.app.providerEditor.apiKey = 'unsaved-provider-key';
  panel.providerSelectionChanged('zai', true);
  assert.equal(panel.app.providerEditor.apiKey, '', 'Switching services resets the previous unsaved key');
  assert.equal(panel.providerLookX(), 0);
  panel.providerSelectionChanged('deepseek', false);
  assert.equal(panel.selectedPreset, 'zai', 'The previous Toggle turning off must not clear the new choice');
  assert.equal(panel.primaryAvailable(), true);
  panel.providerSelectionChanged('zai', false);
  panel.providerSelectionChanged('ollama', true);
  panel.providerSelectionChanged('zai', false);
  assert.equal(panel.selectedPreset, 'ollama'); assert.equal(panel.primaryLabel(), '保存服务');
  assert.equal(panel.providerLookX(), 5); assert.equal(prepared.at(-1).preset, 'ollama');
  const expandedDiameter = panel.connectionDiameter(); panel.setConnectionFocus('key', true);
  assert.equal(panel.keyFocused, true); assert.ok(panel.connectionDiameter() < expandedDiameter); assert.equal(scrolls, 1);
  assert.equal(panel.connectionEditing, true); assert.equal(keyboardMode, 4, 'Key entry overlays the keyboard instead of resizing the whole page');
  panel.setConnectionFocus('key', true); assert.equal(keyboardModes.length, 1, 'Duplicate focus/edit events cannot overwrite the previous keyboard mode');
  panel.keyboardViewport.keyboardHeight = 600; panel.keyboardViewport.onKeyboard(true);
  panel.setConnectionFocus('url', true);
  assert.equal(panel.keyFocused, false, 'URL editing never covers the eyes or starts peeking');
  assert.equal(panel.connectionEditing, true); assert.equal(panel.connectionDiameter(), 96);
  assert.equal(panel.focusedConnectionField, 'url'); assert.equal(keyboardMode, 4);
  panel.setConnectionFocus('key', false);
  assert.equal(panel.focusedConnectionField, 'url', 'Late blur from the previous field cannot cancel the new field');
  panel.setConnectionFocus('key', true); panel.setConnectionFocus('url', false);
  assert.equal(panel.keyFocused, true); assert.equal(panel.focusedConnectionField, 'key');
  assert.equal(keyboardModes.length, 1, 'Switching fields keeps the keyboard layout and its original restoration mode');
  panel.keyboardViewport.keyboardHeight = 0; panel.keyboardViewport.onKeyboard(false);
  assert.equal(panel.connectionEditing, true); assert.equal(panel.keyFocused, true); assert.equal(keyboardMode, 4,
    'Switching from URL to secure keyboard can report zero height after the new field starts editing');
  panel.keyboardViewport.keyboardHeight = 600; panel.keyboardViewport.onKeyboard(true);
  panel.setConnectionFocus('key', false); assert.equal(panel.keyFocused, false);
  assert.equal(panel.connectionEditing, true, 'Providers stay hidden while the keyboard is closing');
  assert.equal(keyboardMode, 4);
  panel.keyboardViewport.keyboardHeight = 0; panel.keyboardViewport.onKeyboard(false);
  assert.equal(panel.connectionEditing, false); assert.equal(keyboardMode, 7, 'Closing restores the previous page keyboard mode');
  panel.setConnectionFocus('url', true);
  assert.equal(panel.connectionEditing, true); assert.equal(panel.keyFocused, false);
  panel.keyboardViewport.keyboardHeight = 600; panel.keyboardViewport.onKeyboard(true);
  panel.keyboardViewport.keyboardHeight = 0; panel.keyboardViewport.onKeyboard(false);
  panel.setConnectionFocus('url', false);
  assert.equal(panel.connectionEditing, false); assert.equal(panel.focusedConnectionField, '');
  assert.equal(keyboardMode, 7, 'Closing the URL keyboard also restores the previous mode');
  panel.setConnectionFocus('key', true); panel.active = false; panel.activeChanged();
  assert.equal(panel.connectionEditing, false); assert.equal(keyboardMode, 7, 'Covered routes must not inherit overlay mode');
  panel.setConnectionFocus('key', true); assert.equal(panel.connectionEditing, false, 'Hidden focus callbacks cannot reclaim keyboard mode');
  panel.active = true;
  await panel.connectSelected();
  assert.equal(providerSaves, 1); assert.equal(panel.providerEditing, false);
  assert.equal(panel.app.active.modelRef.providerId, 'saved-ollama'); assert.equal(panel.primaryLabel(), '继续');
  panel.primaryAction(); assert.equal(panel.step, 4); assert.equal(panel.primaryLabel(), '带进聊天');
  panel.move(-1); assert.equal(panel.step, 3, 'The first-task Back action returns directly to model setup');
  panel.configured = false;
  panel.move(1); assert.equal(panel.step, 4, 'Deferring model setup also opens the first task directly');
  panel.move(-1);
  panel.providerSelectionChanged('ollama', false);
  assert.equal(panel.selectedPreset, ''); assert.equal(panel.primaryAvailable(), false);
  panel.taskSelectionChanged(0, true); panel.taskSelectionChanged(2, true); panel.taskSelectionChanged(0, false);
  assert.equal(panel.selectedTask, 2); assert.equal(panel.message, model.onboardingTasks()[2].prompt);
  panel.taskSelectionChanged(2, false);
  assert.equal(panel.selectedTask, -1); assert.equal(panel.message, model.onboardingTasks()[2].prompt);
  console.log('PASS choice callback ordering, inline provider save, service gaze, key draft isolation, keyboard layout and task draft preservation');
  panel.providerSelectionChanged('deepseek', true);
  const successfulProviderSave = panel.app.saveProvider;
  panel.app.providerEditor.fieldError = field => field === 'key' ? 'missing key' : '';
  await panel.connectSelected(); assert.equal(panel.error, 'missing key'); assert.equal(providerSaves, 1);
  assert.equal(focusedFields.at(-1), 'onboarding-inline-key', 'Invalid input must be focused without attempting a save');
  panel.app.providerEditor.fieldError = () => '';
  panel.app.providerEditor.error = 'vault failed'; panel.app.saveProvider = async () => false;
  await panel.connectSelected(); assert.equal(panel.error, 'vault failed');
  assert.equal(panel.saving, false); assert.equal(panel.providerEditing, true, 'Failed saves retain the inline editor');
  let releaseProvider, pendingProviderSaves = 0;
  panel.app.saveProvider = () => { pendingProviderSaves++; return new Promise(resolve => { releaseProvider = () => resolve(false); }); };
  const pendingProvider = panel.connectSelected(); await panel.connectSelected();
  assert.equal(pendingProviderSaves, 1); assert.equal(panel.saving, true);
  releaseProvider(); await pendingProvider; panel.app.saveProvider = successfulProviderSave;
  await panel.connectSelected(); assert.equal(panel.providerEditing, false);
  assert.equal(panel.app.active.modelRef.providerId, 'saved-deepseek', 'Saving another service must select its model');
  panel.providerSelectionChanged('deepseek', true);
  assert.equal(prepared.at(-1).id, 'saved-deepseek', 'Reopening a saved preset edits it instead of creating duplicates');
  const previousPrepare = panel.app.beginProvider; panel.app.beginProvider = () => false;
  panel.providerSelectionChanged('zai', true);
  assert.equal(panel.selectedPreset, 'deepseek', 'A refused draft reset must not show a stale service editor');
  panel.app.beginProvider = previousPrepare;
  let connection;
  panel.onConnect = preset => { connection = preset; }; panel.connectProvider(''); assert.equal(connection, '');
  panel.onConnect = () => { throw Error('provider is busy'); }; panel.connectProvider(''); assert.equal(panel.error, 'provider is busy');
  console.log('PASS emitted step bounds, explicit completion, duplicate-tap guard and visible save failures');

  const pageEnds = [];
  panel.aboutToAppear(); panel.step = 2;
  panel.getUIContext = () => ({ animateTo: (options, action) => { action(); pageEnds.push(options.onFinish); } });
  panel.move(1); panel.move(1);
  assert.equal(panel.step, 3, 'Repeated clicks during a transition must not skip a scene');
  assert.equal(panel.transitioning, true); assert.equal(panel.pageDirection, 1);
  assert.equal(panel.primaryEnabled(), false);
  assert.equal(panel.primaryAvailable(), true, 'A transition must not flash the primary button into its disabled color');
  pageEnds.shift()(); assert.equal(panel.transitioning, false);
  panel.move(-1); assert.equal(panel.pageDirection, -1);
  const oldEnd = pageEnds.shift();
  panel.foreground = false; panel.foregroundChanged(); assert.equal(panel.transitioning, false);
  panel.foreground = true; panel.move(1); oldEnd();
  assert.equal(panel.transitioning, true, 'A stale callback must not unlock a newer transition');
  pageEnds.shift()(); assert.equal(panel.transitioning, false);
  panel.move(-1); const detachedEnd = pageEnds.shift(); panel.aboutToDisappear(); detachedEnd();
  assert.equal(panel.transitioning, false);
  panel.aboutToAppear(); panel.appearance.effectStrength = 0; panel.move(1);
  assert.equal(panel.step, 3); assert.equal(panel.transitioning, false); assert.equal(pageEnds.length, 0);
  panel.active = false; panel.move(1); assert.equal(panel.step, 3, 'Covered pages must not navigate');
  console.log('PASS directional transitions, duplicate navigation, stable action feedback, stale/background/disposal callbacks and motion-off navigation');

  const introTimers = new Map(); let introTimerId = 0;
  const intro = Object.assign(probe('views/OnboardingIntroduction', 'OnboardingIntroduction',
    ['aboutToAppear', 'aboutToDisappear', 'stopPlayback', 'visibilityChanged', 'syncPlayback', 'actorDiameter'],
    { onboardingIntroduction: model.onboardingIntroduction, Motion: { enter: {} },
      setTimeout: (callback, delay) => { const id = ++introTimerId; introTimers.set(id, { callback, delay }); return id; },
      clearTimeout: id => introTimers.delete(id) }), {
    mounted: false, visible: false, active: true, foreground: true, appearance: { effectStrength: 1 },
    line: 0, spokenLine: -1, onSpeak() {}, timer: -1, revision: 0, bodyHeight: 560, speechHeight: 88,
    getUIContext: () => ({ animateTo: (_, action) => action() })
  });
  const advanceIntro = () => {
    const pending = introTimers.get(intro.timer); introTimers.delete(intro.timer); pending.callback();
  };
  intro.aboutToAppear(); intro.syncPlayback(); assert.equal(introTimers.size, 0);
  intro.visibilityChanged(1); assert.equal(introTimers.size, 1);
  assert.equal(introTimers.get(intro.timer).delay, 3200, 'Each spoken line needs reading time');
  advanceIntro(); assert.equal(intro.line, 1);
  const hiddenIntro = introTimers.get(intro.timer).callback;
  intro.active = false; intro.syncPlayback(); assert.equal(introTimers.size, 0);
  intro.active = true; intro.syncPlayback(); hiddenIntro();
  assert.equal(intro.line, 1); assert.equal(introTimers.size, 1, 'A stale callback cannot advance a resumed introduction');
  intro.foreground = false; intro.syncPlayback(); assert.equal(introTimers.size, 0);
  intro.foreground = true; intro.syncPlayback(); assert.equal(introTimers.size, 1);
  intro.visibilityChanged(0); assert.equal(introTimers.size, 0, 'Offscreen speech must stop advancing');
  intro.visibilityChanged(1); intro.appearance.effectStrength = 0; intro.syncPlayback();
  assert.equal(introTimers.size, 0, 'Motion-off introduction has no automatic text changes');
  intro.bodyHeight = 420; assert.ok(intro.actorDiameter() < 200, 'Short viewports make room for examples');
  intro.bodyHeight = 562; intro.speechHeight = 111;
  assert.ok(intro.actorDiameter() + intro.speechHeight + 332 <= intro.bodyHeight,
    'Three-line English speech must leave the entire caption and pagination in view');
  intro.speechHeight = 187;
  assert.ok(intro.actorDiameter() + intro.speechHeight + 332 <= intro.bodyHeight,
    'Static reduced-motion speech keeps page controls visible by shrinking the decorative actor');
  intro.appearance.effectStrength = 1; intro.syncPlayback();
  advanceIntro(); assert.equal(intro.line, 2); assert.equal(introTimers.size, 0,
    'The introduction stops scheduling timers after the last line; finished examples stay visible');
  intro.foreground = false; intro.syncPlayback(); intro.foreground = true; intro.syncPlayback();
  assert.equal(introTimers.size, 0, 'Returning to a finished introduction must not restart it');
  intro.line = 0; intro.syncPlayback();
  const detachedIntro = introTimers.get(intro.timer).callback; intro.aboutToDisappear(); detachedIntro();
  assert.equal(introTimers.size, 0); assert.equal(intro.line, 0);
  console.log('PASS introduction reading intervals, finite playback, stale callbacks, background/offscreen pause, reduced motion and disposal');

  const deckTimers = new Map(); let deckTimerId = 0;
  const looks = [], deckAnimations = [];
  const deck = Object.assign(probe('views/OnboardingExampleDeck', 'OnboardingExampleDeck',
    ['aboutToAppear', 'aboutToDisappear', 'stopPlayback', 'syncPlayback', 'scheduleTour', 'select', 'choose', 'side', 'fan', 'sideOffset'],
    { Motion: { enter: {} },
      setTimeout: (callback, delay) => { const id = ++deckTimerId; deckTimers.set(id, { callback, delay }); return id; },
      clearTimeout: id => deckTimers.delete(id) }), {
    mounted: false, active: true, speechLine: 0, appearance: { effectStrength: 1 }, compact: false,
    selected: 0, stageWidth: 328, manual: false, tourStep: -1, timer: -1, lookTimer: -1, revision: 0,
    onLook: down => looks.push(down),
    getUIContext: () => ({ animateTo: (options, action) => { deckAnimations.push(options); action(); } })
  });
  const tickDeck = id => { const pending = deckTimers.get(id); assert.ok(pending); deckTimers.delete(id); pending.callback(); };
  deck.aboutToAppear(); assert.equal(deckTimers.size, 0);
  deck.speechLine = 1; deck.syncPlayback(); assert.equal(deck.selected, 0);
  assert.equal(deckTimers.get(deck.timer).delay, 1000);
  assert.equal(deck.lookTimer, -1); assert.equal(looks.at(-1), true, 'The automatic tour holds one downward gaze');
  tickDeck(deck.timer); assert.equal(deck.selected, 1); assert.equal(looks.at(-1), true);
  const staleTour = deckTimers.get(deck.timer).callback;
  deck.active = false; deck.syncPlayback(); assert.equal(deckTimers.size, 0); assert.equal(looks.at(-1), false);
  deck.active = true; deck.syncPlayback(); staleTour(); assert.equal(deck.selected, 1);
  tickDeck(deck.timer); assert.equal(deck.selected, 2);
  tickDeck(deck.timer); assert.equal(deck.selected, 0); assert.equal(deck.timer, -1); assert.equal(looks.at(-1), false);
  deck.speechLine = 2; deck.syncPlayback(); assert.equal(deckTimers.size, 0);
  deck.active = false; deck.syncPlayback(); deck.active = true; deck.syncPlayback();
  assert.equal(deckTimers.size, 0, 'Completed tour never loops after foregrounding');
  deck.tourStep = -1; deck.speechLine = 1; deck.syncPlayback();
  const supersededTour = deckTimers.get(deck.timer).callback;
  deck.choose(2); supersededTour(); assert.equal(deck.selected, 2); assert.equal(deck.timer, -1);
  deck.speechLine = 2; deck.syncPlayback(); assert.equal(deck.selected, 2, 'Speech must not reset a manually selected page');
  deck.choose(3); assert.equal(deck.selected, 0); deck.choose(-1); assert.equal(deck.selected, 2);
  const staleLook = deckTimers.get(deck.lookTimer).callback;
  deck.appearance.effectStrength = 0; deck.syncPlayback(); assert.equal(deckTimers.size, 0);
  const animationCount = deckAnimations.length; deck.choose(1);
  assert.equal(deck.selected, 1); assert.equal(deckAnimations.length, animationCount); assert.equal(deckTimers.size, 0);
  assert.equal(deck.fan(), false); assert.equal(deck.side(0), -1); assert.equal(deck.side(2), 1);
  deck.appearance.effectStrength = 1; deck.compact = true; assert.equal(deck.fan(), false);
  deck.compact = false; assert.equal(deck.fan(), true);
  deck.stageWidth = 328; assert.equal(deck.sideOffset(), 79, 'Side pages fit the measured stage width');
  deck.choose(0); deck.aboutToDisappear(); const lookCount = looks.length; staleLook();
  assert.equal(looks.length, lookCount); assert.equal(deckTimers.size, 0);
  deck.choose(1); assert.equal(deck.selected, 0, 'Unmounted deck ignores input');
  console.log('PASS finite speech-synced deck, manual takeover, swipes, stale callbacks, hidden/disposed cleanup, compact and motion-off interaction');

  const revealTimers = new Map(); let revealId = 0;
  const paper = Object.assign(probe('views/OnboardingExamplePage', 'OnboardingExamplePage',
    ['aboutToAppear', 'aboutToDisappear', 'cancelReveal', 'syncReveal', 'motion'],
    { Motion: { enter: {} },
      setTimeout: callback => { revealTimers.set(++revealId, callback); return revealId; },
      clearTimeout: id => revealTimers.delete(id) }), {
    mounted: false, selected: true, playing: true, appearance: { effectStrength: 1 },
    revealed: true, timer: -1, revision: 0
  });
  paper.aboutToAppear(); assert.equal(paper.revealed, false);
  assert.equal(paper.motion(320, 40).duration, 0, 'Reset is immediate, never a reverse animation');
  const staleReveal = revealTimers.get(paper.timer);
  paper.playing = false; paper.syncReveal(); staleReveal();
  assert.equal(paper.revealed, true); assert.equal(revealTimers.size, 0);
  paper.playing = true; paper.syncReveal(); const reveal = revealTimers.get(paper.timer); revealTimers.delete(paper.timer); reveal();
  assert.equal(paper.motion(320, 40).delay, 40);
  paper.appearance.effectStrength = 0; paper.syncReveal();
  assert.equal(paper.revealed, true); assert.equal(paper.motion(320, 40).duration, 0); assert.equal(paper.motion(320, 40).delay, 0);
  paper.appearance.effectStrength = 1; paper.syncReveal(); paper.aboutToDisappear(); assert.equal(revealTimers.size, 0);
  console.log('PASS paper reveals, per-element timing, immediate resets and background/disposal/reduced-motion cleanup');

  const journeys = [];
  const actor = Object.assign(probe('views/OnboardingPanel', 'OnboardingPanel',
    ['stageChanged', 'locateActor', 'placeActor', 'followActorScroll', 'greetActor', 'animate', 'keepConnectionInputVisible'],
    { Motion: { standard: {} } }), {
    step: 1, active: true, foreground: true, transitioning: false, saving: false,
    actorReady: false, actorScene: -1, actorX: 0, actorY: 0, actorSize: 180, greeted: false,
    stageLeft: 24, stageTop: 100, stageWidth: 320, appearance: { effectStrength: 1 },
    getUIContext: () => ({ animateTo: (options, action) => { journeys.push(options); action(); },
      px2vp: value => value / 2, getComponentUtils: () => ({ getRectangleById: () => ({
        size: { width: 320, height: 320 }, windowOffset: { x: 48, y: 280 }
      }) }) })
  });
  actor.locateActor(1, { width: 220, height: 220, globalPosition: { x: 74, y: 260 } });
  assert.equal(actor.actorReady, true); assert.equal(actor.actorX, 160); assert.equal(actor.actorY, 270);
  assert.equal(journeys.length, 0, 'The first measured destination must not fly in from an uninitialized origin');
  actor.step = 2;
  actor.locateActor(1, { width: 220, height: 220, globalPosition: { x: 74, y: 800 } });
  assert.equal(actor.actorY, 270, 'An exiting page must not pull the persistent actor back');
  actor.locateActor(2, { width: 160, height: 160, globalPosition: { x: 104, y: 200 } });
  assert.equal(actor.actorReady, true); assert.equal(actor.actorSize, 160); assert.equal(actor.actorY, 180);
  assert.equal(journeys.length, 1); assert.equal(journeys[0].duration, 420);
  actor.followActorScroll(2, 'slot'); assert.equal(actor.actorY, 120); assert.equal(journeys.length, 1,
    'Scrolling should track the real slot immediately, without trailing behind the finger');
  actor.appearance.effectStrength = 0; actor.placeActor(32, 52, 64, true);
  assert.equal(actor.actorX, 32); assert.equal(actor.actorSize, 64); assert.equal(journeys.length, 1);
  actor.step = 3; actor.keyFocused = true;
  actor.locateActor(3, { width: 96, height: 96, globalPosition: { x: 0, y: 200 } });
  assert.equal(actor.actorY, 148); assert.equal(actor.actorSize, 96, 'Key entry uses its actual slot without a second pinned reserve');
  actor.followActorScroll(3, 'slot'); assert.equal(actor.actorY, 120, 'The actor follows measured layout rather than competing with a hard-coded keyboard position');
  actor.keyFocused = false;
  actor.step = 4;
  actor.locateActor(4, { width: 64, height: 64, globalPosition: { x: 48, y: 180 } });
  assert.equal(actor.actorX, 56, 'The final task positions Tiny beside its speech bubble');
  actor.hasWoken = true; actor.step = 1;
  actor.wake = () => { throw Error('An awake Tiny must not restart its wake journey'); };
  actor.greetActor(); actor.greetActor();
  panel.active = true; panel.foreground = true; panel.step = 4; panel.transitioning = false; panel.saving = false;
  panel.appearance.effectStrength = 1;
  panel.onMessageChange('Draft'); assert.equal(panel.actorMood(), 'focused');
  const oldTyping = scheduled.get(panel.typingTimer);
  panel.onMessageChange('Draft updated'); oldTyping(); assert.equal(panel.typing, true);
  const typingEnd = scheduled.get(panel.typingTimer); scheduled.delete(panel.typingTimer); typingEnd();
  assert.equal(panel.actorMood(), 'happy', 'A one-second typing pause settles into a smile');
  panel.error = 'Could not save'; assert.equal(panel.actorMood(), 'oops'); panel.error = '';
  panel.saving = true; assert.equal(panel.actorMood(), 'focused'); panel.saving = false;
  let departures = 0;
  panel.onFinish = async () => { departures++; };
  const goodbye = panel.finish('start', 'Keep this draft');
  assert.equal(panel.farewell, true); assert.equal(departures, 0, 'The farewell runs before popping the page');
  await panel.finish('start', 'Duplicate'); assert.equal(departures, 0);
  const goodbyeEnd = scheduled.get(panel.farewellTimer); scheduled.delete(panel.farewellTimer); goodbyeEnd();
  await goodbye; assert.equal(departures, 1); assert.equal(panel.saving, false);
  const cancelledGoodbye = panel.finish('start', 'Do not navigate in background');
  panel.foreground = false; panel.foregroundChanged(); await cancelledGoodbye;
  assert.equal(departures, 1); assert.equal(panel.farewell, false);
  panel.foreground = true; panel.appearance.effectStrength = 0;
  await panel.finish('start', 'Immediate reduced-motion departure'); assert.equal(departures, 2);
  assert.equal(panel.farewellTimer, -1);
  console.log('PASS typing debounce, stale input callbacks, saving/error moods, farewell completion, duplicate taps, background cancellation and motion-off departure');
  console.log('PASS persistent actor measured destinations, continuous transform, exiting-page isolation, scroll tracking and final-task interaction');
})().catch(error => { console.error(error); process.exitCode = 1; });
