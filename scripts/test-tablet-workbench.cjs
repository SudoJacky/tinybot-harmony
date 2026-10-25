// Build first: exercise production window callbacks and emitted editor/preview handlers.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function sourceModule(file) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file), 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports });
  return exports;
}
const { WorkbenchLayout } = sourceModule('entry/src/main/ets/model/WorkbenchLayout.ets');
function emitted(file, name) {
  const original = path.join(root, 'entry/src/main/ets', file + '.ets');
  const compiled = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets', file + '.ts');
  assert.ok(fs.statSync(compiled).mtimeMs >= fs.statSync(original).mtimeMs, 'Build before testing ' + file);
  const tree = ts.createSourceFile(compiled, fs.readFileSync(compiled, 'utf8'), ts.ScriptTarget.Latest, true);
  return { tree, cls: tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name) };
}
function probe(file, name, methods, globals = {}) {
  const { tree, cls } = emitted(file, name), exports = {};
  const selected = cls.members.filter(n => methods.includes(n.name?.getText(tree)));
  assert.equal(selected.length, methods.length);
  vm.runInNewContext(ts.transpileModule('class Probe {' + selected.map(n => n.getText(tree)).join('\n') + '} exports.Probe = Probe;', {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, ...globals });
  return exports.Probe;
}
const RAIL = WorkbenchLayout.RAIL_WIDTH;
for (const width of [320, 600, 839, 840, 960, 979, 980, 1024, 1199, 1200, 1600, 2400]) {
  for (const details of [false, true]) {
    const layout = new WorkbenchLayout(width, details);
    if (width < 840) {
      assert.equal(layout.historyWidth, 0, `Phone keeps no persistent history host at ${width} vp`);
      assert.equal(layout.rail, false);
      assert.equal(layout.docked, false);
      assert.equal(layout.detailX, 0);
      continue;
    }
    assert.equal(layout.docked, details);
    assert.ok(layout.expanded || layout.rail, 'Tablet keeps either the full column or the rail');
    assert.equal(layout.expanded, !layout.rail);
    if (layout.rail) assert.equal(layout.historyWidth, RAIL);
    else assert.ok(layout.historyWidth >= 264 && layout.historyWidth <= 420);
    if (layout.docked) {
      assert.ok(layout.chatWidth >= 440, `Chat keeps its 440 vp minimum at ${width}`);
      assert.ok(layout.detailWidth >= 300, `Detail keeps its 300 vp minimum at ${width}`);
      assert.ok(layout.detailWidth <= width * 0.7 + 0.001, 'Detail stays inside the 70% cap');
      assert.equal(layout.detailX + layout.detailWidth, width);
    } else assert.equal(layout.detailX, 0);
  }
}
assert.equal(new WorkbenchLayout(839, false).historyWidth, 0);
assert.equal(new WorkbenchLayout(840, false).historyWidth, 280);
assert.equal(new WorkbenchLayout(840, true).rail, true, 'A docked pane turns the column into the rail');
assert.equal(new WorkbenchLayout(840, true).historyWidth, RAIL);
assert.equal(new WorkbenchLayout(1019, true).rail, true);
assert.equal(new WorkbenchLayout(1020, true).rail, false, 'The column returns as soon as both panes fit');
assert.equal(new WorkbenchLayout(1199, true).expanded, true);
assert.equal(new WorkbenchLayout(1440, true).historyWidth, 280);
assert.equal(new WorkbenchLayout(1440, true).rail, false);
assert.equal(new WorkbenchLayout(900, true, true).canExpand, false);
assert.equal(new WorkbenchLayout(900, false, false).rail, true, 'The rail survives without a docked pane');
assert.equal(new WorkbenchLayout(1440, true, false).historyWidth, RAIL);
assert.equal(new WorkbenchLayout(1440, true, true, 100).historyWidth, 264, 'History drag clamps low');
assert.equal(new WorkbenchLayout(1440, true, true, 900).historyWidth, 420, 'History drag clamps high');
assert.equal(new WorkbenchLayout(1440, true, true, 280, 2000).detailWidth, 720, 'Detail gives way to the chat minimum');
assert.equal(new WorkbenchLayout(1440, true, true, 280, 2000).chatWidth, 440);
assert.equal(new WorkbenchLayout(1440, true, true, 280, 2000).detailMaxWidth, 720);
assert.equal(new WorkbenchLayout(1440, true, true, 280, 100).detailWidth, 300, 'Detail drag clamps low');
assert.ok(new WorkbenchLayout(1440, true, true, 280).detailWidth > 300, 'First open picks a proportional width');
console.log('PASS phone, rail, two-pane and three-pane boundaries, drag clamps and protected minimums');

const Page = probe('pages/Index', 'Index', ['hasPreview', 'detailOpen', 'workbench', 'windowChanged', 'openFiles', 'openPreview', 'closePreview', 'previewPresenceChanged', 'onBackPress',
  'beginResize', 'resizeHistory', 'resizeDetail', 'endResize'], { WorkbenchLayout });
const draft = { text: 'unsent input', attachments: ['image'] }, active = { id: 'thread', draft, messages: [] };
const session = {}, browser = {};
const page = Object.assign(new Page(), { app: { active }, session, browser, windowWidth: 0,
  workspaceOpen: false, workspaceRequest: 0, workspaceCloseRequest: 0,
  previewId: '', previewThreadId: '', browserExpanded: false,
  drawerOpen: true, drawerDragging: true, drawerReveal: 0.6, drawerContentActive: true, drawerAnimation: 4,
  getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }) }),
  setDrawer() {}, setBrowserExpanded(value) { this.browserExpanded = value; } });
