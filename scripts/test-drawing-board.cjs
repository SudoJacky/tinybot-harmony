// Run after devecocli build. Exercise the emitted Pen Kit integration and attachment flow.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..'), source = path.join(root, 'entry/src/main/ets');
const compile = text => ts.transpileModule(text, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
} }).outputText;
const draftScope = { exports: {}, Observed: value => value };
vm.runInNewContext(compile(fs.readFileSync(path.join(source, 'model/DrawingDraft.ets'), 'utf8')), draftScope);
const { DrawingDraft } = draftScope.exports;
function emitted(name) {
  const file = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views', name + '.ts');
  assert.ok(fs.statSync(file).mtimeMs >= fs.statSync(path.join(source, 'views', name + '.ets')).mtimeMs, 'Rebuild ' + name);
  return fs.readFileSync(file, 'utf8');
}
let serial = 0, current, dialog, thumbnail, supported = true, controllers = 0;
const nodes = new Map();
class Property { constructor(value) { this.value = value; } get() { return this.value; } set(value) { this.value = value; } }
class ViewPU {
  constructor(parent, storage, id) { this.parent = parent; this.id = id; this.effects = new Map(); this.children = new Map(); }
  finalizeConstruction() {}
  createStorageProp() { return new Property({ fontFamily: '' }); }
  observeComponentCreation2(callback) { const id = ++serial; this.effects.set(id, callback); this.currentElmt = id; current = this; callback(id, true); }
  ifElseBranchUpdateFunction(branch, create) { create(); }
  updateStateVarsOfChildByElmtId(id, params) { Object.assign(this.children.get(id), params); }
  static create(child) { child.parent.children.set(child.id, child); }
  flush() { for (const [id, effect] of [...this.effects]) { this.currentElmt = id; current = this; effect(id, false); } }
  getUIContext() { return { getHostContext: () => ({ cacheDir: '/cache' }), showAlertDialog: options => { dialog = options; } }; }
}
class Child extends ViewPU { constructor(parent, params, storage, id) { super(parent, storage, id); Object.assign(this, params); } }
class Controller {
  constructor() { controllers++; this.range = { left: 0, top: 0, right: 0, bottom: 0 }; }
  onLoad(callback) { this.loaded = callback; }
  load(path) { this.path = path; }
  getContentRange() { return this.range; }
  getThumbnail(range) { return thumbnail(range); }
}
const ui = kind => new Proxy({}, { get: (_, name) => value => {
  const key = current.currentElmt; const node = nodes.get(key) || { kind }; nodes.set(key, node);
  if (['id', 'onClick', 'enabled'].includes(name)) node[name] = value;
  if (kind === 'Navigation' && name === 'title' && !node.titleBuilder) {
    node.titleBuilder = value.builder; value.builder();
  }
} });
// API 26 hides two brushes through HiddenConfig; API 20 has neither the type nor the option.
let drawingTools = true;
let hiddenToolType = { MOSAIC: 7, LASER: 3145728 };
const globals = { exports: {}, ViewPU, SynchedPropertyNesedObjectPU: Property, ObservedPropertySimplePU: Property,
  wrapBuilder: builder => ({ builder }),
  canIUse: () => supported, TextAlign: {}, FontWeight: {}, SafeAreaType: {}, SafeAreaEdge: {},
  NavPathStack: class {}, BarStyle: {}, Color: {}, NavigationTitleMode: {}, NavigationMode: {},
  require: id => {
    if (id.includes('HandwritePaint')) return { HandwriteComponent: Child, HandwriteController: Controller, PenType: { BALLPOINT_PEN: 2 }, HiddenToolType: hiddenToolType };
    if (id.includes('ApiLevel&')) return { ApiLevel: { get drawingTools() { return drawingTools; } } };
    if (id.includes('MaterialAttributes&')) return { systemMaterialAttribute: () => ({}), menuMaterialAttribute: () => ({}) };
    if (id === '@ohos:util') return { default: { generateRandomUUID: () => 'unique' } };
    if (id.includes('I18n&')) return { t: value => value };
    if (id.includes('Theme&')) return { Btn: {}, Font: {}, Radius: {}, Motion: {}, Space: {}, systemInsets: async () => [36, 24] };
    if (id.includes('Widgets&')) return { IconButton: Child };
    if (id.includes('AppearanceStyle&')) return { AppearanceStyle: class {} };
    throw Error('Unexpected import: ' + id);
  } };
