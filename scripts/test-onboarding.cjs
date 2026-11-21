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
const Preferences = load('services/OnboardingPreferences').OnboardingPreferences;
const fresh = () => ({ config: { configured: false }, threads: [], projects: [], providerProfiles: [] });
const ready = { ...fresh(), config: { configured: true }, providerProfiles: [{ id: 'saved' }] };
let preferences = new Preferences({});
assert.equal(preferences.resumeStep(fresh()), 1);
for (const data of [
  ready, { ...fresh(), providerProfiles: [{ id: 'saved' }] }, { ...fresh(), projects: [{ id: 'project' }] },
  { ...fresh(), threads: [{ messages: [{ content: 'saved chat' }] }] },
  { ...fresh(), threads: [{ messages: [], draft: 'unsent thought' }] },
  { ...fresh(), threads: [{ messages: [], attachments: [{ id: 'photo' }] }] },
  { ...fresh(), threads: [{ messages: [], pendingInputs: [{ text: 'queued' }] }] },
  ...['archived', 'pinned', 'titleEdited', 'parentThreadId'].map(key => ({ ...fresh(), threads: [{ messages: [], [key]: true }] })),
  { ...fresh(), threads: [{ messages: [], references: [{ threadId: 'source' }] }] },
  { ...fresh(), threads: [{ messages: [] }, { messages: [] }] }
]) assert.equal(preferences.resumeStep(data), 0, 'Returning users and unsent work must be left alone');
preferences.reach(3);
assert.equal(preferences.resumeStep(ready), 0, 'A manual walkthrough does not enroll returning users');
failFlush = true;
assert.throws(() => preferences.begin(), /preference write failed/);
assert.equal(preferences.resumeStep(ready), 0);
failFlush = false;
preferences.begin();
preferences.reach(2);
failFlush = true;
assert.throws(() => preferences.reach(3), /preference write failed/);
assert.equal(preferences.resumeStep(fresh()), 2);
failFlush = false;
preferences.reach(4);
preferences.reach(2);
working = new Map(disk);
preferences = new Preferences({});
assert.equal(preferences.resumeStep(ready), 4, 'Restart after provider save keeps the completion page pending');
failFlush = true;
assert.throws(() => preferences.complete(), /preference write failed/);
assert.equal(preferences.resumeStep(ready), 4);
failFlush = false;
preferences.complete();
working = new Map(disk);
assert.equal(new Preferences({}).resumeStep(fresh()), 0);
working = new Map([['onboardingComplete', true]]);
assert.equal(new Preferences({}).resumeStep(fresh()), 0, 'Existing completed installations upgrade without prompting');
console.log('PASS first-use and upgrade gating, durable checkpoints, provider-ready resumption, and failed-write rollback');


function probe(relative, name, methods, globals = {}) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ' + relative);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  const exports = {};
  const frames = tree.statements.filter(node => ts.isClassDeclaration(node) && node.heritageClauses?.some(h => h.getText(tree).includes('FrameCallback')));
  vm.runInNewContext(compile(frames.map(node => node.getText(tree)).join('\n') + '\nclass Probe {\n' + methods.map(method => {
    const member = component.members.find(node => node.name?.getText(tree) === method);
    assert.ok(member, 'Missing compiled method: ' + method); return member.getText(tree);
  }).join('\n') + '\n} exports.Probe = Probe;'), { exports, FrameCallback: class {}, t: value => value, ...globals });
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
  const events = [];
  const paths = [];
  const store = {
    resumeStep: () => 1,
    begin: () => events.push('begin'),
    reach: step => events.push(step),
    complete: () => events.push('complete')
  };
  const view = Object.assign(probe('pages/Index', 'Index',
    ['offerOnboarding', 'openOnboarding', 'moveOnboarding', 'closeOnboarding', 'syncNavigationLocale'],
    { ShareInbox: { peek: () => undefined } }), {
    app: { ready: true, exportSnapshot: fresh },
    onboardingPreferences: () => store,
    paths: {
      size: () => paths.length,
      pushPath: path => paths.push(path.name),
      getAllPathName: () => paths.slice()
    },
    revealChat: () => { paths.length = 0; events.push('chat'); },
    receiveShare() {},
    receiveLaunch() {}
  });
  return { view, store, paths, events };
}