page.windowChanged(1200);
assert.equal(page.drawerOpen, false); assert.equal(page.drawerReveal, 0); assert.equal(page.drawerAnimation, 5);
page.openFiles('notes.md'); assert.equal(page.workspaceOpen, true); assert.equal(page.workspacePath, 'notes.md');
for (const width of [840, 400, 1200, 900, 600, 1600]) {
  page.windowChanged(width);
  assert.equal(page.app.active, active); assert.equal(active.draft, draft);
  assert.equal(page.session, session); assert.equal(page.browser, browser);
  assert.equal(page.workspaceOpen, true); assert.equal(page.workspacePath, 'notes.md');
  assert.equal(page.workspaceRequest, 1, 'Resize must not send another editor-open request');
}
assert.equal(page.onBackPress(), true); assert.equal(page.workspaceCloseRequest, 1);
assert.equal(page.workspaceOpen, true, 'Back delegates to the editor so unsaved changes cannot be dropped');
page.openPreview('message', 'preview'); assert.equal(page.hasPreview(), true);
active.id = 'other'; assert.equal(page.hasPreview(), false, 'Preview cannot leak into another conversation');
active.id = 'thread'; assert.equal(page.onBackPress(), true);
assert.equal(page.previewVisible, false); assert.equal(page.previewId, 'preview', 'Keep outgoing preview data until its exit finishes');
page.previewPresenceChanged(false); assert.equal(page.previewId, '');
console.log('PASS actual resize/open/back callbacks preserve draft, session and editor, and isolate previews');

page.windowWidth = 1600; page.historyCollapsed = true;
assert.equal(page.workbench().rail, true); assert.equal(page.workbench().historyWidth, 56);
assert.equal(page.detailOpen(), true);
page.historyCollapsed = false; assert.equal(page.workbench().expanded, true);
page.historyPreferredWidth = 0; page.detailPreferredWidth = 0;
page.beginResize(false); page.resizeHistory(80);
assert.equal(page.workbench().historyWidth, 360);
page.endResize(false); assert.equal(page.historyPreferredWidth, 360);
page.beginResize(false); page.resizeHistory(-2000); page.endResize(false);
assert.equal(page.workbench().historyWidth, 264);
page.historyPreferredWidth = 0; page.windowWidth = 1020;
page.beginResize(false); page.resizeHistory(400); page.endResize(false);
assert.equal(page.workbench().expanded, true, 'A drag stops before it would collapse the column');
assert.equal(page.workbench().historyWidth, 280);
assert.equal(page.workbench().detailWidth, 300);
assert.equal(page.workbench().chatWidth, 440);
page.windowWidth = 1600;
page.beginResize(true); page.resizeDetail(-2000);
assert.equal(page.workbench().detailWidth, page.workbench().detailMaxWidth);
assert.equal(page.workbench().chatWidth, 440);
page.endResize(true); assert.equal(page.detailPreferredWidth, page.workbench().detailWidth);
page.beginResize(true); page.resizeDetail(2000); page.endResize(true);
assert.equal(page.workbench().detailWidth, 300);
page.historyCollapsed = true;
assert.equal(page.workbench().rail, true, 'Collapsing keeps the sheet state intact');
console.log('PASS rail state, drag clamps and committed widths keep the chat and detail minima');