for (const kind of ['Navigation', 'Column', 'Row', 'Text', 'Button', 'If', 'Stack', 'Blank', 'SymbolGlyph']) globals[kind] = ui(kind);
vm.runInNewContext(compile(emitted('DrawingBoard')), globals);
const draft = new DrawingDraft();
const board = new globals.exports.DrawingBoard(undefined, { draft }); board.aboutToAppear(); board.initialRender();
const node = id => [...nodes.values()].find(value => value.id === id);

(async () => {
  assert.equal(node('drawing-add').enabled, false, 'Export waits for native loading');
  const native = [...board.children.values()].find(value => value.handwriteController);
  assert.equal(native.handwriteController, board.controller); assert.equal(native.defaultPenType, 2);
  assert.ok(native.hiddenTools, 'API 26 receives the hidden-tool configuration');
  assert.deepEqual([...native.hiddenTools.hiddenOptionalTools], [7, 3145728], 'API 26 hides mosaic and laser');
  native.onInit(); assert.equal(board.controller.path, '/cache/drawing-unique');
  board.controller.loaded({ code: 0, message: 'load success' }); board.flush();
  assert.equal(node('drawing-add').enabled, true); assert.equal(draft.dirty(), false);
  await board.add(); assert.match(board.error, /请先在画板上绘制内容/); assert.equal(draft.saving, false);
  board.controller.range = { left: 20, top: 10, right: 800, bottom: 900 }; assert.equal(draft.dirty(), true);
  let released = 0, attached = 0, captured = 0;
  const pixel = { release: async () => { released++; } };
  thumbnail = async range => { captured++; assert.equal(range, board.controller.range); return pixel; };
  board.onAdd = async () => { throw Error('disk full'); };
  await board.add(); assert.equal(board.error, 'disk full'); assert.equal(draft.dirty(), true);
  assert.equal(draft.saving, false); assert.equal(released, 1);
  let finish;
  board.onAdd = () => new Promise(resolve => { attached++; finish = resolve; });
  const pending = board.add(); await Promise.resolve(); board.flush();
  assert.equal(node('drawing-add').enabled, false);
  assert.equal([...board.children.values()].find(value => value.compId === 'drawing-cancel').disabled, true);
  await board.add(); assert.equal(attached, 1); finish(); await pending;
  assert.equal(released, 2); assert.equal(captured, 2); assert.equal(draft.saving, false);
  thumbnail = async () => { throw Error('native export failed'); }; await board.add();
  assert.equal(board.error, 'native export failed'); assert.equal(draft.saving, false);
  console.log('PASS native Pen Kit initialization, content range, blank validation, ink-only export, errors, pixel release and duplicate-save protection');

  supported = false;
  const beforeControllers = controllers;
  const unsupported = new globals.exports.DrawingBoard(undefined, { draft: new DrawingDraft() });
  unsupported.aboutToAppear(); unsupported.initialRender();
  assert.equal(controllers, beforeControllers, 'Unsupported devices must not instantiate the unavailable Pen Kit controller');
  assert.equal(unsupported.controller, undefined); assert.equal(unsupported.draft.dirty(), false);
  assert.equal([...unsupported.children.values()].some(value => value.handwriteController), false);
  await unsupported.add(); assert.equal(unsupported.draft.saving, false);
  supported = true;
  console.log('PASS unsupported drawing screen avoids native initialization and keeps export disabled');

  // API 20 has no HiddenToolType/HiddenConfig. Reading either value there is the failure this
  // guards against, so the enum itself becomes unreadable while the low-version board is built.
  drawingTools = false;
  hiddenToolType = new Proxy({}, { get(_target, property) {
    throw Error('HiddenToolType.' + String(property) + ' must never be read on API 20');
  } });
  const lowBoard = new globals.exports.DrawingBoard(undefined, { draft: new DrawingDraft() });
  lowBoard.aboutToAppear(); lowBoard.initialRender();
  const lowNative = [...lowBoard.children.values()].find(value => value.handwriteController);
  assert.ok(lowNative, 'The canvas itself stays available on API 20');
  assert.equal(lowNative.hiddenTools, undefined, 'API 20 keeps the stock brush toolbar');
  assert.equal(lowNative.defaultPenType, 2);
  drawingTools = true;
  hiddenToolType = { MOSAIC: 7, LASER: 3145728 };
  console.log('PASS API 20 drawing board keeps the canvas and stock toolbar without reading HiddenToolType');

  // Exercise the actual composer integration, including the async disk-write boundary.
  const tree = ts.createSourceFile('ChatPanel.ts', emitted('ChatPanel'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(value => ts.isClassDeclaration(value) && value.name.text === 'ChatPanel');
  // Replay the compiled overlay bindings with the device's same-node dismissal behavior.
  // A closed sheet bound to the cover's node immediately removes that cover on API 26.
  const initialRender = component.members.find(value => value.name?.getText(tree) === 'initialRender');
  const bindings = initialRender.body.statements.filter(value => {
    const text = value.getText(tree);
    return text.includes('bindContentCover') || (text.includes('bindSheet') && text.includes('showMemoryDraft'));
  }).map(value => value.getText(tree)).join('\n');
  let owner = 0, modal;
  const overlayUi = new Proxy({}, { get: (_, name) => (...args) => {
    if (name === 'bindContentCover') {
      const visible = typeof args[0] === 'boolean' ? args[0] : args[0].value;
      if (visible) modal = { owner, options: args[2] };
      else if (modal?.owner === owner) modal = undefined;
    }
    if (name === 'bindSheet' && !args[0].value && modal?.owner === owner) modal = undefined;
  } });
  const overlayScope = { exports: {}, Stack: overlayUi, Column: overlayUi, ModalTransition: {}, SheetSize: {}, SheetKeyboardAvoidMode: {}, t: value => value };
  vm.runInNewContext(compile(`exports.bind = function() { ${bindings} };`), overlayScope);
  const overlay = { showDrawing: true, previewing: false, showMemoryDraft: false, closeDrawing() { this.closed = true; },
    observeComponentCreation2(callback) { callback(++owner, false); } };
  const renderOverlay = () => { owner = 0; overlayScope.exports.bind.call(overlay); };
  renderOverlay(); assert.ok(modal, 'Closed memory sheet must not remove the drawing cover');
  renderOverlay(); assert.ok(modal, 'A state update must keep the drawing open');
  modal.options.onWillDismiss(); assert.equal(overlay.closed, true, 'System back uses the discard confirmation');
  overlay.showDrawing = false; overlay.previewing = true; renderOverlay(); assert.ok(modal, 'Image preview owns the independent cover too');
  modal.options.onWillDismiss(); assert.equal(overlay.previewing, false); renderOverlay(); assert.equal(modal, undefined);
  console.log('PASS compiled drawing and preview overlays survive closed-sheet bindings and preserve controlled dismissal');
  const names = ['canAttach', 'openDrawing', 'closeDrawing', 'addDrawing'];
  const methods = names.map(name => component.members.find(value => value.name?.getText(tree) === name).getText(tree)).join('\n');
  let boardLoads = 0;
  const scope = { exports: {}, DrawingDraft, MAX_MESSAGE_ATTACHMENTS: 10, Attachments: {}, canIUse: () => supported, deviceInfo: { productModel: 'phone' },
    require: id => { assert.ok(id.includes('DrawingBoard')); boardLoads++; return { drawingBoardBuilder: { builder() {} } }; }, t: value => value };
  vm.runInNewContext(compile(`class Composer { ${methods} } exports.Composer = Composer;`), scope);
  const composer = new scope.exports.Composer();
  let additions = 0, writes = 0, finishWrite;
  const image = { id: 'drawing', mime: 'image/jpeg', path: 'drawing.jpg', size: 100, name: 'Sketch.jpg' };
  Object.assign(composer, { thread: { id: 'chat', attachments: [], archived: false }, appearance: {}, importing: false,
    speechActive: () => false, getUIContext: () => ({ getFocusController: () => ({ clearFocus() {} }), showAlertDialog: value => { dialog = value; } }),
    app: { active: { id: 'chat' }, busy: false, saveError: '', error: '', setAttachments: async items => { additions++; composer.thread.attachments = items; return true; } } });
  scope.Attachments.saveDrawing = async () => { writes++; return image; };
  supported = false; await composer.openDrawing(); assert.equal(boardLoads, 0);
  assert.match(composer.app.error, /此设备不支持系统手写画板/); assert.ok(!composer.showDrawing);
  supported = true; scope.deviceInfo.productModel = 'emulator'; await composer.openDrawing();
  assert.equal(boardLoads, 0, 'Emulators may report the syscap while lacking the system Pen Kit HSP');
  scope.deviceInfo.productModel = 'phone';
  supported = true; composer.app.error = '';
  await composer.openDrawing(); assert.equal(composer.showDrawing, true); composer.closeDrawing(); assert.equal(composer.showDrawing, false);
  await composer.openDrawing(); composer.drawingDraft.hasContent = () => true;
  composer.closeDrawing(); dialog.primaryButton.action(); assert.equal(composer.showDrawing, true);
  composer.drawingDraft.saving = true; composer.closeDrawing(); assert.equal(composer.showDrawing, true); composer.drawingDraft.saving = false;
  await composer.addDrawing(pixel); assert.equal(composer.showDrawing, false); assert.equal(additions, 1);
  assert.equal(composer.thread.attachments[0], image); assert.equal(composer.importing, false);
  await composer.openDrawing(); composer.app.setAttachments = async () => false; composer.app.error = 'persist failed';
  await assert.rejects(composer.addDrawing(pixel), /persist failed/); assert.equal(composer.showDrawing, true); assert.equal(composer.importing, false);
  composer.app.active.id = 'other'; const before = writes;
  await assert.rejects(composer.addDrawing(pixel), /对话已切换/); assert.equal(writes, before);
  composer.app.active.id = 'chat'; scope.Attachments.saveDrawing = () => new Promise(resolve => { finishWrite = resolve; });
  const switched = composer.addDrawing(pixel); composer.app.active.id = 'other'; finishWrite(image);
  await assert.rejects(switched, /对话已切换/); assert.equal(additions, 1); assert.equal(composer.importing, false);
  composer.app.active.id = 'chat'; composer.thread.attachments = Array(9).fill(image);
  scope.Attachments.saveDrawing = async () => image;
  composer.app.setAttachments = async items => { composer.thread.attachments = items; return true; };
  await composer.addDrawing(pixel); assert.equal(composer.thread.attachments.length, 10);
  await assert.rejects(composer.addDrawing(pixel), /当前无法添加附件/);
  composer.showDrawing = false; await composer.openDrawing(); assert.equal(composer.showDrawing, false);
  composer.thread.attachments = [];
  let finishLoad, pendingLoads = 0;
  scope.require = () => { pendingLoads++; return new Promise(resolve => { finishLoad = resolve; }); };
  const opening = composer.openDrawing(); await Promise.resolve();
  await composer.openDrawing(); assert.equal(pendingLoads, 1, 'Repeated taps must not load multiple drawing screens');
  composer.thread.id = 'switched-during-load'; finishLoad({ drawingBoardBuilder: { builder() {} } }); await opening;
  assert.equal(composer.showDrawing, false, 'A delayed module must not open over a different chat');
  assert.equal(composer.drawingOpening, false);
  composer.thread.id = 'chat'; scope.require = () => { throw Error('drawing module failed'); };
  await composer.openDrawing(); assert.equal(composer.app.error, 'drawing module failed'); assert.equal(composer.drawingOpening, false);
  console.log('PASS composer attaches without sending, confirms discard, reports persistence failure and isolates switched/full conversations');
})().catch(error => { console.error(error); process.exitCode = 1; });
