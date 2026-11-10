const backupAccount = { openID: 'fixture-openid-A', checks: 0, async backupOpenID() {
  this.checks++;
  if (!this.openID) throw Error('请先登录华为账号，再备份或恢复。');
  return this.openID;
} };
const { legacyBackupFixture, backupCrypto } = require('./backup-fixture.cjs');
// Platform-adapter integration tests with real temporary files and a scripted HTTP transport.
// Run: node scripts/test-productivity-native.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.resolve(__dirname, '../entry/src/main/ets');
const fixture = path.resolve(__dirname, '../.hvigor/native-productivity-' + crypto.randomUUID());
fs.mkdirSync(fixture, { recursive: true });
const handles = new Map(), handlePaths = new Map(), writableHandles = new Set(); let failManifest = false; let failSharedRename = false;
let failConversationWorker = false;
let sharedWriteFailure = ''; let cancelSharedWrite; let failBackupRename = false; const usageWrites = [];
let beforeUsageOpen;
const folderFailures = {};
let pdfKitLoads = 0;
const cloudLocations = new Map(); let failCloudCopy = false, failCloudRename = false, failCloudRollback = false, failCloudFsync = false; let cloudCopyError;
const nativePath = p => {
  if (typeof p === "number") return handlePaths.get(p);
  if (p.startsWith('file://')) p = decodeURIComponent(new URL(p).pathname);
  return p.startsWith('/sandbox/') ? path.join(fixture, p.slice(1)) : p;
};
const fileIo = {
  rmdir: async p => {
    const target = path.resolve(nativePath(p));
    assert.ok(target.startsWith(fixture + path.sep));
    await fs.promises.rm(target, { recursive: true });
  },
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8, NOFOLLOW: 16, READ_WRITE: 32 },
  access: async p => fs.existsSync(nativePath(p)), mkdir: (p, recursive = false) => fs.promises.mkdir(nativePath(p), { recursive }), readText: p => fs.promises.readFile(nativePath(p), 'utf8'),
  listFile: async p => fs.promises.readdir(nativePath(p)),
  open: async (p, flags) => {
    if (beforeUsageOpen && p.includes('/usage-records/') && p.endsWith('.tmp')) await beforeUsageOpen(p);
    if(p.startsWith('file://') && flags & 2 && !fs.existsSync(nativePath(p)))throw Object.assign(Error('URI provider cannot create a missing file'),{code:13900002});
    const mode = flags & 32 ? fs.constants.O_RDWR | (flags & 2 ? fs.constants.O_CREAT : 0) : flags & 4 ? 'w' : 'r';
    const h = await fs.promises.open(nativePath(p), mode).catch(error=>{if(error.code==='ENOENT')error.code=13900002;throw error;});
    handles.set(h.fd, h); handlePaths.set(h.fd, nativePath(p)); if(flags & 36)writableHandles.add(h.fd); return { fd: h.fd };
  },
  read: async (fd, bytes) => (await handles.get(fd).read(new Uint8Array(bytes))).bytesRead,
  write: async (fd, bytes, options) => {
    if(cancelSharedWrite && handlePaths.get(fd).includes('external')) {
      await handles.get(fd).write(new Uint8Array(bytes).slice(0,3),0,3,options.offset);
      cancelSharedWrite.cancel();cancelSharedWrite=undefined;return 3;
    }
    if(sharedWriteFailure==='write' && handlePaths.get(fd).includes('external')) {
      await handles.get(fd).write(new Uint8Array(bytes).slice(0,3),0,3,options.offset);
      throw Object.assign(Error('injected partial shared write'), {code:13900005});
    }
    return (await handles.get(fd).write(new Uint8Array(bytes), 0, bytes.byteLength, options.offset)).bytesWritten;
  },
  close: async file => { const fd = typeof file === 'number' ? file : file.fd; const external=handlePaths.get(fd)?.includes('external')&&writableHandles.has(fd); await handles.get(fd).close(); handles.delete(fd);handlePaths.delete(fd);writableHandles.delete(fd); if(external&&sharedWriteFailure==='close')throw Object.assign(Error('injected shared close failure'),{code:13900005}); },
  stat: async file => {
    const stat = await (typeof file === 'number' ? handles.get(file).stat() : fs.promises.stat(nativePath(file)));
    stat.location = cloudLocations.get(file) ?? 1;
    stat.mtime = Math.floor(stat.mtimeMs / 1000);
    return stat;
  },
  lstat: async p => {
    try {
      const stat = await fs.promises.lstat(nativePath(p));
      // The device's lstat result lacks the native FileInfo required by this getter.
      Object.defineProperty(stat, 'location', { get() { throw Error('lstat.location causes a native crash; use stat(path).location'); } });
      return stat;
    } catch(e) { if(e.code==='ENOENT')e.code=13900002;throw e; }
  },
  copyFile: async (a,b) => { if (cloudCopyError) throw cloudCopyError; if (failCloudCopy) { fs.writeFileSync(nativePath(b),'partial'); throw Error('injected cloud write failure'); } await fs.promises.copyFile(nativePath(a),nativePath(b)); },
  fsync: async fd => { if(failCloudFsync && handlePaths.get(fd).endsWith('.partial'))throw Error('injected cloud flush failure'); if(sharedWriteFailure==='fsync' && handlePaths.get(fd).includes('external'))throw Object.assign(Error('injected shared fsync failure'),{code:13900005});await handles.get(fd).sync(); },
  truncate: async (fd,len) => { if(sharedWriteFailure==='truncate' && handlePaths.get(fd).includes('external'))throw Object.assign(Error('injected shared truncate failure'),{code:13900005});await handles.get(fd).truncate(len); },
  unlink: p => fs.promises.unlink(nativePath(p)),
  rename: async (a,b) => {
    // Unlike open(), the native rename API takes paths only. Do not normalize picker URIs here.
    if (a.startsWith('file://') || b.startsWith('file://')) throw Object.assign(Error('No such file or directory'), { code: 13900002 });
    if (failSharedRename && a.includes('external')) throw Object.assign(Error('injected shared rename failure'), { code: 13900012 });
    if (failBackupRename && b.includes('/.tinybot-review/')) throw Object.assign(Error('injected backup rename failure'), {code:13900025});
    if (failManifest && b.endsWith('/index.json')) { throw new Error('injected manifest failure'); }
    if(b.includes("/usage-records/"))usageWrites.push(b);
    if (b.includes('/tinybot-backups/') && fs.existsSync(nativePath(b))) throw Object.assign(Error('Invalid argument'), {code:13900020});
    if (failCloudRename && a.endsWith('.partial') && b.endsWith('tinybot-latest.tinybot')) throw Error('injected cloud rename failure');
    if (failCloudRollback && a.endsWith('.tinybot') && b.endsWith('tinybot-latest.tinybot')) throw Error('injected cloud rollback failure');
    await fs.promises.rename(nativePath(a),nativePath(b));
    if (cloudLocations.has(a)) { cloudLocations.set(b, cloudLocations.get(a)); cloudLocations.delete(a); }
    if (b.endsWith('tinybot-latest.tinybot')) cloudLocations.set(b,1);
  }
};
// Reproduce the empty-input behavior observed on the physical HarmonyOS device.
class Encoder { encodeInto(s) { return s === '' ? undefined : new TextEncoder().encode(s); } }
// Harmony uses ignoreBOM=true to remove the marker, unlike Node's WHATWG decoder.
class Decoder { constructor(encoding, opts) { this.decoder = new TextDecoder(encoding, {...opts, ignoreBOM: !opts?.ignoreBOM}); } decodeToString(bytes, opts) { return this.decoder.decode(bytes, opts); } }
const cache = new Map(); const calls = []; let httpScript = () => {}; let destroyed = 0; let jsonScript = () => { throw Error('Unexpected JSON request'); };
let fakeTimers;
const scheduleTimer = (fn, ms) => fakeTimers ? fakeTimers.set(fn, ms) : setTimeout(fn, ms);
const cancelTimer = id => fakeTimers ? fakeTimers.clear(id) : clearTimeout(id);
let selectedFile = '/sandbox/backup-export.json';
let pickerCalls = 0;
let webDavSession;
let cloudStart = () => {}, cacheStart = () => {};
const syncInstances = [], cacheInstances = [];
const cloudSync = {
  SyncState: { UPLOADING:0, UPLOAD_FAILED:1, DOWNLOADING:2, DOWNLOAD_FAILED:3, COMPLETED:4, STOPPED:5 },
  ErrorType: { NO_ERROR:0, NETWORK_UNAVAILABLE:1, WIFI_UNAVAILABLE:2, BATTERY_LEVEL_LOW:3, BATTERY_LEVEL_WARNING:4, CLOUD_STORAGE_FULL:5, LOCAL_STORAGE_FULL:6, DEVICE_TEMPERATURE_TOO_HIGH:7, REMOTE_SERVER_ABNORMAL:8 },
  State: { RUNNING:0, COMPLETED:1, FAILED:2, STOPPED:3 }, DownloadErrorType: { NO_ERROR:0 },
  FileSync: class {
    constructor() { syncInstances.push(this); }
    on(event,callback) { this.callback=callback;queueMicrotask(()=>this.callback?.({state:4,error:0})); }
    off(event,callback) { assert.equal(callback,this.callback);this.callback=undefined; }
    async start() { await cloudStart(this); }
  },
  CloudFileCache: class {
    constructor() { cacheInstances.push(this); }
    on(event,callback) { this.callback=callback; }
    off(event,callback) { assert.equal(callback,this.callback);this.callback=undefined; }
    async start(uri) { this.uri=uri;await cacheStart(this); }
    async stop(uri) { assert.equal(uri,this.uri);this.stopped=true; }
  }
};
const http = { RequestMethod: { POST: 'POST', GET: 'GET' }, HttpDataType: { STRING: 'string', ARRAY_BUFFER: 'buffer' }, createHttp: () => {
  const handlers = {}; let closed = false;
  return { on: (name, fn) => { handlers[name] = fn; }, destroy: () => { closed = true; destroyed++; },
    request: async (url, options) => jsonScript(url, options),
    requestInStream: (url, options, callback) => {
      calls.push({ url, options, body: JSON.parse(options.extraData) });
      httpScript({ url, options, callback, emit: (name, value) => { if (!closed) handlers[name]?.(value); } });
    } };
} };
const backupPreferenceStores = new Map();
const kits = {
  '@kit.ArkData': { preferences: { getPreferencesSync(context, options) {
    const key = context.getApplicationContext().filesDir + '/' + options.name;
    if (!backupPreferenceStores.has(key)) backupPreferenceStores.set(key, new Map());
    const values = backupPreferenceStores.get(key);
    return { getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
      putSync: (key, value) => values.set(key, value), deleteSync: key => values.delete(key), flushSync() {} };
  } } },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
  '@kit.CoreFileKit': { fileIo, cloudSync,
    fileShare: { OperationMode: { READ_MODE: 1, WRITE_MODE: 2 },
      checkPersistentPermission: async policies => policies.map(policy => folderFailures.grants ? folderFailures.grants.has(policy.uri) : true),
      persistPermission: async () => { if (folderFailures.persist) throw folderFailures.persist; },
      activatePermission: async () => { folderFailures.activations = (folderFailures.activations || 0) + 1; if (folderFailures.activate) throw folderFailures.activate; },
      revokePermission: async () => { if (folderFailures.revoke) throw folderFailures.revoke; } },
    fileUri: {getUriFromPath:p=>'file://'+p, FileUri: class { constructor(uri) { this.path = decodeURIComponent(new URL(uri).pathname); } }},
    picker: { DocumentViewPicker: class { async save() {pickerCalls++;return [selectedFile];} async select() {pickerCalls++;return [selectedFile];} } } }, '@kit.ImageKit': { image: {} }, '@kit.NetworkKit': { http },
  '@kit.RemoteCommunicationKit': { rcp: {
    createSession: config => webDavSession(config),
    Request: class { constructor(url, method, headers, content) { Object.assign(this, { url, method, headers, content }); } },
    UploadFromFile: class { constructor(path) { this.path = path; } }
  } },
  '@kit.MediaLibraryKit': {}, '@kit.ShareKit': {}, '@kit.ArkGraphics2D': { drawing: {} },
  '@kit.ArkTS': { url: { URL: { parseURL: (value, base) => new URL(value, base) } }, xml: {
    EventType: { START_TAG: 2, END_TAG: 3, TEXT: 4, CDSECT: 5 },
    XmlPullParser: class {
      constructor(body) { this.body = Buffer.from(body); }
      parseXml({ tokenValueCallbackFunction: emit }) {
        const tag = (event, name, depth, value = '') => emit(event, {
          getName: () => name, getNamespace: () => 'DAV:', getDepth: () => depth, getText: () => value
        });
        if (this.body.length > 1) {
          tag(2, 'multistatus', 1);
          for (const row of JSON.parse(this.body.toString('utf8'))) {
            tag(2, 'response', 2); tag(2, 'href', 3); tag(4, '', 3, row.href); tag(3, 'href', 3);
            tag(2, 'propstat', 3); tag(2, 'resourcetype', 5);
            if (row.directory) { tag(2, 'collection', 6); tag(3, 'collection', 6); }
            tag(3, 'resourcetype', 5); tag(2, 'status', 4); tag(4, '', 4, 'HTTP/1.1 ' + (row.status || '200 OK'));
            tag(3, 'status', 4); tag(3, 'propstat', 3); tag(3, 'response', 2);
          }
          tag(3, 'multistatus', 1);
          return;
        }
        tag(2, 'resourcetype', 5);
        if (this.body[0] === 1) { tag(2, 'collection', 6); tag(3, 'collection', 6); }
        tag(3, 'resourcetype', 5);
      }
    }
  }, taskpool: { execute: async (work, ...args) => {
    if (failConversationWorker) throw Error('conversation worker unavailable');
    return work(...args);
  } }, util: { generateRandomUUID: () => crypto.randomUUID(), TextEncoder: Encoder, TextDecoder: Decoder,
    Base64Helper: class { async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); } encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return Uint8Array.from(Buffer.from(text,'base64')); } } } },
  '@kit.AssetStoreKit': { asset: {} }, '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 }, zlib: {
    ReturnStatus: { STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 }, createZipSync: () => { let current; return {
      inflateInit2: async()=>{}, inflateEnd: async()=>{}, getZStream:async()=>current,
      inflate:async stream=>{const bytes=zlib.inflateRawSync(Buffer.from(stream.nextIn),{maxOutputLength:stream.availableOut});new Uint8Array(stream.nextOut).set(bytes);current={totalOut:bytes.length};return 1;}
    }; }
  } },
  '@kit.PDFKit': { pdfService: {} },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { ...backupCrypto, createRandom:()=>({generateRandom:async n=>({data:Uint8Array.from(crypto.randomBytes(n))})}),
    createMd:()=>{const hash=crypto.createHash('sha256');return{update:async blob=>hash.update(blob.data),digest:async()=>({data:Uint8Array.from(hash.digest())})};} } },
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file,'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText;
  vm.runInNewContext(compiled, { exports, require: id => {
    if (id === '@kit.PDFKit') pdfKitLoads++;
    return id === './HuaweiAccount' ? { huaweiAccount: backupAccount } : id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id];
  },
    Observed: cls => cls, canIUse: () => true, setTimeout: scheduleTimer, clearTimeout: cancelTimer, Uint8Array, ArrayBuffer, DataView, Map, Set, Object, JSON, Error, console }, { filename: file });
  return exports;
}
const model = load(path.join(source, 'model/Conversation'));
const { ConversationStore } = load(path.join(source,'model/ConversationStore'));
const { Attachments } = load(path.join(source,'services/Attachments'));
const { Cancellation } = load(path.join(source,'services/Cancellation'));
const { McpClient } = load(path.join(source,'services/McpClient'));
const { McpTools } = load(path.join(source,'services/McpTools'));
const { ToolApproval } = load(path.join(source,'services/ToolApproval'));
const { CredentialStore } = load(path.join(source,'services/CredentialStore'));
const diagnosticLogs = [], diagnostics = load(path.join(source, 'model/Diagnostics')).Diagnostics;
let noticeLogged = () => {};
diagnostics.configureLogSink(data => { diagnosticLogs.push(data); if (data.event === 'cancel_notice_failed') noticeLogged(); });
const { NativeWorkspaceFiles } = load(path.join(source,'services/NativeWorkspaceFiles'));
const secrets = new Map();
const secretGroups = new Map();
CredentialStore.prototype.read = async alias => secrets.get(alias) || (alias ? 'fixture-secret' : '');
CredentialStore.prototype.readOptional = async alias => secrets.get(alias);
CredentialStore.prototype.listAliases = async group => [...secretGroups.keys()].filter(alias => secretGroups.get(alias) === group);
CredentialStore.prototype.write = async (alias, secret, group) => {
  if (secrets.has(alias)) throw Error('duplicate secret');
  secrets.set(alias, secret);
  if (group) secretGroups.set(alias, group);
};
CredentialStore.prototype.update = async (alias, secret) => { assert.ok(secrets.has(alias)); secrets.set(alias,secret); };
CredentialStore.prototype.remove = async alias => { secrets.delete(alias); secretGroups.delete(alias); };
const server = { id:'s',name:'Fixture',url:'https://fixture.invalid/mcp',enabled:true,credentialAlias:'fixture-key' };
function approvalRequested(approval) {
  const request = approval.request.bind(approval);
  return new Promise(resolve => { approval.request = (...args) => {
    approval.request = request; const pending = request(...args); resolve(); return pending;
  }; });
}
function respond(request, result, sse = false) {
  const value = JSON.stringify({ jsonrpc:'2.0',id:JSON.parse(request.options.extraData).id,result });
  request.emit('headersReceive', { 'Mcp-Session-Id':'fixture-session' }); request.callback(null,200);
  const text = sse ? 'event: message\r\ndata: '+value+'\r\n\r\n' : value;
  const bytes = Buffer.from(text);
  for (let i=0; i<bytes.length; i+=7) request.emit('dataReceive', Uint8Array.from(bytes.subarray(i,i+7)).buffer);
  request.emit('dataEnd');
}
function readSavedUsage(root) {
  const dir=nativePath(root+'/usage-records');const manifest=JSON.parse(fs.readFileSync(path.join(dir,'index.json'),'utf8'));
  return Array.from({length:manifest.pages},(_,i)=>JSON.parse(fs.readFileSync(path.join(dir,i+'.json'),'utf8'))).flat();
}
const providerEffects = { hydrate: messages => Attachments.hydrate(messages),
  recordUsage: record => load(path.join(source, 'services/UsageLedger')).UsageLedger.record(record) };
