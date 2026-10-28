// Run after devecocli build: exercise the emitted file-panel recovery callbacks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = path.resolve('entry/src/main/ets/views/WorkspacePanel.ets');
const emitted = path.resolve('entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/WorkspacePanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build WorkspacePanel before testing');
class Property { constructor(value) { this.value = value; } get() { return this.value; } set(v) { this.value = v; } reset(v) { this.value = v; } }
const context = { cacheDir: '/cache' }, cached = new Map(), exportsSeen = [], removed = [], dialogs = [];
const logs = []; let picked = [];
class ToolFailure extends Error { constructor(code, message) { super(message); this.code = code; } }
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
    if (id.includes('ToolFailure&')) return { ToolFailure };
    if (id.includes('Diagnostics&')) return { Diagnostics: { log: (...args) => logs.push(args) } };
    if (id.includes('TextFiles&')) return { importTextFile: async () => 'imported text' };
    if (id === '@ohos:file.picker') return { default: { DocumentViewPicker: class { async select() { return picked; } } } };
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
  panel.files.write = async () => ({version:'saved'}); panel.files.list = async () => ({ entries: [], truncated: false });
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

  let disk = {content:'first',version:'v1'}, writes = 0;
  panel.directory = ''; panel.previewError = ''; panel.error = '';
  const files = {
    list: async () => ({entries:[],truncated:false}), baseline: async () => undefined,
    read: async p => ({path:p,...disk}),
    write: async (p, content, cancellation, guard) => {
      assert.ok(guard,'Every editor mutation must supply its observation');
      if(guard.version !== disk.version)throw new ToolFailure('FS_STALE_VERSION','changed since read');
      writes++;disk={content,version:'written-'+writes};return {version:disk.version};
    }
  };
  panel.files=files;await panel.open({name:'note.md',kind:'file'});
  panel.editing=true;panel.content='my unsaved draft';disk={content:'other session',version:'v2'};
  await panel.save();await panel.save();
  assert.equal(writes,0);assert.equal(disk.content,'other session');
  assert.equal(panel.content,'my unsaved draft');assert.equal(panel.original,'first');assert.equal(panel.version,'v1');
  assert.equal(panel.editing,true);assert.match(panel.previewError,/文件已变化/);
  assert.ok(logs.some(record=>record[1]==='workspace'&&record[2]==='mutation_failed'&&record[4].code==='FS_STALE_VERSION'));
  await panel.open({name:'note.md',kind:'file'});panel.editing=true;panel.content='combined';await panel.save();
  assert.equal(panel.version,'written-1');assert.equal(panel.original,'combined');assert.equal(panel.editing,false);
  panel.editing=true;panel.content='second edit';await panel.save();assert.equal(writes,2);
  // Input can arrive while native I/O is pending. Only the captured text was saved.
  let release;const write=files.write;
  files.write=async(...args)=>{await new Promise(r=>release=r);return write(...args);};
  panel.editing=true;panel.content='submitted';const pending=panel.save();panel.content='typed while saving';release();await pending;
  assert.equal(disk.content,'submitted');assert.equal(panel.original,'submitted');
  assert.equal(panel.content,'typed while saving');assert.equal(panel.editing,true);
  console.log('PASS stale editor saves retain drafts and receipt versions track only committed text');

  panel.previewing=false;panel.editing=false;panel.entries=[];
  const creates=[];
  files.write=async(p,content,cancellation,guard)=>{
    assert.equal(guard.version,null,'New notes and imports must create only');creates.push(p);
    throw new ToolFailure('FS_NOT_OBSERVED','another session created this name');
  };
  await panel.newNote();assert.match(panel.error,/文件已变化/);
  files.importFile=async(uri,p)=>{creates.push(p);throw new ToolFailure('FS_NOT_OBSERVED','another session created this name');};
  picked=['file://fixtures/note.txt'];await panel.importFiles();assert.match(panel.error,/文件已变化/);
  assert.equal(creates.length,2,'Collisions are reported without silently choosing a different name or overwriting');
  assert.equal(panel.busy,false);
  console.log('PASS new-note and import collisions remain visible after directory refresh');

  dialogs.length=0;let current='before-confirmation',deletions=0;
  files.removalVersion=async()=>current;
  files.remove=async(p,version)=>{assert.equal(p,'note.md');if(version!==current)throw new ToolFailure('FS_STALE_VERSION','changed');deletions++;};
  await panel.confirmDelete('note.md');assert.equal(deletions,0);current='after-confirmation';
  await dialogs[0].secondaryButton.action();assert.equal(deletions,0);assert.match(panel.error,/文件已变化/);
  await panel.confirmDelete('note.md');await dialogs[1].secondaryButton.action();assert.equal(deletions,1);
  await panel.confirmDelete('note.md');panel.files={...files};await dialogs[2].secondaryButton.action();
  assert.equal(deletions,1,'An old dialog cannot delete a file in a newly bound workspace');
  console.log('PASS delete confirmation preserves its file version and workspace identity');
})().catch(error => { console.error(error); process.exitCode = 1; });
