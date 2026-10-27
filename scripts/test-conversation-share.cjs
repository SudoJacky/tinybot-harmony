// Run after a Debug build: exercise actual emitted handlers at the native I/O seam.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { TextEncoder } = require('node:util');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const t = (s, values = []) => s.replace(/\{(\d+)\}/g, (_, n) => values[+n]);
const cache = new Map();
function load(name) {
  if (name === 'I18n') return { t };
  if (cache.has(name)) return cache.get(name);
  const exports = {}; cache.set(name, exports);
  const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/model', name + '.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText,
    { exports, require: id => load(path.posix.normalize(path.posix.join(path.posix.dirname(name), id))),
      Observed: cls => cls, Uint8Array, ArrayBuffer, DataView });
  return exports;
}
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ConversationSharePanel.ts');
const source = path.join(root, 'entry/src/main/ets/views/ConversationSharePanel.ets');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build ConversationSharePanel before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ConversationSharePanel');
const names = ['aboutToAppear', 'aboutToDisappear', 'removeTemporary', 'ensureActive', 'select', 'selectAll', 'context',
  'generateImage', 'reselect', 'outputImage', 'outputMarkdown'];
const methods = names.map(name => component.members.find(node => node.name?.getText(tree) === name).getText(tree)).join('\n');
const files = new Map(), outputs = [], privacy = { allowed: true };
let imageCalls = 0, resolveImage, deferImage = false, failOutput = false;
const globals = { exports: {}, console, t, $r: () => ({ id: 1 }), hostedPrivacy: privacy,
  ...load('ConversationShare'), ...load('ConversationExport'), ...load('ExportMetadata'),
  fs: { access: async p => files.has(p), unlink: async p => files.delete(p) },
  util: { generateRandomUUID: () => 'test', TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } },
  writeBytes: async (p, bytes) => files.set(p, Buffer.from(bytes)),
  image: { createImageSource: () => ({ getImageInfo: async () => ({ size: { width: 720, height: 1440 } }), release: async () => {} }) },
  conversationImage: async (_ctx, sections) => {
    imageCalls++;
    if (deferImage) await new Promise(resolve => { resolveImage = resolve; });
    files.set('preview.png', sections.map(s => s.text).join('\n')); return 'preview.png';
  },
  exportFile: async (_ctx, p, name) => { if (failOutput) throw Error('disk full'); outputs.push({ kind: 'save', name, value: files.get(p) }); },
  shareFile: async (_ctx, p, name) => { outputs.push({ kind: 'share', name, value: files.get(p) }); }
};
vm.runInNewContext(ts.transpileModule(`class Probe { ${methods} } exports.Probe = Probe;`, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals);
function panel() {
  const view = new globals.exports.Probe();
  Object.assign(view, { data: { thread: { title: 'Selected', messages: [
    { id: 'u', role: 'user', content: 'SECRET omitted user text' },
    { id: 'a', role: 'assistant', content: 'Included answer' }
  ] }, profiles: [] }, busy: false, error: '', previewPath: '', selectedIds: [] });
  view.getUIContext = () => ({ getHostContext: () => ({ cacheDir: 'cache', resourceManager: { getColorSync: () => 0 } }) });
  view.aboutToAppear(); return view;
}
(async () => {
  const view = panel(); view.select('u', false);
  assert.equal(view.selectedIds.join(), 'a', 'deselecting one retains the other');
  await view.generateImage();
  assert.equal(view.previewPath, 'preview.png'); assert.equal(view.previewRatio, .5);
  assert.equal(outputs.length, 0, 'generation previews without a save/share sheet');
  assert.ok(!files.get(view.previewPath).includes('SECRET'));
  await view.outputImage(false); await view.outputImage(true);
  assert.equal(outputs.map(o => o.kind).join(), 'save,share');
  assert.equal(outputs[0].value, outputs[1].value, 'both actions use preview bytes');
  assert.ok(files.has(view.previewPath));
  failOutput = true; await view.outputImage(false); failOutput = false;
  assert.equal(view.error, 'disk full'); assert.equal(view.busy, false); assert.ok(files.has(view.previewPath));
  await view.reselect(); assert.ok(!files.has('preview.png'));
  await view.outputMarkdown(false); await view.outputMarkdown(true);
  for (const output of outputs.slice(2)) {
    assert.ok(output.name.endsWith('.md'));
    const text = output.value.toString();
    assert.ok(text.includes('Included answer') && !text.includes('SECRET'));
    assert.ok(text.includes('tinybot-export-aigc') && text.includes('AI生成内容可能有误'));
  }
  assert.equal(files.size, 0, 'temporary Markdown removed');
  view.selectAll(); assert.equal(view.selectedIds.length, 2);
  view.selectAll(); assert.equal(view.selectedIds.length, 0);
  const count = imageCalls; await view.generateImage(); assert.equal(imageCalls, count);
  view.selectAll(); deferImage = true;
  const work = view.generateImage(); await view.generateImage();
  assert.equal(imageCalls, count + 1, 'duplicate taps cannot start a second render');
  view.aboutToDisappear(); resolveImage(); await work;
  assert.equal(files.size, 0, 'leaving during rendering removes late output');
  assert.equal(view.previewPath, ''); deferImage = false;
  const revoked = panel(); privacy.allowed = false; await revoked.outputMarkdown(true);
  assert.equal(revoked.error, '分享已取消'); assert.equal(files.size, 0);
  privacy.allowed = true; deferImage = true;
  const pending = revoked.generateImage(); privacy.allowed = false; resolveImage(); await pending;
  assert.equal(files.size, 0, 'revocation during rendering discards output');
  console.log('PASS selection, preview, save/share bytes, Markdown scope, failures, duplicate taps, cleanup and privacy revocation');
})().catch(error => { console.error(error); process.exitCode = 1; });
