// Run after devecocli build: exercise the emitted file-panel recovery callbacks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = path.resolve('entry/src/main/ets/views/WorkspacePanel.ets');
const emitted = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/WorkspacePanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build WorkspacePanel before testing');
class Property { constructor(value) { this.value = value; } get() { return this.value; } set(v) { this.value = v; } reset(v) { this.value = v; } }
const context = { cacheDir: '/cache' }, cached = new Map(), exportsSeen = [], removed = [], dialogs = [];
class ViewPU {
  finalizeConstruction() {}
  declareWatch() {}
  createStorageProp() { return new Property({}); }
  getUIContext() { return { getHostContext: () => context, getPromptAction: () => ({ showToast() {} }), showAlertDialog: d => dialogs.push(d) }; }
}
const globals = { exports: {}, ViewPU, ArrayBuffer, $r: key => key,
  SynchedPropertyNesedObjectPU: Property, SynchedPropertySimpleOneWayPU: Property,
  ObservedPropertySimplePU: Property, ObservedPropertyObjectPU: Property,
  require: id => {
    if (id.includes('AppearanceStyle&')) return { AppearanceStyle: class {} };
    if (id.includes('I18n&')) return { t: s => s };
    if (id.includes('Cancellation&')) return { Cancellation: class {} };
    if (id.includes('Attachments&')) return { writeBytes: async (p, bytes) => cached.set(p, Buffer.from(bytes)) };
    if (id.includes('NativeActions&')) return { exportFile: async (ctx, p, name) => exportsSeen.push({ name, content: cached.get(p).toString('utf8') }) };
    if (id === '@ohos:file.fs') return { default: { unlink: async p => { removed.push(p); cached.delete(p); } } };
    if (id === '@ohos:util') return { default: { generateRandomUUID: () => 'test', TextEncoder: class { encodeInto(s) { return new TextEncoder().encode(s); } } } };
    return {};
  }
};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
} }).outputText, globals, { filename: emitted });
(async () => {
  const panel = new globals.exports.WorkspacePanel(undefined, { app: { busy: false } });
  panel.directory = 'shared/Vault';
  const backup = { path: 'shared/Vault/note.md', existed: true, content: '原始内容', sourceUri: 'file://docs/Vault/note.md' };
  panel.files = { baseline: async () => backup, read: async () => { throw Error('invalid UTF-8 after partial write'); } };
  await panel.open({ name: 'note.md', kind: 'file' });
  assert.match(panel.previewError, /invalid UTF-8/); assert.equal(panel.baseline, backup);
  await panel.exportBaseline();
  assert.deepEqual(exportsSeen, [{ name: '备份-note.md', content: '原始内容' }]);
  assert.equal(cached.size, 0); assert.equal(removed.length, 1);
  panel.files.write = async () => { throw Error('partial write'); };
  panel.editing = true; panel.content = 'edited'; await panel.save();
  assert.equal(panel.baseline, backup); assert.match(panel.previewError, /partial write/); assert.equal(panel.editing, true);
  panel.files.write = async () => {}; panel.files.list = async () => ({ entries: [], truncated: false });
  await panel.save(); assert.equal(panel.previewError, ''); assert.equal(panel.editing, false);
  const fresh = { ...backup, path: 'shared/Vault/new.md', existed: false, content: '' };
  panel.entries = []; panel.files.baseline = async () => fresh;
  await panel.newNote(); assert.equal(panel.baseline, fresh, 'New files cannot retain a previous file backup');
  panel.editing = false; panel.baseline = backup; panel.selected = backup.path; panel.original = 'current';
  const restored = [];
  panel.files.restore = async (p, expected) => restored.push({p, expected});
  panel.confirmRestore();
  assert.equal(restored.length,0,'Opening the restore confirmation cannot change a file');
  assert.equal(dialogs.length,1);await dialogs[0].secondaryButton.action();
  assert.deepEqual(restored,[{p:backup.path,expected:'current'}]);
  panel.baseline = fresh;panel.confirmRestore();
  panel.baseline = backup;panel.previewError='unreadable';panel.confirmRestore();
  assert.equal(dialogs.length,1,'New files and unreadable content cannot trigger destructive restoration');
  console.log('PASS emitted file-panel backup export, failed-save recovery and explicit restore without acceptance');
})().catch(error => { console.error(error); process.exitCode = 1; });