function idleRuntime(vault) {
  const { AgentRuntime } = load(path.join(source, 'services/AgentRuntime'));
  const { ProviderRegistry } = load(path.join(source, 'services/providers/ProviderRegistry'));
  return new AgentRuntime(new ProviderRegistry(), vault);
}
let completedTests = 0, currentTest = '', suiteCompleted = false;
process.on('beforeExit', () => {
  if (!suiteCompleted) { console.error('Native adapter integration did not finish: ' + currentTest); process.exitCode = 1; }
});
async function test(name, run) {
  if (process.env.TEST_FILTER && !name.includes(process.env.TEST_FILTER)) return;
  currentTest = name;
  await run(); completedTests++; console.log('PASS '+name);
}
(async () => {
  let store;
  await test('shared folder diagnostic retains authorization failures and keeps retries available', async () => {
    const { ProjectFolderAccess } = load(path.join(source, 'services/ProjectFolderAccess'));
    const folders = [{ name: 'PRIVATE_FOLDER', uri: 'file://PRIVATE_URI' }];
    folderFailures.grants = new Set();
    await assert.rejects(ProjectFolderAccess.activate(folders), error =>
      error.code === 'SHARED_FOLDER_AUTH_REQUIRED' && error.recovery === 'reselect_shared_folder' && /项目设置/.test(error.message));
    assert.equal(folderFailures.activations || 0, 0, 'Restored bookmarks without grants cannot be activated');
    await ProjectFolderAccess.activateAll([{ sharedFolders: folders }]);
    assert.equal(diagnosticLogs.findLast(data => data.event === 'folder_startup_failed').fields.errorCode, 'SHARED_FOLDER_AUTH_REQUIRED');
    folderFailures.grants = new Set(folders.map(folder => folder.uri));
    folderFailures.activate = Object.assign(Error('PRIVATE_ACTIVATION'), { code: 201 });
    await ProjectFolderAccess.activateAll([{ sharedFolders: folders }]);
    assert.equal(diagnosticLogs.findLast(data => data.event === 'folder_activate_failed').fields.errorCode, 201);
    folderFailures.activate = undefined;
    await ProjectFolderAccess.activate(folders);
    folderFailures.grants = new Set();
    folderFailures.persist = Object.assign(Error('PRIVATE_PERSIST'), { code: 13900012 });
    await assert.rejects(ProjectFolderAccess.persist(folders));
    assert.equal(diagnosticLogs.findLast(data => data.event === 'folder_persist_failed').fields.errorCode, 13900012);
    folderFailures.persist = undefined;
    folderFailures.revoke = Object.assign(Error('PRIVATE_REVOKE'), { code: 201 });
    await ProjectFolderAccess.revoke(folders);
    assert.equal(diagnosticLogs.findLast(data => data.event === 'folder_revoke_failed').fields.errorCode, 201);
    folderFailures.revoke = undefined;
    folderFailures.grants = undefined;
    assert.ok(!JSON.stringify(diagnosticLogs).includes('PRIVATE_'));
  });
  await test('plain workspace files do not load PDFKit; document reads load it on demand and release temporary files', async () => {
    const before = pdfKitLoads;
    const documents = load(path.join(source, 'services/DocumentFiles'));
    assert.equal(pdfKitLoads, before);
    const filePath = path.join(fixture, 'lazy-document.txt'); fs.writeFileSync(filePath, 'plain workspace text');
    const file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
    try {
      assert.equal(await documents.readDocumentFile(file.fd, 'note.txt', fixture, new Cancellation()), 'plain workspace text');
      assert.equal(pdfKitLoads, before, 'Ordinary file access must not load a native PDF module');
      // The fixture intentionally has no PDF component. Its actionable capability error must remain visible.
      await assert.rejects(documents.readDocumentFile(file.fd, 'note.pdf', fixture, new Cancellation()), /PDF 组件未提供文字提取/);
      assert.equal(pdfKitLoads, before + 1);
      assert.ok(!fs.readdirSync(fixture).some(name => name.startsWith('.tinybot-pdf-')));
    } finally { await fileIo.close(file); }
  });
  await test('MCP cancellation diagnostic records failed remote notice while preserving local cancellation', async () => {
    let callStarted;
    const started = new Promise(resolve => { callStarted = resolve; });
    const logged = new Promise(resolve => { noticeLogged = resolve; });
    httpScript = req => {
      const method = JSON.parse(req.options.extraData).method;
      if (method === 'initialize') respond(req, { protocolVersion: '2025-06-18' });
      else if (method === 'notifications/initialized') req.callback(null, 202);
      else if (method === 'tools/call') callStarted();
      else if (method === 'notifications/cancelled') req.callback(Object.assign(Error('PRIVATE_NOTICE'), { code: 2300056 }));
      else assert.fail('Unexpected RPC method');
    };
    const signal = new Cancellation(), pending = new McpClient(server).call('write', {}, signal);
    await started; signal.cancel(); await assert.rejects(pending, /停止/); await logged; noticeLogged = () => {};
    const record = diagnosticLogs.findLast(data => data.event === 'cancel_notice_failed');
    assert.equal(record.level, 'warn'); assert.equal(record.fields.nativeCode, 2300056);
    assert.ok(!JSON.stringify(record).includes('PRIVATE_NOTICE'));
  });
  await test('atomic legacy migration, unchanged thread reuse and interrupted commit recovery', async () => {
    const data=model.emptyData(); data.activeThreadId='legacy'; data.threads=[{id:'legacy',title:'original',updatedAt:1,messages:[]}];
    const legacy=JSON.stringify(data); fs.writeFileSync(path.join(fixture,'tinybot-v1.json'),legacy);
    store=new ConversationStore(fixture); const loaded=await store.load(); assert.equal(loaded.threads[0].title,'original');
    const index=()=>JSON.parse(fs.readFileSync(path.join(fixture,'sessions-v2/index.json'),'utf8'));
    const first=index().threads[0].file; await store.save(loaded); assert.equal(index().threads[0].file,first);
    loaded.threads[0].title='changed'; failManifest=true; await assert.rejects(store.save(loaded),/injected/); failManifest=false;
    assert.equal((await new ConversationStore(fixture).load()).threads[0].title,'original');
    assert.equal(fs.readFileSync(path.join(fixture,'tinybot-v1.json'),'utf8'),legacy);
    await store.save(loaded); assert.equal((await new ConversationStore(fixture).load()).threads[0].title,'changed');
  });
  await test('ordered saves capture the call-time snapshot',async()=>{
    const data=await store.load(); data.threads[0].title='first'; const a=store.save(data);
    data.threads[0].title='second'; const b=store.save(data); data.threads[0].title='not saved'; await Promise.all([a,b]);
    assert.equal((await new ConversationStore(fixture).load()).threads[0].title,'second');
  });
  await test('partial saves skip unrelated history and preserve queued or failed changes', async () => {
    const data = await store.load();
    data.threads.push({ id: 'inactive', title: 'Inactive', updatedAt: 1, messages: [] });
    await store.save(data);
    const active = data.threads[0], inactive = data.threads[1];
    Object.defineProperty(inactive, 'messages', { configurable: true, enumerable: true,
      get() { throw Error('Unchanged history was traversed'); } });
    active.title = 'partial';
    const saving = store.save(data, [active.id]);
    active.title = 'later mutation';
    await saving;
    assert.equal((await new ConversationStore(fixture).load()).threads[0].title, 'partial');
    Object.defineProperty(inactive, 'messages', { configurable: true, enumerable: true, writable: true, value: [] });
    active.title = 'queued active'; const first = store.save(data, [active.id]);
    inactive.title = 'queued inactive'; const second = store.save(data, [inactive.id]);
    await Promise.all([first, second]);
    let restored = await new ConversationStore(fixture).load();
    assert.equal(restored.threads[0].title, 'queued active'); assert.equal(restored.threads[1].title, 'queued inactive');
    active.title = 'retry active'; failManifest = true;
    await assert.rejects(store.save(data, [active.id]), /injected/); failManifest = false;
    inactive.title = 'retry inactive'; await store.save(data, [inactive.id]);
    restored = await new ConversationStore(fixture).load();
    assert.equal(restored.threads[0].title, 'retry active'); assert.equal(restored.threads[1].title, 'retry inactive');
    const rejectedCandidate = structuredClone(data); rejectedCandidate.threads[1].title = 'rolled back';
    failManifest = true; await assert.rejects(store.save(rejectedCandidate), /injected/); failManifest = false;
    active.title = 'after rollback'; await store.save(data, [active.id]);
    restored = await new ConversationStore(fixture).load();
    assert.equal(restored.threads[0].title, 'after rollback'); assert.equal(restored.threads[1].title, 'retry inactive');
  });
  await test('partial saves retain recovery of inactive conversations', async () => {
    const data = await store.load();
    data.threads[1].messages = [
      { id: 'recovered-user', role: 'user', content: 'hello', status: 'complete', error: '' },
      { id: 'recovered-assistant', role: 'assistant', content: 'partial', status: 'generating', error: '' }
    ];
    await store.save(data);
    const recoveredStore = new ConversationStore(fixture), recovered = await recoveredStore.load();
    assert.notEqual(recovered.threads[1].messages[1].status, 'generating');
    recovered.threads[0].title = 'save after recovery';
    await recoveredStore.save(recovered, [recovered.threads[0].id]);
    const manifest = JSON.parse(fs.readFileSync(path.join(fixture, 'sessions-v2/index.json'), 'utf8'));
    const inactiveFile = manifest.threads.find(item => item.id === recovered.threads[1].id).file;
    const persisted = JSON.parse(fs.readFileSync(path.join(fixture, 'sessions-v2', inactiveFile), 'utf8'));
    assert.equal(persisted.messages[1].status, recovered.threads[1].messages[1].status);
    assert.equal(persisted.messages[1].error, recovered.threads[1].messages[1].error);
  });
  await test('runtime checkpoints reuse history and worker failures retain the durable snapshot', async () => {
    const root=path.join(fixture,'runtime-checkpoints');fs.mkdirSync(root);
    const data=model.emptyData();data.activeThreadId='runtime';data.threads=[{id:'runtime',title:'Original',updatedAt:1,messages:[
      {id:'question',role:'user',content:'historical context',status:'complete',error:''},
      {id:'answer',role:'assistant',content:'working',status:'generating',error:''}
    ]}];
    const repository=new ConversationStore(root);await repository.save(data);
    const history=data.threads[0].messages[0],answer=data.threads[0].messages[1];
    Object.defineProperty(history,'content',{configurable:true,enumerable:true,get(){throw Error('Historical message reserialized');}});
    const hint={threadId:'runtime',messageId:'answer'};
    answer.content='checkpoint';const saving=repository.save(data,['runtime'],hint);answer.content='later';await saving;
    let restored=await new ConversationStore(root).load();assert.equal(restored.threads[0].messages[1].content,'checkpoint');
    assert.equal(restored.threads[0].messages[0].content,'historical context');
    Object.defineProperty(history,'content',{configurable:true,enumerable:true,writable:true,value:'edited history'});
    await repository.save(data,['runtime']);
    failConversationWorker=true;data.threads[0].title='Failed candidate';
    try {await assert.rejects(repository.save(data,['runtime'],hint),/worker unavailable/);} finally {failConversationWorker=false;}
    restored=await new ConversationStore(root).load();assert.equal(restored.threads[0].title,'Original');
    assert.equal(restored.threads[0].messages[0].content,'edited history');
    history.content='authoritative history after failure';data.threads[0].title='Retry';
    await repository.save(data,['runtime'],hint);
    restored=await new ConversationStore(root).load();assert.equal(restored.threads[0].title,'Retry');
    assert.equal(restored.threads[0].messages[0].content,'authoritative history after failure');
  });
  await test('managed text attachments hydrate without mutating persisted history',async()=>{
    Attachments.configure(fixture);const incoming=path.join(fixture,'input.txt');fs.writeFileSync(incoming,'材料内容');
    const item=await Attachments.import(incoming,false);const messages=[{role:'user',content:'总结',attachments:[item]}];
    const hydrated=await Attachments.hydrate(messages);assert.ok(!hydrated[0].content.includes('材料内容'));assert.equal(messages[0].content,'总结');
    assert.equal(fs.readFileSync(Attachments.path(item),'utf8'),'材料内容');
    fs.writeFileSync(incoming,Buffer.from([0xff,0xff]));const binary=await Attachments.import(incoming,false);
    assert.deepEqual(fs.readFileSync(Attachments.path(binary)),Buffer.from([0xff,0xff]));
  });
  await test('drawing attachments encode, persist and hydrate images for all model protocols',async()=>{
    Attachments.configure(fixture);
    const previousImage=kits['@kit.ImageKit'].image;
    const previousGraphics=kits['@kit.ArkGraphics2D'].drawing;
    let releases=0,opaqueReleases=0,packed=Uint8Array.from([255,216,255,217]).buffer;
    const composites=[];
    const scales=[];
    const pixel={getImageInfo:async()=>({size:{width:2400,height:1800}}),scale:async(x,y)=>scales.push([x,y])};
    kits['@kit.ArkGraphics2D'].drawing={Canvas:class {
      constructor(target){this.target=target;}
      drawColor(...channels){assert.deepEqual(channels,[255,255,255,255]);this.target.white=true;}
      drawImage(value,x,y){assert.equal(value,pixel);assert.equal(x,0);assert.equal(y,0);assert.equal(this.target.white,true);this.target.composited=true;}
    }};
    kits['@kit.ImageKit'].image={PixelMapFormat:{RGBA_8888:3},AlphaType:{OPAQUE:1},
      createPixelMapSync:options=>{assert.equal(options.size.width,1600);assert.equal(options.size.height,1200);
        const target={getImageInfo:async()=>({size:options.size}),release:async()=>{opaqueReleases++;}};composites.push(target);return target;},
      createImagePacker:()=>({packing:async(value,options)=>{
        if(value!==pixel){assert.equal(value.composited,true,'native ink must be composited on white before JPEG packing');}
        assert.equal(options.format,'image/jpeg');return packed;
      },release:async()=>{releases++;}})};
    try {
      const item=await Attachments.saveDrawing(pixel);
      assert.equal(item.mime,'image/jpeg');assert.equal(item.size,4);assert.equal(item.name,'手绘示意.jpg');
      assert.deepEqual(scales,[[1600/2400,1600/2400]]);
      assert.deepEqual(fs.readFileSync(Attachments.path(item)),Buffer.from(packed));
      const restored=JSON.parse(JSON.stringify(item));
      const messages=await Attachments.hydrate([{role:'user',content:'Explain this sketch',attachments:[restored]}]);
      const url='data:image/jpeg;base64,'+Buffer.from(packed).toString('base64');
      const {chatRequest}=load(path.join(source,'services/providers/ChatCompletionsProtocol'));
      const {responsesRequest,anthropicRequest}=load(path.join(source,'services/providers/WireProtocols'));
      assert.equal(chatRequest('vision',messages,[]).messages[0].content.at(-1).image_url.url,url);
      assert.equal(responsesRequest('vision',messages,[]).input[0].content.at(-1).image_url,url);
      assert.equal(anthropicRequest('vision',messages,[]).messages[0].content.at(-1).source.data,Buffer.from(packed).toString('base64'));
      assert.equal((await Attachments.savePreview(pixel)).name,'Preview screenshot.jpg');
      packed=new ArrayBuffer(4*1024*1024+1);
      await assert.rejects(Attachments.saveDrawing(pixel),/4 MB/);assert.equal(releases,3);
      assert.equal(opaqueReleases,2,'temporary opaque images are released on success and failure');
    } finally {kits['@kit.ImageKit'].image=previousImage;kits['@kit.ArkGraphics2D'].drawing=previousGraphics;}
  });
  await test('legacy large text attachments persist intact and are read in bounded pages after reload',async()=>{
    const {AttachmentTools}=load(path.join(source,'services/AttachmentTools'));
    const {estimateContextTokens}=load(path.join(source,'model/ConversationContext'));
    const {attachmentTokens}=load(path.join(source,'model/ContextBreakdown'));
    const incoming=path.join(fixture,'large.txt');
    // Cross both old byte/character limits, a chunk boundary and a UTF-8 character boundary.
    const content='a'.repeat(65535)+'中文🙂\n'+'附件正文🙂'.repeat(18000)+'\nEND';
    fs.writeFileSync(incoming,content);
    const item={id:'legacy-large',name:'large.txt',mime:'text/plain',path:'legacy-large.txt',size:Buffer.byteLength(content),text:content};
    fs.writeFileSync(Attachments.path(item),content);
    assert.equal(item.text,content);assert.equal(item.size,Buffer.byteLength(content));
    assert.equal(fs.readFileSync(Attachments.path(item),'utf8'),content);
    const data=model.emptyData();data.activeThreadId='large-attachment';
    data.threads=[{id:data.activeThreadId,title:'Large',updatedAt:1,messages:[{id:'large-user',role:'user',content:'read',status:'complete',error:'',attachments:[item]},
      {id:'large-answer',role:'assistant',content:'saved',status:'complete',error:''}]}];
    const localStore=new ConversationStore(path.join(fixture,'large-store'));fs.mkdirSync(path.join(fixture,'large-store'));
    await localStore.save(data);const restored=(await localStore.load()).threads[0].messages[0];
    const hydrated=(await Attachments.hydrate([{role:'user',content:'read',attachments:restored.attachments}]))[0];
    assert.match(hydrated.content,/read_attachment/);assert.ok(!hydrated.content.includes('END'));
    assert.ok(estimateContextTokens([{role:'user',content:'',attachments:restored.attachments}])<1000);
    assert.ok(attachmentTokens(item)<1000);
    const tools=new AttachmentTools(restored.attachments);let offset=1,column=1,joined='',pages=0;
    while(true){
      const result=JSON.parse(await tools.execute({id:'read',function:{name:'read_attachment',arguments:JSON.stringify({id:item.id,offset,column})}},new Cancellation()));
      assert.ok(Buffer.byteLength(result.content)<=50*1024);joined+=result.content;pages++;
      if(!result.truncated)break;
      assert.ok(result.nextOffset>offset||result.nextOffset===offset&&result.nextColumn>column);
      offset=result.nextOffset;column=result.nextColumn;assert.ok(pages<100);
    }
    assert.equal(joined,content);assert.ok(pages>1);
    await assert.rejects(tools.execute({function:{name:'read_attachment',arguments:'{"id":"other-chat"}'}},new Cancellation()),/unavailable/);
    await assert.rejects(tools.execute({function:{name:'read_attachment',arguments:JSON.stringify({id:item.id,offset:0})}},new Cancellation()),/positive integers/);
    const cancelled=new Cancellation();cancelled.cancel();
    await assert.rejects(tools.execute({function:{name:'read_attachment',arguments:JSON.stringify({id:item.id})}},cancelled));
    fs.writeFileSync(incoming,'x'.repeat(4*1024*1024+1));
    const overImageLimit=await Attachments.import(incoming,false);assert.equal(overImageLimit.size,4*1024*1024+1);
    assert.equal(model.parseAppData(JSON.stringify({...data,threads:[{...data.threads[0],attachments:[overImageLimit]}]})).threads[0].attachments[0].size,4*1024*1024+1);
    fs.writeFileSync(incoming,'');assert.equal((await Attachments.import(incoming,false)).size,0);
    fs.writeFileSync(incoming,'valid\0binary');assert.equal((await Attachments.import(incoming,false)).size,12);
    fs.writeFileSync(incoming,Buffer.concat([Buffer.alloc(65535,97),Buffer.from([0xe4,0xb8])]));assert.equal((await Attachments.import(incoming,false)).size,65537);
  });
  await test('text attachments above the image cap survive backup and restore within the total backup budget',async()=>{
    const {createBackupFile,readBackupFile}=load(path.join(source,'services/Backup'));
    const root='/sandbox/large-backup';fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(root+'/cache'));
    Attachments.configure(root);const content='b'.repeat(4*1024*1024+1);fs.writeFileSync(nativePath(root+'/input.txt'),content);
    const {WorkspaceStore}=load(path.join(source,'model/WorkspaceStore'));await new WorkspaceStore(root).ensureThread('large-backup');
    const [item]=await Attachments.inWorkspace([await Attachments.import(root+'/input.txt',false)],'large-backup');const data=model.emptyData();
    data.activeThreadId='large-backup';data.threads=[{id:'large-backup',title:'Large backup',updatedAt:1,messages:[],attachments:[item]}];
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};
    const backup=await createBackupFile(context,data);const restored=await readBackupFile(context,backup,model.emptyData());
    const restoredItem=restored.threads[0].attachments[0];assert.equal(restoredItem.text,undefined);
    assert.equal(fs.readFileSync(nativePath(Attachments.path(restoredItem)),'utf8'),content);
    Attachments.configure(fixture);
  });
  await test('preview and partial browser screenshot bytes survive backup, restored references and missing-image validation',async()=>{
    const {createBackupFile,readBackupFile}=load(path.join(source,'services/Backup'));
    const root='/sandbox/preview-backup';fs.mkdirSync(nativePath(root+'/attachments'),{recursive:true});fs.mkdirSync(nativePath(root+'/cache'));
    Attachments.configure(root);const bytes=Buffer.from('preview-jpeg');fs.writeFileSync(nativePath(root+'/attachments/shot.jpg'),bytes);
    const shot={image:{id:'shot',name:'Preview.jpg',mime:'image/jpeg',path:'shot.jpg',size:bytes.length},width:100,height:80,viewportWidth:344};
    const browserBytes=Buffer.from('browser-jpeg');fs.writeFileSync(nativePath(root+'/attachments/browser.jpg'),browserBytes);
    const browserFrame={...shot,image:{id:'browser',name:'Browser.jpg',mime:'image/jpeg',path:'browser.jpg',size:browserBytes.length},elapsedMs:123,capturedAt:Date.now()};
    const data=model.emptyData();data.activeThreadId='preview-backup';data.threads=[{id:'preview-backup',title:'Preview',updatedAt:1,messages:[
      {id:'user',role:'user',content:'Create preview',status:'complete',error:''},
      {id:'assistant',role:'assistant',content:'',status:'complete',error:'',steps:[{content:'',tools:[{
        call:{id:'publish',type:'function',function:{name:'publish_preview',arguments:'{"path":"art.svg"}'}},status:'complete',output:'{}',
        previewContent:'```tinybot-ui\n{"op":"begin","version":1,"title":"Preview","state":{}}\n{"op":"end"}\n```',previewScreenshot:shot
      },{call:{id:'capture',type:'function',function:{name:'browser_capture',arguments:'{"count":2,"intervalMs":250}'}},
        status:'failed',output:'{"error":"Interrupted after first frame"}',
        browserObservation:{instanceId:'test-instance',frames:[browserFrame],errors:[]}}]}]}
    ]}];
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};
    const backup=await createBackupFile(context,data);const envelope=legacyBackupFixture(fs.readFileSync(nativePath(backup)));
    assert.equal(envelope.attachments.length,2);
    const restored=await readBackupFile(context,backup,model.emptyData());const image=restored.threads[0].messages[1].steps[0].tools[0].previewScreenshot.image;
    assert.notEqual(image.id,'shot');assert.deepEqual(fs.readFileSync(nativePath(Attachments.path(image))),bytes);
    const browserImage=restored.threads[0].messages[1].steps[0].tools[1].browserObservation.frames[0].image;
    assert.notEqual(browserImage.id,'browser');assert.deepEqual(fs.readFileSync(nativePath(Attachments.path(browserImage))),browserBytes);
    envelope.attachments=[];fs.writeFileSync(nativePath(backup),JSON.stringify(envelope));
    await assert.rejects(readBackupFile(context,backup,model.emptyData()),/备份缺少附件/);
    Attachments.configure(fixture);
  });
  await test('large workspace tools page Unicode without loss, search the tail and restore full baselines',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const {importTextFile}=load(path.join(source,'services/TextFiles'));
    const root='/sandbox/workspace/large';fs.mkdirSync(nativePath(root),{recursive:true});
    const files=new NativeWorkspaceFiles(root),tools=new WorkspaceTools(files),signal=new Cancellation();
    const invoke=async(name,args)=>JSON.parse(await tools.execute({id:name,function:{name,arguments:JSON.stringify(args)}},signal));
    const content=Array.from({length:2300},(_,i)=>`${i}: 中文资料🙂`).join('\n')+'\n'+'长行🙂'.repeat(18000)+'\nTAIL-MARKER';
    fs.writeFileSync(nativePath(root+'/input.txt'),content);assert.equal(await importTextFile(root+'/input.txt'),content);
    await invoke('write_file',{path:'large.txt',content});assert.equal((await files.read('large.txt',signal)).content,content);
    let joined='',offset=1,column=1,pages=0;
    while(true){const result=await invoke('read_file',{path:'large.txt',offset,column});joined+=result.content;pages++;
      assert.ok(Buffer.byteLength(result.content)<=50*1024);
      if(!result.truncated)break;
      assert.ok(result.nextOffset>offset||result.nextOffset===offset&&result.nextColumn>column);
      offset=result.nextOffset;column=result.nextColumn;assert.ok(pages<100);}
    assert.equal(joined,content);assert.ok(pages>2);
    const range=await invoke('read_file',{path:'large.txt',offset:2200,limit:2});assert.equal(range.content,content.split('\n').slice(2199,2201).join('\n')+'\n');
    const search=await invoke('search_file_content',{path:'.',query:'TAIL-MARKER'});assert.equal(search.matches.length,2);assert.equal(search.skipped.length,0);
    assert.equal((await files.baseline('large.txt')).existed,false,'Creating a file retains its original missing-file baseline');
    // A separately seeded existing file exercises edits without a test-only baseline reset API.
    fs.writeFileSync(nativePath(root+'/existing-large.txt'),content);
    await invoke('read_file',{path:'existing-large.txt'});
    await invoke('edit_file',{path:'existing-large.txt',oldText:'TAIL-MARKER',newText:'EDITED'});
    assert.equal((await files.baseline('existing-large.txt')).content,content);
    await files.restore('existing-large.txt',content.replace('TAIL-MARKER','EDITED'));
    assert.equal((await files.read('existing-large.txt',signal)).content,content);
    assert.equal(await files.baseline('existing-large.txt'),undefined);
    assert.equal((await files.baseline('large.txt')).existed,false,'Restoring another file cannot discard the original creation backup');
    for(const args of [{offset:0},{offset:999999},{limit:0},{offset:1,column:999999}])await assert.rejects(invoke('read_file',{path:'large.txt',...args}));
    // Exactly full byte pages must preserve the following newline, including an empty last line.
    for(const sample of ['x'.repeat(50*1024)+'\n','x'.repeat(50*1024-1)+'🙂\n','\n'.repeat(2001)]){
      fs.writeFileSync(nativePath(root+'/boundary.txt'),sample);let actual='',args={path:'boundary.txt'};
      for(let n=0;n<10;n++){const r=await invoke('read_file',args);actual+=r.content;if(!r.truncated)break;args={path:'boundary.txt',offset:r.nextOffset,column:r.nextColumn};}
      assert.equal(actual,sample);
    }
  });
  await test('empty workspace files round-trip with device encoder behavior',async()=>{
    fs.mkdirSync(nativePath('/sandbox/workspace/thread'),{recursive:true});
    const files=new NativeWorkspaceFiles('/sandbox/workspace/thread'), signal=new Cancellation();
    await files.write('empty.md','',signal);assert.equal((await files.read('empty.md',signal)).content,'');
    await files.write('empty.md','# note',signal);assert.equal((await files.read('empty.md',signal)).content,'# note');
    await assert.rejects(files.checkedPath('../escape'));
  });
  await test('binary file jobs preserve original bytes and commit only a new private workspace file', async () => {
    const root = '/sandbox/workspace/file-jobs';
    fs.mkdirSync(nativePath(root), { recursive: true });
    const files = new NativeWorkspaceFiles(root);
    const original = Uint8Array.from([80, 75, 3, 4, 0, 255]);
    const other = Uint8Array.from([80, 75, 3, 4, 1, 254]);
    const signal = new Cancellation();
    const first = files.createJobOutput('job.xlsx', original, signal);
    const second = new NativeWorkspaceFiles(root).createJobOutput('job.xlsx', other, signal);
    await first;
    await assert.rejects(second, (error) => error.code === 'FS_NOT_OBSERVED');
    assert.deepEqual(Buffer.from(await files.readJobInput('job.xlsx', 6, signal)), Buffer.from(original));
    await assert.rejects(files.readJobInput('job.xlsx', 5, signal), (error) => error.code === 'LIMIT_EXCEEDED');
    await assert.rejects(files.createJobOutput('attachments/job.xlsx', other, signal), (error) => error.code === 'FS_INVALID_PATH');
    const mounted = new NativeWorkspaceFiles(root, [{ id: 'test-mount', name: 'Vault', uri: 'file:///sandbox/external', addedAt: 1 }]);
    await assert.rejects(mounted.createJobOutput('shared/Vault/job.xlsx', other, signal), (error) => error.code === 'FS_INVALID_PATH');

    const stop = new Cancellation();
    const fsync = fileIo.fsync;
    fileIo.fsync = async (fd) => { await fsync(fd); stop.cancel(); };
    try {
      await assert.rejects(files.createJobOutput('cancelled.xlsx', other, stop), (error) => error.code === 'CANCELLED');
    } finally { fileIo.fsync = fsync; }
    assert.deepEqual(fs.readdirSync(nativePath(root)), ['job.xlsx']);
  });
  await test('MCP initializes, negotiates session headers, reads JSON/SSE and paginates',async()=>{
    calls.length=0;httpScript=req=>{ const body=JSON.parse(req.options.extraData);
      assert.equal(req.options.maxRedirects,0);assert.equal(req.options.header.Authorization,'Bearer fixture-secret');
      if(body.method==='initialize')respond(req,{protocolVersion:'2025-06-18'});
      else {assert.equal(req.options.header['Mcp-Session-Id'],'fixture-session');
        if(body.method==='notifications/initialized')req.callback(null,202);
        else if(body.params.cursor)respond(req,{tools:[{name:'b',inputSchema:{type:'object'}}]},true);
        else respond(req,{tools:[{name:'a',inputSchema:{type:'object'}}],nextCursor:'next'},true); }
    };
    const tools=await new McpClient(server).list(new Cancellation());assert.equal(tools.length,2);assert.equal(calls.length,4);
  });
  await test('remote tools cannot execute before discovery and explicit approval',async()=>{
    httpScript=req=>{const b=JSON.parse(req.options.extraData);if(b.method==='initialize')respond(req,{protocolVersion:'2025-06-18'});
      else if(b.method==='notifications/initialized')req.callback(null,202);
      else if(b.method==='tools/list')respond(req,{tools:[{name:'read',inputSchema:{type:'object'}}]});
      else respond(req,{content:[{type:'text',text:'done'}]},true);};
    const approval=new ToolApproval(),tools=new McpTools([server],approval, server => new McpClient(server)),signal=new Cancellation();
    const call=(name,args)=>({id:'c',type:'function',function:{name,arguments:JSON.stringify(args)}});
    const action=call('mcp_call',{server:'s',tool:'read',arguments:{}});
    await assert.rejects(tools.execute(action,signal),/mcp_list_tools/);
    await tools.execute(call('mcp_list_tools',{server:'s'}),signal);
    const before=calls.length;const denied=tools.execute(action,signal);await new Promise(r=>setTimeout(r,0));
    assert.equal(calls.length,before);assert.match(approval.title,/Fixture/);approval.respond(false);await assert.rejects(denied,/拒绝/);
    const allowed=tools.execute(action,signal);await new Promise(r=>setTimeout(r,0));approval.respond(true);assert.match(await allowed,/done/);
  });
  await test('canceling approval clears the UI and sends no tool call',async()=>{
    const approval=new ToolApproval(),signal=new Cancellation();const pending=approval.request('tool','{}',signal);signal.cancel();
    await assert.rejects(pending);assert.equal(approval.title,'');
  });
  await test('HTTP failures are not replayed and cancellation destroys pending requests',async()=>{
    let n=0;httpScript=req=>{n++;req.callback(null,401);};await assert.rejects(new McpClient(server).list(new Cancellation()),/401/);assert.equal(n,1);
    httpScript=()=>{}; const signal=new Cancellation();const before=destroyed; const pending=new McpClient(server).list(signal);
    await new Promise(r=>setTimeout(r,0));signal.cancel();await assert.rejects(pending);assert.ok(destroyed>before);
  });
  await test('shared mounts write without rename, keep private backups, reject traversal and nested links', async () => {
    const root = '/sandbox/workspace/shared-test', external = '/sandbox/external/shared-test';
    fs.mkdirSync(nativePath(root), { recursive: true });
    fs.mkdirSync(nativePath(external), { recursive: true });
    fs.writeFileSync(nativePath(external + '/note.txt'), 'original');
    const folder = { id: 'mount-one', name: 'Documents', uri: 'file://' + external, addedAt: 1 };
    const files = new NativeWorkspaceFiles(root, [folder]), signal = new Cancellation();
    assert.equal((await files.list('.', signal)).entries.find(e => e.name === 'shared').kind, 'directory');
    assert.equal((await files.list('shared', signal)).entries[0].name, 'Documents');
    assert.equal((await files.read('shared/Documents/note.txt', signal)).content, 'original');
    await files.write('shared/Documents/new/中文 笔记.md', 'nested', signal, { version: null });
    assert.equal(fs.readFileSync(nativePath(external + '/new/中文 笔记.md'), 'utf8'), 'nested');
    for (const bad of ['shared/Documents/../note.txt', 'shared/Documents//note.txt']) {
      await assert.rejects(files.read(bad, signal));
      await assert.rejects(files.checkedPath(bad));
      await assert.rejects(files.remove(bad));
    }
    const outside = '/sandbox/external/outside'; fs.mkdirSync(nativePath(outside), { recursive: true });
    fs.writeFileSync(nativePath(outside + '/secret.txt'), 'private');
    fs.symlinkSync(nativePath(outside), nativePath(external + '/escape'), 'junction');
    await assert.rejects(files.read('shared/Documents/escape/secret.txt', signal), /符号链接/);
    await assert.rejects(files.write('shared/Documents/escape/new.txt', 'bad', signal), /符号链接/);
    await assert.rejects(files.remove('shared/Documents/escape/secret.txt'), /符号链接/);
    const original = await files.read('shared/Documents/note.txt', signal);
    failSharedRename = true;
    try {
      await files.edit(original.path, [{oldText:'original',newText:'短'}], original.version, signal);
      assert.equal(fs.readFileSync(nativePath(external+'/note.txt'),'utf8'),'短','Shorter edits truncate trailing bytes');
      await files.write(original.path, '', signal);
      assert.equal(fs.statSync(nativePath(external+'/note.txt')).size,0,'Empty writes truncate correctly');
      assert.equal((await files.baseline(original.path)).content,'original');
      await files.restore(original.path,'');
    }
    finally { failSharedRename = false; }
    assert.equal(fs.readFileSync(nativePath(external + '/note.txt'), 'utf8'), 'original');
    assert.ok(!fs.readdirSync(nativePath(external)).some(name => name.startsWith('.tinybot-')));
    const alternate = new NativeWorkspaceFiles(root, [{ ...folder, id: 'another-project-mount', name: 'Alias' }]);
    const writes = await Promise.allSettled([
      files.write(original.path, 'first', signal, { version: original.version }),
      alternate.write('shared/Alias/note.txt', 'second', signal, { version: original.version })
    ]);
    assert.equal(writes.filter(result => result.status === 'fulfilled').length, 1, 'Aliases share one mutation queue');
    assert.match(writes.find(result => result.status === 'rejected').reason.message, /变化/);
  });
  await test('shared direct writes retain recoverable backups on partial write, truncate, sync and close failures', async () => {
    for(const phase of ['write','truncate','fsync','close']) {
      const root='/sandbox/workspace/failure-'+phase, external='/sandbox/external/failure-'+phase;
      fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(external),{recursive:true});
      fs.writeFileSync(nativePath(external+'/note.txt'),'original long text');
      const folder={id:'mount',name:'Vault',uri:'file://'+external,addedAt:1};
      const files=new NativeWorkspaceFiles(root,[folder]), signal=new Cancellation();
      const before=await files.read('shared/Vault/note.txt',signal);
      sharedWriteFailure=phase;
      try {
        await assert.rejects(files.write(before.path,'replacement',signal,{version:before.version}), error=>{
          assert.equal(error.code,'FS_EXTERNAL_IO');assert.equal(error.recovery,'inspect_backup');
          assert.equal(error.details.nativeCode,13900005);assert.equal(error.details.category,phase);
          assert.match(error.message,/修改前备份/);return true;
        });
      } finally {sharedWriteFailure='';}
      const restarted=new NativeWorkspaceFiles(root,[folder]);
      assert.equal((await restarted.baseline(before.path)).content,'original long text');
      const partial=await restarted.read(before.path,signal);
      await restarted.restore(before.path,partial.content);
      assert.equal(fs.readFileSync(nativePath(external+'/note.txt'),'utf8'),'original long text');
      assert.equal(await restarted.baseline(before.path),undefined);
      assert.ok(!fs.readdirSync(nativePath(external)).some(n=>n.startsWith('.tinybot-')));
    }
  });
  await test('shared backup failure blocks mutation and backup identity follows the URI across mount renames', async () => {
    const root='/sandbox/workspace/shared-backup', external='/sandbox/external/shared-backup';
    fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(external),{recursive:true});
    fs.writeFileSync(nativePath(external+'/note.txt'),'original');
    const folder={id:'mount',name:'Vault',uri:'file://'+external,addedAt:1};
    const files=new NativeWorkspaceFiles(root,[folder]),signal=new Cancellation(),p='shared/Vault/note.txt';
    failBackupRename=true;
    try {await assert.rejects(files.write(p,'changed',signal),e=>e.code==='FS_EXTERNAL_IO'&&e.details.category==='backup');}
    finally{failBackupRename=false;}
    assert.equal(fs.readFileSync(nativePath(external+'/note.txt'),'utf8'),'original');
    await files.write(p,'changed',signal);
    const renamed=new NativeWorkspaceFiles(root,[{...folder,name:'Renamed'}]);
    assert.equal((await renamed.baseline('shared/Renamed/note.txt')).content,'original');
    const other=new NativeWorkspaceFiles(root,[{...folder,uri:'file://'+external+'-other'}]);
    assert.equal(await other.baseline(p),undefined,'Different mount at same display path cannot inherit a backup');
    fs.writeFileSync(nativePath(external+'/note.txt'),'outside edit');
    await assert.rejects(renamed.restore('shared/Renamed/note.txt','changed'),/文件已变化/);
    assert.equal((await renamed.baseline('shared/Renamed/note.txt')).content,'original');
    await renamed.restore('shared/Renamed/note.txt','outside edit');
    assert.equal(fs.readFileSync(nativePath(external+'/note.txt'),'utf8'),'original');
    assert.equal(await files.baseline(p),undefined,'Successful restore clears the same URI backup through either mount name');
  });
  await test('cancelled shared writes retain cancellation semantics and a recoverable pre-change backup',async()=>{
    const root='/sandbox/workspace/shared-cancel',external='/sandbox/external/shared-cancel';
    fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(external),{recursive:true});
    fs.writeFileSync(nativePath(external+'/note.txt'),'original');
    const files=new NativeWorkspaceFiles(root,[{id:'mount',name:'Vault',uri:'file://'+external,addedAt:1}]);
    const signal=new Cancellation();cancelSharedWrite=signal;
    await assert.rejects(files.write('shared/Vault/note.txt','replacement',signal),e=>{
      assert.equal(e.code,'CANCELLED');assert.equal(e.recovery,'inspect_backup');assert.match(e.message,/修改前备份/);return true;
    });
    assert.equal((await files.baseline('shared/Vault/note.txt')).content,'original');
    const current=await files.read('shared/Vault/note.txt',new Cancellation());
    await files.restore(current.path,current.content);
    assert.equal(fs.readFileSync(nativePath(external+'/note.txt'),'utf8'),'original');
  });
  await test('baseline persists, hides metadata, detects stale restore and preserves original',async()=>{
    const root='/sandbox/workspace/review';fs.mkdirSync(nativePath(root),{recursive:true});fs.writeFileSync(nativePath(root+'/note.txt'),'before');
    const files=new NativeWorkspaceFiles(root),signal=new Cancellation();await files.write('note.txt','after',signal);
    assert.equal((await new NativeWorkspaceFiles(root).baseline('note.txt')).content,'before');
    await files.write('note.txt','later',signal);assert.equal((await files.baseline('note.txt')).content,'before');
    assert.ok(!(await files.list('.',signal)).entries.some(e=>e.name.startsWith('.tinybot-')));
    await assert.rejects(files.restore('note.txt','after'),/变化/);await files.restore('note.txt','later');
    assert.equal(fs.readFileSync(nativePath(root+'/note.txt'),'utf8'),'before');assert.equal(await files.baseline('note.txt'),undefined);
    await files.write('new.txt','new',signal);await files.restore('new.txt','new');assert.ok(!fs.existsSync(nativePath(root+'/new.txt')));
  });
  await test('per-operation diff uses the actual native write, survives reload and stays out of model output',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const {ToolSet}=load(path.join(source,'services/ToolSet'));
    const {RuleTools}=load(path.join(source,'services/RuleTools'));
    const {stepMessages}=load(path.join(source,'model/Agent'));
    const root='/sandbox/workspace/diff';fs.mkdirSync(nativePath(root),{recursive:true});
    const native=new NativeWorkspaceFiles(root), tools=new RuleTools(new ToolSet([new WorkspaceTools(native)]),false);
    const signal=new Cancellation();
    const invoke=async(name,args)=>{
      const execution={call:{id:crypto.randomUUID(),type:'function',function:{name,arguments:JSON.stringify(args)}},status:'running',output:''};
      execution.output=await tools.execute(execution.call,signal,{execution,executeChild:async()=>{throw Error('unexpected child');}});
      execution.status='complete';return execution;
    };
    const create=await invoke('write_file',{path:'note.txt',content:'head\nold\ntail\n'});
    assert.equal(create.fileDiff.created,true);assert.equal(create.fileDiff.added,3);
    assert.deepEqual(Object.keys(JSON.parse(create.output)).sort(),['bytes','path','written']);
    const edit=await invoke('edit_file',{path:'note.txt',oldText:'old',newText:'new\nextra'});
    assert.equal(edit.fileDiff.added,2);assert.equal(edit.fileDiff.removed,1);
    assert.equal(edit.fileDiff.rows.find(r=>r.kind==='removed').oldLine,2);
    const overwrite=await invoke('write_file',{path:'note.txt',content:'head\nnew\nfinal\n'});
    assert.equal(overwrite.fileDiff.added,1);assert.equal(overwrite.fileDiff.removed,2,'compare to immediately preceding content, not the original baseline');
    const unchanged=await invoke('write_file',{path:'note.txt',content:'head\nnew\nfinal\n'});
    assert.equal(unchanged.fileDiff.added,0);assert.equal(unchanged.fileDiff.removed,0);
    const step={content:'',tools:[create,edit,overwrite,unchanged]};
    assert.ok(!JSON.stringify(stepMessages(step)).includes('fileDiff'));
    const data=model.emptyData();data.activeThreadId='diff';data.threads=[{id:'diff',title:'Diff',updatedAt:1,messages:[
      {id:'user',role:'user',content:'Edit',status:'complete',error:''},
      {id:'answer',role:'assistant',content:'Done',status:'complete',error:'',steps:[step]}]}];
    const restored=model.parseAppData(JSON.stringify(data));
    assert.equal(restored.threads[0].messages[1].steps[0].tools[2].fileDiff.removed,2);
    assert.equal((await native.baseline('note.txt')).existed,false,'workspace restore keeps its separate original baseline');
    await assert.rejects(invoke('edit_file',{path:'note.txt',oldText:'missing',newText:'wrong'}));
    assert.equal((await native.read('note.txt',signal)).content,'head\nnew\nfinal\n');
  });
  await test('batch edits match one original, read and commit once, and keep model receipts small',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const root='/sandbox/workspace/batch';fs.mkdirSync(nativePath(root),{recursive:true});
    const native=new NativeWorkspaceFiles(root),tools=new WorkspaceTools(native),signal=new Cancellation();
    const invoke=(name,args,context)=>tools.execute({id:name,type:'function',function:{name,arguments:JSON.stringify(args)}},signal,context);
    await invoke('write_file',{path:'a.txt',content:'alpha\nbeta\ntail\n'});
    let reads=0,commits=0;const open=fileIo.open,rename=fileIo.rename;
    fileIo.open=async(p,flags)=>{if(p===root+'/a.txt' && flags & fileIo.OpenMode.READ_ONLY)reads++;return open(p,flags);};
    fileIo.rename=async(a,b)=>{if(b===root+'/a.txt')commits++;return rename(a,b);};
    const execution={status:'running'};
    try {
      const result=JSON.parse(await invoke('edit_file',{path:'a.txt',edits:[{oldText:'beta',newText:'alpha'},{oldText:'alpha',newText:'beta'}]},{execution}));
      assert.deepEqual(Object.keys(result).sort(),['bytes','path','written']);
      assert.equal(reads,1);assert.equal(commits,1);
      assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'beta\nalpha\ntail\n');
      assert.ok(execution.fileDiff.added>0);assert.ok(execution.fileDiff.removed>0);
    } finally {fileIo.rename=rename;fileIo.open=open;}
    await invoke('edit_file',{path:'a.txt',oldText:'tail',newText:'$& $1 $` literal'});
    assert.ok(fs.readFileSync(nativePath(root+'/a.txt'),'utf8').endsWith('$& $1 $` literal\n'));
  });
  await test('failed batch validation changes neither the file nor its review baseline',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const root='/sandbox/workspace/batch-failure';fs.mkdirSync(nativePath(root),{recursive:true});
    const original='alpha beta\nrepeat repeat\n';fs.writeFileSync(nativePath(root+'/a.txt'),original);
    const native=new NativeWorkspaceFiles(root),tools=new WorkspaceTools(native),signal=new Cancellation();
    const invoke=(name,args)=>tools.execute({id:name,function:{name,arguments:JSON.stringify(args)}},signal);
    await invoke('read_file',{path:'a.txt'});
    const invalid=[
      {edits:[{oldText:'alpha',newText:'changed'},{oldText:'missing',newText:'x'}]},
      {edits:[{oldText:'alpha beta',newText:'x'},{oldText:'beta',newText:'y'}]},
      {edits:[{oldText:'repeat',newText:'x'}]},
      {edits:[{oldText:'alpha',newText:'x'},{oldText:'alpha',newText:'y'}]},
      {edits:[{oldText:'',newText:'x'}]}, {edits:[]}, {edits:null},
      {edits:[{oldText:'alpha',newText:5}]}, {edits:[{oldText:'alpha',newText:'x',extra:true}]},
      {edits:Array(33).fill({oldText:'alpha',newText:'x'})},
      {edits:[{oldText:'alpha',newText:'x'}],oldText:'beta',newText:'y'},
      {oldText:'alpha',newText:'\0'}
    ];
    for(const args of invalid){await assert.rejects(invoke('edit_file',{path:'a.txt',...args}));
      assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),original);assert.equal(await native.baseline('a.txt'),undefined);}
    await assert.rejects(invoke('edit_file',{path:'a.txt',edits:[{oldText:'alpha',newText:'x'},{oldText:'missing',newText:'y'}]}),/第 2 项/);
    await invoke('edit_file',{path:'a.txt',edits:[{oldText:'alpha',newText:''},{oldText:' beta',newText:'ok'}]});
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'ok\nrepeat repeat\n');
  });
  await test('native edits preserve UTF-8 BOM, CRLF, untouched mixed endings and no final newline',async()=>{
    const root='/sandbox/workspace/line-endings';fs.mkdirSync(nativePath(root),{recursive:true});
    const native=new NativeWorkspaceFiles(root),signal=new Cancellation();
    const original='\uFEFFhead\r\nold\r\nblock\r\ntail\nlast';
    fs.writeFileSync(nativePath(root+'/a.txt'),original);
    const snapshot=await native.read('a.txt',signal);assert.equal(snapshot.content,original);
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const view=JSON.parse(await new WorkspaceTools(native).execute({id:'read',function:{name:'read_file',arguments:'{"path":"a.txt"}'}},signal));
    assert.equal(view.content,original.slice(1),'hide the encoding marker from text copied by the model');
    const receipt=await native.edit('a.txt',[{oldText:'old\nblock',newText:'new\nmore'}],snapshot.version,signal);
    const expected='\uFEFFhead\r\nnew\r\nmore\r\ntail\nlast';
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),expected);
    assert.equal(receipt.before,original);assert.equal(receipt.after,expected);
    const noop=await native.edit('a.txt',[{oldText:'more\ntail\nlast',newText:'more\ntail\nlast'}],receipt.version,signal);
    assert.equal(noop.after,expected,'no-op must not normalize untouched mixed endings');
    await native.restore('a.txt',expected);assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),original);
    const empty=await native.write('empty.txt','',signal);assert.equal(empty.version.length,44);
  });
  await test('only explicit successful reads and writes authorize mutations; stale content is rejected',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const root='/sandbox/workspace/observations';fs.mkdirSync(nativePath(root),{recursive:true});
    fs.writeFileSync(nativePath(root+'/a.txt'),'alpha\ntail');
    const native=new NativeWorkspaceFiles(root),signal=new Cancellation();let tools=new WorkspaceTools(native);
    const invoke=(name,args)=>tools.execute({id:name,function:{name,arguments:JSON.stringify(args)}},signal);
    const edit=()=>invoke('edit_file',{path:'a.txt',oldText:'alpha',newText:'beta'});
    await assert.rejects(edit(),/先.*读取/);
    await assert.rejects(invoke('write_file',{path:'a.txt',content:'lost'}),/先.*读取/);
    await invoke('search_file_content',{path:'.',query:'alpha'});await assert.rejects(edit(),/先.*读取/);
    await assert.rejects(invoke('read_file',{path:'a.txt',offset:0}));await assert.rejects(edit(),/先.*读取/);
    await invoke('read_file',{path:'a.txt',offset:1,limit:1});
    // Same byte count, with timestamps restored: content version still detects a change outside the read page.
    const stat=fs.statSync(nativePath(root+'/a.txt'));
    fs.writeFileSync(nativePath(root+'/a.txt'),'alpha\nTAIL');fs.utimesSync(nativePath(root+'/a.txt'),stat.atime,stat.mtime);
    await assert.rejects(edit(),/已变化/);await assert.rejects(invoke('write_file',{path:'a.txt',content:'lost'}),/已变化/);
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'alpha\nTAIL');
    await invoke('read_file',{path:'a.txt'});await edit();
    await invoke('write_file',{path:'a.txt',content:'new'});
    tools=new WorkspaceTools(native);await assert.rejects(edit(),/先.*读取/);
    await invoke('write_file',{path:'created.txt',content:'new'});
    await invoke('edit_file',{path:'created.txt',oldText:'new',newText:'edited'});
    await invoke('read_file',{path:'a.txt'});fs.unlinkSync(nativePath(root+'/a.txt'));
    await assert.rejects(invoke('write_file',{path:'a.txt',content:'resurrect'}),/已变化/);
    assert.equal(fs.existsSync(nativePath(root+'/a.txt')),false);
  });
  await test('shared mutation queue prevents lost updates across workspace adapter instances',async()=>{
    const root='/sandbox/workspace/racing';fs.mkdirSync(nativePath(root),{recursive:true});
    const a=new NativeWorkspaceFiles(root),b=new NativeWorkspaceFiles(root),signal=new Cancellation();
    const original=await a.write('a.txt','initial',signal);
    const results=await Promise.allSettled([
      a.edit('a.txt',[{oldText:'initial',newText:'first'}],original.version,signal),
      b.edit('a.txt',[{oldText:'initial',newText:'second'}],original.version,signal)
    ]);
    assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
    assert.match(results.find(r=>r.status==='rejected').reason.message,/已变化/);
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'first');
    const creates=await Promise.allSettled([a.write('new.txt','first',signal,{version:null}),b.write('new.txt','second',signal,{version:null})]);
    assert.equal(creates.filter(r=>r.status==='fulfilled').length,1);
  });
  await test('queue holds through native commit, allows different files and releases after cancellation',async()=>{
    const root='/sandbox/workspace/queue';fs.mkdirSync(nativePath(root),{recursive:true});
    const a=new NativeWorkspaceFiles(root),b=new NativeWorkspaceFiles(root),signal=new Cancellation();
    let release,entered;const blocked=new Promise(r=>release=r),started=new Promise(r=>entered=r);
    const rename=fileIo.rename;let holding=true;
    fileIo.rename=async(from,to)=>{if(to===root+'/a.txt'&&holding){holding=false;entered();await blocked;}return rename(from,to);};
    let first,second;
    try{
      first=a.write('a.txt','first',signal);await started;
      const cancelled=new Cancellation();let secondFinished=false;
      second=b.write('a.txt','second',cancelled).then(()=>{secondFinished=true;return undefined;},e=>{secondFinished=true;return e;});
      cancelled.cancel();
      await b.write('b.txt','independent',signal);
      assert.equal(secondFinished,false,'queued cancellation must not release another writer while native I/O is active');
      release();await first;assert.match((await second).message,/停止/);
      await b.write('a.txt','third',signal);assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'third');
      assert.equal(fs.readdirSync(nativePath(root)).filter(p=>p.endsWith('.tmp')).length,0);
    }finally{release();await first;await second;fileIo.rename=rename;}
  });
  await test('delete waits for an active write and rejects the version confirmed before that write',async()=>{
    const root='/sandbox/workspace/delete-race';fs.mkdirSync(nativePath(root),{recursive:true});
    const a=new NativeWorkspaceFiles(root),b=new NativeWorkspaceFiles(root),signal=new Cancellation();
    const initial=await a.write('a.txt','initial',signal,{version:null});
    const confirmed=await b.removalVersion('a.txt');
    let release,entered;const blocked=new Promise(r=>release=r),started=new Promise(r=>entered=r);
    const rename=fileIo.rename;let holding=true,writer,deleted,deleteFinished=false;
    fileIo.rename=async(from,to)=>{if(to===root+'/a.txt'&&holding){holding=false;entered();await blocked;}return rename(from,to);};
    try {
      writer=a.write('a.txt','new content',signal,{version:initial.version});await started;
      deleted=b.remove('a.txt',confirmed).then(()=>{deleteFinished=true;return undefined;},e=>{deleteFinished=true;return e;});
      await b.write('independent.txt','other file',signal,{version:null});
      assert.equal(deleteFinished,false,'Deletion must wait for publication, not unlink underneath a writer');
      release();await writer;assert.equal((await deleted).code,'FS_STALE_VERSION');
      assert.equal((await a.read('a.txt',signal)).content,'new content');
    } finally {release();await writer;await deleted;fileIo.rename=rename;}
    const observed=await a.read('a.txt',signal),version=await b.removalVersion('a.txt');
    const results=await Promise.allSettled([b.remove('a.txt',version),a.remove('a.txt',version)]);
    assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
    assert.equal(results.find(r=>r.status==='rejected').reason.code,'FS_STALE_VERSION');
    await assert.rejects(a.write('a.txt','stale editor',signal,{version:observed.version}),e=>e.code==='FS_STALE_VERSION');
    assert.equal(fs.existsSync(nativePath(root+'/a.txt')),false,'Stale saves must not resurrect deleted files');
  });
  await test('binary deletion uses a guarded snapshot and releases its lock after native failure',async()=>{
    const root='/sandbox/workspace/delete-binary';fs.mkdirSync(nativePath(root),{recursive:true});
    const file=nativePath(root+'/image.png'),files=new NativeWorkspaceFiles(root);
    const bytes=Buffer.alloc(70000,0xff);bytes[0]=0;fs.writeFileSync(file,bytes);
    const initial=await files.removalVersion('image.png');
    assert.equal(initial,crypto.createHash('sha256').update(bytes).digest('base64'));
    bytes[69999]=1;fs.writeFileSync(file,bytes);
    await assert.rejects(files.remove('image.png',initial),e=>e.code==='FS_STALE_VERSION');
    const current=await files.removalVersion('image.png');
    const unlink=fileIo.unlink;fileIo.unlink=async()=>{throw Error('injected unlink failure');};
    try {await assert.rejects(files.remove('image.png',current),/injected unlink failure/);}
    finally {fileIo.unlink=unlink;}
    await files.remove('image.png',current);assert.equal(fs.existsSync(file),false);
  });
  await test('shared-folder aliases queue readers and deletes behind an in-place write',async()=>{
    const root='/sandbox/workspace/shared-read-race',external='/sandbox/external-read-race';
    fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(external),{recursive:true});
    fs.writeFileSync(nativePath(external+'/note.txt'),'old contents');
    const folder={id:'mount',name:'Docs',uri:'file://'+external,addedAt:1};
    const a=new NativeWorkspaceFiles(root,[folder]);
    const b=new NativeWorkspaceFiles(root,[{...folder,id:'alias',name:'Alias'}]),signal=new Cancellation();
    const before=await a.read('shared/Docs/note.txt',signal),confirmed=await b.removalVersion('shared/Alias/note.txt');
    let release,entered;const blocked=new Promise(r=>release=r),started=new Promise(r=>entered=r);
    const write=fileIo.write;let holding=true,writer,reader,deletion,readFinished=false,deleteFinished=false;
    fileIo.write=async(fd,bytes,options)=>{
      if(holding&&handlePaths.get(fd)===nativePath(external+'/note.txt')) {
        holding=false;await handles.get(fd).write(new Uint8Array(bytes).slice(0,3),0,3,options.offset);
        entered();await blocked;
      }
      return write(fd,bytes,options);
    };
    try {
      writer=a.write(before.path,'replacement text',signal,{version:before.version});await started;
      reader=b.read('shared/Alias/note.txt',signal).then(value=>{readFinished=true;return value;});
      deletion=b.remove('shared/Alias/note.txt',confirmed).then(()=>{deleteFinished=true;return undefined;},e=>{deleteFinished=true;return e;});
      await a.write('unrelated.txt','independent',signal,{version:null});
      assert.equal(readFinished,false);assert.equal(deleteFinished,false);
      release();await writer;assert.equal((await reader).content,'replacement text');
      assert.equal((await deletion).code,'FS_STALE_VERSION');
      await b.remove('shared/Alias/note.txt',await b.removalVersion('shared/Alias/note.txt'));
      assert.equal(fs.existsSync(nativePath(external+'/note.txt')),false);
    } finally {release();await writer;await reader;await deletion;fileIo.write=write;}
  });
  await test('oversized MCP results survive storage and reach the model verbatim without projection',async()=>{
    const {stepMessages}=load(path.join(source,'model/Agent'));
    const {executeToolBatch}=load(path.join(source,'services/ToolExecution'));
    const approval=new ToolApproval(),signal=new Cancellation();let invocations=0;
    const payload='资料🙂'.repeat(24000)+'TAIL-AFTER-48000';
    const mcp=new McpTools([server],approval,()=>({list:async()=>[{name:'large',inputSchema:{type:'object'}}],call:async()=>{invocations++;return{content:[{type:'text',text:payload}]};}}));
    const call=(name,args)=>({id:name,type:'function',function:{name,arguments:JSON.stringify(args)}});
    await mcp.execute(call('mcp_list_tools',{server:'s'}),signal);
    const step={content:'',tools:[{call:call('mcp_call',{server:'s',tool:'large',arguments:{}}),status:'pending',output:''}]};
    const approvalReady=approvalRequested(approval);
    const run=executeToolBatch(step,0,mcp,mcp.definitions(),signal,{checkpoint:async()=>{},event:()=>{}});
    await approvalReady;approval.respond(true);await run;
    assert.equal(step.tools[0].status,'complete');assert.equal(JSON.parse(step.tools[0].output).content[0].text,payload);
    const root=path.join(fixture,'full-mcp');fs.mkdirSync(root);const disk=new ConversationStore(root),data=model.emptyData();
    data.activeThreadId='full';data.threads=[{id:'full',title:'Full MCP',updatedAt:1,messages:[{id:'u',role:'user',content:'Read',status:'complete',error:''},
      {id:'a',role:'assistant',content:'',status:'complete',error:'',steps:[step]}]}];await disk.save(data);
    const saved=(await disk.load()).threads[0].messages[1].steps[0];
    const toolMessage=stepMessages(saved).find(m=>m.role==='tool');
    assert.equal(toolMessage.content,saved.tools[0].output);
    assert.ok(toolMessage.content.includes('TAIL-AFTER-48000'));
    assert.ok(!toolMessage.content.includes('contextPreview'));
    assert.equal(invocations,1);
  });
  await test('search discovers beyond directory caps, filters globs, pages matches and preserves context',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const root='/sandbox/workspace/search-pages';fs.mkdirSync(nativePath(root),{recursive:true});fs.mkdirSync(nativePath(root+'/src'));
    for(let i=0;i<205;i++)fs.writeFileSync(nativePath(root+`/src/f${String(i).padStart(3,'0')}.ts`),'before\nTODO '+i+'\nafter');
    fs.writeFileSync(nativePath(root+'/skip.md'),'TODO markdown');fs.writeFileSync(nativePath(root+'/.hidden.ts'),'TODO hidden');
    const native=new NativeWorkspaceFiles(root),tools=new WorkspaceTools(native),signal=new Cancellation();
    const invoke=async(name,args)=>JSON.parse(await tools.execute({id:name,function:{name,arguments:JSON.stringify(args)}},signal));
    const first=await invoke('list_files',{path:'src'}),last=await invoke('list_files',{path:'src',offset:first.nextOffset});
    assert.equal(first.entries.length,200);assert.equal(last.entries.length,5);
    let reads=0;const original=native.read.bind(native);native.read=async(...args)=>{reads++;return original(...args);};
    let names=[],cursor;do{const page=await invoke('find_files',{path:'.',glob:'src/**/*.ts',limit:17,cursor});names.push(...page.paths);cursor=page.nextCursor;}while(cursor);
    assert.equal(names.length,205);assert.equal(new Set(names).size,205);assert.equal(reads,0,'finding names must not read text');
    let matches=[];cursor=undefined;do{const page=await invoke('search_file_content',{path:'.',glob:'*.ts',query:'todo',ignoreCase:true,context:1,limit:19,cursor});matches.push(...page.matches);cursor=page.nextCursor;}while(cursor);
    assert.equal(matches.length,205);assert.ok(matches.every(m=>m.line===2&&m.before[0]==='before'&&m.after[0]==='after'));
    assert.equal(new Set(matches.map(m=>m.path)).size,205);
    await assert.rejects(tools.execute({id:'edit',function:{name:'edit_file',arguments:'{"path":"src/f000.ts","oldText":"TODO","newText":"DONE"}'}},signal),e=>e.code==='FS_NOT_OBSERVED');
  });
  await test('search continues within a file and through empty pages, rejects stale or mismatched cursors',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const root='/sandbox/workspace/search-cursor';fs.mkdirSync(nativePath(root),{recursive:true});
    const native=new NativeWorkspaceFiles(root),tools=new WorkspaceTools(native),signal=new Cancellation();
    const invoke=async(name,args)=>JSON.parse(await tools.execute({id:name,function:{name,arguments:JSON.stringify(args)}},signal));
    fs.writeFileSync(nativePath(root+'/many.txt'),'TODO\n'.repeat(230));
    const args={path:'.',query:'TODO',limit:100};const a=await invoke('search_file_content',args),b=await invoke('search_file_content',{...args,cursor:a.nextCursor}),c=await invoke('search_file_content',{...args,cursor:b.nextCursor});
    assert.equal(a.matches.length+b.matches.length+c.matches.length,230);assert.equal(c.truncated,false);assert.equal(b.matches[0].line,101);
    const replay=await invoke('search_file_content',{...args,cursor:a.nextCursor});assert.deepEqual(replay.matches,b.matches);
    const otherRun=new WorkspaceTools(native);
    await otherRun.execute({id:'other',function:{name:'search_file_content',arguments:JSON.stringify(args)}},signal);
    await assert.rejects(otherRun.execute({id:'other',function:{name:'search_file_content',arguments:JSON.stringify({...args,cursor:a.nextCursor})}},signal),e=>e.code==='FS_INVALID_CURSOR');
    await assert.rejects(invoke('search_file_content',{...args,query:'changed',cursor:a.nextCursor}),e=>e.code==='FS_INVALID_CURSOR');
    fs.appendFileSync(nativePath(root+'/many.txt'),'changed');await assert.rejects(invoke('search_file_content',{...args,cursor:a.nextCursor}),e=>e.code==='FS_STALE_SEARCH');
    for(let i=0;i<201;i++)fs.writeFileSync(nativePath(root+`/f${String(i).padStart(3,'0')}.md`),i===200?'TARGET':'other');
    const empty=await invoke('search_file_content',{path:'.',query:'TARGET',glob:'*.md'});assert.equal(empty.matches.length,0);assert.equal(empty.truncated,true);
    const tail=await invoke('search_file_content',{path:'.',query:'TARGET',glob:'*.md',cursor:empty.nextCursor});assert.equal(tail.matches.length,1);
    const cancelled=new Cancellation();cancelled.cancel();await assert.rejects(tools.execute({id:'x',function:{name:'find_files',arguments:'{"path":"."}'}},cancelled));
  });
  await test('turn summaries record net changes, include nested calls, survive reload and never enter model messages',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const {turnFileChanges}=load(path.join(source,'model/TurnFileChanges'));
    const {stepMessages}=load(path.join(source,'model/Agent'));
    const root='/sandbox/workspace/turn-changes';fs.mkdirSync(nativePath(root),{recursive:true});fs.writeFileSync(nativePath(root+'/a.txt'),'base\n');
    const native=new NativeWorkspaceFiles(root),signal=new Cancellation();let tools=new WorkspaceTools(native);
    const invoke=async(name,args)=>{const tool={call:{id:crypto.randomUUID(),type:'function',function:{name,arguments:JSON.stringify(args)}},status:'running',output:''};tool.output=await tools.execute(tool.call,signal,{execution:tool});tool.status='complete';return tool;};
    await invoke('read_file',{path:'a.txt'});
    const first=await invoke('edit_file',{path:'a.txt',oldText:'base',newText:'temporary'});
    const reverted=await invoke('edit_file',{path:'a.txt',oldText:'temporary',newText:'base'});
    assert.equal(turnFileChanges([{content:'',tools:[first,reverted]}]).length,0,'reverted edits must not add up');
    const final=await invoke('edit_file',{path:'a.txt',oldText:'base',newText:'final\nextra'});
    const empty=await invoke('write_file',{path:'empty.txt',content:''});
    const parent={call:{id:'parent',function:{name:'orchestrate',arguments:'{}'}},status:'complete',output:'{}',children:[final,first,reverted,empty]};
    const steps=[{content:'',tools:[parent]}];const changes=turnFileChanges(JSON.parse(JSON.stringify(steps)));
    assert.equal(changes.length,2);assert.equal(changes[0].added,2);assert.equal(changes[0].removed,1);assert.equal(changes[1].created,true);
    assert.ok(!JSON.stringify(stepMessages(steps[0])).includes('turnFileChange'));
    tools=new WorkspaceTools(native);await invoke('read_file',{path:'a.txt'});
    const secondTurn=await invoke('edit_file',{path:'a.txt',oldText:'extra',newText:'next'});
    assert.equal(secondTurn.turnFileChange.diff.added,1);assert.equal(secondTurn.turnFileChange.diff.removed,1);
    assert.equal((await native.baseline('a.txt')).content,'base\n','user restore baseline stays separate');
  });
  await test('real tool execution serializes actionable file errors without modifying the file',async()=>{
    const {WorkspaceTools}=load(path.join(source,'services/WorkspaceTools'));
    const {executeToolBatch}=load(path.join(source,'services/ToolExecution'));
    const root='/sandbox/workspace/error-codes';fs.mkdirSync(nativePath(root),{recursive:true});fs.writeFileSync(nativePath(root+'/a.txt'),'repeat repeat\nunique');
    const tools=new WorkspaceTools(new NativeWorkspaceFiles(root)),signal=new Cancellation();
    const invoke=async(name,args)=>{const step={content:'',tools:[{call:{id:crypto.randomUUID(),type:'function',function:{name,arguments:JSON.stringify(args)}},status:'pending',output:''}]};await executeToolBatch(step,0,tools,tools.definitions(),signal,{checkpoint:async()=>{},event:()=>{}});return step.tools[0];};
    let tool=await invoke('edit_file',{path:'a.txt',oldText:'unique',newText:'x'});let result=JSON.parse(tool.output);
    assert.equal(tool.status,'failed');assert.equal(result.code,'FS_NOT_OBSERVED');assert.equal(result.details.path,'a.txt');assert.equal(result.recovery,'read_file');
    await invoke('read_file',{path:'a.txt'});
    tool=await invoke('edit_file',{path:'a.txt',edits:[{oldText:'unique',newText:'x'},{oldText:'repeat',newText:'y'}]});result=JSON.parse(tool.output);
    assert.equal(result.code,'FS_AMBIGUOUS_MATCH');assert.equal(result.details.editIndex,2);assert.equal(result.details.path,'a.txt');assert.equal(result.recovery,'add_match_context');
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'repeat repeat\nunique');
    fs.writeFileSync(nativePath(root+'/a.txt'),'external');tool=await invoke('write_file',{path:'a.txt',content:'lost'});assert.equal(JSON.parse(tool.output).code,'FS_STALE_VERSION');
    assert.equal(fs.readFileSync(nativePath(root+'/a.txt'),'utf8'),'external');
  });
  await test('common error receipts classify tool arguments, policy, resources and unknown failures without retry',async()=>{
    const {executeToolBatch}=load(path.join(source,'services/ToolExecution'));
    const {ToolSet}=load(path.join(source,'services/ToolSet'));
    const {RuleTools}=load(path.join(source,'services/RuleTools'));
    const {AttachmentTools}=load(path.join(source,'services/AttachmentTools'));
    const {MemoryTools}=load(path.join(source,'services/MemoryTools'));
    const {CodeExecutionTools}=load(path.join(source,'services/CodeExecutionTools'));
    const invoke=async(tools,name,args,raw=false)=>{
      const step={content:'',tools:[{call:{id:crypto.randomUUID(),type:'function',function:{name,arguments:raw?args:JSON.stringify(args)}},status:'pending',output:''}]};
      await executeToolBatch(step,0,tools,tools.definitions(),new Cancellation(),{checkpoint:async()=>{},event:()=>{}});
      return {...step.tools[0],result:JSON.parse(step.tools[0].output)};
    };
    let runs=0;const unknown={definitions:()=>[],execute:async()=>{runs++;throw Error('raw native failure');}};
    let receipt=await invoke(unknown,'x','{',true);assert.equal(receipt.result.code,'INVALID_ARGUMENTS');assert.equal(runs,0);
    receipt=await invoke(unknown,'x',{});assert.equal(receipt.result.code,'UNKNOWN_ERROR');assert.equal(receipt.result.error,'raw native failure');assert.equal(runs,1);
    receipt=await invoke({definitions:()=>[],execute:async()=>{throw null;}},'x',{});assert.equal(receipt.result.code,'UNKNOWN_ERROR');assert.equal(receipt.result.error,'null');
    receipt=await invoke(new ToolSet([]),'missing',{});assert.equal(receipt.result.code,'TOOL_UNAVAILABLE');
    receipt=await invoke(new RuleTools(unknown,true),'write_file',{});assert.equal(receipt.result.code,'PERMISSION_DENIED');assert.equal(runs,1);
    receipt=await invoke(new AttachmentTools([]),'read_attachment',{id:'missing'});assert.equal(receipt.result.code,'NOT_FOUND');
    receipt=await invoke(new MemoryTools(async()=>{runs++;return '{}';}),'memory',{operations:'[bad'});assert.equal(receipt.result.code,'INVALID_ARGUMENTS');assert.equal(runs,1);
    receipt=await invoke(new CodeExecutionTools({execute:async()=>JSON.stringify({status:'timeout',error:'budget expired',stdout:'before timeout',result:null})}),'execute_code',{code:'while(true){}'});
    assert.equal(receipt.status,'failed');assert.equal(receipt.result.code,'TIMEOUT');assert.equal(receipt.result.status,'timeout');assert.equal(receipt.result.stdout,'before timeout');
    receipt=await invoke(new CodeExecutionTools({execute:async()=>JSON.stringify({status:'cancelled',error:'stopped',stdout:'partial'})}),'execute_code',{code:'return 1;'});
    assert.equal(receipt.status,'cancelled');assert.equal(receipt.result.code,'CANCELLED');assert.equal(receipt.result.stdout,'partial');
  });
  await test('MCP failures preserve remote data, classify HTTP and denial, and record cancellation separately',async()=>{
    const {executeToolBatch}=load(path.join(source,'services/ToolExecution'));
    const approval=new ToolApproval();let remoteCalls=0;
    const remote={isError:true,content:[{type:'text',text:'remote failure '+ 'x'.repeat(60000)}],error:{remote:'untouched'}};
    const tools=new McpTools([server],approval,()=>({list:async()=>[{name:'write',inputSchema:{type:'object'}}],call:async()=>{remoteCalls++;return remote;}}));
    const call=(name,args)=>({id:crypto.randomUUID(),type:'function',function:{name,arguments:JSON.stringify(args)}});
    await tools.execute(call('mcp_list_tools',{server:'s'}),new Cancellation());
    const run=async(allow)=>{
      const step={content:'',tools:[{call:call('mcp_call',{server:'s',tool:'write',arguments:{}}),status:'pending',output:''}]};
      const ready=approvalRequested(approval);
      const pending=executeToolBatch(step,0,tools,tools.definitions(),new Cancellation(),{checkpoint:async()=>{},event:()=>{}});
      await ready;approval.respond(allow);await pending;return step.tools[0];
    };
    let receipt=await run(false);assert.equal(JSON.parse(receipt.output).code,'USER_DENIED');assert.equal(remoteCalls,0);
    receipt=await run(true);let result=JSON.parse(receipt.output);assert.equal(receipt.status,'failed');assert.equal(result.code,'REMOTE_TOOL_ERROR');assert.deepEqual(result.details.result,remote);assert.equal(remoteCalls,1);
    for(const [status,code] of [[401,'AUTH_REQUIRED'],[403,'PERMISSION_DENIED'],[429,'RATE_LIMITED'],[503,'HTTP_ERROR']]){
      let count=0;httpScript=req=>{count++;req.callback(null,status);};
      await assert.rejects(new McpClient(server).list(new Cancellation()),error=>error.code===code&&error.details.httpStatus===status);assert.equal(count,1);
    }
    const signal=new Cancellation();let started;const admitted=new Promise(resolve=>{started=resolve;});
    httpScript=()=>{started();};
    const client=new McpClient(server);const adapter={definitions:()=>[],execute:()=>client.list(signal)};
    const step={content:'',tools:[{call:call('mcp_list_tools',{server:'s'}),status:'pending',output:''}]};
    const pending=executeToolBatch(step,0,adapter,[],signal,{checkpoint:async()=>{},event:()=>{}});await admitted;signal.cancel();await assert.rejects(pending);
    assert.equal(step.tools[0].status,'cancelled');assert.equal(JSON.parse(step.tools[0].output).code,'CANCELLED');
  });
  await test('interrupted receipts distinguish never-started from unknown outcomes without changing completed results',async()=>{
    const {interruptTools}=load(path.join(source,'model/Agent'));
    const steps=[{content:'',tools:['pending','running','complete'].map(status=>({status,output:'original'}))}];
    interruptTools(steps);assert.equal(JSON.parse(steps[0].tools[0].output).code,'NOT_EXECUTED');
    assert.equal(JSON.parse(steps[0].tools[1].output).code,'OUTCOME_UNKNOWN');assert.equal(steps[0].tools[2].output,'original');
  });
  await test('image hydration awaits actual base64 encoding',async()=>{
    const id=crypto.randomUUID(),bytes=Buffer.from([255,216,255,217]);fs.writeFileSync(path.join(fixture,'attachments',id+'.jpg'),bytes);
    const item={id,name:'image.jpg',mime:'image/jpeg',path:id+'.jpg',size:bytes.length};
    const output=await Attachments.hydrate([{role:'user',content:'look',attachments:[item]}]);assert.equal(output[0].images[0],'data:image/jpeg;base64,'+bytes.toString('base64'));
  });
  await test('Office ZIP extraction is bounded and keeps paragraph and cell positions',async()=>{
    function zip(name,text){const filename=Buffer.from(name),raw=Buffer.from(text),packed=zlib.deflateRawSync(raw);const local=Buffer.alloc(30);local.writeUInt32LE(0x04034b50);local.writeUInt16LE(8,8);local.writeUInt32LE(packed.length,18);local.writeUInt32LE(raw.length,22);local.writeUInt16LE(filename.length,26);
      const directory=Buffer.alloc(46);directory.writeUInt32LE(0x02014b50);directory.writeUInt16LE(8,10);directory.writeUInt32LE(packed.length,20);directory.writeUInt32LE(raw.length,24);directory.writeUInt16LE(filename.length,28);
      const end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(1,8);end.writeUInt16LE(1,10);end.writeUInt32LE(directory.length+filename.length,12);end.writeUInt32LE(local.length+filename.length+packed.length,16);return Uint8Array.from(Buffer.concat([local,filename,packed,directory,filename,end])).buffer;}
    const {officeText,zipEntries}=load(path.join(source,'services/DocumentText'));
    assert.match(await officeText(zip('word/document.xml','<w:document><w:p><w:t>中文 &amp; text</w:t></w:p></w:document>')),/中文 & text/);
    assert.match(await officeText(zip('xl/worksheets/sheet1.xml','<worksheet><row><c r="A1" t="inlineStr"><is><t>Title</t></is></c><c r="B1"><v>42</v></c></row></worksheet>')),/A1: Title\nB1: 42/);
    assert.throws(()=>zipEntries(new ArrayBuffer(1)));
  });
  await test('OAuth validates resource, uses PKCE, binds tokens and refreshes securely',async()=>{
    const {McpOAuth}=load(path.join(source,'services/McpOAuth'));let challenge='',tokenRequests=0;
    const json=value=>({responseCode:200,header:{},result:JSON.stringify(value)});
    jsonScript=(url,options)=>{
      assert.equal(options.maxRedirects,0);
      if(url===server.url)return{responseCode:401,header:{'www-authenticate':'Bearer resource_metadata="https://fixture.invalid/resource"'},result:''};
      if(url.endsWith('/resource'))return json({resource:server.url,authorization_servers:['https://auth.invalid']});
      if(url.includes('.well-known'))return json({issuer:'https://auth.invalid',authorization_endpoint:'https://auth.invalid/authorize',token_endpoint:'https://auth.invalid/token',registration_endpoint:'https://auth.invalid/register',code_challenge_methods_supported:['S256']});
      if(url.endsWith('/register')){const body=JSON.parse(options.extraData);assert.equal(body.token_endpoint_auth_method,'none');return json({client_id:'native-app'});}
      if(url.endsWith('/token')){tokenRequests++;const params=new URLSearchParams(options.extraData);assert.equal(params.get('resource'),server.url);
        if(params.get('grant_type')==='authorization_code'){assert.equal(crypto.createHash('sha256').update(params.get('code_verifier')).digest('base64url'),challenge);return json({access_token:'first',refresh_token:'refresh',expires_in:1,token_type:'Bearer'});}
        assert.equal(params.get('refresh_token'),'refresh');return json({access_token:'second',expires_in:3600,token_type:'Bearer'});}
      throw Error('unexpected '+url);
    };
    const context={startAbility:async want=>{const url=new URL(want.uri);challenge=url.searchParams.get('code_challenge');assert.equal(url.searchParams.get('code_challenge_method'),'S256');
      McpOAuth.receive('tinybot-harmony://oauth/callback?state=wrong&code=ignored');
      setTimeout(()=>McpOAuth.receive('tinybot-harmony://oauth/callback?state='+url.searchParams.get('state')+'&code=valid'),0);}};
    const alias=await McpOAuth.login(server,context);assert.equal(tokenRequests,1);
    const authenticated={...server,credentialAlias:alias,authType:'oauth'};const tokens=await Promise.all([McpOAuth.bearer(authenticated),McpOAuth.bearer(authenticated)]);
    assert.deepEqual(tokens,['second','second']);assert.equal(tokenRequests,2);await assert.rejects(McpOAuth.bearer({...authenticated,url:'https://other.invalid/mcp'}),/不匹配/);
    await assert.rejects(McpOAuth.login(server, { startAbility: async () => {
      throw Object.assign(Error('PRIVATE_AUTHORIZATION_URI'), { code: 16000042 });
    } }, 'native-app'), /浏览器/);
    const launchFailure = diagnosticLogs.findLast(data => data.event === 'browser_launch_failed');
    assert.equal(launchFailure.fields.errorCode, 16000042);
    assert.ok(!JSON.stringify(launchFailure).includes('PRIVATE_AUTHORIZATION_URI'));
  });

  await test('configured API OAuth uses PKCE, declared scopes and rotating tokens without MCP resource discovery',async()=>{
    const {McpOAuth}=load(path.join(source,'services/McpOAuth'));let challenge='',requests=0;
    const json=value=>({responseCode:200,header:{},result:JSON.stringify(value)});
    jsonScript=(url,options)=>{
      assert.equal(url,'https://api-auth.invalid/token');assert.equal(options.maxRedirects,0);requests++;
      const params=new URLSearchParams(options.extraData);assert.equal(params.get('resource'),null,'Generic OAuth does not force RFC8707 resource parameters');
      if(params.get('grant_type')==='authorization_code') {
        assert.equal(params.get('client_id'),'registered-panel-app');assert.equal(params.get('redirect_uri'),'tinybot-harmony://oauth/callback');
        assert.equal(crypto.createHash('sha256').update(params.get('code_verifier')).digest('base64url'),challenge);
        return json({access_token:'api-first',refresh_token:'api-refresh',expires_in:1,token_type:'Bearer'});
      }
      assert.equal(params.get('refresh_token'),'api-refresh');return json({access_token:'api-second',refresh_token:'api-rotated',expires_in:3600,token_type:'Bearer'});
    };
    const config={clientId:'registered-panel-app',authorizationEndpoint:'https://api-auth.invalid/authorize',tokenEndpoint:'https://api-auth.invalid/token',scopes:['read:metrics']};
    const context={startAbility:async want=>{const url=new URL(want.uri);challenge=url.searchParams.get('code_challenge');assert.equal(url.searchParams.get('scope'),'read:metrics');
      assert.equal(url.searchParams.get('code_challenge_method'),'S256');assert.equal(url.searchParams.get('resource'),null);
      McpOAuth.receive('tinybot-harmony://oauth/callback?state=wrong&code=ignored');
      setTimeout(()=>McpOAuth.receive('tinybot-harmony://oauth/callback?state='+url.searchParams.get('state')+'&code=api-code'),0);}};
    const alias=await McpOAuth.loginConfigured('https://api.invalid/metrics',config,context);
    const resource={url:'https://api.invalid/metrics',credentialAlias:alias,authType:'oauth'};
    assert.deepEqual(await Promise.all([McpOAuth.bearer(resource),McpOAuth.bearer(resource)]),['api-second','api-second']);assert.equal(requests,2);
    assert.equal(JSON.parse(secrets.get(alias)).refreshToken,'api-rotated');
    await assert.rejects(McpOAuth.bearer({...resource,url:'https://other.invalid/metrics'}),/不匹配/);
    await assert.rejects(McpOAuth.loginConfigured(resource.url,{...config,tokenEndpoint:'http://insecure.invalid/token'},context),/HTTPS/);
    const {oauthJson}=load(path.join(source,'services/McpOAuth'));
    jsonScript=()=>({responseCode:200,header:{},result:'ACCESS_TOKEN_PRIVATE invalid json'});
    await assert.rejects(oauthJson(config.tokenEndpoint,'grant_type=refresh_token'),error=>error.message==='OAuth service returned invalid JSON');
  });
  await test('project sessions use the same native tools, deliveries and task-output root while standalone chats stay isolated', async()=>{
    const {NativeSessionResources}=load(path.join(source,'services/NativeSessionService'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {defaultExtensions}=load(path.join(source,'model/Skills'));
    const root='/sandbox/project-tools'; fs.mkdirSync(nativePath(root),{recursive:true});
    const resources=new NativeSessionResources(root,new ProviderRegistry(),new ToolApproval());
    await resources.ensureWorkspace('project-work');
    await resources.ensureWorkspace('a','project-work'); await resources.ensureWorkspace('b','project-work');
    const ext=defaultExtensions();ext.webEnabled=false;
    const tools=id=>resources.tools(id,ext,'',undefined,[],undefined,'project-work');
    const invoke=(group,name,args)=>group.execute({id:crypto.randomUUID(),type:'function',function:{name,arguments:JSON.stringify(args)}},new Cancellation());
    const a=tools('a'),b=tools('b');
    await invoke(a,'write_file',{path:'src/main.js',content:'return 1;'});
    assert.equal(JSON.parse(await invoke(b,'read_file',{path:'src/main.js'})).content,'return 1;');
    await invoke(b,'edit_file',{path:'src/main.js',oldText:'1',newText:'2'});
    assert.equal(JSON.parse(await invoke(a,'read_file',{path:'src/main.js'})).content,'return 2;');
    assert.equal(JSON.parse(await invoke(b,'present_files',{files:[{path:'src/main.js'}]})).files[0].path,'src/main.js');
    await resources.afterTask('b','answer','delivered','project-work');
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/project-work/任务结果/answer.md'),'utf8'),'delivered');
    assert.equal(fs.existsSync(nativePath(root+'/workspace/a')),false);
    await resources.ensureWorkspace('standalone');
    await assert.rejects(invoke(resources.tools('standalone',ext,''),'read_file',{path:'src/main.js'}));
    await assert.rejects(invoke(b,'read_file',{path:'../standalone/main.js'}));
    await assert.rejects(resources.ensureWorkspace('a','missing'),/项目工作区/);
    assert.equal(fs.existsSync(nativePath(root+'/workspace/missing')),false);
  });
  await test('projects persist atomically, keep old chats unassigned, inherit on forks and survive deletion and restart',async()=>{
    const {NativeSessionResources}=load(path.join(source,'services/NativeSessionService'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {SessionService}=load(path.join(source,'services/SessionService'));
    const {projectContext}=load(path.join(source,'model/Project'));
    const root='/sandbox/project-session';fs.mkdirSync(nativePath(root),{recursive:true});
    const repository=new ConversationStore(root), vault={read:async()=>'',write:async()=>{},remove:async()=>{}};
    const resources=new NativeSessionResources(root,new ProviderRegistry(),new ToolApproval());
    const create=()=>new SessionService(repository,idleRuntime(vault),vault,resources);
    const old=model.emptyData();old.version=1;delete old.projects;
    old.threads=[{id:'legacy',title:'original',updatedAt:1,messages:[]}];old.activeThreadId='legacy';
    await repository.save(old);const session=create();await session.initialize();assert.equal(session.state.ready,true,session.state.error);
    const before=session.snapshot();failManifest=true;
    assert.equal(await session.saveProject('Failed','do not publish'),false);failManifest=false;
    assert.equal(JSON.stringify(session.snapshot()),JSON.stringify(before));
    assert.equal((await repository.load()).projects.length,0);
    assert.equal(await session.saveProject('Calculator','Keep calculations pure.'),true,session.state.error);
    let data=session.snapshot();const project=data.projects[0],a=data.activeThreadId;
    assert.equal(data.threads.find(t=>t.id==='legacy').projectId,undefined);
    assert.equal(session.workspaceId,project.workspaceId);
    const files=new NativeWorkspaceFiles(root+'/workspace/'+project.workspaceId);
    await files.write('main.js','v1',new Cancellation());
    assert.equal(await session.newThread(project.id),true);
    assert.equal(session.snapshot().activeThreadId,a,'An untouched project chat is reused');
    assert.equal(await session.renameThread(a,'First project chat'),true);
    assert.equal(await session.newThread(project.id),true);const b=session.snapshot().activeThreadId;
    assert.notEqual(a,b);assert.equal(session.workspaceId,project.workspaceId);
    assert.equal(await session.forkThread(),true);data=session.snapshot();
    const branch=data.threads.find(t=>t.id===data.activeThreadId);
    assert.equal(branch.projectId,project.id);assert.equal(branch.parentThreadId,b);
    assert.ok(projectContext(data,branch).includes('Keep calculations pure.'));
    assert.ok(!projectContext(data,branch).includes('独立的新工作区'));
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/'+project.workspaceId+'/main.js'),'utf8'),'v1');
    assert.equal(await session.saveProject('Renamed','Updated.',project.id),true);
    assert.equal(await session.deleteThread(a),true);
    assert.equal(await session.deleteThread(b),true);
    assert.equal(await session.deleteThread(branch.id),true);
    data=session.snapshot();assert.equal(data.projects.length,1);assert.equal(data.projects[0].workspaceId,project.workspaceId);
    assert.equal(data.threads.filter(t=>t.projectId===project.id).length,0);
    const restart=create();await restart.initialize();assert.equal(restart.state.ready,true,restart.state.error);
    assert.equal(await restart.newThread(project.id),true);
    assert.equal(restart.workspaceId,project.workspaceId);assert.equal(restart.snapshot().projects[0].name,'Renamed');
    await restart.selectThread('legacy');await restart.forkThread();
    const ordinary=restart.snapshot().threads.find(t=>t.id===restart.snapshot().activeThreadId);
    assert.equal(ordinary.projectId,undefined);assert.equal(restart.workspaceId,ordinary.id);
    await assert.rejects(Promise.resolve().then(()=>model.parseAppData(JSON.stringify({...data,projects:[],threads:[{...data.threads[0],projectId:project.id}]}))),/项目/);
    fs.renameSync(nativePath(root+'/workspace/'+project.workspaceId),nativePath(root+'/workspace/missing-project'));
    const missing=create();await missing.initialize();assert.equal(missing.state.ready,false);assert.match(missing.state.error,/项目工作区/);
    assert.equal(fs.existsSync(nativePath(root+'/workspace/'+project.workspaceId)),false);
  });
  await test('independent panel Agent reads scoped files with restricted tools, persists runs, rejects bad output and cancels without a source chat',async()=>{
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {installNativePanelAgent}=load(path.join(source,'services/NativePanelAgent'));
    const {LifePanels}=load(path.join(source,'services/LifePanels'));
    const {WorkspaceStore}=load(path.join(source,'model/WorkspaceStore'));
    const root='/sandbox/panel-agent',workspace=new WorkspaceStore(root);fs.mkdirSync(nativePath(root),{recursive:true});await workspace.ensureThread('owner');
    fs.writeFileSync(nativePath(workspace.pathFor('owner')+'/count.json'),'{"count":7}');
    const settings=model.emptyData();settings.config={...settings.config,providerId:'panel-agent-test',model:'fixture',baseUrl:'https://fixture.invalid/v1',credentialAlias:''};
    settings.extensions={...settings.extensions,webEnabled:false};settings.threads=[];
    const registry=new ProviderRegistry();let mode='valid',requests=0,entered;
    registry.register({info:{id:'panel-agent-test',name:'Panel test'},endpoint:address=>address,
      async stream(request,cancellation,onText){
        requests++;const names=request.tools.map(tool=>tool.function.name);
        for(const forbidden of ['write_file','edit_file','browser_open','mcp_call','request_user_input','publish_life_panel'])assert.ok(!names.includes(forbidden),forbidden);
        assert.ok(names.includes('read_file'));assert.ok(request.messages.some(m=>m.content.includes('Read count.json')));
        for(const mail of ['list_mail_accounts','search_mail','read_mail'])assert.ok(names.includes(mail),'Independent panel Agent can use enabled read-only mailbox connections');
        if(mode==='cancel')return new Promise((resolve,reject)=>{entered=true;cancellation.onCancel(()=>reject(Error('cancelled')));});
        if(mode==='bad')return {content:'Unable to obtain a value PRIVATE_MODEL_TEXT',toolCalls:[]};
        if(mode==='error')return {content:'{"status":"error","code":"AUTH_REQUIRED"}',toolCalls:[]};
        if(mode==='invalid-data')return {content:'{"status":"success","data":{"count":"bad"}}',toolCalls:[]};
        if(!request.messages.some(message=>message.role==='tool'))return {content:'',toolCalls:[{id:'read-count',type:'function',function:{name:'read_file',arguments:JSON.stringify({path:mode==='missing'?'missing.json':'count.json'})}}]};
        if(mode==='missing')return {content:'{"status":"error","code":"NOT_FOUND"}',toolCalls:[]};
        assert.ok(request.messages.some(message=>message.role==='tool'&&message.content.includes('7')));
        onText('{"status":"success","data":{"count":7}}');return {content:'{"status":"success","data":{"count":7}}',toolCalls:[]};
      }});
    installNativePanelAgent(root,registry,new CredentialStore(),()=>settings);
    const panels=new LifePanels(root),repo=panels.repository('owner'),spec={version:1,title:'Count',size:'S',source:{type:'agent',prompt:'Read count.json and return its current count'},refreshMinutes:15,data:{count:0},nodes:[{id:'count',kind:'Metric',value:{path:'/data/count'}}]};
    await repo.publish('summary',spec,'summary.panel.json','deleted-chat',false,new Cancellation());
    let record=await repo.refresh('summary',new Cancellation());assert.equal(record.data.count,7);assert.equal(requests,2);assert.equal(record.runs[0].status,'complete');
    mode='bad';await assert.rejects(repo.refresh('summary',new Cancellation()));record=await repo.get('summary');assert.equal(record.data.count,7);assert.equal(record.runs[0].status,'failed');
    assert.equal(record.runs[0].failure.stage,'output');assert.equal(record.runs[0].failure.code,'OUTPUT_INVALID');assert.ok(!JSON.stringify(record).includes('PRIVATE_MODEL_TEXT'));
    mode='error';await assert.rejects(repo.refresh('summary',new Cancellation()));record=await repo.get('summary');assert.equal(record.runs[0].failure.code,'AUTH_REQUIRED');assert.equal(record.runs[0].failure.stage,'acquisition');
    mode='missing';await assert.rejects(repo.refresh('summary',new Cancellation()));record=await repo.get('summary');assert.equal(record.runs[0].failure.stage,'tool');assert.equal(record.runs[0].failure.tool,'read_file');assert.equal(record.runs[0].failure.code,'FILE_NOT_FOUND');
    mode='invalid-data';await assert.rejects(repo.refresh('summary',new Cancellation()));record=await repo.get('summary');assert.equal(record.runs[0].failure.stage,'validation');assert.equal(record.runs[0].failure.code,'DATA_INVALID');assert.equal(record.data.count,7);
    mode='cancel';const signal=new Cancellation(),pending=repo.refresh('summary',signal);while(!entered)await new Promise(r=>setTimeout(r,0));signal.cancel();await assert.rejects(pending);
    record=await repo.get('summary');assert.equal(record.data.count,7);assert.equal(record.runs[0].status,'cancelled');assert.equal(settings.threads.length,0);
  });
  await test('project backup stores shared files once, restores fresh roots and preserves local project files on repeated import',async()=>{
    const {createBackupFile,readBackupFile}=load(path.join(source,'services/Backup'));
    const {SessionService}=load(path.join(source,'services/SessionService'));
    const root='/sandbox/project-backup';fs.mkdirSync(nativePath(root+'/workspace/shared'),{recursive:true});fs.mkdirSync(nativePath(root+'/cache'));
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};
    Attachments.configure(root);
    const data=model.emptyData();data.projects=[{id:'p',workspaceId:'shared',name:'Shared',instructions:'Rules',createdAt:1,updatedAt:1}];
    data.threads=['a','b'].map(id=>({id,projectId:'p',title:id,updatedAt:1,messages:[]}));data.activeThreadId='a';
    fs.writeFileSync(nativePath(root+'/workspace/shared/code.js'),'backup');
    const backup=await createBackupFile(context,data);const envelope=legacyBackupFixture(fs.readFileSync(nativePath(backup)));
    assert.equal(envelope.format,'tinybot-harmony.backup.v2');assert.equal(envelope.files.length,1);assert.equal(envelope.files[0].workspaceId,'shared');
    const restored=await readBackupFile(context,backup,model.emptyData());
    assert.equal(restored.projects[0].id,'p');assert.notEqual(restored.projects[0].workspaceId,'shared');
    assert.equal(restored.threads[0].projectId,restored.threads[1].projectId);
    const restoredFile=nativePath(root+'/workspace/'+restored.projects[0].workspaceId+'/code.js');
    assert.equal(fs.readFileSync(restoredFile,'utf8'),'backup');fs.writeFileSync(restoredFile,'local edit');
    restored.threads=restored.threads.slice(0,1);restored.projects[0].instructions='Local rules';
    const repository=new ConversationStore(root),vault={read:async()=>'',write:async()=>{},remove:async()=>{}};
    await repository.save(restored);
    const resources={createId:()=>crypto.randomUUID(),ensureWorkspace:async()=>{},configureProviders:()=>{},reportError:()=>{},tools:()=>({definitions:()=>[]})};
    const session=new SessionService(repository,idleRuntime(vault),vault,resources);await session.initialize();
    const addition=await readBackupFile(context,backup,session.snapshot());assert.equal(addition.threads.length,1);
    assert.equal(await session.importSnapshot(addition),true,session.state.error);
    assert.equal(session.snapshot().projects[0].instructions,'Local rules');assert.equal(fs.readFileSync(restoredFile,'utf8'),'local edit');
    const snapshot=JSON.stringify(session.snapshot());
    assert.equal(await session.importSnapshot(await readBackupFile(context,backup,session.snapshot())),true);
    assert.equal(JSON.stringify(session.snapshot()),snapshot);
    // No conversations are necessary to preserve a project's files.
    data.threads=[];data.activeThreadId='';
    const emptyBackup=await createBackupFile(context,data);
    const emptyEnvelope = legacyBackupFixture(fs.readFileSync(nativePath(emptyBackup)));
    assert.equal(emptyEnvelope.files.filter(file => file.workspaceId === 'shared').length,1);
    assert.ok(emptyEnvelope.files.some(file => file.workspaceId === restored.projects[0].workspaceId), 'Unreferenced workspaces are retained too');
    // An actual v1 envelope has no project metadata and uses thread IDs for file ownership.
    const legacy=model.emptyData();legacy.version=1;delete legacy.projects;
    legacy.threads=[{id:'old-chat',title:'Old',updatedAt:1,messages:[]}];legacy.activeThreadId='old-chat';
    const legacyPath=root+'/cache/legacy.json';fs.writeFileSync(nativePath(legacyPath),JSON.stringify({format:'tinybot-harmony.backup.v1',data:legacy,attachments:[],files:[{threadId:'old-chat',path:'old.txt',bytes:Buffer.from('old').toString('base64')}]}));
    const old=await readBackupFile(context,legacyPath,model.emptyData());assert.equal(old.projects.length,0);assert.equal(old.threads[0].projectId,undefined);
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/old-chat/old.txt'),'utf8'),'old');
    const invalid=JSON.parse(JSON.stringify(envelope));invalid.data.projects=[];
    fs.writeFileSync(nativePath(root+'/cache/bad-project.json'),JSON.stringify(invalid));
    await assert.rejects(readBackupFile(context,root+'/cache/bad-project.json',session.snapshot()),/项目/);
    assert.equal(fs.readFileSync(restoredFile,'utf8'),'local edit');
  });
  await test('WebDAV stages a real archive, preserves the last snapshot on failure and gates all transfer I/O', async () => {
    const { WebDavBackup } = load(path.join(source, 'services/WebDavBackup'));
    const { saveWebDavConnection, webDavSettings, clearWebDavConnection } = load(path.join(source, 'services/WebDavConnection'));
    const { exportBackup, readBackup, createBackupFile, readBackupFile } = load(path.join(source, 'services/Backup'));
    const root = '/sandbox/webdav-app', context = { cacheDir: root + '/cache', getApplicationContext: () => ({ filesDir: root }) };
    fs.mkdirSync(nativePath(context.cacheDir), { recursive: true });
    const directory = 'https://backup.example/dav/tinybot/', final = directory + 'tinybot-latest.tinybot';
    const openID = backupAccount.openID, data = model.emptyData(), previous = Buffer.from('last valid backup');
    const remote = new Map([[final, previous]]), methods = [];
    let failPut = false, failMove = false, downloadStatus = 200, sessions = 0, closed = 0;
    let otherId = '';
    const result = statusCode => ({ statusCode });
    webDavSession = config => {
      sessions++;
      assert.equal(config.requestConfiguration.security.remoteValidation, 'system');
      assert.equal(config.requestConfiguration.transfer.autoRedirect, false);
      assert.equal(config.headers.authorization, 'Basic ' + Buffer.from('alice:app-password').toString('base64'));
      return {
        async fetch(request) {
          methods.push(request.method);
          assert.match(request.url, /^https:\/\/backup\.example\/dav\/tinybot\/tinybot-[a-f0-9-]+\.partial$/);
          if (request.method === 'PUT') {
            assert.equal(request.headers['content-type'], 'application/octet-stream');
            remote.set(request.url, fs.readFileSync(nativePath(request.content.path)));
            if (failPut) throw Object.assign(Error('redacted server URL'), { code: 1007900056 });
            return result(201);
          }
          if (request.method === 'MOVE') {
            assert.equal(request.headers.Destination, final);
            assert.equal(request.headers.Overwrite, 'T');
            if (failMove) return result(207);
            remote.set(final, remote.get(request.url)); remote.delete(request.url);
            return result(204);
          }
          assert.equal(request.method, 'DELETE');
          remote.delete(request.url);
          return result(204);
        },
        async downloadToFile(address, target) {
          methods.push('GET');
          assert.equal(address, final); assert.equal(target.kind, 'file');
          if (downloadStatus === 200) fs.writeFileSync(nativePath(target.file), remote.get(final));
          return result(downloadStatus);
        },
        close() { closed++; }
      };
    };
    try {
      await assert.rejects(saveWebDavConnection('', 'Backup', 'http://backup.example/dav/', 'alice', 'app-password'), /HTTPS/);
      await assert.rejects(saveWebDavConnection('', 'Backup', 'https://alice:password@backup.example/dav/', 'alice', 'app-password'), /HTTPS/);
      otherId = (await saveWebDavConnection('', 'Other backup', 'https://other.example/dav/', 'bob', 'other-password')).id;
      const { id } = await saveWebDavConnection('', 'Backup', directory.slice(0, -1), 'alice', 'app-password');
      const saved = (await webDavSettings()).find(item => item.id === id);
      assert.equal(saved.directory, directory); assert.equal(saved.username, 'alice'); assert.equal(saved.password, undefined);
      await assert.rejects(saveWebDavConnection(id, 'Backup', directory + 'other/', 'alice', ''), /填写 WebDAV 密码/);
      await saveWebDavConnection(id, 'Backup', directory, 'alice', '');

      backupAccount.openID = '';
      const beforePicker = pickerCalls;
      await assert.rejects(exportBackup(context, data), /请先登录/);
      await assert.rejects(readBackup(context, data), /请先登录/);
      await assert.rejects(createBackupFile(context, data), /请先登录/);
      await assert.rejects(readBackupFile(context, context.cacheDir + '/absent', data), /请先登录/);
      await assert.rejects(WebDavBackup.create(context, data, id), /请先登录/);
      await assert.rejects(WebDavBackup.restore(context, data, id), /请先登录/);
      assert.equal(pickerCalls, beforePicker); assert.equal(sessions, 0);
      assert.deepEqual(fs.readdirSync(nativePath(context.cacheDir)), []);
      backupAccount.openID = openID;

      failPut = true;
      await assert.rejects(WebDavBackup.create(context, data, id), /PUT.*1007900056/);
      assert.deepEqual(methods.splice(0), ['PUT', 'DELETE']);
      assert.deepEqual([...remote], [[final, previous]]);
      failPut = false; failMove = true;
      await assert.rejects(WebDavBackup.create(context, data, id), /MOVE.*207/);
      assert.deepEqual(methods.splice(0), ['PUT', 'MOVE', 'DELETE']);
      assert.deepEqual([...remote], [[final, previous]]);
      failMove = false;
      data.config.userDocument = 'Restored from WebDAV';
      await WebDavBackup.create(context, data, id);
      assert.deepEqual(methods.splice(0), ['PUT', 'MOVE']);
      const restored = await WebDavBackup.restore(context, model.emptyData(), id);
      assert.equal(restored.config.userDocument, data.config.userDocument);
      assert.deepEqual(methods.splice(0), ['GET']);
      assert.doesNotMatch(remote.get(final).toString('utf8'), /app-password/);
      downloadStatus = 404;
      await assert.rejects(WebDavBackup.restore(context, model.emptyData(), id), /没有可恢复的备份/);
      downloadStatus = 302;
      await assert.rejects(WebDavBackup.restore(context, model.emptyData(), id), /最终 HTTPS 目录地址/);
      assert.equal(closed, sessions);
      assert.deepEqual(fs.readdirSync(nativePath(context.cacheDir)), []);
      await clearWebDavConnection(id);
      assert.deepEqual(Array.from(await webDavSettings(), item => item.id), [otherId]);
      assert.equal(remote.size, 1, 'Removing device settings leaves the server backup in place');
    } finally {
      if (otherId) await clearWebDavConnection(otherId);
      backupAccount.openID = openID;
      webDavSession = undefined;
    }
  });
  await test('Nutstore root reuses or creates the backup folder and restores without creating it', async () => {
    const { WebDavBackup } = load(path.join(source, 'services/WebDavBackup'));
    const { saveWebDavConnection, webDavSettings, clearWebDavConnection } = load(path.join(source, 'services/WebDavConnection'));
    const root = '/sandbox/nutstore-app', context = { cacheDir: root + '/cache', getApplicationContext: () => ({ filesDir: root }) };
    fs.mkdirSync(nativePath(context.cacheDir), { recursive: true });
    const davRoot = 'https://dav.jianguoyun.com/dav/', folder = davRoot + 'Tinybot/', lower = davRoot + 'tinybot/';
    const files = new Map(), folders = new Map(), requests = [];
    let createStatus = 201, id = '';
    webDavSession = () => ({
      async fetch(request) {
        const { method, url, headers } = request;
        requests.push(method);
        if (method === 'PROPFIND') {
          assert.ok(url === folder || url === lower);
          assert.equal(headers.Depth, '0'); assert.match(request.content, /resourcetype/);
          return folders.has(url) ? { statusCode: 207, body: Uint8Array.of(folders.get(url) ? 1 : 0).buffer } : { statusCode: 404 };
        }
        if (method === 'MKCOL') {
          assert.equal(url, folder);
          if (createStatus === 201 || createStatus === 405) folders.set(url, true);
          return { statusCode: createStatus };
        }
        const directory = url.slice(0, url.lastIndexOf('/') + 1);
        assert.equal(folders.get(directory), true);
        if (method === 'PUT') {
          files.set(url, fs.readFileSync(nativePath(request.content.path)));
          return { statusCode: 201 };
        }
        assert.equal(method, 'MOVE');
        assert.equal(headers.Destination, directory + 'tinybot-latest.tinybot');
        assert.equal(headers.Overwrite, 'T');
        files.set(headers.Destination, files.get(url)); files.delete(url);
        return { statusCode: 204 };
      },
      async downloadToFile(url, target) {
        requests.push('GET');
        if (!files.has(url)) return { statusCode: 404 };
        fs.writeFileSync(nativePath(target.file), files.get(url));
        return { statusCode: 200 };
      },
      close() {}
    });
    try {
      const data = model.emptyData();
      id = (await saveWebDavConnection('', 'Nutstore', davRoot.slice(0, -1), 'alice', 'app-password')).id;
      assert.equal((await webDavSettings()).find(item => item.id === id).directory, davRoot);
      await assert.rejects(WebDavBackup.restore(context, data, id), /没有可恢复的备份/);
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'PROPFIND']);
      createStatus = 403;
      await assert.rejects(WebDavBackup.create(context, data, id), /无法创建 WebDAV.*403/);
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'PROPFIND', 'MKCOL']);
      assert.equal(files.size, 0);
      createStatus = 201;
      await WebDavBackup.create(context, data, id);
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'PROPFIND', 'MKCOL', 'PUT', 'MOVE']);
      data.config.userDocument = 'Second snapshot';
      await WebDavBackup.create(context, data, id);
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'PUT', 'MOVE']);
      assert.deepEqual([...files.keys()], [folder + 'tinybot-latest.tinybot']);
      assert.equal((await WebDavBackup.restore(context, model.emptyData(), id)).config.userDocument, 'Second snapshot');
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'GET']);

      folders.delete(folder); folders.set(lower, true);
      await WebDavBackup.create(context, data, id);
      assert.deepEqual(requests.splice(0), ['PROPFIND', 'PROPFIND', 'PUT', 'MOVE']);
      assert.ok(files.has(lower + 'tinybot-latest.tinybot'));
      folders.set(folder, false);
      await assert.rejects(WebDavBackup.create(context, data, id), /目标不是文件夹/);
      assert.deepEqual(requests.splice(0), ['PROPFIND']);

      folders.clear(); createStatus = 405;
      await WebDavBackup.create(context, data, id);
      assert.deepEqual(requests, ['PROPFIND', 'PROPFIND', 'MKCOL', 'PROPFIND', 'PUT', 'MOVE']);
      assert.deepEqual(fs.readdirSync(nativePath(context.cacheDir)), []);
    } finally {
      await clearWebDavConnection(id);
      webDavSession = undefined;
    }
  });
  await test('named WebDAV connections preserve legacy grants and isolate accounts at the same URL', async () => {
    const { webDavSettings, saveWebDavConnection, clearWebDavConnection, webDavShareRoot, withWebDavShare } =
      load(path.join(source, 'services/WebDavConnection'));
    const { validateSharedFolders } = load(path.join(source, 'model/SharedFolders'));
    const directory = 'https://example.com/dav/';
    const oldGrant = crypto.randomUUID();
    const alias = 'tinybot.webdav.backup.v1';
    secrets.set(alias, JSON.stringify({ directory, username: 'legacy-user', password: 'old-password', id: oldGrant }));
    let id = '';
    webDavSession = config => ({ auth: config.headers.authorization, close() {} });
    const authFor = grant => withWebDavShare(grant, directory, async (session, verify) => { await verify(); return session.auth; });
    const basic = value => 'Basic ' + Buffer.from(value).toString('base64');
    try {
      const [legacy] = await webDavSettings();
      assert.equal(legacy.name, '默认 WebDAV');
      assert.equal(legacy.grantId, oldGrant);
      const team = await saveWebDavConnection('', 'Team', directory, 'team-user', 'team-password');
      id = team.id;
      assert.deepEqual(Array.from(await webDavSettings(), item => item.name), ['默认 WebDAV', 'Team']);
      const teamGrant = (await webDavShareRoot(id)).id;
      validateSharedFolders([
        { id: 'personal', name: 'Personal', uri: directory, addedAt: 1, webDavConnectionId: oldGrant },
        { id: 'team', name: 'Team', uri: directory, addedAt: 2, webDavConnectionId: teamGrant }
      ]);
      assert.equal(await authFor(oldGrant), basic('legacy-user:old-password'));
      assert.equal(await authFor(teamGrant), basic('team-user:team-password'));
      const renamed = await saveWebDavConnection(legacy.id, 'Personal', directory, 'legacy-user', '');
      assert.equal(renamed.grantId, oldGrant);
      assert.equal((await webDavSettings())[0].name, 'Personal');
      assert.equal(await authFor(oldGrant), basic('legacy-user:old-password'));

      const rotated = await saveWebDavConnection(id, 'Team', directory, 'team-user', 'new-password');
      assert.equal(rotated.grantId, teamGrant);
      assert.equal(await authFor(teamGrant), basic('team-user:new-password'));
      await clearWebDavConnection(id);
      await assert.rejects(authFor(teamGrant), error => error.code === 'SHARED_FOLDER_AUTH_REQUIRED');
      assert.equal(await authFor(oldGrant), basic('legacy-user:old-password'));
      assert.deepEqual(Array.from(await webDavSettings(), item => item.name), ['Personal']);
    } finally {
      if (id) await clearWebDavConnection(id);
      await clearWebDavConnection('legacy');
      webDavSession = undefined;
    }
  });
  await test('cloud folder selection and workspace tools enforce the project grant, connection scope and conditional writes', async () => {
    const { saveWebDavConnection, clearWebDavConnection, webDavShareRoot } = load(path.join(source, 'services/WebDavConnection'));
    const { listWebDavDirectory } = load(path.join(source, 'services/WebDavWorkspaceFiles'));
    const { savedProjectCandidate, importedSessionCandidate } = load(path.join(source, 'services/SessionCandidates'));
    const { WorkspaceTools } = load(path.join(source, 'services/WorkspaceTools'));
    const { RuleTools } = load(path.join(source, 'services/RuleTools'));
    const root = '/sandbox/webdav-shared', base = 'https://backup.example/dav/', directory = base + 'Docs/';
    fs.mkdirSync(nativePath(root), { recursive: true });
    const sent = [];
    let id = '';
    let etag = '"one"', text = 'first', concurrent = false;
    const signal = new Cancellation();
    webDavSession = (config) => {
      assert.equal(config.requestConfiguration.transfer.autoRedirect, false);
      return {
        async fetch(request) {
          sent.push(request);
          if (request.method === 'PROPFIND') {
            const entries = request.url === base ? [
              { href: '/dav/', directory: true }, { href: '/dav/Docs/', directory: true },
              { href: '/dav/Other/', directory: true, status: '403 Forbidden' },
              { href: 'https://other.example/dav/Bad/', directory: true },
              { href: '/dav/escape%2Fchild/', directory: true }, { href: '/elsewhere/', directory: true }
            ] : [{ href: '/dav/Docs/', directory: true }, { href: '/dav/Docs/note.txt', directory: false }];
            assert.equal(request.headers.Depth, '1');
            return { statusCode: 207, body: Uint8Array.from(Buffer.from(JSON.stringify(entries))).buffer };
          }
          assert.equal(request.method, 'PUT'); assert.equal(request.url, directory + 'note.txt');
          if (concurrent) { etag = '"external"'; text = 'changed outside the app'; }
          if (request.headers['If-Match'] !== etag) { return { statusCode: 412, headers: {} }; }
          text = request.content; etag = '"two"';
          return { statusCode: 204, headers: { ETag: [etag] } };
        },
        async downloadToFile(address, target) {
          sent.push({ method: 'GET', url: address });
          assert.equal(address, directory + 'note.txt');
          fs.writeFileSync(nativePath(target.file), text);
          return { statusCode: 200, headers: { etag: [etag] } };
        },
        close() {}, cancel() {}
      };
    };
    try {
      id = (await saveWebDavConnection('', 'Workspace', base, 'alice', 'app-password')).id;
      const connection = await webDavShareRoot(id);
      const listed = await listWebDavDirectory(connection.id, connection.directory, signal);
      assert.deepEqual(Array.from(listed, row => row.uri), [directory]);
      const folder = { id: 'mount', name: 'Cloud', uri: directory, addedAt: 1, webDavConnectionId: connection.id };
      const candidate = savedProjectCandidate(model.emptyData(), 'Cloud project', '',
        () => ({ id: 'thread', messages: [], title: '', updatedAt: 1 }), () => 'project', undefined, [folder]);
      assert.equal(candidate.addedFolders.length, 0, 'Cloud grants do not request native file access');
      const imported = importedSessionCandidate(model.emptyData(), candidate.data, () => 'generated');
      assert.equal(imported.data.projects[0].sharedFolders.length, 0);
      const mounts = [folder];
      let allowed = false, cloudApprovals = 0, sessionApprovals = 0;
      const { ToolFailure } = load(path.join(source, 'model/ToolFailure'));
      const { ApprovalTools } = load(path.join(source, 'services/ApprovalTools'));
      const files = new NativeWorkspaceFiles(root, mounts, () => mounts, async target => {
        assert.equal(target, 'shared/Cloud/note.txt'); cloudApprovals++;
        if (!allowed) throw new ToolFailure('USER_DENIED', 'Fixture denied the write', 'respect_user_decision');
      });
      const tools = new WorkspaceTools(files);
      const ask = new ApprovalTools(tools, { request: async () => { sessionApprovals++; } }, 'Fixture',
        path => path.startsWith('shared/Cloud/'));
      const remotePath = 'shared/Cloud/note.txt';
      const call = (name, args) => ({ id: name, type: 'function', function: { name, arguments: JSON.stringify(args) } });
      assert.equal((await files.list('shared/Cloud', signal)).entries[0].name, 'note.txt');
      assert.equal(await tools.readTextForCode(remotePath, 20, signal), 'first');
      const before = sent.length;
      const write = call('write_file', { path: remotePath, content: 'next' });
      await assert.rejects(files.readJobInput(remotePath, 20, signal), error => error.code === 'PERMISSION_DENIED');
      await assert.rejects(files.createJobOutput(remotePath, Uint8Array.of(1), signal), error => error.code === 'FS_INVALID_PATH');
      await assert.rejects(files.read('shared/Cloud/%2f', signal), error => error.code === 'FS_INVALID_PATH');
      assert.equal(sent.length, before);

      await assert.rejects(new RuleTools(tools, true).execute(write, signal), error => error.code === 'PERMISSION_DENIED');
      await assert.rejects(ask.execute(write, signal), error => error.code === 'USER_DENIED');
      assert.equal(cloudApprovals, 1);
      assert.equal(sent.length, before);
      allowed = true;
      await ask.execute(write, signal);
      assert.equal(cloudApprovals, 2); assert.equal(sessionApprovals, 0);
      assert.equal(text, 'next');
      assert.equal(sent.at(-1).headers['If-Match'], '"one"');

      const full = new WorkspaceTools(new NativeWorkspaceFiles(root, mounts));
      await assert.rejects(new RuleTools(full, true).execute(write, signal), error => error.code === 'PERMISSION_DENIED');
      await full.readTextForCode(remotePath, 20, signal);
      const edit = call('edit_file', { path: remotePath, oldText: 'next', newText: 'full' });
      await full.execute(edit, signal);
      assert.equal(text, 'full');
      assert.equal(cloudApprovals, 2); assert.equal(sessionApprovals, 0);
      concurrent = true;
      await assert.rejects(full.execute(write, signal), error => error.code === 'FS_STALE_VERSION');
      assert.equal(text, 'changed outside the app');
      await saveWebDavConnection(id, 'Workspace', base, 'bob', 'other-password');
      const switched = sent.length;
      await assert.rejects(files.read(remotePath, signal), error => error.code === 'SHARED_FOLDER_AUTH_REQUIRED');
      assert.equal(sent.length, switched);
      assert.deepEqual(fs.readdirSync(nativePath(root)), []);
    } finally { await clearWebDavConnection(id); webDavSession = undefined; }
  });
  await test('backup preserves conversation identities, attachments, files and scoped memory without secrets',async()=>{
    const {exportBackup,readBackup}=load(path.join(source,'services/Backup'));
    const root='/sandbox/backup-app';fs.mkdirSync(nativePath(root+'/workspace/thread'),{recursive:true});fs.mkdirSync(nativePath(root+'/cache'));fs.mkdirSync(nativePath(root+'/attachments'));
    Attachments.configure(root);const id=crypto.randomUUID();fs.writeFileSync(nativePath(root+'/attachments/'+id+'.txt'),'sample');fs.writeFileSync(nativePath(root+'/workspace/thread/note.txt'),'workspace');
    const data=model.emptyData();data.activeThreadId='thread';const attachment={id,name:'input.txt',mime:'text/plain',path:id+'.txt',size:6,text:'sample'};
    data.config.userDocument = '# About me\nCall me Lin.\n';
    data.threads=[{id:'thread',title:'source',updatedAt:1,messages:[{id:'u',role:'user',content:'hello',status:'complete',error:'',attachments:[attachment]},{id:'a',role:'assistant',content:'answer',status:'complete',error:''}],modelRef:{providerId:'provider',modelId:'model'}}];
    data.providerProfiles=[{id:'provider',name:'Provider',protocol:'chat-completions',baseUrl:'https://api.invalid/v1',credentialAlias:'SECRET-ALIAS',noApiKey:false,enabled:true,models:['model'],contextWindow:32768}];
    data.productivity={memories:[{id:'m',content:'fact',threadId:'thread',updatedAt:1,sourceThreadId:'thread',sourceMessageId:'u'}],templates:[],servers:[]};
    data.productivity.options={autoMemory:false,saveSummary:false,readOnly:false,capabilities:[],
      search:{provider:'bing-browser',enabled:true,tavily:{baseUrl:'https://api.tavily.com',credentialAlias:'SECRET-INACTIVE-TAVILY'}}};
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};await exportBackup(context,JSON.parse(JSON.stringify(data)));
    const exported=JSON.stringify(legacyBackupFixture(fs.readFileSync(nativePath(selectedFile))));assert.ok(!exported.includes('SECRET-ALIAS'));
    assert.ok(!exported.includes('SECRET-INACTIVE-TAVILY'));
    // Also reject device-local aliases supplied by an imported file, even for inactive providers.
    const imported=legacyBackupFixture(fs.readFileSync(nativePath(selectedFile)));imported.data.productivity.options.search.tavily.credentialAlias='IMPORTED-TAVILY-ALIAS';
    fs.writeFileSync(nativePath(selectedFile),JSON.stringify(imported));
    const restored=await readBackup(context,model.emptyData());assert.equal(restored.threads[0].id,'thread');assert.equal(restored.providerProfiles[0].enabled,false);
    assert.equal(restored.productivity.options.search.tavily.credentialAlias,'');
    assert.equal(JSON.parse(exported).data.config.userDocument, data.config.userDocument);
    assert.equal(restored.config.userDocument, data.config.userDocument);
    assert.equal(restored.productivity.memories[0].threadId,restored.threads[0].id);assert.equal(restored.productivity.memories[0].sourceMessageId,restored.threads[0].messages[0].id);
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/'+restored.threads[0].id+'/note.txt'),'utf8'),'workspace');
    const restoredAttachment=restored.threads[0].messages[0].attachments[0];assert.notEqual(restoredAttachment.id,id);assert.equal(fs.readFileSync(nativePath(root+'/attachments/'+restoredAttachment.path),'utf8'),'sample');
    const {SessionService}=load(path.join(source,'services/SessionService'));
    const repository=new ConversationStore(nativePath(root));await repository.save(data);
    const vault={read:async()=>{throw Error('restore must not read credentials');},write:async()=>{throw Error('restore must not write credentials');},remove:async()=>{throw Error('restore must not remove credentials');}};
    const resources={createId:()=>crypto.randomUUID(),ensureWorkspace:async()=>{},configureProviders:()=>{},reportError:()=>{},
      tools:()=>({definitions:()=>[],execute:async()=>{throw Error('restore must not execute tools');}})};
    const session=new SessionService(repository,idleRuntime(vault),vault,resources);await session.initialize();
    const local=session.snapshot();assert.equal(await session.importSnapshot(restored),true,session.state.error);
    const merged=await repository.load();assert.deepEqual(merged.providerProfiles,local.providerProfiles);assert.deepEqual(merged.config,local.config);
    assert.equal(merged.threads.length,1,'restoring an existing conversation must not duplicate it');assert.equal(merged.threads[0].modelRef.providerId,'provider');
    model.parseAppData(JSON.stringify(restored));const bad=JSON.parse(exported);bad.files[0].path='../escape';fs.writeFileSync(nativePath(selectedFile),JSON.stringify(bad));await assert.rejects(readBackup(context,model.emptyData()),/路径/);
  });
  await test('repeated restore merges three chats and templates without overwriting local files or edits',async()=>{
    const {createBackupFile,readBackupFile}=load(path.join(source,'services/Backup'));
    const {SessionService}=load(path.join(source,'services/SessionService'));
    const {defaultProductivity}=load(path.join(source,'model/Productivity'));
    const root='/sandbox/dedup-app';fs.mkdirSync(nativePath(root+'/cache'),{recursive:true});
    fs.mkdirSync(nativePath(root+'/attachments'));Attachments.configure(root);
    const attachment={id:'dedup-attachment',name:'note.txt',mime:'text/plain',path:'dedup-attachment.txt',size:6};
    fs.writeFileSync(nativePath(root+'/attachments/'+attachment.path),'sample');
    const data=model.emptyData();data.productivity=defaultProductivity();data.activeThreadId='chat-0';
    data.threads=Array.from({length:3},(_,i)=>({id:'chat-'+i,title:'same title',updatedAt:1,messages:[
      {id:'question-'+i,role:'user',content:'same question',status:'complete',error:'',attachments:[{...attachment}]},
      {id:'answer-'+i,role:'assistant',content:'same answer',status:'complete',error:''}]}));
    data.threads[1].parentThreadId='chat-0';data.threads[1].parentMessageId='answer-0';
    data.threads[1].references=[{threadId:'chat-0',title:'same title',content:'snapshot',capturedAt:1,truncated:false}];
    data.productivity.templates.push({id:'custom',name:'Custom',content:'original {{input}}'});
    data.productivity.memories=[{id:'memory',content:'fact',threadId:'chat-1',sourceThreadId:'chat-0',sourceMessageId:'question-0',updatedAt:1}];
    for(const thread of data.threads){fs.mkdirSync(nativePath(root+'/workspace/'+thread.id),{recursive:true});fs.writeFileSync(nativePath(root+'/workspace/'+thread.id+'/note.txt'),'backup');}
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};
    const backup=await createBackupFile(context,data);const original=legacyBackupFixture(fs.readFileSync(nativePath(backup)));
    const vault={read:async()=>'',write:async()=>{},remove:async()=>{}};
    const resources={createId:()=>crypto.randomUUID(),ensureWorkspace:async()=>{},configureProviders:()=>{},reportError:()=>{},tools:()=>({definitions:()=>[]})};
    const repository=new ConversationStore(nativePath(root));
    const local=JSON.parse(JSON.stringify(data));local.threads=local.threads.slice(0,1);local.threads[0].title='edited locally';
    local.productivity.templates.find(t=>t.id==='custom').content='edited locally';local.productivity.memories=[];
    await repository.save(local);const session=new SessionService(repository,idleRuntime(vault),vault,resources);await session.initialize();
    fs.writeFileSync(nativePath(root+'/workspace/chat-0/note.txt'),'local file');
    fs.writeFileSync(nativePath(root+'/attachments/'+attachment.path),'edited');
    const prepared=await readBackupFile(context,backup,session.snapshot());
    assert.equal(prepared.threads.length,2);assert.equal(prepared.threads[0].parentThreadId,'chat-0');
    assert.equal(prepared.threads[0].parentMessageId,'answer-0');assert.equal(prepared.threads[0].references[0].threadId,'chat-0');
    assert.equal(prepared.threads[0].messages[0].id,'question-1');
    assert.equal(await session.importSnapshot(prepared),true,session.state.error);
    const merged=session.snapshot();assert.equal(merged.threads.length,3);assert.equal(merged.threads[0].title,'edited locally');
    assert.equal(merged.productivity.templates.length,3);assert.equal(merged.productivity.templates.find(t=>t.id==='custom').content,'edited locally');
    assert.equal(merged.productivity.memories.length,1);assert.equal(merged.productivity.memories[0].sourceMessageId,'question-0');
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/chat-0/note.txt'),'utf8'),'local file');
    assert.equal(fs.readFileSync(nativePath(root+'/attachments/'+attachment.path),'utf8'),'edited');
    const files=fs.readdirSync(nativePath(root+'/attachments')).sort();
    for(let i=0;i<2;i++){
      const restored=await readBackupFile(context,backup,session.snapshot());assert.equal(restored.threads.length,0);
      assert.equal(await session.importSnapshot(restored),true,session.state.error);
      assert.equal(JSON.stringify(session.snapshot()),JSON.stringify(merged));
      assert.deepEqual(fs.readdirSync(nativePath(root+'/attachments')).sort(),files);
    }
    // Re-export/reload keeps identities and therefore remains idempotent after restart.
    const exportedAgain=await createBackupFile(context,session.snapshot());
    const restarted=new SessionService(repository,idleRuntime(vault),vault,resources);await restarted.initialize();
    assert.equal(await restarted.importSnapshot(await readBackupFile(context,exportedAgain,restarted.snapshot())),true);
    assert.equal(restarted.snapshot().threads.length,3);
    // An old regenerated ID must not duplicate an identical template. Same name alone is insufficient.
    const legacy=model.emptyData();legacy.productivity=defaultProductivity();
    legacy.productivity.templates=legacy.productivity.templates.map(t=>({...t,id:crypto.randomUUID()}));
    legacy.productivity.templates.push({id:'another',name:'Custom',content:'different content'});
    assert.equal(await restarted.importSnapshot(legacy),true,restarted.state.error);
    assert.equal(restarted.snapshot().productivity.templates.length,4);
    // Even skipped chats must still undergo backup validation before filesystem writes.
    original.files[0].path='../escape';fs.writeFileSync(nativePath(backup),JSON.stringify(original));
    await assert.rejects(readBackupFile(context,backup,restarted.snapshot()),/路径/);
    original.files[0].path='note.txt';original.data.threads[0].id='../escape';
    fs.writeFileSync(nativePath(backup),JSON.stringify(original));await assert.rejects(readBackupFile(context,backup,restarted.snapshot()));
    Attachments.configure('/sandbox/backup-app');
  });
  await test('cloud backups replace the latest snapshot, preserve history and stay pending until native upload',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    await assert.rejects(CloudBackup.list(context),/云空间/);
    assert.equal(fs.existsSync(nativePath(context.cloudFileDir)),false,'never manufacture a local cloud root');
    fs.mkdirSync(nativePath(context.cloudFileDir));
    assert.equal((await CloudBackup.list(context)).length,0);assert.equal(syncInstances.length,0,'listing never starts upload');
    const data=JSON.parse(fs.readFileSync(nativePath(selectedFile),'utf8')).data;
    data.providerProfiles[0].credentialAlias='SECRET-CLOUD';data.providerProfiles[0].enabled=true;
    const before=JSON.stringify(data);
    cloudStart=async sync=>{sync.callback({state:cloudSync.SyncState.COMPLETED,error:0});};
    assert.equal(await CloudBackup.create(context,data),false,'Sync completion alone cannot confirm upload');
    let items=await CloudBackup.list(context);assert.equal(items.length,1);assert.equal(items[0].location,1,'sync completion alone is not proof of upload');
    assert.equal(JSON.stringify(data),before,'export never mutates live configuration');
    const firstPath=context.cloudFileDir+'/tinybot-backups/'+items[0].name;
    const original=fs.readFileSync(nativePath(firstPath),'utf8');assert.ok(!original.includes('SECRET-CLOUD'));
    assert.equal(legacyBackupFixture(fs.readFileSync(nativePath(firstPath))).data.providerProfiles[0].enabled,false);
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0,'temporary plaintext snapshot is removed');
    cloudLocations.set(firstPath,2);
    assert.equal((await CloudBackup.list(context))[0].location,2,'reopening lists cloud-only metadata without downloading');
    assert.equal(cacheInstances.length,0);
    cloudLocations.set(firstPath,3);
    assert.equal(items[0].name,'tinybot-latest.tinybot');
    assert.ok(Math.abs(items[0].createdAt-Date.now())<2000,'latest date comes from native mtime in seconds');
    const historical='tinybot-1700000000000-'+crypto.randomUUID()+'.json';
    fs.writeFileSync(nativePath(context.cloudFileDir+'/tinybot-backups/'+historical),'historical backup');
    data.threads[0].title='Updated backup';
    const rename=fileIo.rename;
    fileIo.rename=async(a,b)=>{
      if(b===firstPath){
        const retained = fs.readdirSync(nativePath(context.cloudFileDir+'/tinybot-backups')).filter(n=>n.endsWith('.tinybot'));
        assert.ok(retained.some(n=>fs.readFileSync(nativePath(context.cloudFileDir+'/tinybot-backups/'+n),'utf8')===original),'old backup remains recoverable until replacement');
        assert.equal(legacyBackupFixture(fs.readFileSync(nativePath(a))).data.threads[0].title,'Updated backup');
      }
      return rename(a,b);
    };
    try { await CloudBackup.create(context,data); } finally { fileIo.rename=rename; }
    items=await CloudBackup.list(context);assert.equal(items.length,3,'Keep the previous uploaded copy and legacy backup while replacement is pending');
    assert.equal(fs.readFileSync(nativePath(context.cloudFileDir+'/tinybot-backups/'+historical),'utf8'),'historical backup');
    assert.equal(legacyBackupFixture(fs.readFileSync(nativePath(firstPath))).data.threads[0].title,'Updated backup');
    assert.equal(items.find(i=>i.name==='tinybot-latest.tinybot').location,1,'replacement needs uploading again');
    await CloudBackup.create(context,data);assert.equal((await CloudBackup.list(context)).length,4,'Pending replacements remain recoverable until one is confirmed uploaded');
    fs.unlinkSync(nativePath(context.cloudFileDir+'/tinybot-backups/'+historical));
    assert.ok(syncInstances.every(s=>!s.callback),'native listeners are removed');
  });
  await test('automatic and manual backups share one file and retire old copies only after upload',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const directory=context.cloudFileDir+'/tinybot-backups',manual=directory+'/tinybot-latest.tinybot';
    const before=fs.readFileSync(nativePath(manual));
    const snapshot=legacyBackupFixture(before).data;
    const name='tinybot-latest.tinybot',automatic=manual;
    snapshot.threads[0].title='Shared automatic backup';
    cloudStart=async sync=>{cloudLocations.set(manual,3);sync.callback({state:cloudSync.SyncState.COMPLETED,error:0});};
    const checks = backupAccount.checks;
    assert.equal(await CloudBackup.create(context,snapshot,{openID:await backupAccount.backupOpenID()}),true);
    assert.equal(backupAccount.checks,checks+1,'Packing reuses the account verified before the automatic backup');
    assert.notDeepEqual(fs.readFileSync(nativePath(manual)),before);
    assert.deepEqual(Array.from(await CloudBackup.list(context),item=>item.name),[name],'Only the shared backup remains after confirmed upload');
    const restored=await CloudBackup.restore(context,name,model.emptyData());
    assert.equal(restored.threads.length,snapshot.threads.length);
    assert.equal(restored.threads[0].title,snapshot.threads[0].title);
    const complete=fs.readFileSync(nativePath(automatic));failCloudCopy=true;
    try{await assert.rejects(CloudBackup.create(context,snapshot),/injected cloud write/);}
    finally{failCloudCopy=false;}
    assert.deepEqual(fs.readFileSync(nativePath(automatic)),complete,'Failed replacement preserves the shared restore point');
    const cancellation=new Cancellation(),copy=fileIo.copyFile;
    fileIo.copyFile=async(a,b)=>{await copy(a,b);cancellation.cancel();};
    try{await assert.rejects(CloudBackup.create(context,snapshot,{cancellation}),error=>error.code==='CANCELLED');}
    finally{fileIo.copyFile=copy;}
    assert.deepEqual(fs.readFileSync(nativePath(automatic)),complete,'Expiry before promotion preserves the complete snapshot');
    assert.ok(fs.readdirSync(nativePath(directory)).every(file=>!file.endsWith('.partial')));
    const legacyName='tinybot-auto-'+crypto.randomUUID()+'.tinybot',legacy=directory+'/'+legacyName;
    fs.writeFileSync(nativePath(legacy),complete);cloudLocations.set(legacy,3);
    fs.utimesSync(nativePath(manual),new Date(1000),new Date(1000));
    assert.equal((await CloudBackup.restoreLatest(context,model.emptyData())).threads[0].title,snapshot.threads[0].title,'Legacy automatic backups remain discoverable by one-step restore');
    await assert.rejects(CloudBackup.retryUpload(context),/存在更新的备份/,'An older shared backup cannot delete a newer legacy snapshot');
    assert.equal(fs.existsSync(nativePath(legacy)),true);
    assert.equal(await CloudBackup.create(context,snapshot),true);
    assert.deepEqual(Array.from(await CloudBackup.list(context),item=>item.name),[name]);
    const obsolete=directory+'/tinybot-1700000000000-'+crypto.randomUUID()+'.tinybot';
    fs.writeFileSync(nativePath(obsolete),complete);
    const savedShared=fs.readFileSync(nativePath(manual)),unlink=fileIo.unlink;
    fileIo.unlink=async value=>{if(value===obsolete)throw Error('injected retirement failure');return unlink(value);};
    try{await assert.rejects(CloudBackup.retryUpload(context),/备份已上传.*清理未完成.*injected retirement failure/);}
    finally{fileIo.unlink=unlink;}
    assert.deepEqual(fs.readFileSync(nativePath(manual)),savedShared,'Cleanup failure cannot remove the newly uploaded backup');
    assert.equal(fs.existsSync(nativePath(obsolete)),true);
    assert.equal(await CloudBackup.retryUpload(context),true);
    assert.deepEqual(Array.from(await CloudBackup.list(context),item=>item.name),[name]);
  });
  await test('cloud metadata lookup excludes directories and symbolic links before querying location',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud'};
    const name='tinybot-1700000000000-'+crypto.randomUUID()+'.json';
    const file=context.cloudFileDir+'/tinybot-backups/'+name;
    const originalLstat=fileIo.lstat,originalStat=fileIo.stat;
    fs.mkdirSync(nativePath(file));
    fileIo.stat=async value=>{assert.notEqual(value,file,'rejected entries must not be followed by stat');return originalStat(value);};
    try {
      assert.ok((await CloudBackup.list(context)).every(item=>item.name!==name));
      await assert.rejects(CloudBackup.restore(context,name,model.emptyData()),/备份文件无效/);
      await assert.rejects(CloudBackup.remove(context,name),/备份文件无效/);
      fileIo.lstat=async value=>value===file?{isFile:()=>false,isSymbolicLink:()=>true}:originalLstat(value);
      assert.ok((await CloudBackup.list(context)).every(item=>item.name!==name));
      await assert.rejects(CloudBackup.restore(context,name,model.emptyData()),/备份文件无效/);
      await assert.rejects(CloudBackup.remove(context,name),/备份文件无效/);
    } finally {fileIo.lstat=originalLstat;fileIo.stat=originalStat;fs.rmdirSync(nativePath(file));}
  });
  await test('short-task expiry cancels archive writes and sync waiting without retaining partial files or locks',async()=>{
    const {writeBackupArchive}=load(path.join(source,'services/BackupArchive'));
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const root='/sandbox/cancelled-archive';fs.mkdirSync(nativePath(root));
    const input=root+'/input.bin',output=root+'/cancelled.tinybot';fs.writeFileSync(nativePath(input),'source bytes');
    const signal=new Cancellation(),write=fileIo.write;
    fileIo.write=async(...args)=>{const result=await write(...args);signal.cancel();return result;};
    try{await assert.rejects(writeBackupArchive(output,'{}',[input],signal),error=>error.code==='CANCELLED');}
    finally{fileIo.write=write;}
    assert.equal(fs.existsSync(nativePath(output)),false);assert.equal(fs.readFileSync(nativePath(input),'utf8'),'source bytes');
    cloudStart=async()=>{};const syncSignal=new Cancellation();const pending=CloudBackup.sync(syncSignal);
    const rejected=assert.rejects(pending,/后台备份时间已结束/);await new Promise(setImmediate);syncSignal.cancel();await rejected;
    assert.equal(CloudBackup.busy,false);assert.equal(syncInstances.at(-1).callback,undefined);
    cloudStart=async sync=>sync.callback({state:cloudSync.SyncState.COMPLETED,error:0});assert.equal(await CloudBackup.sync(),true);
    const {NativeWorkspaceFiles}=load(path.join(source,'services/NativeWorkspaceFiles'));
    const workspace=root+'/workspace/thread';fs.mkdirSync(nativePath(workspace),{recursive:true});
    const files=new NativeWorkspaceFiles(workspace);const before=NativeWorkspaceFiles.contentRevision;
    await files.writeMiniApp('mini-apps/probe/data.json','{"version":1,"value":2}',new Cancellation(),{version:null});
    assert.ok(NativeWorkspaceFiles.contentRevision>before,'Managed mini app data changes invalidate automatic backup');
    const after=NativeWorkspaceFiles.contentRevision;await files.read('mini-apps/probe/data.json',new Cancellation());
    assert.equal(NativeWorkspaceFiles.contentRevision,after,'Reading does not create a backup change');
  });
  await test('cloud quota failure preserves the pending snapshot; failed writes never become restore points',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const before=(await CloudBackup.list(context)).length;
    const latest=context.cloudFileDir+'/tinybot-backups/tinybot-latest.tinybot';
    const snapshot=legacyBackupFixture(fs.readFileSync(nativePath(latest))).data;
    snapshot.threads[0].title='Pending backup';
    cloudStart=async sync=>{sync.callback({state:cloudSync.SyncState.UPLOAD_FAILED,error:cloudSync.ErrorType.CLOUD_STORAGE_FULL});};
    await assert.rejects(CloudBackup.create(context,snapshot),/云空间已满/);
    assert.equal((await CloudBackup.list(context)).length,before+1,'Failed upload retains both the replacement and last uploaded backup');
    assert.equal(legacyBackupFixture(fs.readFileSync(nativePath(latest))).data.threads[0].title,'Pending backup');
    const retained=fs.readFileSync(nativePath(latest));
    failCloudCopy=true;
    try { await assert.rejects(CloudBackup.create(context,snapshot),/injected cloud write/); } finally { failCloudCopy=false; }
    assert.equal((await CloudBackup.list(context)).length,before+1);
    assert.ok(fs.readdirSync(nativePath(context.cloudFileDir+'/tinybot-backups')).every(n=>!n.endsWith('.partial')));
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0);
    assert.deepEqual(fs.readFileSync(nativePath(latest)),retained);
    for (const stage of ['flush','rename']) {
      failCloudFsync=stage==='flush';failCloudRename=stage==='rename';
      try { await assert.rejects(CloudBackup.create(context,snapshot),new RegExp('injected cloud '+stage)); }
      finally {failCloudFsync=false;failCloudRename=false;}
      assert.deepEqual(fs.readFileSync(nativePath(latest)),retained,'failed '+stage+' preserves the last complete backup');
      assert.ok(fs.readdirSync(nativePath(context.cloudFileDir+'/tinybot-backups')).every(n=>!n.endsWith('.partial')));
    }
    cloudCopyError=Object.assign(Error('Permission denied'),{code:13900012});
    try { await assert.rejects(CloudBackup.create(context,snapshot),/13900012.*Tinybot/); } finally {cloudCopyError=undefined;}
    assert.equal((await CloudBackup.list(context)).length,before+1);
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0);
    cloudStart=async sync=>{cloudLocations.set(latest,3);sync.callback({state:cloudSync.SyncState.COMPLETED,error:0});};
    assert.equal(await CloudBackup.retryUpload(context),true);
    assert.equal((await CloudBackup.list(context)).length,1,'Previous restore copy retires after retry uploads the replacement');
  });
  await test('failed cloud replacement and rollback retain a discoverable complete backup',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const directory=context.cloudFileDir+'/tinybot-backups',latest=directory+'/tinybot-latest.tinybot';
    const retained=fs.readFileSync(nativePath(latest));
    const previousDate=(await CloudBackup.list(context))[0].createdAt;
    const snapshot=legacyBackupFixture(retained).data;
    snapshot.threads[0].title='Must not replace retained backup';
    failCloudRename=true;failCloudRollback=true;
    try { await assert.rejects(CloudBackup.create(context,snapshot),/injected cloud rename failure/); }
    finally {failCloudRename=false;failCloudRollback=false;}
    const items=await CloudBackup.list(context);
    assert.equal(items.length,1);
    assert.notEqual(items[0].name,'tinybot-latest.tinybot');
    assert.equal(items[0].createdAt,Math.trunc(previousDate));
    assert.deepEqual(fs.readFileSync(nativePath(directory+'/'+items[0].name)),retained);
    assert.ok(fs.readdirSync(nativePath(directory)).every(n=>!n.endsWith('.partial')));
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0);
    const restored=await CloudBackup.restore(context,items[0].name,model.emptyData());
    assert.equal(restored.threads[0].title,legacyBackupFixture(retained).data.threads[0].title);
    await fileIo.rename(directory+'/'+items[0].name,latest);
  });
  await test('cloud restore awaits its own download completion and skips existing chats',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const items=await CloudBackup.list(context);const item=items.find(i=>i.name==='tinybot-latest.tinybot');
    const file=context.cloudFileDir+'/tinybot-backups/'+item.name;cloudLocations.set(file,2);
    const workspaces=()=>fs.readdirSync(nativePath('/sandbox/backup-app/workspace')).length;
    const before=workspaces();cacheStart=async()=>{};
    let settled=false;const restore=CloudBackup.restore(context,item.name,model.emptyData()).then(data=>{settled=true;return data;});
    while (!cacheInstances.at(-1)?.uri) await new Promise(setImmediate);
    const cache=cacheInstances.at(-1);
    await new Promise(setImmediate);assert.equal(settled,false,'start acknowledgement is not completion');
    cache.callback({uri:'file:///another-backup',state:1,error:0});await new Promise(setImmediate);assert.equal(settled,false);
    assert.equal(workspaces(),before,'no restore files before download completion');
    await assert.rejects(CloudBackup.sync(),/正在进行/);
    cloudLocations.set(file,3);cache.callback({uri:cache.uri,state:1,error:0});
    const data=await restore;assert.equal(data.threads[0].id,'thread');
    assert.equal(data.providerProfiles[0].enabled,false);assert.equal(data.providerProfiles[0].credentialAlias,'');
    assert.equal(fs.readFileSync(nativePath('/sandbox/backup-app/workspace/'+data.threads[0].id+'/note.txt'),'utf8'),'workspace');
    assert.equal(cache.callback,undefined);assert.equal(cache.stopped,undefined);
    const attachmentFiles=fs.readdirSync(nativePath('/sandbox/backup-app/attachments')).sort();
    const again=await CloudBackup.restore(context,item.name,data);assert.equal(again.threads.length,0);
    assert.deepEqual(fs.readdirSync(nativePath('/sandbox/backup-app/attachments')).sort(),attachmentFiles);
    await assert.rejects(CloudBackup.restore(context,'../escape.json',model.emptyData()),/备份文件无效/);
  });
  await test('cloud download failure and malformed backups leave existing conversations untouched',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const item=(await CloudBackup.list(context)).find(i=>i.location===3),file=context.cloudFileDir+'/tinybot-backups/'+item.name;
    const before=fs.readdirSync(nativePath('/sandbox/backup-app/workspace')).join(',');cloudLocations.set(file,2);
    cacheStart=async cache=>{cache.callback({uri:cache.uri,state:2,error:2});};
    await assert.rejects(CloudBackup.restore(context,item.name,model.emptyData()),/下载失败/);
    assert.equal(cacheInstances.at(-1).stopped,true);assert.equal(cacheInstances.at(-1).callback,undefined);
    cloudLocations.set(file,3);const original=fs.readFileSync(nativePath(file));const bad=legacyBackupFixture(original);bad.files[0].path='../escape';
    fs.writeFileSync(nativePath(file),JSON.stringify(bad));
    try { await assert.rejects(CloudBackup.restore(context,item.name,model.emptyData()),/路径/); } finally { fs.writeFileSync(nativePath(file),original); }
    assert.equal(fs.readdirSync(nativePath('/sandbox/backup-app/workspace')).join(','),before);
    assert.equal(fs.readFileSync(nativePath('/sandbox/backup-app/workspace/thread/note.txt'),'utf8'),'workspace');
  });
  await test('cloud timeouts release locks and listeners without reporting upload success',async()=>{
    const {CloudBackup,cloudBackupError}=load(path.join(source,'services/CloudBackup'));
    const timers=new Map();let id=0;fakeTimers={set(fn,ms){const key=++id;timers.set(key,{fn,ms});return key;},clear(key){timers.delete(key);}};
    try {
      cloudStart=async()=>{};const pending=CloudBackup.sync();await new Promise(setImmediate);
      assert.equal(timers.size,1);assert.equal([...timers.values()][0].ms,30000);[...timers.values()][0].fn();
      assert.equal(await pending,false);assert.equal(timers.size,0);assert.equal(syncInstances.at(-1).callback,undefined);
      cloudStart=async()=>{throw Object.assign(Error('not ready'),{code:22400001});};
      const unavailable=assert.rejects(CloudBackup.sync(),error=>/华为云空间/.test(cloudBackupError(error)));
      for(const delay of [500,1000,2000]){
        await new Promise(setImmediate);
        const retry=[...timers].find(([,timer])=>timer.ms===delay);assert.ok(retry,'bounded readiness retry');timers.delete(retry[0]);retry[1].fn();
      }
      await unavailable;
      assert.equal(timers.size,0);assert.equal(syncInstances.at(-1).callback,undefined);
      const context={cloudFileDir:'/sandbox/cloud',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
      const item=(await CloudBackup.list(context))[0];cloudLocations.set('/sandbox/cloud/tinybot-backups/'+item.name,2);cacheStart=async()=>{};
      const download=CloudBackup.restore(context,item.name,model.emptyData());const rejected=assert.rejects(download,/下载超时/);
      while (!timers.size) await new Promise(setImmediate);
      assert.equal([...timers.values()][0].ms,60000);
      const firstTimer = [...timers.keys()][0], cache = cacheInstances.at(-1);
      cache.callback({uri:cache.uri,state:0,error:0,processed:1024});
      assert.equal(timers.has(firstTimer),false,'new download bytes extend the idle timeout');
      const progressTimer = [...timers.keys()][0];
      cache.callback({uri:cache.uri,state:0,error:0,processed:1024});
      cache.callback({uri:'file://other',state:0,error:0,processed:2048});
      assert.equal([...timers.keys()][0],progressTimer,'stalled or unrelated callbacks do not extend the timeout');
      [...timers.values()][0].fn();await rejected;
      assert.equal(timers.size,0);assert.equal(cacheInstances.at(-1).callback,undefined);assert.equal(cacheInstances.at(-1).stopped,true);
    } finally {fakeTimers=undefined;}
  });
  await test('cloud deletion removes only the selected snapshot without downloading or touching app data',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/delete-cloud'},directory=context.cloudFileDir+'/tinybot-backups';
    fs.mkdirSync(nativePath(directory),{recursive:true});fs.writeFileSync(nativePath(directory+'/keep.txt'),'keep');
    const appBefore=fs.readFileSync(nativePath('/sandbox/backup-app/sessions-v2/index.json'),'utf8');
    const downloads=cacheInstances.length;
    cloudStart=async sync=>{sync.callback({state:4,error:0});};
    for(const location of [1,2,3]) {
      const name='tinybot-1700000000000-'+crypto.randomUUID()+'.json',file=directory+'/'+name;
      fs.writeFileSync(nativePath(file),'snapshot');cloudLocations.set(file,location);
      assert.equal(await CloudBackup.remove(context,name),true);assert.equal(fs.existsSync(nativePath(file)),false);
    }
    assert.equal(cacheInstances.length,downloads);assert.equal(fs.readFileSync(nativePath(directory+'/keep.txt'),'utf8'),'keep');
    assert.equal(fs.readFileSync(nativePath('/sandbox/backup-app/sessions-v2/index.json'),'utf8'),appBefore);
    await assert.rejects(CloudBackup.remove(context,'../keep.txt'),/备份文件无效/);
  });
  await test('cloud deletion distinguishes unlink failure from pending cloud sync and supports retrying sync',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/delete-cloud'},name='tinybot-1700000000000-'+crypto.randomUUID()+'.json';
    const file=context.cloudFileDir+'/tinybot-backups/'+name;fs.writeFileSync(nativePath(file),'keep on failure');
    const original=fileIo.unlink;const syncCount=syncInstances.length;
    fileIo.unlink=async value=>{if(value===file)throw Error('unlink denied');return original(value);};
    try {await assert.rejects(CloudBackup.remove(context,name),/unlink denied/);} finally {fileIo.unlink=original;}
    assert.equal(fs.existsSync(nativePath(file)),true);assert.equal(syncInstances.length,syncCount);
    cloudStart=async()=>{throw Object.assign(Error('offline'),{code:22400002});};
    await assert.rejects(CloudBackup.remove(context,name),/已从本机列表移除.*尚待同步.*网络不可用/);
    assert.equal(fs.existsSync(nativePath(file)),false);assert.equal(syncInstances.at(-1).callback,undefined);
    cloudStart=async sync=>{sync.callback({state:4,error:0});};assert.equal(await CloudBackup.sync(),true);
  });
  await test('cloud deletion holds the operation lock until sync settles and reports timeouts as pending',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/delete-cloud'},name='tinybot-1700000000000-'+crypto.randomUUID()+'.json';
    const file=context.cloudFileDir+'/tinybot-backups/'+name;fs.writeFileSync(nativePath(file),'snapshot');
    const timers=new Map();let id=0;fakeTimers={set(fn,ms){const key=++id;timers.set(key,{fn,ms});return key;},clear(key){timers.delete(key);}};
    try {
      cloudStart=async()=>{};const pending=CloudBackup.remove(context,name);
      while(!timers.size)await new Promise(setImmediate);
      await assert.rejects(CloudBackup.sync(),/正在进行/);
      assert.equal([...timers.values()][0].ms,30000);[...timers.values()][0].fn();
      assert.equal(await pending,false);assert.equal(fs.existsSync(nativePath(file)),false);
      assert.equal(timers.size,0);assert.equal(syncInstances.at(-1).callback,undefined);
      cloudStart=async sync=>{sync.callback({state:4,error:0});};assert.equal(await CloudBackup.sync(),true);
    } finally {fakeTimers=undefined;}
  });
  await test('mini apps laboratory setting gates native tool catalog and dispatch', async()=>{
    const {NativeSessionResources}=load(path.join(source,'services/NativeSessionService'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {defaultExtensions}=load(path.join(source,'model/Skills'));
    const {defaultProductivity}=load(path.join(source,'model/Productivity'));
    const resources=new NativeSessionResources('/sandbox/labs',new ProviderRegistry(),new ToolApproval());
    const data=defaultProductivity(), ext=defaultExtensions(); ext.webEnabled=false;
    data.options=load(path.join(source,'model/AssistantOptions')).defaultAssistantOptions();
    for(const enabled of [undefined,false,true,false]) {
      data.options.miniAppsEnabled=enabled;
      const tools=resources.tools('chat',ext,'',data);
      for(const name of ['list_mini_apps','publish_mini_app']) {
        assert.equal(tools.definitions().some(tool=>tool.function.name===name),enabled===true);
        if(enabled!==true) await assert.rejects(tools.execute({id:name,type:'function',function:{name,arguments:'{}'}},new Cancellation()),
          error=>['TOOL_UNAVAILABLE','PERMISSION_DENIED'].includes(error.code));
      }
      assert.ok(tools.definitions().some(tool=>tool.function.name==='publish_preview'),'Ordinary previews remain available');
      for(const name of ['get_life_panel_catalog','list_life_panels','publish_life_panel']) {
        assert.ok(tools.definitions().some(tool=>tool.function.name===name),'Life Panel is independent of the Mini apps laboratory flag');
      }
      const catalog=JSON.parse(await tools.execute({id:'catalog',function:{name:'get_life_panel_catalog',arguments:'{}'}},new Cancellation()));
      assert.equal(catalog.protocol,'tinybot.life-panel');
    }
  });
  await test('removed image generation stays unavailable with legacy model configuration', async()=>{
    const {NativeSessionResources}=load(path.join(source,'services/NativeSessionService'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {defaultExtensions}=load(path.join(source,'model/Skills'));
    const {defaultProductivity}=load(path.join(source,'model/Productivity'));
    const {defaultAssistantOptions}=load(path.join(source,'model/AssistantOptions'));
    const {ToolCatalog}=load(path.join(source,'services/ToolCatalog'));
    const resources=new NativeSessionResources('/sandbox/removed-images',new ProviderRegistry(),new ToolApproval());
    resources.configureProviders([{id:'image-provider',name:'Legacy',protocol:'chat-completions',baseUrl:'https://images.invalid/v1',
      credentialAlias:'fixture-key',noApiKey:false,enabled:true,models:['image-test']}]);
    const data=defaultProductivity(); data.options={...defaultAssistantOptions(),image:{providerId:'image-provider',modelId:'image-test'}};
    const ext=defaultExtensions(); ext.webEnabled=false;
    const tools=resources.tools('chat',ext,'',data,[{id:'text',name:'note.txt',path:'text.txt',mime:'text/plain',size:4,text:'note'}]);
    assert.ok(!tools.definitions().some(tool=>tool.function.name==='generate_image'));
    const invoke=(name,args)=>tools.execute({id:name,type:'function',function:{name,arguments:JSON.stringify(args)}},new Cancellation());
    await assert.rejects(invoke('generate_image',{prompt:'a circle'}),error=>error.code==='TOOL_UNAVAILABLE');
    const discovery=new ToolCatalog(tools);
    assert.ok(!discovery.definitions().some(tool=>tool.function.name==='generate_image'));
    assert.ok(!discovery.definitions().some(tool=>tool.function.name==='tool_search'));
    await assert.rejects(discovery.execute({id:'search',type:'function',function:{name:'tool_search',arguments:'{"query":""}'}},new Cancellation()),error=>error.code==='TOOL_UNAVAILABLE');
    assert.ok(tools.definitions().some(tool=>tool.function.name==='read_attachment'));
  });
  await test('model discovery validates credential origin and uses the protocol endpoint',async()=>{
    const {discoverModels}=load(path.join(source,'services/ModelDiscovery'));let requests=0;
    jsonScript=(url,options)=>{requests++;assert.equal(url,'https://models.invalid/v1/models');assert.equal(options.header.Authorization,'Bearer fixture-secret');return{responseCode:200,result:JSON.stringify({data:[{id:'one'},{id:'one'},{id:'two'}]})};};
    const profile={id:'p',protocol:'responses',baseUrl:'https://models.invalid/v1',credentialAlias:'fixture-key'};
    const draft={...profile,apiKey:'',noApiKey:false};assert.equal((await discoverModels(draft,[profile])).join(','),'one,two');
    assert.equal((await discoverModels({...draft,protocol:'chat-completions',baseUrl:'https://models.invalid/v1/chat/completions/'},[profile])).join(','),'one,two');
    for (const baseUrl of ['https://other.invalid/v1','https://models.invalid/other/v1','https://models.invalid:8443/v1','http://models.invalid/v1']) {
      await assert.rejects(discoverModels({...draft,baseUrl},[profile]),/API Key/);
    }
    assert.equal(requests,2);
  });
  await test('long thinking survives SSE overhead and more than 2 MiB of UTF-8 text, persistence and replay', async () => {
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const {chatRequest}=load(path.join(source,'services/providers/ChatCompletionsProtocol'));
    const {anthropicRequest}=load(path.join(source,'services/providers/WireProtocols'));
    const {stepMessages,validateSteps}=load(path.join(source,'model/Agent'));
    const event=data=>'data: '+JSON.stringify(data)+'\n\n';
    const input={model:'fixture-model',baseUrl:'https://fixture.invalid/v1',apiKey:'',messages:[{role:'user',content:'fixture'}],tools:[]};
    for(const scenario of ['chat-overhead','chat-thinking','anthropic-thinking']) {
      const anthropic=scenario==='anthropic-thinking';
      const protocol=anthropic?'anthropic-messages':'chat-completions';
      const piece=scenario==='chat-overhead'?'分析':'逐步核对推导。'.repeat(64);
      const count=scenario==='chat-overhead'?12000:1800;
      const thought=piece.repeat(count),answer='推导完成。';
      let wire=anthropic?event({type:'message_start',message:{usage:{input_tokens:10,output_tokens:0}}})+event({type:'content_block_start',index:0,content_block:{type:'thinking',thinking:'',signature:''}}):'';
      const chunk=anthropic?event({type:'content_block_delta',index:0,delta:{type:'thinking_delta',thinking:piece}}):event({
        id:'chatcmpl-long-reasoning-fixture',object:'chat.completion.chunk',created:1700000000,model:'fixture-thinking-model',system_fingerprint:'fixture',
        choices:[{index:0,delta:{reasoning_content:piece},finish_reason:null}]
      });
      wire+=chunk.repeat(count);
      if(anthropic) {
        wire+=event({type:'content_block_delta',index:0,delta:{type:'signature_delta',signature:'fixture-signature'}})+event({type:'content_block_stop',index:0});
        wire+=event({type:'content_block_start',index:1,content_block:{type:'text',text:''}})+event({type:'content_block_delta',index:1,delta:{type:'text_delta',text:answer}})+event({type:'content_block_stop',index:1});
        wire+=event({type:'message_delta',delta:{stop_reason:'end_turn'},usage:{output_tokens:42}})+event({type:'message_stop'});
      } else {
        wire+=event({choices:[{index:0,delta:{content:answer},finish_reason:'stop'}]})+event({choices:[],usage:{prompt_tokens:10,completion_tokens:42,total_tokens:52}})+'data: [DONE]\n\n';
      }
      const bytes=Buffer.from(wire);
      assert.ok(bytes.byteLength>2*1024*1024,scenario+' must cross the old transport cap');
      if(scenario==='chat-overhead')assert.ok(Buffer.byteLength(thought)<100000,'SSE metadata can dwarf actual reasoning');
      else assert.ok(Buffer.byteLength(thought)>2*1024*1024,'actual CJK reasoning also exceeds 2 MiB');
      httpScript=request=>{
        request.callback(null,200);
        // Arbitrary byte boundaries split multibyte characters and SSE lines.
        for(let offset=0;offset<bytes.length;offset+=3071)request.emit('dataReceive',Uint8Array.from(bytes.subarray(offset,offset+3071)).buffer);
        request.emit('dataEnd');
      };
      let text='',reasoning='';
      const provider=new ProtocolProvider({id:scenario,name:scenario,protocol,defaultBaseUrl:input.baseUrl,defaultModel:input.model}, providerEffects);
      const turn=await provider.stream(input,new Cancellation(),delta=>{text+=delta;},delta=>{reasoning+=delta;});
      assert.equal(text,answer);assert.equal(reasoning,thought);assert.equal(turn.reasoningContent,thought);assert.equal(turn.usage.status,'complete');
      assert.equal(turn.usage.tokens.output,42);
      const step={content:turn.content,reasoningContent:turn.reasoningContent,anthropicContent:turn.anthropicContent,tools:[]};validateSteps([step]);
      const root=path.join(fixture,scenario);fs.mkdirSync(root);
      const data=model.emptyData();data.activeThreadId=scenario;
      data.threads=[{id:scenario,title:'Long thinking',updatedAt:1,messages:[{id:'question',role:'user',content:'fixture',status:'complete',error:''},
        {id:'reply',role:'assistant',content:turn.content,status:'complete',error:'',steps:[step]}]}];
      await new ConversationStore(root).save(data);
      const restored=(await new ConversationStore(root).load()).threads[0].messages[1].steps[0];
      assert.equal(restored.reasoningContent,thought);assert.equal(restored.content,answer);
      const history=stepMessages(restored);
      if(anthropic) {
        const replay=anthropicRequest(input.model,history,[]);assert.equal(replay.messages[0].content[0].thinking,thought);
        assert.equal(replay.messages[0].content[0].signature,'fixture-signature');
      } else assert.equal(chatRequest(input.model,history,[],{replayReasoning:true}).messages[0].reasoning_content,thought);
      console.log('  '+scenario+': '+bytes.byteLength+' wire bytes, '+Buffer.byteLength(thought)+' reasoning bytes, saved and reloaded');
    }
  });
  await test('Responses reasoning reaches the live process after the answer rules out a refusal and survives reload', async () => {
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {runAgentLoop}=load(path.join(source,'services/AgentLoop'));
    const {ThreadViewModel}=load(path.join(source,'viewmodel/SessionViewModels'));
    const {buildTimeline}=load(path.join(source,'model/ProcessPresentation'));
    const registry=new ProviderRegistry();
    registry.register(new ProtocolProvider({id:'responses-thinking',name:'Responses',protocol:'responses',defaultBaseUrl:'https://fixture.invalid/v1',defaultModel:'gpt-5.2'}, providerEffects));
    for(const style of ['summary','content']) {
      const turn={content:'',steps:[]},deltas=[];
      const data=model.emptyData();data.activeThreadId='responses-'+style;
      data.threads=[{id:data.activeThreadId,title:'Responses thinking',updatedAt:1,messages:[{id:'u',role:'user',content:'fixture',status:'complete',error:''},
        {id:'a',role:'assistant',content:'',status:'generating',error:'',steps:turn.steps}]}];
      const thread=new ThreadViewModel(data.threads[0]);
      const config={...model.defaultConfig(),providerId:'responses-thinking',baseUrl:'https://fixture.invalid/v1',model:'gpt-5.2',reasoning:'high'};
      const bound=registry.bind(config,{read:async()=>''});
      const root=path.join(fixture,'responses-live-'+style);fs.mkdirSync(root);const repository=new ConversationStore(root);
      const update=()=>{data.threads[0].messages[1].steps=turn.steps;data.threads[0].messages[1].content=turn.content;thread.update(data.threads[0]);};
      httpScript=request=>{
        assert.equal(JSON.parse(request.options.extraData).reasoning.summary,'auto');assert.equal(JSON.parse(request.options.extraData).reasoning.effort,'high');
        request.callback(null,200);
        const emit=value=>{const bytes=Buffer.from('data: '+JSON.stringify(value)+'\n\n');for(let i=0;i<bytes.length;i+=7)request.emit('dataReceive',Uint8Array.from(bytes.subarray(i,i+7)).buffer);};
        const type=style==='summary'?'response.reasoning_summary_text':'response.reasoning_text';
        const coordinates=style==='summary'?{output_index:0,summary_index:0}:{output_index:0,content_index:0};
        emit({type:type+'.delta',...coordinates,delta:'先检查输入，'});
        emit({type:type+'.delta',...coordinates,delta:'再核对结果。'});
        assert.equal(thread.messages[1].content,'','answer is still empty while thinking streams');
        assert.equal(thread.messages[1].stepViews[0].reasoningContent,'','reasoning is held while a refusal remains possible');
        emit({type:type+'.done',...coordinates,text:'先检查输入，再核对结果。'});
        emit({type:'response.output_text.delta',delta:'最终回答。'});
        assert.equal(thread.messages[1].stepViews[0].reasoningContent,'先检查输入，再核对结果。');
        const thinking=buildTimeline(thread.messages[1].stepViews)[0];assert.equal(thinking.kind,'process');assert.equal(thinking.items[0].tool,-1);
        const item={type:'reasoning',summary:[],encrypted_content:'must-not-display'};
        item[style]=[{type:style==='summary'?'summary_text':'reasoning_text',text:'先检查输入，再核对结果。'}];
        emit({type:'response.completed',response:{status:'completed',output:[item,{type:'message',content:[{type:'output_text',text:'最终回答。'}]}]}});
        request.emit('dataEnd');
      };
      await runAgentLoop({model:bound,messages:[{role:'user',content:'fixture'}],tools:{definitions:()=>[],execute:async()=>{throw Error('Unexpected tool');}},turn,maxSteps:1},new Cancellation(),{
        event:event=>{update();if(event.type==='reasoning_delta')deltas.push(event.delta);},checkpoint:async()=>{update();await repository.save(data);}
      });
      assert.equal(deltas.join(''),'先检查输入，再核对结果。','done/completed must not duplicate thought text');
      data.threads[0].messages[1].status='complete';update();await repository.save(data);
      const restored=new ThreadViewModel((await new ConversationStore(root).load()).threads[0]);
      assert.equal(restored.messages[1].content,'最终回答。');assert.equal(restored.messages[1].reasoningContent,'先检查输入，再核对结果。');
      assert.equal(restored.messages[1].stepViews[0].reasoningContent,'先检查输入，再核对结果。');
      assert.ok(buildTimeline(restored.messages[1].stepViews).some(entry=>entry.kind==='process'));
      assert.equal(JSON.stringify(restored).includes('must-not-display'),false);
    }
  });
  await test('provider retries interrupted reasoning, text and tool arguments without replaying writes', async () => {
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const {runAgentLoop}=load(path.join(source,'services/AgentLoop'));
    const provider=new ProtocolProvider({id:'test',name:'Test',protocol:'chat-completions',defaultBaseUrl:'https://fixture.invalid/v1',defaultModel:'test'},providerEffects);
    for(const partial of ['reasoning','text','arguments']) {
      let attempts=0,writes=0,aborted;const bodies=[],saved=[];
      const turn={content:'',steps:[]};
      httpScript=request=>{
        attempts++;bodies.push(JSON.parse(request.options.extraData));
        const emit=value=>request.emit('dataReceive',Uint8Array.from(Buffer.from('data: '+JSON.stringify({choices:[value]})+'\n\n')).buffer);
        if(attempts===2) {
          aborted=request;
          const delta=partial==='reasoning'?{reasoning_content:'unfinished thought'}:partial==='text'?{content:'unfinished answer'}:
            {tool_calls:[{index:0,id:'aborted-write',type:'function',function:{name:'write_file',arguments:'{"path":"unfinished'}}]};
          emit({index:0,delta});
          request.callback(Object.assign(Error('receive failed'),{code:2300056}));return;
        }
        if(attempts===3)aborted.emit('dataReceive',Uint8Array.from(Buffer.from('data: {"choices":[{"delta":{"content":"late"}}]}\n\n')).buffer);
        request.callback(null,200);
        emit({index:0,delta:attempts===1?{content:'Prior',tool_calls:[{index:0,id:'committed-write',type:'function',function:{name:'write_file',arguments:'{}'}}]}:{content:'Done'}});
        emit({index:0,delta:{},finish_reason:attempts===1?'tool_calls':'stop'});
        request.emit('dataReceive',Uint8Array.from(Buffer.from('data: [DONE]\n\n')).buffer);request.emit('dataEnd');
      };
      const bound={stream:(messages,tools,cancellation,onText,options)=>provider.stream({model:'test',baseUrl:'https://fixture.invalid/v1',apiKey:'',messages,tools},cancellation,onText,options?.onReasoning)};
      await runAgentLoop({model:bound,messages:[{role:'user',content:'fixture'}],turn,maxSteps:3,
        tools:{definitions:()=>[{type:'function',function:{name:'write_file'}}],execute:async call=>{assert.equal(call.id,'committed-write');writes++;return 'saved';}}},
        new Cancellation(),{event:()=>{},checkpoint:async()=>saved.push(JSON.parse(JSON.stringify(turn)))});
      assert.equal(attempts,3);assert.equal(writes,1);assert.equal(turn.content,'Prior\n\nDone');
      assert.deepEqual(bodies[1],bodies[2]);assert.equal(turn.steps[1].retries.length,1);
      assert.ok(saved.some(value=>value.steps[1]?.retries?.[0].waiting&&value.content==='Prior'));
      assert.ok(!JSON.stringify(turn).includes('unfinished'));assert.ok(!JSON.stringify(turn).includes('aborted-write'));
    }
  });
  await test('provider keeps active streams beyond three minutes and stops idle or cancelled streams', async () => {
    const {NetworkTransfers}=load(path.join(source,'services/NetworkTransfers'));
    let networkScopes=0, scopeStarts=0, scopeEnds=0;
    const unobserve=NetworkTransfers.observe(async()=>{
      networkScopes++;scopeStarts++;
      return async()=>{networkScopes--;scopeEnds++;};
    });
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const provider=new ProtocolProvider({id:'test',name:'Test',protocol:'chat-completions',defaultBaseUrl:'https://fixture.invalid/v1',defaultModel:'test'}, providerEffects);
    const input={model:'test',baseUrl:'https://fixture.invalid/v1',apiKey:'',messages:[{role:'user',content:'hello'}],tools:[],usageOrigin:{threadId:'trace-thread',turnId:'trace-turn',purpose:'conversation',step:2}};
    const {UsageLedger}=load(path.join(source,'services/UsageLedger'));
    const recordsBefore=new Set(UsageLedger.list().map(item=>item.id));
    let now=0, sequence=0, transport; const timers=new Map();
    fakeTimers={set(fn,ms){const id=++sequence;timers.set(id,{fn,at:now+ms});return id;},clear(id){timers.delete(id);}};
    const advance=ms=>{now+=ms;for(const [id,item] of [...timers])if(item.at<=now){timers.delete(id);item.fn();}};
    const emit=text=>transport.emit('dataReceive',Uint8Array.from(Buffer.from(text)).buffer);
    httpScript=request=>{assert.equal(networkScopes,1,'Native model I/O requires an admitted transfer');transport=request;request.callback(null,200);};
    try {
      const pending=provider.stream(input,new Cancellation(),()=>{});
      await new Promise(setImmediate);
      assert.equal(transport.options.readTimeout,0);
      assert.equal(transport.options.connectTimeout,15000);
      assert.equal(JSON.parse(transport.options.extraData).stream_options.include_usage, true);
      assert.equal(JSON.stringify(JSON.parse(transport.options.extraData)).includes('trace-thread'),false,'local attribution stays out of API payloads');
      advance(119000);emit(': heartbeat\n\n');
      advance(119000);emit(': heartbeat\n\n');
      assert.equal(timers.size,1);
      emit('data: {"choices":[{"index":0,"delta":{"content":"done"}}]}\n\ndata: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
      transport.emit('dataEnd');
      assert.equal((await pending).content,'done');assert.equal(timers.size,0);
      assert.equal(networkScopes,0,'Successful SSE ends its scope before returning to tools');
      const idle=provider.stream({...input, requestUsage: false},new Cancellation(),()=>{});
      const timedOut=assert.rejects(idle,/120/);
      await new Promise(setImmediate);
      assert.equal(JSON.parse(transport.options.extraData).stream_options, undefined);
      advance(119999);emit('');advance(1);
      await timedOut;assert.equal(timers.size,0);
      const idlePartial=provider.stream(input,new Cancellation(),()=>{});
      const partialTimedOut=assert.rejects(idlePartial,error=>error.name==='TransientProviderError'&&error.code==='timeout');
      await new Promise(setImmediate);
      emit('data: {"choices":[{"index":0,"delta":{"reasoning_content":"unfinished"}}]}\n\n');
      advance(120000);await partialTimedOut;assert.equal(timers.size,0);
      const cancellation=new Cancellation();let text='';
      const cancelled=provider.stream(input,cancellation,delta=>{text+=delta;});
      const rejected=assert.rejects(cancelled);
      await new Promise(setImmediate);cancellation.cancel();await rejected;
      emit('data: {"choices":[{"delta":{"content":"late"}}]}\n\n');
      advance(120000);assert.equal(text,'');assert.equal(timers.size,0);
      httpScript=request=>{transport=request;};
      const startup=provider.stream(input,new Cancellation(),()=>{});
      const startupTimedOut=assert.rejects(startup,/120/);
      await new Promise(setImmediate);advance(120000);
      await startupTimedOut;assert.equal(timers.size,0);
      const tracked=UsageLedger.list().filter(item=>!recordsBefore.has(item.id));
      assert.equal(tracked.length,5);assert.equal(tracked.map(item=>item.status).sort().join(','),'cancelled,complete,failed,failed,failed');
      assert.ok(tracked.every(item=>item.origin.threadId==='trace-thread'&&item.origin.turnId==='trace-turn'&&item.origin.step===2),'all outcomes keep their origin');
      assert.equal(scopeStarts,5);assert.equal(scopeEnds,5);assert.equal(networkScopes,0,'Idle, cancelled and startup failure all release scope ownership');
    } finally {fakeTimers=undefined;unobserve();}
  });
  await test('complete portable backup encrypts connections, merges device data and rolls back failed imports', async () => {
    await require('./complete-backup-fixture.cjs')({ load: name => load(path.join(source, name)), fs, nativePath, secrets,
      model, crypto, ConversationStore, idleRuntime, Attachments, backupAccount, preferences: kits['@kit.ArkData'].preferences });
  });
  await test('usage ledger preserves new requests while restoring persisted records',async()=>{
    const {UsageLedger}=load(path.join(source,'services/UsageLedger'));const root='/sandbox/ledger';fs.mkdirSync(nativePath(root),{recursive:true});
    const previousRecordCount=UsageLedger.list().length;
    let usageNotifications=0;
    const stopWatching=UsageLedger.subscribe(()=>{usageNotifications++;});
    const stopBrokenWatcher=UsageLedger.subscribe(()=>{throw new Error('view failure');});
    fs.writeFileSync(nativePath(root+'/usage-ledger.json'),JSON.stringify([{id:'old',model:'old'}]));
    const ready=UsageLedger.configure(root);UsageLedger.record({id:'new',model:'new',status:'running_or_unknown'});await ready;
    UsageLedger.record({id:'new',model:'new',status:'complete'});await UsageLedger.queue;
    const records=readSavedUsage(root);assert.equal(records.length,previousRecordCount+2);assert.equal(records.find(x=>x.id==='new').status,'complete');
    assert.ok(usageNotifications>=3,'load and request updates notify the usage page');
    stopWatching();stopBrokenWatcher();const notificationsBefore=usageNotifications;
    UsageLedger.record({id:'new',model:'new',status:'complete',tokens:{input:100,output:20}});await UsageLedger.queue;
    assert.equal(usageNotifications,notificationsBefore,'closed pages unsubscribe');
    assert.equal(UsageLedger.list().filter(x=>x.id==='new').length,1,'settlement updates one request');
    const origin={threadId:'thread',turnId:'turn',purpose:'team_task',attempt:2};
    UsageLedger.record({...UsageLedger.list().find(x=>x.id==='new'),origin});
    UsageLedger.recordTool('new',{id:'tool',name:'read_skill',skill:'review',status:'running',startedAt:10,durationMs:0});
    UsageLedger.recordTool('new',{id:'tool',name:'read_skill',skill:'review',status:'complete',startedAt:10,durationMs:50});
    UsageLedger.recordTool('absent',{id:'ignored',name:'test',status:'complete',startedAt:10,durationMs:0});
    await UsageLedger.queue;
    const saved=readSavedUsage(root);
    assert.equal(saved.length,previousRecordCount+2);
    const enriched=saved.find(x=>x.id==='new');assert.deepEqual(enriched.origin,origin);
    assert.deepEqual(enriched.tokens,{input:100,output:20});assert.equal(enriched.tools.length,1);assert.equal(enriched.tools[0].durationMs,50);
  });
  await test('usage shards coalesce writes, recover migration and restore updates', async()=>{
    const ledgerFile=path.join(source,'services/UsageLedger.ets');cache.delete(ledgerFile);
    const {UsageLedger:Ledger}=load(ledgerFile);const root='/sandbox/large-ledger';fs.mkdirSync(nativePath(root),{recursive:true});
    const legacy=Array.from({length:700},(_,i)=>({id:'bulk-'+i,model:'model',provider:'test',startedAt:i,status:'complete',durationMs:1,tokens:{input:100,output:20}}));
    fs.writeFileSync(nativePath(root+'/usage-ledger.json'),JSON.stringify(legacy));
    failManifest=true;await assert.rejects(Ledger.configure(root),/manifest failure/);failManifest=false;
    assert.equal(JSON.parse(fs.readFileSync(nativePath(root+'/usage-ledger.json'),'utf8')).length,700,'legacy stays intact after interrupted migration');
    cache.delete(ledgerFile);const {UsageLedger:Recovered}=load(ledgerFile);await Recovered.configure(root);
    assert.equal(readSavedUsage(root).length,700);
    usageWrites.length=0;
    for(let i=0;i<200;i++)Recovered.record({...legacy[350],durationMs:i});
    await Recovered.queue;
    assert.equal(usageWrites.filter(p=>p.endsWith('/1.json')).length,1,'a burst writes the affected shard once');
    assert.equal(usageWrites.length,1,'no other shards or manifest are rewritten');
    assert.equal(readSavedUsage(root).find(r=>r.id==='bulk-350').durationMs,199);
    cache.delete(ledgerFile);const {UsageLedger:Reloaded}=load(ledgerFile);await Reloaded.configure(root);
    assert.equal(Reloaded.list().length,700);assert.equal(Reloaded.list().find(r=>r.id==='bulk-350').durationMs,199);
    // Loading a broken shard must not permit a later request to overwrite history.
    fs.writeFileSync(nativePath(root+'/usage-records/1.json'),'broken');
    cache.delete(ledgerFile);const {UsageLedger:Broken}=load(ledgerFile);await assert.rejects(Broken.configure(root));
    Broken.record({...legacy[0],id:'after-failure'});await Broken.queue;
    assert.equal(fs.readFileSync(nativePath(root+'/usage-records/1.json'),'utf8'),'broken');
    await assert.rejects(Broken.backup(root), 'a failed load cannot be exported as a partial ledger');
  });
  await test('usage backup flush cannot overlap a request flush on the same shard', async () => {
    const ledgerFile = path.join(source, 'services/UsageLedger.ets');
    cache.delete(ledgerFile);
    const { UsageLedger: Ledger } = load(ledgerFile);
    const root = '/sandbox/usage-backup-race';
    fs.mkdirSync(nativePath(root), { recursive: true });
    await Ledger.configure(root);
    const usage = { id: 'request', model: 'model', status: 'running_or_unknown' };
    beforeUsageOpen = () => { throw Error('injected usage write failure'); };
    Ledger.record(usage);
    await Ledger.queue;
    assert.match(Ledger.error, /injected usage write failure/);
    assert.ok(diagnosticLogs.some(log => log.module === 'storage' && log.event === 'usage_save_failed'));

    let entered, release, attempts = 0;
    const firstWrite = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    beforeUsageOpen = async () => {
      if (++attempts === 1) { entered(); await held; }
    };
    const backup = Ledger.backup(root);
    try {
      await firstWrite;
      Ledger.record({ ...usage, status: 'complete' });
      await new Promise(setImmediate);
      assert.equal(attempts, 1, 'a new request must wait for the backup writer');
    } finally {
      release();
      await Promise.allSettled([backup, Ledger.queue]);
      beforeUsageOpen = undefined;
    }
    assert.equal((await backup)[0].status, 'complete');
    assert.equal(readSavedUsage(root)[0].status, 'complete');
    assert.equal(Ledger.error, '');
  });
  suiteCompleted = true;
  console.log(completedTests+' native adapter integration checks passed. Fixtures: '+fixture);
})().catch(error=>{console.error(error);process.exitCode=1;});
