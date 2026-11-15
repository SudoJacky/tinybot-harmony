// Run after devecocli build. Replay emitted image properties and native modal ownership.
// This checks the real call sites; it does not simulate native image painting.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const compile = text => ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
function component(name) {
  const relative = 'entry/src/main/ets/views/' + name;
  const source = path.join(root, relative + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug', relative + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Rebuild ' + name);
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const value = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === name);
  return { tree, method: name => value.members.find(node => node.name?.getText(tree) === name) };
}
const bubble = component('MessageBubble'), composer = component('ChatPanel');
const image = { id: 'drawing', name: 'Sketch.jpg', path: 'drawing.jpg', mime: 'image/jpeg' };
const attachmentPath = value => '/attachments/' + value.path;
let painted;
const uiImage = new Proxy({}, { get: (_, property) => value => { painted[property] = value; } });
const scope = { exports: {}, Image: uiImage, ImageFit: { Cover: 'cover', Contain: 'contain' }, Radius: {},
  Attachments: { path: attachmentPath } };
vm.runInNewContext(compile(`exports.preview = function(item) ${bubble.method('preview').body.getText(bubble.tree)};`), scope);
function callbacks(comp, method, matches) {
  const result = [];
  function visit(node) {
    if (ts.isCallExpression(node) && node.expression.getText(comp.tree) === 'this.observeComponentCreation2') {
      const callback = node.arguments[0];
      if (ts.isArrowFunction(callback) && callback.body.statements.some(statement => matches(statement.getText(comp.tree)))) {
        result.push(callback.getText(comp.tree));
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(comp.method(method));
  return result;
}
const imageCallbacks = (comp, method) => callbacks(comp, method, text => text.startsWith('Image.create(') && text.includes('Attachments.path'));
function replay(callback, view) {
  vm.runInNewContext(compile(`exports.render = function(item) { (${callback})(1, true); };`), scope);
  scope.exports.render.call(view, image);
}
const sent = imageCallbacks(bubble, 'userMessage');
assert.ok(sent.length >= 2, 'Exercise single and multiple sent images');
const failures = [];
for (const callback of sent) {
  painted = {};
  const view = { images: () => [image], preview: scope.exports.preview, previewing: false };
  replay(callback, view);
  assert.equal(painted.create, 'file://' + attachmentPath(image));
  painted.onClick();
  assert.equal(view.previewing, true, 'Sent attachment opens the preview');
  assert.equal(view.previewPath, attachmentPath(image));
  if (painted.objectFit !== 'contain') failures.push('Sent attachment crops ink with ' + painted.objectFit);
}
const thumbnails = imageCallbacks(composer, 'attachmentThumbnail');
assert.equal(thumbnails.length, 1, 'Exercise the shared draft thumbnail');
painted = {};
replay(thumbnails[0], {});
assert.equal(painted.create, 'file://' + attachmentPath(image));
assert.equal(painted.objectFit, 'cover', 'Draft thumbnails fill the tile');
Object.assign(scope, { Button: uiImage, ButtonType: {}, Color: {} });
vm.runInNewContext(compile(`exports.previewDraft = function(item) ${composer.method('previewAttachment').body.getText(composer.tree)};`), scope);
for (const method of ['singleAttachment', 'floatingAttachment']) {
  const previews = callbacks(composer, method, text => text.startsWith('Button.onClick(') && text.includes('previewAttachment(item)'));
  assert.equal(previews.length, 1, method + ' has a preview button');
  const view = { previewAttachment: scope.exports.previewDraft, previewing: false };
  painted = {};
  replay(previews[0], view);
  painted.onClick();
  assert.equal(view.previewing, true);
  assert.equal(view.previewPath, attachmentPath(image));
}

// API 26 removes an open cover when a closed sheet binds to the same native node.
const bindings = bubble.method('initialRender').body.statements.filter(node =>
  /bindContentCover|bindSheet/.test(node.getText(bubble.tree))).map(node => node.getText(bubble.tree)).join('\n');
let owner = 0, cover, sheet;
const overlayUi = new Proxy({}, { get: (_, name) => (...args) => {
  const binding = args[0];
  if (name === 'bindContentCover') {
    if (binding.value) cover = { owner, binding };
    else if (cover?.owner === owner) cover = undefined;
  }
  if (name === 'bindSheet') {
    if (!binding.value && cover?.owner === owner) cover = undefined;
    if (binding.value) sheet = { owner, binding };
    else if (sheet?.owner === owner) sheet = undefined;
  }
} });
const overlays = { exports: {}, Radius: { sheet: {} }, Column: overlayUi, ModalTransition: {}, ResponseType: {}, IS_PC: false };
vm.runInNewContext(compile(`exports.bind = function() { ${bindings} };`), overlays);
const view = { previewing: true, documentOpen: false, appearance: {}, actions() {},
  observeComponentCreation2(callback) { callback(++owner, false); } };
const render = () => { owner = 0; overlays.exports.bind.call(view); };
render();
if (!cover) failures.push('closed document sheet dismisses the image preview');
else {
  render(); assert.ok(cover, 'State updates keep the image preview open');
  cover.binding.changeEvent(false); render(); assert.equal(cover, undefined, 'Back dismisses preview');
  view.documentOpen = true; render(); assert.ok(sheet, 'Document preview still opens');
  sheet.binding.changeEvent(false); render(); assert.equal(sheet, undefined, 'Document preview dismisses');
  view.previewing = true; render(); assert.ok(cover, 'Image preview reopens after a document');
}
assert.deepEqual(failures, []);
console.log('PASS full sent images, cropped draft thumbnails, both draft preview buttons and document/image transitions');
