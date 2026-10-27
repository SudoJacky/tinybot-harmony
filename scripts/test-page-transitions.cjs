// Build first. Exercise the emitted presence lifecycle, including interrupted and zero-duration animation.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function probe(file, name, methods, globals = {}, extra = []) {
  const source = path.join(root, 'entry/src/main/ets', file + '.ets');
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing ' + file);
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
const Page = probe('common/AnimatedPage', 'AnimatedPage',
  ['aboutToAppear', 'aboutToDisappear', 'retentionChanged', 'visibilityChanged', 'animate'],
  { FrameCallback: class {}, Motion: { medium: 220, fast: 160, enter: 'enter', standard: 'exit' } }, ['PageEnterFrame']);
function fixture(retained = false, immediate = false) {
  const frames = [], animations = [], presence = [];
  const page = Object.assign(new Page(), { visible: false, retained, renderContent: false, present: false, progress: 0, generation: 0,
    onPresenceChanged: value => presence.push(value),
    getUIContext: () => ({ postFrameCallback: frame => frames.push(frame), animateTo(options, update) {
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
  'removeDetailTab', 'detailTabPresent', 'detailTabsAvailable', 'setDetailPane'],
  { Motion: { medium: 220, fast: 160 } });
const calls = [];
const browser = Object.assign(new Browser(), { browserExpanded: true, browserPresent: true, browserClosing: false,
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
