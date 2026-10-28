// Real workspace bytes and production attachment/read/backup code; only Harmony APIs are replaced.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto'), zlib = require('node:zlib');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.resolve(__dirname, '../entry/src/main/ets');
const fixture = path.resolve(__dirname, '../.hvigor/mini-apps-' + crypto.randomUUID());
fs.mkdirSync(fixture, { recursive: true });
const disk = value => value.startsWith('/sandbox/') ? path.join(fixture, value.slice(9)) : value;
const handles = new Map(), cache = new Map();
let copyFailure = false, pdfReads = 0, pdfPages = [], jsReads = 0;
const fileIo = {
  readText: p => fs.promises.readFile(disk(p),'utf8'),
  rmdir: async p => {
    const target = path.resolve(disk(p));
    assert.ok(target.startsWith(fixture + path.sep), 'Deletion stays within this test fixture');
    await fs.promises.rm(target, { recursive: true });
  },
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8, NOFOLLOW: 16 },
  access: async p => fs.existsSync(disk(p)), mkdir: (p, recursive = false) => fs.promises.mkdir(disk(p), { recursive }),
  lstat: async p => { try { return await fs.promises.lstat(disk(p)); } catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; } },
  stat: p => typeof p === 'number' ? handles.get(p).stat() : fs.promises.stat(disk(p)),
  open: async (p, flags) => { const handle = await fs.promises.open(disk(p), flags & 4 ? 'w' : 'r'); handles.set(handle.fd, handle); return { fd: handle.fd }; },
  close: async file => { const fd = typeof file === 'number' ? file : file.fd; const handle = handles.get(fd); handles.delete(fd); await handle.close(); },
  read: async (fd, bytes) => { jsReads++; return (await handles.get(fd).read(new Uint8Array(bytes))).bytesRead; },
  write: async (fd, bytes, options) => (await handles.get(fd).write(new Uint8Array(bytes), 0, bytes.byteLength, options.offset)).bytesWritten,
  fsync: fd => handles.get(fd).sync(), unlink: p => fs.promises.unlink(disk(p)),
  listFile: p => fs.promises.readdir(disk(p)), rename: (a, b) => fs.promises.rename(disk(a), disk(b)),
  copyFile: async (input, output) => {
    const buffer = new Uint8Array(64 * 1024);
    while (true) {
      const { bytesRead } = await handles.get(input).read(buffer); if (!bytesRead) break;
      await handles.get(output).write(buffer.subarray(0, bytesRead));
      if (copyFailure) throw Error('injected copy failure');
    }
  }
};
const kits = {
  '@kit.CoreFileKit': { fileIo }, '@kit.ImageKit': { image: {} }, '@kit.ArkGraphics2D': { drawing: {} },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } async encodeToString(bytes) { return this.encodeToStringSync(bytes); } decodeSync(text) { return Uint8Array.from(Buffer.from(text, 'base64')); } }
  } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => { const hash = crypto.createHash('sha256'); return {
    update: async value => hash.update(value.data), digest: async () => ({ data: Uint8Array.from(hash.digest()) })
  }; } } },
  '@kit.BasicServicesKit': { zlib: { ReturnStatus: { STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 }, createZipSync: () => {
    let size = 0; return { inflateInit2: async () => {}, inflateEnd: async () => {}, getZStream: async () => ({ totalOut: size }),
      inflate: async stream => { const bytes = zlib.inflateRawSync(Buffer.from(stream.nextIn), { maxOutputLength: stream.availableOut }); new Uint8Array(stream.nextOut).set(bytes); size = bytes.length; return 1; } };
  } } },
  '@kit.PDFKit': { pdfService: { PdfDocument: class {
    loadDocument(p) { assert.equal(fs.readFileSync(disk(p)).subarray(0, 4).toString(), '%PDF'); pdfReads++; }
    getPageCount() { return pdfPages.length; } getPage(i) { return { getTextContent: () => pdfPages[i], release() {} }; }
    releaseDocument() {}
  } } }
};
const t = (text, values = []) => text.replace(/\{(\d+)\}/g, (_, i) => String(values[i]));
function mock(name, value) { cache.set(path.join(source, name + '.ets'), value); }
mock('model/I18n', { t }); mock('model/Diagnostics', { Diagnostics: { acceptsLog: () => false, log() {}, begin: () => 0, end() {} } });
mock('common/ApiLevel', { ApiLevel: { pdfTextContent: true } });
mock('services/ProjectFolderAccess', { ProjectFolderAccess: { activate: async () => {} } });
mock('services/NativeActions', { exportFile: async () => {} });
function compile(text) { return ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText; }
function load(name) {
  const file = path.resolve(source, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, ArrayBuffer, Uint8Array, DataView, Error, Map, Set, console,
    setTimeout, clearTimeout, Observed: cls => cls,
    require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : assert.ok(id in kits, id) || kits[id]
  }, { filename: file });
  return exports;
}
const { MiniApps, MiniAppValidationStorage } = load('services/MiniApps');
const { MiniAppTools } = load('services/MiniAppTools');
const { miniAppPage, miniAppPath } = load('model/MiniApp');
const { parseWebUiMessage } = load('model/WebUi');
const { NativeWorkspaceFiles } = load('services/NativeWorkspaceFiles');
const { WorkspaceStore } = load('model/WorkspaceStore');
const { Cancellation } = load('services/Cancellation');
const { RuleTools } = load('services/RuleTools');
const { emptyData } = load('model/Conversation');
const root = '/sandbox/app', workspace = new WorkspaceStore(root), apps = new MiniApps(root);
const signal = new Cancellation();
const files = id => new NativeWorkspaceFiles(workspace.pathFor(id));
const invoke = (tools, name, args) => tools.execute({id:'test',function:{name,arguments:JSON.stringify(args)}}, new Cancellation()).then(JSON.parse);
const plain = value => JSON.parse(JSON.stringify(value));
async function main() {
  fs.mkdirSync(disk(root), {recursive:true});
  await workspace.ensureThread('chat'); await workspace.ensureThread('other');
  const repo = apps.repository('chat'), other = apps.repository('other');
  const source = 'const snapshot = await tinybot.storage.load(); document.body.textContent = JSON.stringify(snapshot.value);';
  const page = miniAppPage('ledger.js',source);
  await files('chat').write('ledger.js', source, signal);
  const app = await repo.publish('ledger','Ledger','Expenses','ledger.js','chat',page,false,signal);
  const initial = await repo.load(app.id); assert.equal(initial.value,null);
  const saved = await repo.save(app.id,{rows:[{amount:30,category:'午餐'}]},initial.revision);
  const restarted = new MiniApps(root).repository('chat');
  assert.deepEqual(plain((await restarted.load(app.id)).value), {rows:[{amount:30,category:'午餐'}]});
  await other.publish('ledger','Other','','ledger.js','other',page,false,signal);
  assert.equal((await other.load('ledger')).value,null);
  assert.throws(()=>apps.repository('../outside')); assert.throws(()=>miniAppPath('../other','data.json'));
  const competing = await Promise.allSettled([
    repo.save(app.id,{total:40},saved.revision), restarted.save(app.id,{total:50},saved.revision)
  ]);
  assert.equal(competing.filter(x=>x.status==='fulfilled').length,1);
  assert.equal(competing.filter(x=>x.status==='rejected').length,1);
  const before = await repo.load(app.id);
  const changed = miniAppPage('ledger.js','document.body.textContent="updated"');
  await repo.publish(app.id,'Updated','','ledger.js','chat',changed,true,signal);
  assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  await repo.change(app.id,'rollback'); assert.equal((await repo.get(app.id)).page.js,page.js);
  assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  await assert.rejects(new MiniAppValidationStorage(before).save({},before.revision),/startup/);
  await repo.change(app.id,'archive');
  await assert.rejects(repo.save(app.id,{},before.revision),/removed/);
  assert.ok((await apps.list()).some(x=>x.app.id===app.id&&x.app.archived));
  await repo.change(app.id,'restore'); assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  const nativeRename = fileIo.rename;
  fileIo.rename = async (a,b) => { if(b.endsWith('/data.json'))throw Error('disk write failed'); return nativeRename(a,b); };
  await assert.rejects(repo.save(app.id,{lost:true},before.revision),/disk write failed/);
  fileIo.rename = nativeRename;
  assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  assert.ok(!fs.readdirSync(disk(workspace.pathFor('chat')+'/mini-apps/ledger')).some(x=>x.endsWith('.tmp')));
  console.log('PASS restart persistence, workspace isolation, optimistic concurrent saves, page update/rollback, archive and disk failure');

  let failValidation = false, validationCount = 0;
  const disabledTools = new MiniAppTools(apps,'chat','chat',files('chat'), async () => { assert.fail('Disabled tools must not validate pages'); });
  assert.equal(disabledTools.definitions().length, 0);
  const existingApp = plain(await repo.get(app.id)), existingData = plain(await repo.load(app.id));
  await assert.rejects(invoke(disabledTools,'list_mini_apps',{}), error => error.code === 'PERMISSION_DENIED');
  await assert.rejects(invoke(disabledTools,'publish_mini_app',{path:'ledger.js',title:'Disabled',appId:app.id}), error => error.code === 'PERMISSION_DENIED');
  assert.deepEqual(plain(await repo.get(app.id)), existingApp); assert.deepEqual(plain(await repo.load(app.id)), existingData);
  const tools = new MiniAppTools(apps,'chat','chat',files('chat'), async (text,storage) => {
    validationCount++; assert.ok(JSON.parse(text).js); await storage.load();
    await assert.rejects(storage.save({},'initial'),/startup/);
    if(failValidation) throw Error('startup failed');
  }, true);
  const created = await invoke(tools,'publish_mini_app',{path:'ledger.js',title:'New ledger'});
  assert.equal(created.published,true); assert.equal(created.startup,'passed');
  failValidation=true;
  await assert.rejects(invoke(tools,'publish_mini_app',{path:'ledger.js',title:'Broken',appId:created.appId}),/startup failed/);
  assert.equal((await repo.get(created.appId)).title,'New ledger');
  failValidation=false;
  await invoke(tools,'publish_mini_app',{path:'ledger.js',title:'Version 2',appId:created.appId});
  assert.equal((await repo.get(created.appId)).title,'Version 2');
  assert.equal(validationCount,3);
  assert.equal((await invoke(tools,'list_mini_apps',{})).length,2);
  const readonly=new RuleTools(tools,true);
  assert.ok(!readonly.definitions().some(t=>t.function.name==='publish_mini_app'));
  await assert.rejects(invoke(readonly,'publish_mini_app',{path:'ledger.js',title:'Denied'}));
  assert.throws(()=>parseWebUiMessage('{"type":"storageSave","id":1,"value":{}}'));
  assert.throws(()=>parseWebUiMessage('{"type":"storageLoad","id":1,"path":"../other"}'));
  assert.equal(parseWebUiMessage('{"type":"storageSave","id":1,"value":null,"revision":"abc"}').revision,'abc');
  console.log('PASS real tool dispatch, failed update leaves published page intact, read-only permissions and bridge validation');

  // No conversations remain: all app workspaces must still be exported and restored.
  const {Attachments}=load('services/Attachments'); Attachments.configure(root);
  const {createBackupFile,readBackupFile}=load('services/Backup');
  const context = {filesDir:root,cacheDir:root+'/cache',getApplicationContext(){return this;}};
  fs.mkdirSync(disk(context.cacheDir),{recursive:true});
  const data=emptyData(); data.threads=[];
  const backup=await createBackupFile(context,data);
  const envelope=JSON.parse(fs.readFileSync(disk(backup),'utf8'));
  assert.deepEqual([...envelope.miniAppWorkspaceIds].sort(),['chat','other']);
  assert.ok(envelope.files.some(x=>x.path==='mini-apps/ledger/data.json'));
  const restoreRoot='/sandbox/restored'; fs.mkdirSync(disk(restoreRoot),{recursive:true});
  const restore={filesDir:restoreRoot,cacheDir:restoreRoot,getApplicationContext(){return this;}};
  await readBackupFile(restore,backup,emptyData());
  const restored=new MiniApps(restoreRoot);
  assert.equal((await restored.list()).length,3);
  assert.deepEqual(plain(await restored.repository('chat').load('ledger')),plain(before));
  const modified=await restored.repository('chat').save('ledger',{local:true},before.revision);
  await readBackupFile(restore,backup,emptyData());
  assert.deepEqual(plain(await restored.repository('chat').load('ledger')),plain(modified),'restore keeps local data');
  await apps.repository('other').change('ledger','archive');
  await apps.remove('other','ledger');
  assert.equal((await apps.list('other')).length,0); assert.equal((await apps.list('chat')).length,2);
  console.log('PASS backup/restore after deleting source chats, local data wins, permanent deletion stays scoped');
  if(process.argv.includes('--browser')) await browserTest(repo,app.id);
}
async function browserTest(repo,id) {
  const {chromium}=require('playwright');
  const {webUiHost}=load('model/WebUi');
  const host=webUiHost(fs.readFileSync(path.resolve(__dirname,'../entry/src/main/resources/rawfile/interactive-web/host.js'),'utf8'),'');
  const browser=await chromium.launch({channel:'msedge',headless:true});
  try {
    const page=await browser.newPage(); let deny=false, mutateAttempts=0;
    await page.exposeFunction('storageNative',async data=>{
      parseWebUiMessage(JSON.stringify(data));
      try {
        if(deny)throw Error('Storage unavailable');
        if(data.type==='storageSave')mutateAttempts++;
        return {type:'storageResult',id:data.id,snapshot:data.type==='storageLoad'?await repo.load(id):await repo.save(id,data.value,data.revision)};
      } catch(error) {return {type:'storageResult',id:data.id,error:error.message};}
    });
    const script=`let snapshot=await tinybot.storage.load();document.body.innerHTML='<button>Save</button><output></output>';
      const output=document.querySelector('output');output.textContent=JSON.stringify(snapshot.value);
      document.querySelector('button').onclick=async()=>{try{snapshot=await tinybot.storage.save({amount:99},snapshot.revision);output.textContent='Saved';}catch(e){output.textContent=e.message;}};`;
    async function mount(preflight=false) {
      await page.goto('about:blank');await page.setContent(host);
      await page.evaluate(({spec,preflight})=>{
        window.messages=[];const pair=new MessageChannel();
        pair.port1.onmessage=async event=>{const data=JSON.parse(event.data);messages.push(data);
          if(data.type==='storageLoad'||data.type==='storageSave')pair.port1.postMessage(JSON.stringify(await storageNative(data)));
        };pair.port1.start();window.postMessage('tinybot-web-port','*',[pair.port2]);
        pair.port1.postMessage(JSON.stringify({type:'init',spec,values:{},active:true,preflight}));
      },{spec:miniAppPage('ledger.js',script),preflight});
      await page.waitForFunction(()=>messages.some(x=>x.type==='ready'||x.type==='error'));
      return page.frames().find(f=>f.parentFrame());
    }
    let frame=await mount();await frame.locator('button').click();await frame.locator('output').filter({hasText:'Saved'}).waitFor();
    frame=await mount();assert.equal(await frame.locator('output').textContent(),'{"amount":99}');
    const snapshot=await repo.load(id);await repo.save(id,{external:1},snapshot.revision);
    await frame.locator('button').click();await page.waitForFunction(()=>messages.filter(x=>x.type==='storageSave').length===1);
    await frame.locator('output').filter({hasText:'文件自上次读取后已变化'}).waitFor();
    assert.equal((await repo.load(id)).value.external,1);
    const count=mutateAttempts;frame=await mount(true);
    await assert.rejects(frame.evaluate(()=>tinybot.storage.save({},'fake')),/active user interaction/);
    assert.equal(mutateAttempts,count);
    deny=true;await mount();assert.ok((await page.evaluate(()=>messages)).some(x=>x.type==='error'&&x.message.includes('Storage unavailable')));
    console.log('PASS real Chromium host: save/reopen, stale write rejection, preflight blocks writes, unavailable storage fails visibly');
  } finally {await browser.close();}
}
main().catch(error=>{console.error(error);process.exitCode=1;});
