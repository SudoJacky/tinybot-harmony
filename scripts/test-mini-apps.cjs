const backupAccount = { openID: 'fixture-openid-A', error: undefined, async backupOpenID() { if (this.error) throw this.error; if (!this.openID) throw Error('请登录创建备份时使用的华为账号。'); return this.openID; } };
const { legacyBackupFixture, backupCrypto } = require('./backup-fixture.cjs');
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
  '@kit.NetworkKit': { socket: {} },
  '@kit.AssetStoreKit': { asset: {} },
  '@kit.CoreFileKit': { fileIo }, '@kit.ImageKit': { image: {} }, '@kit.ArkGraphics2D': { drawing: {} },
  '@kit.ArkTS': { util: {
    generateRandomUUID: () => crypto.randomUUID(),
    TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
    TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); } decodeToString(bytes, options) { return this.decoder.decode(bytes, options); } },
    Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } async encodeToString(bytes) { return this.encodeToStringSync(bytes); } decodeSync(text) { return Uint8Array.from(Buffer.from(text, 'base64')); } }
  } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { ...backupCrypto, createMd: () => { const hash = crypto.createHash('sha256'); return {
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
let panelResponse = '{}';
let panelScriptHandler;
const panelScriptCalls=[];
// Execute sample function bodies in a test VM; native QuickJS limits/queue have separate adapter tests.
mock('services/NativeCodeExecutor',{NativeCodeExecutor:class {
  async execute(code,inputJson,cancellation) {
    cancellation.check();panelScriptCalls.push({code,inputJson});
    if(panelScriptHandler)return panelScriptHandler(code,inputJson,cancellation);
    try {
      const result=vm.runInNewContext('(function(input){'+code+'})(JSON.parse(inputJson))',{inputJson},{timeout:100});
      if(result&&typeof result.then==='function')return JSON.stringify({status:'unsupported_async',error:'Promises are unsupported'});
      return JSON.stringify({status:'ok',result});
    }catch(error){return JSON.stringify({status:'error',error:error.message});}
  }
}});
const panelSecrets=new Map();let apiRequest, apiResponse={status:200,header:{},text:'',bytes:new ArrayBuffer(0)}, apiStop=false;
let apiHandler=async()=>apiResponse;
mock('services/NetworkTransfers',{NetworkTransfers:{begin:async()=>async()=>{}}});
mock('services/CompatHttp',{CompatHttp:{request:async(spec,register)=>{apiRequest=spec;apiStop=false;if(register)register(()=>apiStop=true);return apiHandler(spec);}}});
mock('services/CredentialStore',{CredentialStore:class {
  async readOptional(alias){return panelSecrets.get(alias);}
  async read(alias){if(!panelSecrets.has(alias))throw Error('Missing credentials');return panelSecrets.get(alias);}
  async write(alias,value){assert.ok(!panelSecrets.has(alias));panelSecrets.set(alias,value);}
  async update(alias,value){assert.ok(panelSecrets.has(alias));panelSecrets.set(alias,value);}
  async remove(alias){panelSecrets.delete(alias);}
}});
mock('services/NativeWebTransport', { NativeWebTransport: class {
  async get(url, cancellation, maxBytes) { cancellation.check(); assert.equal(maxBytes, 256 * 1024); return { body: panelResponse }; }
} });
function compile(text) { return ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText; }
function load(name) {
  const file = path.resolve(source, name.endsWith('.ets') ? name : name + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports, ArrayBuffer, Uint8Array, DataView, Error, Map, Set, console,
    setTimeout, clearTimeout, Observed: cls => cls,
    require: id => id === './HuaweiAccount' ? { huaweiAccount: backupAccount } : id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : assert.ok(id in kits, id) || kits[id]
  }, { filename: file });
  return exports;
}
const { MiniApps, MiniAppValidationStorage } = load('services/MiniApps');
const { MiniAppTools } = load('services/MiniAppTools');
const { miniAppPage, miniAppPath, parseMiniApp, miniAppCanRollback, miniAppInCollection } = load('model/MiniApp');
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
  const beforeName = plain(await repo.get(app.id));
  await repo.rename(app.id, '  Personal ledger  ');
  assert.deepEqual(plain(await repo.get(app.id)), {...beforeName, title:'Personal ledger'});
  assert.deepEqual(plain(await repo.load(app.id)), plain(before), 'Rename changes neither page nor stored user data');
  const beforeIcon = plain(await repo.get(app.id));
  assert.equal(beforeIcon.icon, undefined, 'Legacy manifests need no migration');
  assert.equal(beforeIcon.iconColor, undefined, 'Legacy colors need no migration');
  await repo.setIcon(app.id, 'list', 'blue');
  assert.deepEqual(plain(await repo.get(app.id)), {...beforeIcon, icon:'list', iconColor:'blue'}, 'Only icon and color metadata change');
  assert.equal((await restarted.get(app.id)).icon, 'list', 'Icon selection survives restart');
  assert.equal((await restarted.get(app.id)).iconColor, 'blue', 'Color selection survives restart');
  assert.deepEqual(plain(await repo.load(app.id)), plain(before), 'Icon selection cannot change user data');
  for (const icon of ['', 'unknown', null, 1]) {
    await assert.rejects(repo.setIcon(app.id, icon), /Invalid mini app icon/);
    assert.throws(()=>parseMiniApp(JSON.stringify({...beforeIcon,icon}),app.id), /Invalid mini app icon/);
  }
  for (const iconColor of ['', '#FF0000', 'unknown', null, 1]) {
    await assert.rejects(repo.setIcon(app.id, 'clock', iconColor), /Invalid mini app icon color/);
    assert.throws(()=>parseMiniApp(JSON.stringify({...beforeIcon,iconColor}),app.id), /Invalid mini app icon color/);
  }
  await repo.setIcon(app.id,'note');
  assert.equal((await repo.get(app.id)).iconColor,'blue','An icon-only update retains the selected color');
  await repo.setIcon(app.id,'list');
  assert.equal((await other.get('ledger')).icon, undefined, 'Icon selection stays in its workspace');
  assert.equal((await other.get('ledger')).iconColor, undefined, 'Color selection stays in its workspace');
  await assert.rejects(repo.rename(app.id, '  '), /1–160/);
  await assert.rejects(repo.rename(app.id, 'x'.repeat(161)), /1–160/);
  assert.equal((await other.get('ledger')).title, 'Other', 'Same ID in another workspace stays unchanged');
  const changed = miniAppPage('ledger.js','document.body.textContent="updated"');
  await repo.publish(app.id,'Updated','','ledger.js','chat',changed,true,signal);
  assert.equal((await repo.get(app.id)).icon, 'list', 'Page publication retains the user-selected icon');
  assert.equal((await repo.get(app.id)).iconColor, 'blue', 'Page publication retains the selected color');
  assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  await repo.change(app.id,'rollback'); assert.equal((await repo.get(app.id)).page.js,page.js);
  assert.equal((await repo.get(app.id)).icon, 'list', 'Page rollback retains the selected icon');
  assert.equal((await repo.get(app.id)).iconColor, 'blue', 'Page rollback retains the selected color');
  assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  await assert.rejects(new MiniAppValidationStorage(before).save({},before.revision),/startup/);
  await repo.change(app.id,'archive');
  await assert.rejects(repo.save(app.id,{},before.revision),/removed/);
  assert.ok((await apps.list()).some(x=>x.app.id===app.id&&x.app.archived));
  await repo.change(app.id,'restore'); assert.deepEqual(plain(await repo.load(app.id)),plain(before));
  const nativeRename = fileIo.rename;
  fileIo.rename = async (a,b) => { if(b.endsWith('/app.json'))throw Error('icon write failed'); return nativeRename(a,b); };
  await assert.rejects(repo.setIcon(app.id,'clock','orange'), /icon write failed/);
  fileIo.rename = nativeRename;
  assert.equal((await repo.get(app.id)).icon,'list','Failed icon save leaves committed metadata intact');
  assert.equal((await repo.get(app.id)).iconColor,'blue','Failed save cannot commit half of the icon/color pair');
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
  const envelope=legacyBackupFixture(fs.readFileSync(disk(backup)));
  assert.deepEqual([...envelope.miniAppWorkspaceIds].sort(),['chat','other']);
  assert.ok(envelope.files.some(x=>x.path==='mini-apps/ledger/data.json'));
  const restoreRoot='/sandbox/restored'; fs.mkdirSync(disk(restoreRoot),{recursive:true});
  const restore={filesDir:restoreRoot,cacheDir:restoreRoot,getApplicationContext(){return this;}};
  await readBackupFile(restore,backup,emptyData());
  const restored=new MiniApps(restoreRoot);
  assert.equal((await restored.list()).length,3);
  assert.deepEqual(plain(await restored.repository('chat').load('ledger')),plain(before));
  assert.equal((await restored.repository('chat').get('ledger')).icon,'list','Backup restores selected icons');
  assert.equal((await restored.repository('chat').get('ledger')).iconColor,'blue','Backup restores selected colors');
  const modified=await restored.repository('chat').save('ledger',{local:true},before.revision);
  await readBackupFile(restore,backup,emptyData());
  assert.deepEqual(plain(await restored.repository('chat').load('ledger')),plain(modified),'restore keeps local data');
  await apps.repository('other').change('ledger','archive');
  await apps.remove('other','ledger');
  assert.equal((await apps.list('other')).length,0); assert.equal((await apps.list('chat')).length,2);
  console.log('PASS backup/restore after deleting source chats, local data wins, permanent deletion stays scoped');
  await versionTwoTest();
  if(process.argv.includes('--browser')) await browserTest(repo,app.id);
}
async function versionTwoTest() {
  const dir = '/sandbox/v2', workspace = new WorkspaceStore(dir), apps = new MiniApps(dir);
  fs.mkdirSync(disk(dir), {recursive:true}); await workspace.ensureThread('v2-workspace');
  const repo = apps.repository('v2-workspace'), appDir = workspace.pathFor('v2-workspace') + '/mini-apps/versioned';
  const page = miniAppPage('counter.js', 'document.body.textContent="current"');
  const revision = (number, schema) => ({id:'v'+number,number,title:'Counter '+number,description:'fixture',summary:'revision',
    sourcePath:'counter.js',sourceThreadId:'v2-workspace',createdAt:100+number,dataSchema:schema,page:{...page,js:'document.body.textContent="v'+number+'"'}});
  const revisions = [revision(1,1),revision(2,2)];
  const manifest = {version:2,id:'versioned',title:'Counter 2',description:'fixture',sourcePath:'counter.js',sourceThreadId:'v2-workspace',
    createdAt:101,updatedAt:102,lastOpenedAt:0,archived:false,page:revisions[1].page,currentRevisionId:'v2',dataFile:'data-v2.json',revisions,
    adoptions:[{revisionId:'v1',adoptedAt:101,dataFile:'data.json'},{revisionId:'v2',adoptedAt:102,dataFile:'data-v2.json'}]};
  fs.mkdirSync(disk(appDir), {recursive:true});
  const write = (name,value) => fs.writeFileSync(disk(appDir+'/'+name), JSON.stringify(value));
  write('app.json',manifest); write('data.json',{version:1,value:{old:7}});
  write('data-v2.json',{version:1,value:{count:42}}); write('trial-v2.json',{version:1,value:{count:9},baseRevisionId:'v1',baseDataRevision:'old',edited:true});
  const originalHistory = plain(manifest.revisions), oldData = fs.readFileSync(disk(appDir+'/data.json'));
  await repo.rename('versioned', 'My counter');
  assert.deepEqual(plain(await repo.get('versioned')), {...plain(manifest), title:'My counter'},
    'Renaming v2 preserves immutable revisions, adoptions and the active data file');
  const beforeIcon = plain(await repo.get('versioned'));
  await repo.setIcon('versioned','star','rose');
  assert.deepEqual(plain(await repo.get('versioned')), {...beforeIcon,icon:'star',iconColor:'rose'}, 'v2 icon/color changes preserve revisions and adoption history');
  assert.equal((await apps.list()).length,1);
  let data = await repo.load('versioned'); assert.deepEqual(plain(data.value),{count:42});
  data = await repo.save('versioned',{count:43},data.revision);
  assert.deepEqual(fs.readFileSync(disk(appDir+'/data.json')),oldData,'Save must not overwrite the old schema file');
  assert.equal(miniAppCanRollback(await repo.get('versioned')),false);
  await assert.rejects(repo.change('versioned','rollback'),/compatible/);
  await repo.change('versioned','open'); await repo.change('versioned','archive'); await repo.change('versioned','restore');
  assert.deepEqual(plain((await repo.get('versioned')).revisions),originalHistory);
  const updated = await repo.publish('versioned','Updated','fixture','counter.js','v2-workspace',page,true,signal);
  assert.equal(updated.icon,'star','v2 page publication retains the user-selected icon');
  assert.equal(updated.iconColor,'rose','v2 page publication retains the selected color');
  assert.equal(updated.version,2); assert.equal(updated.revisions.length,3); assert.equal(updated.revisions[2].dataSchema,2);
  assert.equal(updated.currentRevisionId,updated.revisions[2].id); assert.equal(updated.dataFile,'data-v2.json');
  assert.deepEqual(plain(updated.revisions.slice(0,2)),originalHistory);
  assert.equal(miniAppCanRollback(updated),true);
  await repo.change('versioned','rollback');
  assert.equal((await repo.get('versioned')).currentRevisionId,'v2');
  assert.equal((await repo.get('versioned')).icon,'star','v2 rollback retains the selected icon');
  assert.equal((await repo.get('versioned')).iconColor,'rose','v2 rollback retains the selected color');
  assert.equal((await repo.get('versioned')).page.js,revisions[1].page.js);
  assert.deepEqual(plain(await repo.load('versioned')),plain(data));
  await repo.change('versioned','rollback');
  assert.equal((await repo.get('versioned')).currentRevisionId,updated.currentRevisionId);
  for (const mutate of [m=>m.dataFile='../data.json',m=>m.currentRevisionId='missing',m=>m.revisions[0]=null,
    m=>m.revisions[0].dataSchema=0,m=>m.adoptions[0].dataFile='../../other.json',m=>m.adoptions[0].revisionId='missing']) {
    const invalid=plain(manifest); mutate(invalid); assert.throws(()=>parseMiniApp(JSON.stringify(invalid),'versioned'));
  }
  const draft=plain(manifest); draft.currentRevisionId=''; draft.adoptions=[];
  assert.equal(miniAppInCollection(parseMiniApp(JSON.stringify(draft),'versioned')),false,'Unadopted v2 trials stay outside the collection');
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};
  fs.mkdirSync(disk(context.cacheDir));
  const {createBackupFile,readBackupFile}=load('services/Backup');
  const backup=await createBackupFile(context,emptyData());
  const restoredDir='/sandbox/v2-restored'; fs.mkdirSync(disk(restoredDir));
  const target={filesDir:restoredDir,cacheDir:restoredDir,getApplicationContext(){return this;}};
  await readBackupFile(target,backup,emptyData());
  const restored=new MiniApps(restoredDir).repository('v2-workspace');
  assert.deepEqual(plain(await restored.get('versioned')),plain(await repo.get('versioned')));
  assert.deepEqual(plain((await restored.load('versioned')).value),{count:43});
  for (const name of ['app.json','data.json','data-v2.json','trial-v2.json']) {
    assert.deepEqual(fs.readFileSync(disk(new WorkspaceStore(restoredDir).pathFor('v2-workspace')+'/mini-apps/versioned/'+name)),
      fs.readFileSync(disk(appDir+'/'+name)), 'Archive round trip preserves '+name+' byte for byte');
  }
  const local=await restored.load('versioned'); await restored.save('versioned',{count:44},local.revision);
  await readBackupFile(target,backup,emptyData());
  assert.deepEqual(plain((await restored.load('versioned')).value),{count:44},'Repeated restore keeps local v2 data');
  console.log('PASS v2 validation, active data file, non-destructive updates/rollback, schema boundary and byte-exact archive restore');
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
async function lifePanelTest() {
  const { LifePanels, PanelRepository, NativePanelSourceReader } = load('services/LifePanels');
  const { LifePanelTools } = load('services/LifePanelTools');
  const { parsePanelSpec, panelValue, panelCells, panelDue } = load('model/LifePanel');
  const dir='/sandbox/panels', ws=new WorkspaceStore(dir), panels=new LifePanels(dir);
  fs.mkdirSync(disk(dir),{recursive:true}); await ws.ensureThread('panel-chat');
  const scoped=new NativeWorkspaceFiles(ws.pathFor('panel-chat')), repo=panels.repository('panel-chat');
  const spec={version:1,title:'Today',size:'L',data:{count:3,tasks:[{id:'walk',label:'Walk',done:false}],points:[1,3,2]},
    source:{type:'workspace-json',path:'data.json'},refreshMinutes:5,nodes:[
      {id:'row',kind:'Row'}, {id:'count',kind:'Metric',parent:'row',value:{path:'/data/count'},private:true},
      {id:'progress',kind:'Progress',value:{path:'/data/count'},max:{value:10}},
      {id:'tasks',kind:'Checklist',items:{path:'/data/tasks'}}, {id:'trend',kind:'Sparkline',value:{path:'/data/points'}}]};
  assert.equal(parsePanelSpec(JSON.stringify(spec)).size,'L');
  for(const change of [s=>s.version=2,s=>s.size='XL',s=>s.nodes[1].value.path='/data/missing',
    s=>s.nodes[1].parent='count',s=>s.data.count=Infinity,s=>s.nodes[1].value={path:'/data/count',value:1},
    s=>s.nodes[0].kind='Web',s=>s.nodes[1].decimals=5,s=>s.refreshMinutes=0,s=>s.data.tasks.push({...s.data.tasks[0]}),
    s=>s.source={type:'json-url',url:'https://user:password@example.com/data'}]) {
    const bad=plain(spec);change(bad);assert.throws(()=>parsePanelSpec(JSON.stringify(bad)));
  }
  assert.equal(panelValue({path:'/data/a~1b/~0x/0'},{'a/b':{'~x':[7]}},{}),7);
  assert.throws(()=>panelValue({path:'/data/__proto__'},{},{}),/Unsafe/);
  const cells=plain(panelCells(['S','L','M','S'],3));
  const occupied=new Set(); for(const cell of cells) for(let y=0;y<cell.rows;y++) for(let x=0;x<cell.columns;x++) {
    const key=`${cell.row+y}:${cell.column+x}`;assert.ok(!occupied.has(key));occupied.add(key);
  }
  assert.deepEqual(cells.map(c=>[c.columns,c.rows]),[[1,1],[2,2],[2,1],[1,1]]);
  await scoped.write('today.panel.json',JSON.stringify(spec),signal);
  await scoped.write('data.json',JSON.stringify(spec.data),signal);
  const tools=new LifePanelTools(panels,'panel-chat','deleted-thread',scoped);
  assert.equal((await invoke(tools,'get_life_panel_catalog',{})).version,1);
  const receipt=await invoke(tools,'publish_life_panel',{path:'today.panel.json'}), id=receipt.panelId;
  assert.equal(receipt.openFrom,'Life Panel');
  const readonly=new RuleTools(tools,true);
  assert.ok(!readonly.definitions().some(t=>t.function.name==='publish_life_panel'));
  assert.ok(readonly.definitions().some(t=>t.function.name==='list_life_panels'));
  await assert.rejects(invoke(readonly,'publish_life_panel',{path:'today.panel.json'}));
  await assert.rejects(scoped.write('life-panels/'+id+'/panel.json','{}',signal),/app-owned/);
  let record=await repo.get(id);assert.ok(panelDue(record,Date.now()));
  record=await repo.toggle(id,record.configRevision,'tasks','walk',true);
  await scoped.write('data.json',JSON.stringify({...spec.data,count:6}),signal);
  record=await repo.refresh(id,signal);assert.equal(record.data.count,6);assert.equal(record.user['tasks:walk'],true);
  assert.equal(panelDue(record,record.refreshedAt+299999),false);
  const goodTime=record.refreshedAt;
  await scoped.write('data.json','{"count":"bad"}',signal);
  await assert.rejects(repo.refresh(id,signal));record=await repo.get(id);
  assert.equal(record.data.count,6);assert.equal(record.refreshedAt,goodTime);assert.ok(record.error);
  assert.equal(panelDue(record,record.attemptedAt+299999),false,'Failed source retries wait for expiry');
  // Slow fetches coexist with checklist edits and coalesce across repository instances.
  let release, calls=0;const reader={read:async()=>{calls++;return await new Promise(r=>release=r);}};
  const managed={read:(...args)=>scoped.read(...args),write:(...args)=>scoped.writeLifePanel(...args)};
  const slow=new PanelRepository(managed,'slow-key',reader), second=new PanelRepository(managed,'slow-key',reader);
  const fetch=slow.refresh(id,new Cancellation());
  while(!release) await new Promise(r=>setTimeout(r,0));
  const duplicate=second.refresh(id,new Cancellation());assert.equal(fetch,duplicate);assert.equal(calls,1);
  await slow.toggle(id,record.configRevision,'tasks','walk',false);
  release({...spec.data,count:7});await fetch;
  assert.equal((await repo.get(id)).user['tasks:walk'],false);
  release=undefined;const obsolete=slow.refresh(id,new Cancellation());while(!release) await new Promise(r=>setTimeout(r,0));
  await repo.publish(id,{...spec,title:'New definition'},'today.panel.json','new-thread',true,signal);
  release({...spec.data,count:9});await assert.rejects(obsolete,/changed during refresh/);
  assert.equal((await repo.get(id)).definition.title,'New definition');assert.equal((await repo.get(id)).data.count,3);assert.equal((await repo.get(id)).error,'');
  release=undefined;const cancelled=new Cancellation(), work=slow.refresh(id,cancelled);
  while(!release) await new Promise(r=>setTimeout(r,0));cancelled.cancel();release({...spec.data,count:8});await assert.rejects(work);
  assert.equal((await repo.get(id)).data.count,3,'Background cancellation cannot commit late results');
  await repo.resize(id,'S');assert.equal((await repo.get(id)).definition.size,'S');
  await repo.archive(id,true);assert.equal(panelDue(await repo.get(id),Date.now()),false);await repo.archive(id,false);
  panelResponse=JSON.stringify({payload:spec.data});
  const httpSpec={...spec,source:{type:'json-url',url:'https://example.com/data',pointer:'/payload'}};
  assert.deepEqual(plain(await new NativePanelSourceReader(scoped).read(httpSpec,signal)),spec.data);
  panelResponse='<html>Sign in</html>';await assert.rejects(new NativePanelSourceReader(scoped).read(httpSpec,signal));
  // Mail snapshots use the same production reader, transforms, persistence and failure history.
  // Protocol and secure-account behavior are covered separately by test-mail.cjs.
  const {MailService}=load('services/MailService'), originalQuery=MailService.prototype.query;
  let mailFailure=false;
  MailService.prototype.query=async function(query,cancellation){cancellation.check();assert.equal(query.accountId,'mail-connection');if(mailFailure)throw Error('Mailbox access is disabled in Settings');return {unread:4,messages:[{id:'42:9',subject:'Delivery'}]};};
  try {
    const mailSpec={version:1,title:'Mail',size:'S',refreshMinutes:5,source:{type:'mail',mail:{accountId:'mail-connection',folder:'INBOX',limit:5},
      transform:{op:'object',fields:{count:{path:'/response/unread'}}}},data:{count:0},nodes:[{id:'count',kind:'Metric',value:{path:'/data/count'}}]};
    await repo.publish('mail-card',mailSpec,'mail.panel.json','deleted-chat',false,signal);
    const fresh=await repo.refresh('mail-card',signal);assert.equal(fresh.data.count,4);assert.equal(fresh.runs[0].status,'complete');
    mailFailure=true;await assert.rejects(repo.refresh('mail-card',signal),/disabled/);
    const retained=await repo.get('mail-card');assert.equal(retained.data.count,4);assert.equal(retained.refreshedAt,fresh.refreshedAt);assert.equal(retained.runs[0].status,'failed');
    await repo.archive('mail-card',true);
  } finally {MailService.prototype.query=originalQuery;}
  // No chat remains. Backup must retain panel-only workspaces and app-owned user edits.
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};
  fs.mkdirSync(disk(context.cacheDir));const {createBackupFile,readBackupFile}=load('services/Backup');
  const backup=await createBackupFile(context,emptyData());
  const restoreDir='/sandbox/panels-restored';fs.mkdirSync(disk(restoreDir));
  const target={filesDir:restoreDir,cacheDir:restoreDir,getApplicationContext(){return this;}};
  await readBackupFile(target,backup,emptyData());
  const restored=new LifePanels(restoreDir);assert.equal((await restored.list()).length,2);
  assert.equal((await restored.repository('panel-chat').get('mail-card')).definition.source.mail.accountId,'mail-connection');
  assert.deepEqual(plain(await restored.repository('panel-chat').get(id)),plain(await repo.get(id)));
  await restored.repository('panel-chat').toggle(id,(await repo.get(id)).configRevision,'tasks','walk',true);
  await readBackupFile(target,backup,emptyData());assert.equal((await restored.repository('panel-chat').get(id)).user['tasks:walk'],true);
  console.log('PASS Life Panel protocol, bindings, native sizing, tools/permissions, atomic user state, refresh deduplication, stale/cancelled results and orphan backup/restore');
}
async function lifePanelApiTest() {
  const {validatePanelSource}=load('model/PanelSource'), {validatePanelTransform,transformPanelData}=load('model/PanelTransform');
  const {PanelCredentials}=load('services/PanelCredentials'), {PanelApiTransport}=load('services/PanelApiTransport');
  const {LifePanels}=load('services/LifePanels');
  const expr={op:'object',fields:{
    total:{op:'sum',args:[{op:'map',args:[{path:'/response/rows'},{op:'number',args:[{path:'/item/amount'}]}]}]},
    average:{op:'round',args:[{op:'average',args:[{op:'map',args:[{path:'/response/rows'},{op:'number',args:[{path:'/item/amount'}]}]}]},{value:1}]},
    items:{op:'map',args:[{op:'slice',args:[{op:'filter',args:[{path:'/response/rows'},{op:'gt',args:[{op:'number',args:[{path:'/item/amount'}]},{value:0}]}]},{value:0},{value:5}]},
      {op:'object',fields:{id:{op:'string',args:[{path:'/item/id'}]},label:{op:'concat',args:[{path:'/item/name'},{value:' #'},{path:'/index'}]},value:{op:'string',args:[{path:'/item/amount'}]}}}]}
  }};
  validatePanelTransform(expr);
  const payload={rows:[{id:1,name:'One',amount:'12.5'},{id:2,name:'Two',amount:'0'},{id:3,name:'Three',amount:'7.5'}]};
  assert.deepEqual(plain(transformPanelData(payload,expr)),{total:20,average:6.7,items:[{id:'1',label:'One #0',value:'12.5'},{id:'3',label:'Three #1',value:'7.5'}]});
  for(const expression of [{op:'eval',args:[]},{path:'/response/__proto__'},{op:'add',args:[{value:1}]},
    {op:'map',args:[{path:'/response/rows'},{path:'/unavailable'}]}]) assert.throws(()=>validatePanelTransform(expression));
  for(const expression of [{op:'divide',args:[{value:1},{value:0}]},{op:'number',args:[{value:''}]},
    {op:'average',args:[{value:[]}]},{op:'filter',args:[{value:[1]},{value:1}]}]) assert.throws(()=>transformPanelData({},expression));
  let deep={value:1};for(let i=0;i<12;i++)deep={op:'string',args:[deep]};assert.throws(()=>validatePanelTransform(deep),/nesting/);
  assert.throws(()=>transformPanelData({text:'x'.repeat(150000),rows:[1,2,3]}, {op:'map',args:[{path:'/response/rows'},{path:'/response/text'}]}),/256 KiB/);
  const source={type:'api',url:'https://api.example.test/query',method:'POST',headers:{'X-Client':'Tinybot'},body:{period:'week'},
    auth:{type:'api-key',in:'header',name:'X-API-Key'},transform:expr};
  validatePanelSource(source);
  const catalog=JSON.parse(load('model/LifePanel').LIFE_PANEL_CATALOG);
  validatePanelSource({...source,transform:catalog.javascriptExample});
  for(const patch of [{method:'DELETE'},{method:'GET'},{url:'http://api.example.test/query'},{headers:{Host:'evil.test'}},
    {headers:{Authorization:'secret'}},{headers:{'X-Client':'bad\r\nheader'}},{headers:{a:'one',A:'two'}},
    {auth:{type:'oauth',oauth:{clientId:'x',authorizationEndpoint:'https://id.test/auth',tokenEndpoint:'http://id.test/token'}}}]) {
    assert.throws(()=>validatePanelSource({...source,...patch}));
  }
  const credentials=new PanelCredentials('private-namespace'), transport=new PanelApiTransport(credentials), id='api-panel';
  await assert.rejects(transport.read(id,source,new Cancellation()),/not connected/);
  await credentials.save(id,source,'fixture-api-secret');assert.equal(await credentials.connected(id,source),true);
  assert.equal(await credentials.connected(id,{...source,auth:{name:'x-api-key',in:'header',type:'api-key'}}),true,'Equivalent field ordering/header casing does not require reconnecting');
  assert.equal(await new PanelCredentials('other-workspace').connected(id,source),false);
  const changed={...source,url:'https://other.example.test/query'};
  assert.equal(await credentials.connected(id,changed),false);await assert.rejects(transport.read(id,changed,new Cancellation()),/not connected/);
  const bytes=value=>new TextEncoder().encode(JSON.stringify(value)).buffer;
  apiResponse={status:200,header:{},text:'',bytes:bytes(payload)};
  assert.deepEqual(JSON.parse(await transport.read(id,source,new Cancellation())),payload);
  assert.equal(apiRequest.method,'POST');assert.equal(apiRequest.redirect,'return');assert.equal(apiRequest.headers['X-API-Key'],'fixture-api-secret');
  assert.equal(apiRequest.headers['X-Client'],'Tinybot');assert.equal(apiRequest.headers['Content-Type'],'application/json');assert.deepEqual(JSON.parse(apiRequest.body),{period:'week'});
  const query={...source,method:'GET',body:undefined,auth:{type:'api-key',in:'query',name:'key'}};
  await credentials.save(id,query,'a+b/c=');await transport.read(id,query,new Cancellation());assert.ok(apiRequest.url.endsWith('?key=a%2Bb%2Fc%3D'));
  const bearer={...source,auth:{type:'bearer'}};await credentials.save(id,bearer,'bearer-secret');await transport.read(id,bearer,new Cancellation());
  assert.equal(apiRequest.headers.Authorization,'Bearer bearer-secret');
  for(const status of [302,401,403,500]) {apiResponse={...apiResponse,status};await assert.rejects(transport.read(id,bearer,new Cancellation()),/redirect|authentication|HTTP/);}
  apiHandler=async()=>{throw Error('request included fixture-api-secret bearer-secret a+b/c=');};
  await assert.rejects(transport.read(id,bearer,new Cancellation()),error=>!error.message.includes('secret')&&error.message.includes('transport failed'));
  let release;apiHandler=async()=>await new Promise(r=>release=r);const cancelled=new Cancellation(),pending=transport.read(id,bearer,cancelled);
  while(!release)await new Promise(r=>setTimeout(r,0));cancelled.cancel();await assert.rejects(pending);assert.equal(apiStop,true);release(apiResponse);
  apiHandler=async()=>apiResponse;apiResponse={status:200,header:{},text:'',bytes:bytes(payload)};
  const dir='/sandbox/api-panels',ws=new WorkspaceStore(dir);fs.mkdirSync(disk(dir),{recursive:true});await ws.ensureThread('api-workspace');
  const panels=new LifePanels(dir),repo=panels.repository('api-workspace'), vault=panels.credentials('api-workspace');
  const spec={version:1,title:'API data',size:'L',data:{total:0,average:0,items:[]},source,nodes:[
    {id:'total',kind:'Metric',value:{path:'/data/total'}},{id:'items',kind:'ItemList',items:{path:'/data/items'}}]};
  await repo.publish(id,spec,'api.panel.json','deleted-chat',false,new Cancellation());await vault.save(id,source,'device-only-secret');
  let result=await repo.refresh(id,new Cancellation());assert.equal(result.data.total,20);assert.equal(result.data.items[0].id,'1');
  apiResponse={...apiResponse,bytes:bytes({rows:[{amount:'invalid'}]})};await assert.rejects(repo.refresh(id,new Cancellation()));
  result=await repo.get(id);assert.equal(result.data.total,20);assert.ok(result.error);
  assert.ok(!JSON.stringify((await panels.list())).includes('device-only-secret'));
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};fs.mkdirSync(disk(context.cacheDir));
  const backup=await load('services/Backup').createBackupFile(context,emptyData());
  const archive=legacyBackupFixture(fs.readFileSync(disk(backup)));assert.ok(!JSON.stringify(archive).includes('device-only-secret'));
  await vault.disconnect(id);assert.equal(await vault.connected(id,source),false);await credentials.disconnect(id);
  console.log('PASS authenticated GET/POST, API key headers/query, bearer, scoped secure credentials, redirect/error redaction, cancellation, transforms and credential-free backup');
}
async function lifePanelScriptTest() {
  const {validatePanelSource}=load('model/PanelSource');
  const {LifePanels,NativePanelSourceReader}=load('services/LifePanels');
  const {PanelDataTransform}=load('services/PanelDataTransform');
  const {NativeCodeExecutor}=load('services/NativeCodeExecutor');
  const transform={type:'javascript',code:'return { total: input.orders.reduce((sum, order) => sum + Number(order.amount), 0), items: input.orders.map(order => ({id:String(order.id), label:order.name})) };'};
  const source={type:'workspace-json',path:'orders.json',pointer:'/payload',transform};
  validatePanelSource(source);
  for(const invalid of [{type:'javascript',code:''},{type:'javascript',code:5},{type:'typescript',code:'return {};'},
    {type:'javascript',code:'return {};',op:'object'},{type:'javascript',code:'return {};',path:'transform.js'},
    {type:'javascript',code:' '.repeat(64*1024)+'return {};'},null]) assert.throws(()=>validatePanelSource({...source,transform:invalid}));
  const dir='/sandbox/script-panels',ws=new WorkspaceStore(dir);fs.mkdirSync(disk(dir),{recursive:true});await ws.ensureThread('script-chat');
  const scoped=new NativeWorkspaceFiles(ws.pathFor('script-chat')),panels=new LifePanels(dir),repo=panels.repository('script-chat');
  const input={orders:[{id:1,name:'First',amount:'12.5'},{id:2,name:'Second',amount:'7.5'}]};
  await scoped.write('orders.json',JSON.stringify({payload:input,authorization:'not-exposed'}),signal);
  const spec={version:1,title:'Script data',size:'L',source:plain(source),data:{total:0,items:[{id:'1',label:'First'}]},
    nodes:[{id:'total',kind:'Metric',value:{path:'/data/total'}},{id:'tasks',kind:'Checklist',items:{path:'/data/items'}}]};
  await repo.publish('script',spec,'script.panel.json','removed-chat',false,signal);
  spec.source.transform.code='throw Error("mutated source");';
  let record=await repo.refresh('script',signal);assert.equal(record.data.total,20);assert.equal(record.data.items[0].id,'1');
  assert.equal(record.definition.source.transform.code,transform.code,'Publication freezes the script without a live workspace dependency');
  assert.deepEqual(JSON.parse(panelScriptCalls.at(-1).inputJson),input,'Only pointer-selected response data reaches the script');
  await repo.toggle('script',record.configRevision,'tasks','1',true);await repo.refresh('script',signal);
  record=await repo.get('script');assert.equal(record.user['tasks:1'],true);
  const previous=plain(record.data),updatedAt=record.refreshedAt;
  for(const output of [{status:'timeout',error:'Execution exceeded 2 seconds'}, {status:'memory_limit',error:'32 MiB limit exceeded'},
    {status:'unsupported_async',error:'Promise result'}, {status:'error',error:'ReferenceError: missing is not defined'},
    {status:'ok',result:{total:9,items:[]},resultTruncated:true},{status:'ok'}, {status:'ok',result:42},
    {status:'ok',result:null},{status:'ok',result:{text:'x'.repeat(256*1024)}},{status:'ok',result:{text:'x'.repeat(600*1024)}},{status:'ok',result:{total:'bad',items:[]}}]) {
    panelScriptHandler=async()=>JSON.stringify(output);
    await assert.rejects(repo.refresh('script',signal));record=await repo.get('script');
    assert.deepEqual(plain(record.data),previous);assert.equal(record.refreshedAt,updatedAt);assert.equal(record.user['tasks:1'],true);assert.ok(record.error);
  }
  const runner=new PanelDataTransform(new NativeCodeExecutor());panelScriptHandler=undefined;
  await assert.rejects(runner.run(input,{type:'javascript',code:'return ('},signal,'syntax'),/JavaScript transform failed/);
  await assert.rejects(runner.run(input,{type:'javascript',code:'return Promise.resolve({total:1});'},signal,'async'),/unsupported_async/);
  await assert.rejects(runner.run(input,{type:'javascript',code:'throw Error("bad response field");'},signal,'throws'),/bad response field/);
  for(let i=0;i<2;i++)assert.equal((await runner.run(input,{type:'javascript',code:'globalThis.count=(globalThis.count||0)+1; return {count};'},signal,'fresh')).count,1);
  // Late script results cannot commit after background cancellation or definition replacement.
  let release;panelScriptHandler=async()=>await new Promise(r=>release=r);
  const stop=new Cancellation(),cancelled=repo.refresh('script',stop);
  while(!release)await new Promise(r=>setTimeout(r,0));stop.cancel();release(JSON.stringify({status:'ok',result:{total:999,items:[]}}));await assert.rejects(cancelled);
  assert.deepEqual(plain((await repo.get('script')).data),previous);
  release=undefined;const obsolete=repo.refresh('script',new Cancellation());while(!release)await new Promise(r=>setTimeout(r,0));
  const next={...spec,source:{...source,transform:{type:'javascript',code:'return {total:42,items:[]};'}}};
  await repo.publish('script',next,'script.panel.json','new-chat',true,signal);
  release(JSON.stringify({status:'ok',result:{total:999,items:[]}}));await assert.rejects(obsolete,/changed during refresh/);
  assert.equal((await repo.get('script')).definition.source.transform.code,next.source.transform.code);
  panelScriptHandler=undefined;record=await repo.refresh('script',signal);assert.equal(record.data.total,42);
  const fresh=await new NativePanelSourceReader(scoped).read(next,signal,'reopened');assert.equal(fresh.total,42);
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};fs.mkdirSync(disk(context.cacheDir));
  const {createBackupFile,readBackupFile}=load('services/Backup'), backup=await createBackupFile(context,emptyData());
  const targetDir='/sandbox/script-restored';fs.mkdirSync(disk(targetDir));const target={filesDir:targetDir,cacheDir:targetDir,getApplicationContext(){return this;}};
  await readBackupFile(target,backup,emptyData());const restored=new LifePanels(targetDir).repository('script-chat');
  assert.equal((await restored.get('script')).definition.source.transform.code,next.source.transform.code);
  assert.equal((await restored.refresh('script',signal)).data.total,42,'Backup restores executable transforms after source chat deletion');
  console.log('PASS JavaScript transform contract, response-only input, publication snapshot, validation/errors/limits, user state, cancellation, obsolete results and backup execution');
}
async function lifeBoardsTest() {
  const {LifePanels}=load('services/LifePanels'),{LifeBoards}=load('services/LifeBoards'),{LifePanelTools}=load('services/LifePanelTools');
  const {publishedPanels}=load('model/PublishedPanel'),{parsePanelTarget}=load('model/LifeBoard'),{panelDue}=load('model/LifePanel');
  const dir='/sandbox/boards',ws=new WorkspaceStore(dir),panels=new LifePanels(dir),boards=new LifeBoards(dir);
  fs.mkdirSync(disk(dir),{recursive:true});for(const id of ['owner','another-chat','empty-board'])await ws.ensureThread(id);
  const spec={version:1,title:'Shared tasks',size:'L',data:{tasks:[{id:'one',label:'One'}]},nodes:[{id:'tasks',kind:'Checklist',items:{path:'/data/tasks'}}]};
  const repo=panels.repository('owner');await repo.publish('shared',spec,'shared.panel.json','deleted-chat',false,signal);
  await repo.publish('other',spec,'other.panel.json','deleted-chat',false,signal);
  const first=await boards.save('owner','','Work','Shared project'),second=await boards.save('another-chat','','Life','');
  const empty=await boards.save('empty-board','','Empty','Retain after chat deletion');
  const reference={workspaceId:'owner',panelId:'shared'};
  await Promise.all([boards.pin('owner',first.id,reference,true),boards.pin('owner',first.id,{workspaceId:'owner',panelId:'other'},true)]);
  await boards.pin('another-chat',second.id,reference,true);
  assert.equal((await boards.get('owner',first.id)).items.length,2,'Concurrent pins do not lose references');
  await boards.arrange('owner',first.id,{workspaceId:'owner',panelId:'other'},'owner/shared','S');
  const ordered=await new LifeBoards(dir).get('owner',first.id);assert.equal(ordered.items[0].panelId,'other');assert.equal(ordered.items[0].size,'S');
  assert.equal((await boards.get('another-chat',second.id)).items[0].size,'L','Sizes belong to each board');
  await repo.toggle('shared',1,'tasks','one',true);assert.equal((await panels.repository('owner').get((await boards.get('another-chat',second.id)).items[0].panelId)).user['tasks:one'],true);
  await boards.pin('owner',first.id,reference,false);assert.ok((await repo.get('shared')).user['tasks:one'],'Unpin never deletes data or shared card');
  await assert.rejects(boards.save('owner',first.id,'Work','',[{workspaceId:'owner',panelId:'shared',size:'XL'}]));
  await assert.rejects(boards.save('owner',first.id,'Work','',[{...reference,size:'S'},{...reference,size:'M'}]));
  const files=new NativeWorkspaceFiles(ws.pathFor('another-chat'));
  const tools=new LifePanelTools(panels,'another-chat','new-chat',files,boards);
  await files.write('update.panel.json',JSON.stringify({...spec,title:'Edited from another chat'}),signal);
  const receipt=await invoke(tools,'publish_life_panel',{path:'update.panel.json',panelId:'shared',workspaceId:'owner',boardId:second.id,boardWorkspaceId:'another-chat'});
  assert.equal(receipt.workspaceId,'owner');assert.equal((await repo.get('shared')).definition.title,'Edited from another chat');
  assert.equal((await repo.get('shared')).user['tasks:one'],true);assert.equal((await boards.get('another-chat',second.id)).items.length,1);
  const links=plain(publishedPanels([{content:'',tools:[{status:'complete',call:{id:'pub',function:{name:'publish_life_panel'}},output:JSON.stringify(receipt)}]}]));
  assert.equal(links[0].target.panelId,'shared');assert.equal(parsePanelTarget(JSON.stringify(links[0].target)).workspaceId,'owner');
  const readonly=new RuleTools(tools,true);
  for(const name of ['manage_life_board','manage_life_panel_task','publish_life_panel'])assert.ok(!readonly.definitions().some(tool=>tool.function.name===name));
  assert.equal((await invoke(tools,'list_life_boards',{})).length,3);
  await invoke(tools,'manage_life_board',{action:'save',boardId:second.id,workspaceId:'another-chat',title:'Renamed'});
  assert.equal((await boards.get('another-chat',second.id)).items.length,1);
  await invoke(tools,'manage_life_board',{action:'archive',boardId:second.id,workspaceId:'another-chat'});assert.equal((await boards.get('another-chat',second.id)).archived,true);
  await invoke(tools,'manage_life_board',{action:'restore',boardId:second.id,workspaceId:'another-chat'});
  // Independent Agent runs survive source chat deletion and keep data/user state separate.
  let agentCalls=0,release,slow=false;
  panels.installAgent(async(workspaceId,id,definition,data,cancellation)=>{
    assert.equal(workspaceId,'owner');assert.equal(id,'agent');assert.equal(definition.source.type,'agent');agentCalls++;
    if(slow)await new Promise(r=>release=r);cancellation.check();return {count:agentCalls};
  });
  const agentSpec={version:1,title:'Agent summary',size:'S',source:{type:'agent',prompt:'Read the project data and count current items.'},refreshMinutes:15,
    data:{count:0},nodes:[{id:'count',kind:'Metric',value:{path:'/data/count'}}]};
  await repo.publish('agent',agentSpec,'agent.panel.json','deleted-thread',false,signal);
  await repo.refresh('agent',signal);let record=await repo.get('agent');assert.equal(record.data.count,1);assert.equal(record.runs[0].status,'complete');
  await invoke(tools,'manage_life_panel_task',{workspaceId:'owner',panelId:'agent',action:'pause'});
  assert.equal(panelDue(await repo.get('agent'),Date.now()+999999999),false);
  await invoke(tools,'manage_life_panel_task',{workspaceId:'owner',panelId:'agent',action:'refresh'});assert.equal((await repo.get('agent')).data.count,2,'Manual refresh still works while paused');
  await invoke(tools,'manage_life_panel_task',{workspaceId:'owner',panelId:'agent',action:'resume'});
  slow=true;const running=repo.refresh('agent',signal);while(!release)await new Promise(r=>setTimeout(r,0));
  await repo.pause('agent',true);release();await running;assert.equal((await repo.get('agent')).runs[0].status,'complete','Pause only stops automatic work; an explicit manual refresh completes');
  slow=false;await repo.pause('agent',false);for(let i=0;i<11;i++)await repo.refresh('agent',signal);
  assert.equal((await repo.get('agent')).runs.length,10);
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};fs.mkdirSync(disk(context.cacheDir));
  const {createBackupFile,readBackupFile}=load('services/Backup'),backup=await createBackupFile(context,emptyData());
  const dest='/sandbox/boards-restored';fs.mkdirSync(disk(dest));const target={filesDir:dest,cacheDir:dest,getApplicationContext(){return this;}};
  await readBackupFile(target,backup,emptyData());const restored=new LifeBoards(dest);
  assert.equal((await restored.list()).length,3);assert.equal((await restored.get('empty-board',empty.id)).items.length,0);
  assert.deepEqual(plain(await restored.get('owner',first.id)),plain(await boards.get('owner',first.id)));
  assert.equal((await new LifePanels(dest).repository('owner').get('agent')).runs.length,10);
  await restored.pin('another-chat',second.id,reference,false);await readBackupFile(target,backup,emptyData());
  assert.equal((await restored.get('another-chat',second.id)).items.length,0,'Repeated restore preserves local layout');
  const projectData=emptyData();projectData.threads=[];projectData.projects=[{id:'p',name:'Project',workspaceId:'owner',instructions:'',createdAt:1,updatedAt:1}];
  const projectBackup=await createBackupFile(context,projectData),projectDir='/sandbox/boards-project-restored';fs.mkdirSync(disk(projectDir));
  const projectTarget={filesDir:projectDir,cacheDir:projectDir,getApplicationContext(){return this;}};
  const projectRestored=await readBackupFile(projectTarget,projectBackup,emptyData());
  const migrated=await new LifeBoards(projectDir).get('another-chat',second.id);
  assert.equal(migrated.items[0].workspaceId,projectRestored.projects[0].workspaceId,'Cross-board references follow restored project workspace remapping');
  assert.equal((await new LifePanels(projectDir).repository(migrated.items[0].workspaceId).get('shared')).user['tasks:one'],true);
  console.log('PASS multi-board references, per-board layout, concurrent pins, cross-chat editing, chat receipts, task pause/history/Agent runner and orphan board backup');
}
async function lifePanelRecoveryTest() {
  const {LifePanels,PanelRepository}=load('services/LifePanels'),{LifePanelTools}=load('services/LifePanelTools');
  const dir='/sandbox/panel-recovery',ws=new WorkspaceStore(dir),panels=new LifePanels(dir);fs.mkdirSync(disk(dir),{recursive:true});
  for(const id of ['owner','editor'])await ws.ensureThread(id);
  const ownerFiles=new NativeWorkspaceFiles(ws.pathFor('owner')),editorFiles=new NativeWorkspaceFiles(ws.pathFor('editor'));
  const spec={version:1,title:'Local count',size:'S',source:{type:'workspace-json',path:'data.json'},refreshMinutes:1,data:{count:1},nodes:[{id:'count',kind:'Metric',value:{path:'/data/count'}}]};
  await ownerFiles.write('data.json','{"count":1}',signal);await editorFiles.write('data.json','{"count":99}',signal);
  const repo=panels.repository('owner');await repo.publish('counter',spec,'count.panel.json','owner',false,signal);
  const tools=new LifePanelTools(panels,'editor','editor',editorFiles);
  await editorFiles.write('new.panel.json',JSON.stringify({...spec,data:{count:99}}),signal);
  await assert.rejects(invoke(tools,'publish_life_panel',{path:'new.panel.json',panelId:'counter',workspaceId:'owner'}),/source.*workspaceId|source workspace/i,
    'Cross-chat publication must reject ambiguous local source paths before changing the card');
  assert.equal((await repo.get('counter')).data.count,1);
  await editorFiles.write('new.panel.json',JSON.stringify({...spec,source:{...spec.source,workspaceId:'editor'},data:{count:99}}),signal);
  await invoke(tools,'publish_life_panel',{path:'new.panel.json',panelId:'counter',workspaceId:'owner'});
  assert.equal((await repo.refresh('counter',signal)).data.count,99,'Refresh uses the explicitly bound source workspace');
  let reads=0;const testRepo=new PanelRepository(repo.files,ws.pathFor('owner'),{read:async()=>{reads++;return {count:7};}});
  await testRepo.publish('queued',spec,'queued.panel.json','owner',false,signal);await testRepo.pause('queued',true);
  await testRepo.refresh('queued',signal,'automatic');assert.equal(reads,0,'A paused queued automatic refresh is skipped without running the source');
  assert.equal((await testRepo.get('queued')).runs.length,0,'A skipped task does not create a failed run');
  await testRepo.refresh('queued',signal);assert.equal(reads,1,'Manual refresh remains available while automatic work is paused');
  await testRepo.pause('queued',false);await testRepo.refresh('queued',signal,'automatic');assert.equal(reads,1,'A just-refreshed card is no longer due even if the scheduler snapshot was stale');
  let release;const blocked=new PanelRepository(repo.files,ws.pathFor('owner'),{read:async()=>await new Promise(resolve=>release=resolve)});
  await blocked.publish('automatic',spec,'auto.panel.json','owner',false,signal);
  const automatic=blocked.refresh('automatic',signal,'automatic'),cancelled=assert.rejects(automatic);
  while(!release)await new Promise(resolve=>setTimeout(resolve,0));await blocked.pause('automatic',true);release({count:8});await cancelled;
  const stopped=await blocked.get('automatic');assert.equal(stopped.data.count,1);assert.equal(stopped.runs[0].status,'cancelled');assert.equal(stopped.runs[0].trigger,'automatic');
  const summary=await invoke(tools,'list_life_panels',{limit:1});assert.equal(summary.items.length,1);assert.ok(summary.nextCursor);
  assert.ok(!('definition' in summary.items[0]));assert.ok(!('data' in summary.items[0]));
  const detail=await invoke(tools,'get_life_panel',{workspaceId:'owner',panelId:'counter'});assert.equal(detail.panel.data.count,99);
  const pageTwo=await invoke(tools,'list_life_panels',{limit:1,cursor:summary.nextCursor});assert.equal(pageTwo.items.length,1);assert.notEqual(pageTwo.items[0].panelId,summary.items[0].panelId);
  await assert.rejects(invoke(tools,'list_life_panels',{archived:true,cursor:summary.nextCursor}),/Cursor/);
  const {WorkspaceRetention}=load('services/WorkspaceRetention'),ownership=await WorkspaceRetention.inventory(ws.rootDir);
  assert.ok(WorkspaceRetention.retained(emptyData(),ownership).has('editor'),'A card keeps its external local source workspace alive');
  const context={filesDir:dir,cacheDir:dir+'/cache',getApplicationContext(){return this;}};fs.mkdirSync(disk(context.cacheDir));
  const {createBackupFile,readBackupFile}=load('services/Backup'),backup=await createBackupFile(context,emptyData());
  const dest='/sandbox/panel-recovery-restored';fs.mkdirSync(disk(dest));const target={filesDir:dest,cacheDir:dest,getApplicationContext(){return this;}};
  await readBackupFile(target,backup,emptyData());assert.equal((await new LifePanels(dest).repository('owner').refresh('counter',signal)).data.count,99,'Backup restores bound source files without either source chat');
  const projectData=emptyData();projectData.projects=[{id:'source-project',workspaceId:'editor',name:'Source project',instructions:'',createdAt:1,updatedAt:1}];
  const projectBackup=await createBackupFile(context,projectData),projectDir='/sandbox/panel-recovery-project';fs.mkdirSync(disk(projectDir));
  const projectTarget={filesDir:projectDir,cacheDir:projectDir,getApplicationContext(){return this;}};
  const restored=await readBackupFile(projectTarget,projectBackup,emptyData()),restoredRepo=new LifePanels(projectDir).repository('owner');
  assert.equal((await restoredRepo.get('counter')).definition.source.workspaceId,restored.projects[0].workspaceId);
  assert.equal((await restoredRepo.refresh('counter',signal)).data.count,99,'Explicit sources follow project workspace remapping');
  const saved=await repo.get('counter');
  for(let i=0;i<51;i++) {
    const id='arch-'+String(i).padStart(2,'0'),folder=disk(ws.pathFor('owner')+'/life-panels/'+id);fs.mkdirSync(folder,{recursive:true});
    fs.writeFileSync(path.join(folder,'panel.json'),JSON.stringify({...saved,id,archived:true}));
  }
  const emptyPage=await panels.page({limit:1});assert.equal(emptyPage.items.length,0);assert.ok(emptyPage.nextCursor,'Bounded scans can return an empty page with a continuation cursor');
  const continued=await panels.page({limit:1,cursor:emptyPage.nextCursor});assert.equal(continued.items.length,1);
  console.log('PASS explicit cross-chat sources, fresh automatic admission, manual refresh while paused, and summary/detail tools');
}
const run=process.argv.includes('--lifecycle')?lifePanelRecoveryTest():main().then(lifePanelTest).then(lifePanelApiTest).then(lifePanelScriptTest).then(lifeBoardsTest).then(lifePanelRecoveryTest);
Promise.resolve(run).catch(error=>{console.error(error);process.exitCode=1;});