// A narrow overlay defaults to the center of Stack; anchor the real emitted sidebar at the window origin.
const drawerAttributes = {};
const ui = new Proxy({}, { get: (_, name) => value => { drawerAttributes[name] = value; } });
const gesture = new Proxy({}, { get: () => () => {} });
const Drawer = probe('pages/Index', 'Index', ['drawer'], { Stack: ui, Column: gesture,
  Gesture: gesture, PanGesture: gesture, GesturePriority: {}, PanDirection: {}, HitTestMode: {}, Alignment: {} });
let first = true;
Object.assign(new Drawer(), { workbench: () => new WorkbenchLayout(1440, true),
  observeComponentCreation2(callback) { if (first) { first = false; callback(1, true); } } }).drawer();
assert.equal(drawerAttributes.width, 280); assert.equal(drawerAttributes.position.x, 0); assert.equal(drawerAttributes.position.y, 0);
console.log('PASS emitted sidebar is anchored at the window origin rather than centered over chat');
// With a rail host the drawer becomes an overlay again: full-width scrim host,
// an 84% panel and no persistent right edge.
let railFirst = true;
Object.assign(new Drawer(), { workbench: () => new WorkbenchLayout(900, true),
  observeComponentCreation2(callback) { if (railFirst) { railFirst = false; callback(1, true); } } }).drawer();
assert.equal(drawerAttributes.width, '100%');
console.log('PASS emitted drawer falls back to the overlay host beside the rail');

// Rail composition: the six desktop actions, in top-to-bottom order, each wired
// to the callback the page handed to the rail.
const railProps = [];
class RailButtonStub { constructor(parent, params) { this.params = params; railProps.push(params); } }
const railUi = new Proxy({}, { get: () => () => {} });
const railGlobals = {
  Stack: railUi, Column: railUi, Blank: railUi, Button: railUi, SymbolGlyph: railUi,
  ViewPU: { create() {} }, ViewStackProcessor: { visualState() {} }, HorizontalAlign: { Center: 0 },
  SafeAreaType: { SYSTEM: 0 }, SafeAreaEdge: { TOP: 0, BOTTOM: 1 }, HitTestMode: { None: 0 },
  Color: { Transparent: 0 }, ButtonType: { Normal: 0 }, t: value => value, $r: value => value,
  RailButton: RailButtonStub
};
const Rail = probe('views/HistoryRail', 'HistoryRail', ['initialRender'], railGlobals);
const actions = [];
const rail = Object.assign(new Rail(), {
  appearance: { accentContainer: 1, accent: 2 }, active: true, filesActive: true,
  onExpand: () => actions.push('expand'), onNewChat: () => actions.push('new'), onSearch: () => actions.push('search'),
  onFiles: () => actions.push('files'), onTools: () => actions.push('tools'), onSettings: () => actions.push('settings'),
  observeComponentCreation2(callback) { callback(1, true); }
});
rail.initialRender();
assert.deepEqual(railProps.map((button) => button.compId), ['workbench-rail-expand', 'workbench-rail-new-chat',
  'workbench-rail-search', 'workbench-rail-files', 'workbench-rail-tools', 'workbench-rail-settings']);
for (const button of railProps) { button.onTap(); }
assert.deepEqual(actions, ['expand', 'new', 'search', 'files', 'tools', 'settings']);
assert.equal(railProps[3].active, true, 'The open files pane marks its rail control');
assert.equal(railProps[0].label, '展开会话列表');
console.log('PASS emitted rail keeps six desktop actions in order and forwards each tap');

// The workbench model seat opens a compact card above the composer instead of
// navigating away from the conversation, and sizes that card to the catalog.
const chatSourcePath = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
assert.ok(fs.statSync(chatSourcePath).mtimeMs >= fs.statSync(path.join(root, 'entry/src/main/ets/views/ChatPanel.ets')).mtimeMs,
  'Build before testing ChatPanel');
