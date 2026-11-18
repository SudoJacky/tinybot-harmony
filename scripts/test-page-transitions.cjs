// Build first. Exercise the emitted presence lifecycle, including interrupted and zero-duration animation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { debugArtifact } = require('./debug-artifact.cjs');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function probe(file, name, methods, globals = {}, extra = []) {
  const built = debugArtifact(file);
  const tree = ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
  const classes = tree.statements.filter(ts.isClassDeclaration), cls = classes.find(n => n.name.text === name);
  const selected = cls.members.filter(n => methods.includes(n.name?.getText(tree)));
  assert.equal(selected.length, methods.length);
  const exports = {};
  vm.runInNewContext(ts.transpileModule(classes.filter(n => extra.includes(n.name.text)).map(n => n.getText(tree)).join('\n') +
    'class Probe {' + selected.map(n => n.getText(tree)).join('\n') + '} exports.Probe = Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, ...globals });
  return exports.Probe;
}
const screenExports = {};
let displayId = 7;
const displays = new Map([[7, { width: 1019, height: 1360, xDPI: 200, yDPI: 200 }]]);
const fallbackScreen = { width: 1440, height: 1920, xDPI: 200, yDPI: 200 };
const warnings = [];
const screenSource = path.join(root, 'entry/src/main/ets/common/FullscreenTransition.ets');
vm.runInNewContext(ts.transpileModule(fs.readFileSync(screenSource, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
} }).outputText, { exports: screenExports, require(name) {
  if (name === '../model/Diagnostics') { return { Diagnostics: { log: (...args) => warnings.push(args) } }; }
  assert.equal(name, '@kit.ArkUI');
  return { display: { getDisplayByIdSync(id) {
    if (!displays.has(id)) { throw new Error('Display disconnected'); }
    return displays.get(id);
  }, getDefaultDisplaySync: () => fallbackScreen }, window: { findWindow(name) {
    assert.equal(name, 'main');
    return { getWindowProperties: () => ({ displayId, windowRect: { width: 1000, height: 1800 } }) };
  } } };
} }, { filename: screenSource });
const { fullscreenTransitionDuration, previewFullscreenMotion } = screenExports;
const ui = { getWindowName: () => 'main' };

const Page = probe('common/AnimatedPage', 'AnimatedPage',
  ['aboutToAppear', 'aboutToDisappear', 'retentionChanged', 'visibilityChanged', 'animate'],
  { FrameCallback: class {}, Motion: { medium: 220, fast: 160, enter: 'enter', standard: 'exit' },
    Curve: { EaseInOut: 'ease-in-out' }, fullscreenTransitionDuration }, ['PageEnterFrame']);
function fixture(retained = false, immediate = false, fullScreen = false) {
  const frames = [], animations = [], presence = [];
  const page = Object.assign(new Page(), { visible: false, retained, fullScreen, renderContent: false, present: false, progress: 0, generation: 0,
    onPresenceChanged: value => presence.push(value),
    getUIContext: () => ({ ...ui, postFrameCallback: frame => frames.push(frame), animateTo(options, update) {
      update(); animations.push(options); if (immediate) options.onFinish();
    } }) });
  page.aboutToAppear();
  return { page, frames, animations, presence, show() { page.visible = true; page.visibilityChanged(); },
    hide() { page.visible = false; page.visibilityChanged(); } };
}
const f = fixture(); assert.equal(f.page.renderContent, false);
f.show(); assert.equal(f.page.renderContent, true); assert.equal(f.page.present, true); assert.equal(f.page.progress, 0);
assert.equal(f.animations.length, 0, 'A new page must paint its initial pose before entering');
f.frames.shift().onIdle(); assert.equal(f.page.progress, 1); assert.equal(f.animations.at(-1).duration, 220);
f.hide(); assert.equal(f.page.progress, 0); assert.equal(f.animations.at(-1).duration, 160);
assert.equal(f.page.renderContent, true); assert.equal(f.page.present, true, 'Outgoing page remains visible during exit');
f.animations.at(-1).onFinish(); assert.equal(f.page.renderContent, false); assert.equal(f.page.present, false);
assert.deepEqual(f.presence, [true, false]);
console.log('PASS actual enter/exit lifecycle paints an initial frame and defers outgoing disposal');

for (const [width, height, duration] of [[1019, 1360, 220], [1020, 1360, 270], [1440, 1920, 270], [1441, 1920, 320]]) {
  displays.set(7, { width, height, xDPI: 200, yDPI: 200 });
  const full = fixture(true, false, true);
  full.show(); full.frames.shift().onIdle();
  assert.equal(full.animations.at(-1).duration, duration);
  full.hide();
  assert.equal(full.animations.at(-1).duration, duration);
  assert.equal(full.animations.at(-1).curve, 'ease-in-out');
  assert.equal(full.page.present, true);
  full.animations.at(-1).onFinish();
  assert.equal(full.page.present, false);
  assert.equal(full.page.renderContent, true, 'The hidden Web host stays mounted');
}
displayId = undefined;
assert.equal(fullscreenTransitionDuration(ui), 270);
displayId = 8;
assert.equal(fullscreenTransitionDuration(ui), 320, 'Unplugged displays use the longest duration');
displays.set(8, { width: 500, height: 500, xDPI: 0, yDPI: 100 });
assert.equal(fullscreenTransitionDuration(ui), 320, 'Missing physical density uses the longest duration');
assert.deepEqual(warnings.map(args => args.slice(0, 3)), Array.from({ length: 2 }, () => ['warn', 'navigation', 'transition_screen_failed']));
console.log('PASS full-screen entry and exit use the current display diagonal and report unavailable metrics');

