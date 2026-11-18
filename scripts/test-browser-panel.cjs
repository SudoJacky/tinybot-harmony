// Run after devecocli build; exercise the actual emitted address callbacks and system-back handler.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
function emitted(relative) {
  const source = path.join(root, 'entry/src/main/ets', relative + '.ets');
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', relative + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing ' + relative);
  return ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
}
const panelTree = emitted('views/BrowserPanel'), handlers = {};
const panelClass = panelTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'BrowserPanel');
function visit(node, names) {
  if (ts.isCallExpression(node)) {
    const name = node.expression.getText(panelTree);
    if (names.includes(name)) handlers[name] = node.arguments[0].getText(panelTree);
  }
  ts.forEachChild(node, child => visit(child, names));
}
visit(panelClass.members.find(node => node.name?.getText(panelTree) === 'addressField'),
  ['TextInput.onFocus', 'TextInput.onBlur', 'TextInput.onChange', 'TextInput.create']);
visit(panelClass, ['Web.onPageEnd']);
const indexTree = emitted('pages/Index');
const index = indexTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'Index');
let presentCallback;
function findPresentation(node) {
  if (ts.isPropertyAssignment(node) && node.name.getText(indexTree) === 'onPresent') presentCallback = node.initializer.getText(indexTree);
  ts.forEachChild(node, findPresentation);
}
findPresentation(indexTree); assert.ok(presentCallback, 'Preview capture must be able to present the browser');
const presentationExports = {};
vm.runInNewContext(ts.transpileModule('export function callback(){return (' + presentCallback + ');}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: presentationExports });
const presented = { owner: 'agent', expanded: false, tab: '', setBrowserExpanded(value) { this.expanded = value; }, openDetailTab(value) { this.tab = value; } };
presentationExports.callback.call(presented)();
assert.equal(presented.expanded, true); assert.equal(presented.tab, 'browser'); assert.equal(presented.owner, 'agent');
console.log('PASS emitted preview presentation expands the browser and selects its tab without taking control');
const back = index.members.find(n => n.name?.getText(indexTree) === 'onBackPress').body.getText(indexTree);
const navigate = panelClass.members.find(n => n.name?.getText(panelTree) === 'navigate').body.getText(panelTree);
const feedbackStatements = [];
function feedback(node) {
  if (ts.isVariableDeclaration(node) && node.name.getText(panelTree) === 'forEachItemGenFunction' && node.initializer?.getText(panelTree).includes("browser-agent-action")) {
    feedbackStatements.push(node.initializer.getText(panelTree));
  }
  ts.forEachChild(node, feedback);
}
feedback(panelTree);
assert.equal(feedbackStatements.length, 1);
const feedbackExports = {}, marker = {};
const markerUi = new Proxy({}, { get: (_, name) => (...args) => { marker[name] = args[0]; } });
vm.runInNewContext(ts.transpileModule(`export function marker() { return (${feedbackStatements[0]}); }`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: feedbackExports, Stack: markerUi, Circle: new Proxy({}, { get: () => () => {} }),
  HitTestMode: { None: 'pass-through' }, Motion: {},
  TransitionEffect: { OPACITY: { combine() { return this; }, animation() { return this; } }, scale() {}, asymmetric() {} } });
const markerView = { webWidth: 400, webHeight: 600, appearance: {}, observeComponentCreation2(callback) { callback(1, true); } };
feedbackExports.marker.call(markerView)({ id: 1, x: 0.25, y: 0.5 });
assert.equal(marker.position.x, 84); assert.equal(marker.position.y, 284);
assert.equal(marker.hitTestBehavior, 'pass-through'); assert.equal(marker.accessibilityLevel, 'no');
console.log('PASS emitted operation cue maps normalized coordinates onto the Web viewport and passes through input');
const compiled = {};
vm.runInNewContext(ts.transpileModule(`export function callbacks() {
  return { focus: ${handlers['TextInput.onFocus']}, blur: ${handlers['TextInput.onBlur']},
    change: ${handlers['TextInput.onChange']}, loaded: ${handlers['Web.onPageEnd']}, display: () => (${handlers['TextInput.create']}).text };
}
export function back() ${back}
export function navigate() ${navigate}`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
  { exports: compiled, t: value => value, browserAddress: value => value });
const browser = { url: 'https://example.com/', editingAddress: false, takeovers: 0, takeOver() { this.takeovers++; } };
let navigated;
const panel = { browser, address: '', addressDirty: false,
  hasWebAddress() { return !browser.preview && /^https?:\/\//i.test(browser.url); },
  rememberVisit() {},
  driver: { userNavigate(url) { navigated = url; }, pageEnd(url) { browser.url = url; } },
  getUIContext() { return { getFocusController() { return { clearFocus() { browser.editingAddress = false; } }; } }; } },
  events = compiled.callbacks.call(panel);
events.change(browser.url);
assert.equal(browser.takeovers, 0, 'Programmatic URL updates must not take control');
events.focus(); assert.equal(events.display(), browser.url);
events.change(browser.url); assert.equal(browser.takeovers, 0, 'Focus and unchanged values remain viewing');
events.blur(); assert.equal(browser.takeovers, 0);
browser.url = 'https://example.com/redirect'; events.change(browser.url);
assert.equal(browser.takeovers, 0, 'Redirects while not editing remain viewing');
events.focus(); events.change('');
assert.equal(browser.takeovers, 1, 'Real editing takes control');
assert.equal(events.display(), '', 'Clearing an address must not restore the old URL');
events.blur(); assert.equal(events.display(), '', 'Blur preserves an unsent empty draft');
events.focus(); assert.equal(events.display(), '', 'Refocusing does not replace the draft');
events.change('https://example.com/edited'); events.blur(); compiled.navigate.call(panel);
assert.equal(navigated, 'https://example.com/edited', 'The Go button must use the draft even after blur');
events.loaded({ url: navigated }); assert.equal(panel.addressDirty, false); assert.equal(events.display(), navigated);
let backwards = 0, collapsed = 0, cleared = 0;
const view = { browserExpanded: true, detailPaneOpen: true, currentDetailTab: () => 'browser',
  browser: { editingAddress: false, owner: 'agent', userBack() { backwards++; return true; } },
  hideBrowserTab() { collapsed++; this.browserExpanded = false; },
  getUIContext() { return { getFocusController() { return { clearFocus() { cleared++; } }; } }; } };
assert.equal(compiled.back.call(view), true); assert.equal(backwards, 0); assert.equal(collapsed, 1);
view.browser.owner = 'user'; compiled.back.call(view);
assert.equal(backwards, 1); assert.equal(collapsed, 1, 'User history is navigated before collapsing');
view.browser.userBack = () => false; compiled.back.call(view);
assert.equal(collapsed, 2, 'At the start of history, back collapses the viewer');
view.browser.editingAddress = true; compiled.back.call(view);
assert.equal(cleared, 1); assert.equal(collapsed, 2, 'Back dismisses address editing before navigation');
console.log('PASS emitted browser address callbacks: programmatic changes/focus/copy keep control, editing and empty drafts work');
console.log('PASS emitted system back: dismiss editing, navigate user history, collapse agent viewing without takeover');

const browserMethods = ['openBrowser', 'enableAndOpenBrowser'].map(name =>
  index.members.find(node => node.name?.getText(indexTree) === name).getText(indexTree)).join('\n');
const pageExports = {};
vm.runInNewContext(ts.transpileModule(`export class Page { ${browserMethods} }`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: pageExports, t: value => value });
function page(policy) {
  const view = new pageExports.Page(), events = [];
  view.appearance = { surface: {} };
  view.browser = { policy, permissionSaving: false, openForUser() { events.push('open'); },
    report(message) { events.push(['report', message]); },
    async setEnabled() { events.push('save'); this.policy = 'enabled'; } };
  view.setBrowserExpanded = value => events.push(['expanded', value]);
  // Permission behavior is under test here; the tab side effect has its own suite.
  view.openDetailTab = () => {};
  view.getUIContext = () => ({ showAlertDialog(dialog) { view.dialog = dialog; },
    getPromptAction: () => ({ showToast: value => events.push(['toast', value.message]) }) });
  return { view, events };
}
(async () => {
  let { view, events } = page('enabled'); view.openBrowser();
  assert.deepEqual(events, ['open', ['expanded', true]]); assert.equal(view.dialog, undefined);
  for (const policy of ['unset', 'disabled']) {
    ({ view, events } = page(policy)); view.openBrowser();
    assert.equal(events.length, 0); assert.ok(view.dialog);
    view.dialog.primaryButton.action(); assert.equal(events.length, 0);
    await view.dialog.secondaryButton.action();
    assert.deepEqual(events, ['save', 'open', ['expanded', true]]);
  }
  ({ view, events } = page('unset')); let saved;
  view.browser.setEnabled = async () => { await new Promise(resolve => { saved = resolve; }); view.browser.policy = 'enabled'; };
  view.openBrowser(); const enabling = view.dialog.secondaryButton.action();
  assert.equal(events.length, 0, 'Do not mount the browser before permission persists');
  saved(); await enabling; assert.deepEqual(events, ['open', ['expanded', true]]);
  ({ view, events } = page('disabled'));
  view.browser.setEnabled = async () => { throw Error('permission disk error'); };
  view.openBrowser(); await view.dialog.secondaryButton.action();
  assert.deepEqual(events, [['toast', 'permission disk error']]);
  assert.equal(view.browser.policy, 'disabled');
  ({ view, events } = page('enabled')); view.browser.permissionSaving = true; view.openBrowser();
  assert.equal(events.length, 0); assert.equal(view.dialog, undefined);
  console.log('PASS emitted manual browser entry: enabled opens directly, cancel preserves policy, enable waits for persistence and save failures stay visible');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Replay the shipped annotation callbacks, including the native-image lifetime and draft boundary.
const annotationTree = emitted('views/BrowserAnnotationBoard');
const annotationClass = annotationTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'BrowserAnnotationBoard');
function probe(tree, component, names, globals = {}) {
  const body = names.map(name => component.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
  const exports = {};
  vm.runInNewContext(ts.transpileModule(`export class Probe { ${body} }`, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, t: value => value, ...globals });
  return new exports.Probe();
}
const annotationExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/model/BrowserAnnotation.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
}).outputText, { exports: annotationExports, Observed: value => value, require: () => ({ t: value => value }) });
const TouchType = { Down: 0, Move: 1, Up: 2, Cancel: 3 };
(async () => {
  const geometry = [], logs = [];
  const workflowTree = emitted('services/BrowserAnnotationImage');
  function annotationWorkflow(renderBrowserAnnotation, Diagnostics) {
    const names = ['releaseAnnotationPixel', 'submitBrowserAnnotation', 'captureBrowserDraft'];
    const methods = workflowTree.statements.filter(node => ts.isFunctionDeclaration(node) && names.includes(node.name?.text));
    assert.equal(methods.length, names.length);
    const exports = {};
    vm.runInNewContext(ts.transpileModule(methods.map(node => node.getText(workflowTree)).join('\n'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
    }).outputText, { exports, Diagnostics, renderBrowserAnnotation, BrowserAnnotation: annotationExports.BrowserAnnotation });
    return exports;
  }
  const areaHandlers = {};
  function areas(node) {
    if (ts.isCallExpression(node) && ['Canvas.onAreaChange', 'Stack.onAreaChange'].includes(node.expression.getText(annotationTree))) {
      areaHandlers[node.expression.getText(annotationTree)] = node.arguments[0].getText(annotationTree);
    }
    ts.forEachChild(node, areas);
  }
  areas(annotationTree);
  const areaExports = {};
  vm.runInNewContext(ts.transpileModule(`export function areaCallbacks() { return {
    frame: ${areaHandlers['Stack.onAreaChange']}, canvas: ${areaHandlers['Canvas.onAreaChange']}
  }; }`, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, { exports: areaExports });
  const layout = { captureWidth: 900, captureHeight: 1200, frameWidth: 0, frameHeight: 0, draw() {} };
  const area = areaExports.areaCallbacks.call(layout);
  area.frame({}, { width: 300, height: 600 }); area.canvas({}, { width: 0, height: 0 });
  assert.equal(layout.frameWidth, 300); assert.equal(layout.frameHeight, 400, 'Initial zero-size canvas measurement cannot collapse the image frame');
  area.canvas({}, { width: 300, height: 400 }); assert.equal(layout.canvasWidth, 300);
  let outputReleases = 0, captureReleases = 0, adds = 0, finish;
  const output = { release: async () => { outputReleases++; } };
  const boardDiagnostics = { log: (...args) => logs.push(args) };
  const boardWorkflow = annotationWorkflow(async (pixel, strokes) => {
    assert.equal(pixel, board.pixel); assert.equal(strokes, board.draft.strokes); return output;
  }, boardDiagnostics);
  const board = probe(annotationTree, annotationClass, ['setInitiallyProvidedValue', 'draw', 'touch', 'add', 'aboutToDisappear'],
    { TouchType, Diagnostics: boardDiagnostics, ...boardWorkflow });
  Object.assign(board, { canvasWidth: 100, canvasHeight: 200, ready: true, pointer: -1, draft: new annotationExports.BrowserAnnotation(),
    __draft: { set() {} },
    canvas: { clearRect() {}, beginPath() {}, moveTo: (...point) => geometry.push(point), lineTo() {}, stroke() {} },
    getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }) }) });
  const nativePixel = { release: async () => { captureReleases++; } };
  board.setInitiallyProvidedValue({ pixel: nativePixel, pageTitle: 'Test page', captureWidth: 900, captureHeight: 1200 });
  assert.equal(board.pixel, nativePixel, 'The compiled component boundary retains the original native image handle');
  const touch = (type, x, y) => board.touch({ type, changedTouches: [{ id: 1, x, y }], touches: type === TouchType.Up ? [] : [{ id: 1 }], stopPropagation() {} });
  touch(TouchType.Down, 25, 50); touch(TouchType.Move, 50, 100); touch(TouchType.Up, 75, 150);
  assert.equal(board.draft.strokes.length, 1); assert.equal(board.draft.strokes[0].points[0].x, 0.25);
  board.canvasWidth = 200; board.canvasHeight = 400; board.draw();
  assert.deepEqual(geometry.at(-1), [50, 100], 'Resizing keeps the stroke aligned to the same image coordinates');
  board.onAdd = async () => { throw Error('attachment write failed'); }; await board.add();
  assert.equal(board.error, 'attachment write failed'); assert.equal(board.draft.saving, false); assert.equal(outputReleases, 1);
  assert.equal(board.draft.strokes.length, 1); assert.equal(logs.length, 1);
  board.onAdd = () => new Promise(resolve => { adds++; finish = resolve; });
  const adding = board.add(); await Promise.resolve(); await board.add(); assert.equal(adds, 1);
  finish(); await adding; assert.equal(outputReleases, 2); assert.equal(captureReleases, 0);
  board.aboutToDisappear(); assert.equal(captureReleases, 1);
  console.log('PASS emitted annotation canvas: touch geometry, resize alignment, failed-save retry, duplicate-add guard and image release');

  const events = []; let unpause, dialog, focusClears = 0;
  let renderedReleases = 0;
  const rendered = { release: async () => { renderedReleases++; } };
  const panelDiagnostics = { log() {} };
  const panelWorkflow = annotationWorkflow(async (_pixel, strokes) => { assert.equal(strokes[0].points.length, 5); return rendered; },
    panelDiagnostics);
  const panel = probe(panelTree, panelClass, ['pickAt', 'annotate', 'closeAnnotation', 'captureElementNote'],
    { Diagnostics: panelDiagnostics, ...panelWorkflow });
  Object.assign(panel, { appearance: { surface: {} }, mounted: true, expanded: true, foreground: true,
    capturing: false, showAnnotation: false, canAnnotate: true, threadId: 'original',
    browser: { pauseForAnnotation: () => new Promise(resolve => { events.push('pause'); unpause = resolve; }), report: error => events.push(error) },
    driver: { capture: async () => { events.push('capture'); return { pixel: {}, width: 900, height: 1200 }; } },
    getUIContext: () => ({ getFocusController: () => ({ clearFocus() { focusClears++; } }), showAlertDialog: value => { dialog = value; } }) });
  const capturing = panel.annotate(); assert.equal(panel.capturing, true); assert.deepEqual(events, ['pause']);
  await panel.annotate(); unpause(); await capturing;
  assert.deepEqual(events, ['pause', 'capture']); assert.equal(panel.showAnnotation, true); assert.equal(panel.annotationThreadId, 'original');
  panel.annotation.note = 'A note'; panel.closeAnnotation(); assert.equal(panel.showAnnotation, true);
  dialog.primaryButton.action(); assert.equal(panel.showAnnotation, true); dialog.secondaryButton.action(); assert.equal(panel.showAnnotation, false);
  panel.showAnnotation = true; panel.annotation.saving = true; panel.closeAnnotation(); assert.equal(panel.showAnnotation, true);
  console.log('PASS emitted annotation entry waits for takeover, prevents duplicate captures and confirms dismissal of unsaved notes');
  let screenshotReleased = 0;
  panel.showAnnotation = false;
  panel.browser.pauseForAnnotation = async () => {};
  const screenshot = { release: async () => { screenshotReleased++; } };
  panel.driver.capture = async () => ({ pixel: screenshot });
  panel.onScreenshot = async (threadId, pixel) => {
    assert.equal(threadId, 'original'); assert.equal(pixel, screenshot);
  };
  await panel.annotate(true);
  assert.equal(screenshotReleased, 1); assert.equal(panel.showAnnotation, false);
  const element = { x: 0.2, y: 0.3, width: 0.2, height: 0.1, label: 'Submit', location: '#submit' };
  Object.assign(panel, { pickingElement: true, webWidth: 400, webHeight: 500, scheduleElementRefresh() {} });
  Object.assign(panel.browser, { preview: { viewportWidth: 300 }, documentVersion: 1, previewInstance: 2 });
  panel.driver.inspectElement = async command => {
    assert.equal(command.action, 'select'); assert.equal(command.x, 0.25); assert.equal(command.y, 0.35);
    return { id: 7, mark: element, values: ['rgb(0, 0, 0)'] };
  };
  await panel.pickAt({ x: 75, y: 175 });
  assert.equal(panel.elementSelection.id, 7);
  assert.equal(panel.pickingElement, false); assert.equal(panel.showAnnotation, false);
  panel.driver.captureElement = async id => {
    assert.equal(id, 7);
    return { pixel: {}, element, width: 900, height: 1200 };
  };
  await panel.annotate(false, panel.elementSelection.id);
  assert.equal(panel.showAnnotation, true);
  assert.equal(panel.annotation.strokes[0].points.length, 5);
  panel.showAnnotation = false;
  panel.driver.captureElement = async () => ({ pixel: screenshot, element, changes: [{ property: 'border-width', before: '2px', after: '7px' }] });
  panel.onAnnotation = async (threadId, pixel, capture, note) => {
    assert.equal(threadId, 'original'); assert.equal(pixel, rendered);
    assert.equal(capture.changes[0].after, '7px'); assert.equal(note, 'test');
  };
  panel.editElement = async command => { assert.equal(command.action, 'clear'); return true; };
  const focusBeforeCapture = focusClears;
  await panel.captureElementNote('test', false);
  assert.equal(panel.showAnnotation, false); assert.equal(screenshotReleased, 2); assert.equal(renderedReleases, 1);
  assert.equal(focusClears, focusBeforeCapture, 'Dismissing the note keyboard before capture resizes the web viewport');
  console.log('PASS selecting leaves the page open for editing, screenshot stages directly and element capture seeds an editable outline');

  const highlight = probe(panelTree, panelClass, ['elementHighlight'], { Stack: markerUi, HitTestMode: { None: 'pass-through' } });
  let updateHighlight;
  Object.assign(highlight, { appearance: {}, webWidth: 400, webHeight: 500, browser: panel.browser,
    elementSelection: { mark: element }, observeComponentCreation2(callback) { updateHighlight = callback; callback(1, true); } });
  highlight.elementHighlight();
  assert.equal(marker.position.x, 60); assert.equal(marker.position.y, 150);
  assert.equal(marker.hitTestBehavior, 'pass-through');
  highlight.elementSelection = { mark: { ...element, y: 0.5 } };
  updateHighlight(1, false);
  assert.equal(marker.position.y, 250, 'The ArkUI highlight must follow the current selection geometry');

  const driverTree = emitted('services/NativeBrowserDriver');
  const driverClass = driverTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'NativeBrowserDriver');
  const driver = probe(driverTree, driverClass, ['captureElement']);
  let current = { mark: element, viewport: 'current' }, nativeReleases = 0;
  const capture = { pixel: { release: async () => { nativeReleases++; } } };
  driver.browser = { documentVersion: 1, previewInstance: 0 };
  driver.inspectElement = async () => current;
  driver.capture = async () => capture;
  assert.equal((await driver.captureElement(7)).element, element);
  driver.capture = async () => { current = { mark: element, viewport: 'changed' }; return capture; };
  await assert.rejects(driver.captureElement(7), /页面已变化/);
  assert.equal(nativeReleases, 1);
  console.log('PASS element capture uses current coordinates and releases the screenshot if the viewport changes mid-capture');

  const draftEvents = [];
  const page = probe(indexTree, index, ['addBrowserAnnotation'], {
    MAX_MESSAGE_ATTACHMENTS: 10,
    Attachments: { saveBrowserAnnotation: async () => { draftEvents.push('image'); return { id: 'capture' }; },
      saveBrowserScreenshot: async () => { draftEvents.push('screenshot'); return { id: 'screenshot' }; },
      discardStaged: async items => draftEvents.push(['discard', ...items]) },
    browserAnnotationContent: (page, note) => ({ url: page.url, note })
  });
  Object.assign(page, { app: { active: { id: 'original', attachments: [] }, canQueueInput: true,
    appendDraftAttachment: async (...args) => draftEvents.push(args) }, paths: { clear() {} }, setDrawer() {},
    hideBrowserTab: () => draftEvents.push('browser hidden') });
  await page.addBrowserAnnotation('original', {}, { url: 'https://example.com' }, 'Change this');
  assert.equal(draftEvents[1][0], 'original');
  assert.deepEqual(draftEvents[1][1].browserAnnotation, { url: 'https://example.com', note: 'Change this' });
  assert.equal(draftEvents[1].length, 2);
  assert.equal(draftEvents.at(-1), 'browser hidden');
  await assert.rejects(page.addBrowserAnnotation('other', {}, {}, ''), /对话已切换/);
  assert.equal(draftEvents.filter(value => value === 'image').length, 1, 'Wrong-thread exports cannot write or attach an image');
  await page.addBrowserAnnotation('original', {}, undefined, '');
  assert.deepEqual(draftEvents.at(-2), ['original', { id: 'screenshot' }]);
  page.app.appendDraftAttachment = async () => { throw new Error('Draft save failed'); };
  await assert.rejects(page.addBrowserAnnotation('original', {}, undefined, ''), /Draft save failed/);
  assert.equal(draftEvents.at(-1)[0], 'discard');
  assert.equal(draftEvents.at(-1)[1].id, 'screenshot');
  await assert.rejects(page.addBrowserAnnotation('original', {}, { url: 'https://example.com' }, 'Change this'), /Draft save failed/);
  assert.deepEqual(draftEvents.at(-1), ['discard', { id: 'capture', browserAnnotation: undefined }]);
  console.log('PASS emitted annotation submission stages the captured URL and image in the original chat without sending or handing off');
})().catch(error => { console.error(error); process.exitCode = 1; });