function testIndex() {
  let p = page();
  p.view.offerOnboarding();
  p.view.offerOnboarding();
  assert.deepEqual(p.paths, ['onboarding']);
  assert.equal(p.view.onboardingStep, 1);
  p.view.navigationLocale = 'zh-CN';
  p.view.locale = 'en';
  p.view.syncNavigationLocale();
  assert.equal(p.view.navigationLocale, 'zh-CN', 'The notification must keep the open navigation subtree mounted');
  p.view.moveOnboarding(2, true);
  p.view.moveOnboarding(1, false);
  p.view.closeOnboarding(false);
  assert.equal(p.view.navigationLocale, 'en', 'The rest of the app adopts the language when the guide leaves');
  assert.deepEqual(p.events, ['begin', 2, 'chat']);
  assert.equal(p.view.onboardingActive, false);

  p = page();
  p.store.resumeStep = () => 4;
  p.view.offerOnboarding();
  assert.equal(p.view.onboardingStep, 4);
  p.store.complete = () => { throw Error('preference write failed'); };
  assert.throws(() => p.view.closeOnboarding(true), /preference write failed/);
  assert.deepEqual(p.paths, ['onboarding']);
  p.store.complete = () => p.events.push('complete');
  p.view.closeOnboarding(true);
  p.view.closeOnboarding(true);
  assert.deepEqual(p.events, ['begin', 'complete', 'chat']);
}

function panel() {
  const events = [];
  const editor = {
    id: '', apiKey: '', balanceApiKey: '', error: '', models: 'first\nsecond',
    get modelList() { return this.models.split('\n'); },
    fieldError: () => '',
    reset(profile) { this.id = profile.id; this.apiKey = ''; this.models = profile.models.join('\n'); }
  };
  const app = {
    active: {}, providerProfiles: [], providerEditor: editor,
    providerPresets: [{ id: 'deepseek', name: 'DeepSeek', protocol: 'chat-completions' }],
    beginProvider: () => true,
    async flushDraft() {},
    async saveProvider() {
      events.push(['save', editor.id, editor.models]);
      if (!editor.id) this.providerProfiles.push({ id: 'saved', models: editor.modelList });
      return true;
    },
    async selectModel(providerId, modelId) {
      events.push(['model', providerId, modelId]);
      this.active.modelRef = { providerId, modelId };
      this.configured = true;
      return true;
    }
  };
  const account = { ready: true, signedIn: false, async signIn() { events.push('sign-in'); } };
  const view = Object.assign(probe('views/OnboardingPanel', 'OnboardingPanel', [
    't', 'aboutToAppear', 'aboutToDisappear', 'visibleStep', 'blocked', 'move', 'goBack', 'backRequested', 'pause',
    'canContinue', 'primaryAction', 'clearValidation', 'setLanguage', 'setMode', 'presets', 'chooseProvider', 'clearProviderDraft', 'saveProvider'
  ], {
    Edge: { Top: 0 }, CUSTOM_PROVIDER: 'custom', isSupportedProtocol: protocol => protocol === 'chat-completions',
    LanguagePreferences: { select: value => events.push(['language', value]) },
    AppearancePreferences: { select: value => events.push(['appearance', value.mode]) },
    copyAppearance: value => ({ ...value })
  }), {
    initialStep: 1, active: true, foreground: true, account, app, options: { mode: 'system' }, language: 'system',
    scroller: { scrollEdge() {} },
    getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }) }),
    onMove: (step, forward) => events.push(['step', step, forward]),
    onClose: completed => events.push(['close', completed])
  });
  view.aboutToAppear();
  return { view, events, account, app, editor };
}