displayId = 7;
displays.set(7, { width: 1019, height: 1360, xDPI: 200, yDPI: 200 });
const previewUi = { ...ui, px2vp: px => px / 2, getComponentUtils: () => ({ getRectangleById(id) {
  if (id === 'message-list') { return { windowOffset: { x: 0, y: 100 }, size: { width: 1000, height: 1200 } }; }
  assert.equal(id, 'preview-card');
  return { windowOffset: { x: 80, y: 540 }, size: { width: 640, height: 1200 } };
} }) };
const preview = previewFullscreenMotion(previewUi, 'preview-card', true);
assert.equal(preview.duration, 220);
assert.equal(preview.x, -50); assert.equal(preview.y, 10);
assert.equal(preview.scale, 0.72);
assert.equal(previewFullscreenMotion({}, 'preview-card', false), undefined);
console.log('PASS preview cover scales proportionally around the visible card and supports instant transitions');

const interrupted = fixture(); interrupted.show(); interrupted.frames.shift().onIdle(); interrupted.hide();
const staleExit = interrupted.animations.at(-1);
interrupted.show(); staleExit.onFinish();
assert.equal(interrupted.page.present, true); assert.equal(interrupted.page.renderContent, true);
assert.equal(interrupted.page.progress, 1);
interrupted.hide(); interrupted.animations.at(-1).onFinish(); assert.equal(interrupted.page.renderContent, false);
const early = fixture(); early.show(); const staleFrame = early.frames.shift(); early.hide(); staleFrame.onIdle();
assert.equal(early.animations.length, 1, 'A closed page cannot be reopened by its old post-frame callback');
early.animations[0].onFinish(); assert.equal(early.page.present, false);
console.log('PASS rapid close/reopen and close-before-first-frame do not blank or resurrect a page');

const kept = fixture(true); assert.equal(kept.page.renderContent, true);
kept.show(); kept.frames.shift().onIdle(); kept.hide(); kept.animations.at(-1).onFinish();
assert.equal(kept.page.renderContent, true); assert.equal(kept.page.present, false);
kept.page.retained = false; kept.page.retentionChanged(); assert.equal(kept.page.renderContent, false);
const disposed = fixture(); disposed.show(); disposed.page.aboutToDisappear(); disposed.frames.shift().onIdle();
assert.equal(disposed.animations.length, 0, 'Disposal cancels queued entry work');
const zero = fixture(false, true); zero.show(); zero.frames.shift().onIdle(); zero.hide();
assert.equal(zero.page.present, false); assert.equal(zero.page.renderContent, false);
console.log('PASS hidden retained editors/Web hosts survive, disposed callbacks are inert, synchronous completion releases correctly');

const Browser = probe('pages/Index', 'Index', ['closeBrowser', 'browserPresenceChanged', 'setBrowserExpanded',
  'removeDetailTab', 'detailTabPresent', 'detailTabsAvailable', 'setDetailPane', 'compactDetailLauncher', 'hideBrowserTab', 'saveDetailSelection'],
  { Motion: { medium: 220, fast: 160 } });
const calls = [];
const browser = Object.assign(new Browser(), { browserExpanded: true, browserPresent: true, browserClosing: false,
  appearance: { effectStrength: 1 },
  detailTabs: ['browser'], activeDetailTab: 'browser', detailPaneOpen: true, detailReveal: 1,
  detailClosing: false, detailClosingLauncher: false, detailAnim: 0,
  browser: { open: true, takeOver: () => calls.push('pause'), close: () => calls.push('close') },
  getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }),
    animateTo(_options, update) { update(); if (_options.onFinish) { _options.onFinish(); } } }) });
browser.closeBrowser(); assert.deepEqual(calls, ['pause']); assert.equal(browser.browserExpanded, false);
browser.browserPresenceChanged(false); assert.deepEqual(calls, ['pause', 'close']);
browser.browserExpanded = true; browser.closeBrowser(); browser.setBrowserExpanded(true); browser.browserPresenceChanged(false);
assert.deepEqual(calls, ['pause', 'close', 'pause'], 'Reopening cancels a pending close');
console.log('PASS browser pauses immediately, closes after exit, and keeps a reopened session alive');

browser.browser.open = false; browser.browserExpanded = true; browser.browserPresenceChanged(false);
assert.equal(browser.browserExpanded, false, 'Agent/policy closure also releases the visible inspector');
console.log('PASS external browser closure cannot leave an empty inspector reserved');

Object.assign(browser, { largeScreen: true, windowWidth: 1400, browserPresent: true, browserExpanded: true,
  detailTabs: ['browser'], detailPaneOpen: true, activeDetailTab: 'browser' });
browser.browser.open = true;
browser.hideBrowserTab();
assert.equal(browser.compactDetailLauncher(), false, 'A maximized tab cannot shrink to a floating card while exiting');
browser.browserPresenceChanged(false);
assert.equal(browser.compactDetailLauncher(), true, 'The compact launcher is available again after exit');
assert.equal(browser.browser.open, true);
assert.deepEqual(calls, ['pause', 'close', 'pause'], 'Collapse does not close the browser session');
console.log('PASS a wide browser keeps its geometry through collapse without closing the session');