const chatSource = fs.readFileSync(chatSourcePath, 'utf8');
const triggerAt = chatSource.indexOf("Button.id('workbench-model-picker')");
assert.ok(triggerAt > 0, 'Locate the emitted composer model trigger');
const triggerSource = chatSource.slice(triggerAt, triggerAt + 2400);
assert.match(triggerSource, /this\.showModelMenu = !this\.showModelMenu;/, 'The model trigger toggles the menu');
assert.match(triggerSource, /Button\.bindPopup\(this\.showModelMenu, \{ builder: \{ builder: this\.modelMenu\.bind\(this\) \}/,
  'The model trigger owns the menu popup');
const menuAt = chatSource.indexOf('modelMenu(parent = null)');
assert.ok(menuAt > 0, 'Locate the emitted model menu builder');
assert.match(chatSource.slice(menuAt, menuAt + 1600), /ModelPickerPanel\(this, \{ app: this\.app, compact: true/,
  'The popup reuses the searchable model list in compact mode');
assert.match(chatSource.slice(menuAt, menuAt + 1600), /this\.modelMenuHeight\(\)/, 'The card height follows the catalog');
assert.match(chatSource, /modelMenuHeight\(\): number \{/, 'The catalog-sized height is computed once');
console.log('PASS emitted composer model seat opens one compact, catalog-sized model menu');

const dialogs = [], toasts = [];
const Editor = probe('views/WorkspacePanel', 'WorkspacePanel', ['dirty', 'fileName', 'leave', 'requestClose', 'backRequested', 'openRequested', 'reference'], { t: value => value, $r: value => value });
let closed = 0, rebound = 0;
const editor = Object.assign(new Editor(), { embedded: true, busy: false, editing: true, previewing: true,
  content: 'unsaved edit', original: 'original', selected: 'note.md', directory: '', ownerWorkspaceId: 'project-one',
  app: { activeWorkspaceId: 'project-two', active: { draft: 'keep' }, setDraft() { throw Error('Cross-workspace reference'); } },
  onClose() { closed++; }, bindWorkspace() { rebound++; }, toast: text => toasts.push(text),
  getUIContext: () => ({ showAlertDialog: dialog => dialogs.push(dialog) }), appearance: {} });
editor.requestClose(); assert.equal(closed, 0); assert.equal(dialogs.length, 1);
dialogs.at(-1).primaryButton.action(); assert.equal(editor.content, 'unsaved edit'); assert.equal(closed, 0);
editor.openRequested(); assert.equal(rebound, 0);
dialogs.at(-1).secondaryButton.action(); assert.equal(rebound, 1);
editor.requestClose(); dialogs.at(-1).secondaryButton.action(); assert.equal(closed, 1);
editor.reference(); assert.equal(editor.app.active.draft, 'keep'); assert.equal(toasts.length, 1);
editor.busy = true; editor.requestClose(); assert.equal(closed, 1);
console.log('PASS unsaved editor requires explicit discard, cancel retains content, cross-workspace reference is rejected');

const { tree, cls } = emitted('views/PreviewPanel', 'PreviewPanel');
let handler;
function visit(node) {
  if (ts.isPropertyAssignment(node) && node.name.getText(tree) === 'onInteract' && node.initializer.getText(tree).includes('this.app.interactUi')) handler = node.initializer.getText(tree);
  ts.forEachChild(node, visit);
}
visit(cls); assert.ok(handler, 'Locate the actual side-preview interaction handler');
const previewExports = {};
vm.runInNewContext(ts.transpileModule('exports.bind = function() { return (' + handler + '); };', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: previewExports });
let interaction;
const preview = { threadId: 'owner-thread', messageId: 'owner-message', app: { active: { id: 'different-thread' },
  interactUi(...args) { interaction = args; } } };
previewExports.bind.call(preview)('surface', { count: 2 }, 'save');
assert.equal(interaction[0], 'owner-thread'); assert.equal(interaction[1], 'owner-message');
assert.equal(interaction[2], 'surface'); assert.equal(interaction[3].count, 2);
console.log('PASS emitted side-preview interactions keep original conversation, message and surface identity');
// Run the actual emitted card render branches: an inspected preview has only one live surface.
let surfaces = 0, clicked, label;
const noopUi = new Proxy({}, { get: () => () => {} });
const cardGlobals = { Column: noopUi, If: new Proxy({}, { get: (_, name) => name === 'canRetake' ? () => false : () => {} }),
  Button: new Proxy({}, { get: (_, name) => name === 'onClick' ? callback => { clicked = callback; } :
    name === 'createWithLabel' ? value => { label = value; } : () => {} }),
  Btn: {}, Space: {}, HorizontalAlign: {}, t: value => value, ViewPU: { create() {} },
  InteractiveAnswer: class { constructor() { surfaces++; } } };
const Card = probe('views/PublishedPreviewCard', 'PublishedPreviewCard', ['initialRender'], cardGlobals);
const card = Object.assign(new Card(), { inspectable: true, inspected: false, expanded: true,
  preview: { id: 'preview', path: 'demo.html', content: 'demo', superseded: false },
  onInspect() { this.inspected = true; },
  observeComponentCreation2(callback) { callback(1, true); }, ifElseBranchUpdateFunction(_branch, render) { render(); } });
card.initialRender(); assert.equal(surfaces, 1); assert.equal(label, '在侧区打开');
clicked.call(card); surfaces = 0; card.initialRender(); assert.equal(surfaces, 0); assert.equal(label, '在侧区查看');
card.inspected = false; card.initialRender(); assert.equal(surfaces, 1);
console.log('PASS emitted preview card detaches the inline surface while inspected and restores it on close');

card.inline = true; card.expanded = false;
surfaces = 0; card.initialRender(); assert.equal(surfaces, 1);
clicked.call(card); surfaces = 0; card.initialRender(); assert.equal(surfaces, 0);
card.inspected = false; card.initialRender(); assert.equal(surfaces, 1);
console.log('PASS final-answer inline preview transfers its live surface to the side panel and restores it on close');

// Exercise the emitted final-answer card arguments, including the real inspect callback.
const bubble = emitted('views/MessageBubble', 'MessageBubble');
let inlineArguments;
function findInlineCard(node) {
  if (ts.isNewExpression(node) && node.expression.getText(bubble.tree) === 'PublishedPreviewCard') {
    const args = node.arguments?.[1];
    if (args && ts.isObjectLiteralExpression(args) && args.properties.some(p => p.name?.getText(bubble.tree) === 'inline')) {
      inlineArguments = args.getText(bubble.tree);
    }
  }
  ts.forEachChild(node, findInlineCard);
}
findInlineCard(bubble.cls); assert.ok(inlineArguments, 'Locate the actual final-answer preview card');
const inlineExports = {};
vm.runInNewContext(ts.transpileModule('exports.bind = function(entry, partIndex) { return (' + inlineArguments + '); };', {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: inlineExports });
let inspectedTarget;
const inlineBubble = { message: { id: 'answer' }, previewInspectable: true, inspectedPreviewId: 'final-preview',
  answerParts: () => [{ preview: { id: 'final-preview' } }], onInspectPreview: (...args) => { inspectedTarget = args; } };
const inlineProps = inlineExports.bind.call(inlineBubble, { step: 0 }, 0);
assert.equal(inlineProps.inline, true); assert.equal(inlineProps.inspectable, true); assert.equal(inlineProps.inspected, true);
inlineProps.onInspect(); assert.deepEqual(inspectedTarget, ['answer', 'final-preview']);
console.log('PASS emitted final-answer preview wires side-panel availability, active identity and inspect action');


// Use the real session/runtime and a gated streaming provider, without any network or credentials.
const modules = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (modules.has(file)) return modules.get(file);
  const exports = {}; modules.set(file, exports);
  let content = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) content += '\nexport { Fixture, seed };';
  vm.runInNewContext(ts.transpileModule(content, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
  } }).outputText, { exports, Observed: cls => cls, setTimeout, clearTimeout, console, require: id => {
    if (id === '@ohos/hypium') return {};
    if (!id.startsWith('.')) throw Error('Unexpected dependency ' + id);
    return load(path.resolve(path.dirname(file), id));
  } }, { filename: file });
  return exports;
}
(async () => {
  const { Fixture } = load(path.join(root, 'entry/src/test/SessionService.test'));
  const { ChatViewModel } = load(path.join(root, 'entry/src/main/ets/viewmodel/ChatViewModel'));
  const { stepPreviews } = load(path.join(root, 'entry/src/main/ets/model/PublishedPreview'));
  const SidePreview = probe('views/PreviewPanel', 'PreviewPanel', ['message', 'previews'], { stepPreviews });
  const publishedStep = { content: '', tools: [{ status: 'complete', call: { id: 'publish', function: { name: 'publish_preview' } },
    output: JSON.stringify({ path: 'demo.html', title: 'Demo', previewId: 'pv_final', reference: '[[tinybot-preview:pv_final]]' }),
    previewContent: 'published snapshot' }] };
  const side = Object.assign(new SidePreview(), { messageId: 'answer', previewId: 'answer:publish',
    app: { active: { messages: [{ id: 'answer', stepViews: [publishedStep] }], latestPreviewIds: ['answer:publish'] } } });
  assert.equal(stepPreviews('answer', publishedStep, 0, []).length, 0, 'Referenced previews stay out of legacy cards');
  assert.equal(side.previews().length, 1); assert.equal(side.previews()[0].content, 'published snapshot');
  side.previewId = 'foreign-preview'; assert.equal(side.previews().length, 0);
  console.log('PASS emitted side panel resolves final-answer snapshots while excluding unrelated previews');
  const fixture = new Fixture(), app = new ChatViewModel();
  await app.initialize(fixture.session);
  const Chat = probe('views/ChatPanel', 'ChatPanel', ['centeredWelcome', 'composerExpanded']);
  const chat = Object.assign(new Chat(), { app, thread: app.active, workbench: true, panelHeight: 800,
    viewport: { keyboardHeight: 0 }, voiceMode: false, composerFocused: false, importing: false,
    showPlus: false, showContext: false, showReasoning: false, showQueue: false,
    hasDraft: () => app.draft.length > 0, speechActive: () => false, voiceOverlayVisible: () => false });
  assert.equal(chat.centeredWelcome(), true); assert.equal(chat.composerExpanded(), true);
  chat.workbench = false;
  assert.equal(chat.centeredWelcome(), false); assert.equal(chat.composerExpanded(), false, 'Phone retains its compact idle composer');
  chat.workbench = true; app.setDraft('typed without moving the editor');
  assert.equal(chat.centeredWelcome(), true, 'Typing alone must not move the tablet editor');
  chat.viewport.keyboardHeight = 600; assert.equal(chat.centeredWelcome(), false, 'Dock above the soft keyboard');
  chat.viewport.keyboardHeight = 0; chat.panelHeight = 400; assert.equal(chat.centeredWelcome(), false, 'Short windows remain usable');
  chat.panelHeight = 800; assert.equal(chat.centeredWelcome(), true);
  chat.voiceMode = true; assert.equal(chat.centeredWelcome(), false, 'Voice mode docks before hold starts so recording cannot move its target');
  chat.voiceMode = false; assert.equal(chat.centeredWelcome(), true);

  let started, finish, calls = 0;
  const streaming = new Promise(resolve => { started = resolve; });
  const hold = new Promise(resolve => { finish = resolve; });
  fixture.provider.stream = async (_request, cancellation, onText) => {
    calls++; onText('first'); started(); await hold; cancellation.check();
    onText('first second'); return { content: 'first second', toolCalls: [] };
  };
  app.setDraft('window resize during answer');
  const sending = app.send(() => {}); await streaming;
  chat.thread = app.active; assert.equal(chat.centeredWelcome(), false, 'The first actual turn docks the same composer');
  app.setDraft('unsent follow-up');
  const runningPage = Object.assign(new Page(), page, { app, session: fixture.session });
  const threadId = app.active.id, answerId = app.active.messages.at(-1).id;
  for (const width of [1440, 960, 500, 840, 1200, 400, 1440]) {
    runningPage.windowChanged(width);
    assert.equal(app.busy, true, 'Resizing must not stop the real runtime');
    assert.equal(app.active.id, threadId); assert.equal(app.active.messages.at(-1).id, answerId);
    assert.equal(app.active.draft, 'unsent follow-up'); assert.equal(calls, 1);
  }
  finish(); await sending; await app.flushDraft();
  assert.equal(app.busy, false); assert.equal(app.active.messages.at(-1).content, 'first second');
  const restored = await fixture.repository.load();
  assert.equal(restored.threads[0].draft, 'unsent follow-up');
  assert.equal(restored.threads[0].messages.at(-1).status, 'complete');
  console.log('PASS native welcome/composer behavior with real session: typing, keyboard, short windows, first turn, streaming and saved drafts');
})().catch(error => { console.error(error); process.exitCode = 1; });