async function testPanel() {
  let p = panel();
  await p.view.primaryAction();
  assert.deepEqual(p.events, [], 'The OS login sheet requires consent');
  p.view.agreed = true;
  await p.view.primaryAction();
  assert.deepEqual(p.events, ['sign-in']);
  assert.equal(p.view.visibleStep(), 1, 'Cancellation leaves the account step open');
  p.account.signedIn = true;
  await p.view.primaryAction();
  await p.view.setLanguage('en');
  p.view.setMode('dark');
  await p.view.primaryAction();
  assert.deepEqual(p.events.slice(1), [['step', 2, true], ['language', 'en'], ['appearance', 'dark'], ['step', 3, true]]);
  await p.view.primaryAction();
  assert.equal(p.view.visibleStep(), 3);
  p.view.chooseProvider(0);
  p.view.modelId = 'second';
  p.editor.apiKey = 'fixture';
  const selectModel = p.app.selectModel;
  p.app.selectModel = async () => false;
  await p.view.primaryAction();
  assert.equal(p.view.visibleStep(), 3);
  assert.match(p.view.error, /切换当前模型/);
  assert.equal(p.editor.id, 'saved');
  p.app.selectModel = selectModel;
  await p.view.primaryAction();
  assert.equal(p.view.visibleStep(), 4);
  assert.equal(p.app.providerProfiles.length, 1);
  assert.deepEqual(p.events.slice(5), [
    ['save', '', 'second\nfirst'], ['save', 'saved', 'second\nfirst'],
    ['model', 'saved', 'second'], ['step', 4, true]
  ]);
  assert.equal(p.editor.apiKey, '');
  p.view.backRequested();
  assert.equal(p.view.visibleStep(), 3);
  await p.view.primaryAction();
  await p.view.primaryAction();
  assert.deepEqual(p.events.at(-1), ['close', true]);

  p = panel();
  p.view.step = 4;
  assert.equal(p.view.visibleStep(), 1, 'A resumed route still needs current account state');
  p.account.signedIn = true;
  assert.equal(p.view.visibleStep(), 3, 'A removed provider must be configured again');
  p.view.chooseProvider(0);
  p.editor.apiKey = 'unsaved-fixture';
  p.view.pause();
  p.view.aboutToDisappear();
  assert.deepEqual(p.events.at(-1), ['close', false]);
  assert.equal(p.editor.apiKey, '', 'The setup checkpoint does not retain uncommitted credentials');
}

function testPreferenceMotion() {
  const frames = [];
  const { SegmentedMotion } = load('common/SegmentedMotion');
  const segmented = Object.assign(probe('common/Widgets', 'Segmented', [
    'stopAnimation', 'target', 'resetGeometry', 'syncSelection', 'motionChanged'
  ], { SegmentedMotion }), {
    options: ['跟随系统', '简体中文', 'English'], selected: 0,
    gap: 0, trackWidth: 300, segmentWidth: 0, generation: 0, appearance: { effectStrength: 1 },
    getUIContext: () => ({ createAnimator() {
      const animator = { play() {}, cancel() { this.cancelled = true; } };
      frames.push(animator);
      return animator;
    } })
  });
  segmented.resetGeometry();
  segmented.selected = 2;
  segmented.syncSelection();
  const forward = frames[0];
  forward.onFrame(0.25);
  const midpoint = [segmented.thumbLeft, segmented.thumbRight];
  assert.ok(midpoint[1] > 100 && midpoint[1] < 300);
  segmented.options = ['Follow system', '简体中文', 'English'];
  segmented.resetGeometry();
  assert.equal(forward.cancelled, undefined, 'Translating the labels keeps the running thumb animation');
  segmented.selected = 1;
  segmented.syncSelection();
  assert.equal(forward.cancelled, true);
  frames[1].onFrame(0);
  assert.deepEqual([segmented.thumbLeft, segmented.thumbRight], midpoint, 'Retargets from the displayed thumb');
  segmented.appearance.effectStrength = 0;
  segmented.motionChanged();
  assert.equal(frames[1].cancelled, true);
  assert.deepEqual([segmented.thumbLeft, segmented.thumbRight], [100, 200]);
  frames[1].onFinish();
  assert.deepEqual([segmented.thumbLeft, segmented.thumbRight], [100, 200]);
  segmented.selected = 0;
  segmented.syncSelection();
  assert.equal(frames.length, 2, 'Effects-off selection completes without an animator');
  assert.deepEqual([segmented.thumbLeft, segmented.thumbRight], [0, 100]);
  console.log('PASS preference selection motion survives relabeling, rapid retargeting and effects-off mode');
}

testIndex();
testPreferenceMotion();
testPanel().then(() => {
  console.log('PASS compiled setup flow, consent, preferences, provider retry, completion, and pause');
}).catch(error => { console.error(error); process.exitCode = 1; });
