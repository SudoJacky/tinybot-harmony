// Platform-adapter integration tests with real temporary files and a scripted HTTP transport.
// Run: node scripts/test-productivity-native.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const source = path.resolve(__dirname, '../entry/src/main/ets');
const fixture = path.resolve(__dirname, '../.hvigor/native-productivity-' + crypto.randomUUID());
fs.mkdirSync(fixture, { recursive: true });
const handles = new Map(); let failManifest = false; const usageWrites = [];
const cloudLocations = new Map(); let failCloudCopy = false; let cloudCopyError;
const nativePath = p => p.startsWith('/sandbox/') ? path.join(fixture, p.slice(1)) : p;
const fileIo = {
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8, NOFOLLOW: 16 },
  access: async p => fs.existsSync(nativePath(p)), mkdir: p => fs.promises.mkdir(nativePath(p)), readText: p => fs.promises.readFile(nativePath(p), 'utf8'),
  listFile: async p => fs.promises.readdir(nativePath(p)),
  open: async (p, flags) => { const h = await fs.promises.open(nativePath(p), flags & 4 ? 'w' : 'r'); handles.set(h.fd, h); return { fd: h.fd }; },
  read: async (fd, bytes) => (await handles.get(fd).read(new Uint8Array(bytes))).bytesRead,
  write: async (fd, bytes, options) => (await handles.get(fd).write(new Uint8Array(bytes), 0, bytes.byteLength, options.offset)).bytesWritten,
  close: async file => { const fd = typeof file === 'number' ? file : file.fd; await handles.get(fd).close(); handles.delete(fd); },
  stat: async file => {
    const stat = await (typeof file === 'number' ? handles.get(file).stat() : fs.promises.stat(nativePath(file)));
    stat.location = cloudLocations.get(file) ?? 1;
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
  fsync: fd => handles.get(fd).sync(), unlink: p => fs.promises.unlink(nativePath(p)),
  rename: async (a,b) => { if (failManifest && b.endsWith('/index.json')) { throw new Error('injected manifest failure'); } if(b.includes("/usage-records/"))usageWrites.push(b); await fs.promises.rename(nativePath(a),nativePath(b)); }
};
// Reproduce the empty-input behavior observed on the physical HarmonyOS device.
class Encoder { encodeInto(s) { return s === '' ? undefined : new TextEncoder().encode(s); } }
class Decoder { constructor(encoding, opts) { this.decoder = new TextDecoder(encoding, opts); } decodeToString(bytes, opts) { return this.decoder.decode(bytes, opts); } }
const cache = new Map(); const calls = []; let httpScript = () => {}; let destroyed = 0; let jsonScript = () => { throw Error('Unexpected JSON request'); };
let fakeTimers;
const scheduleTimer = (fn, ms) => fakeTimers ? fakeTimers.set(fn, ms) : setTimeout(fn, ms);
const cancelTimer = id => fakeTimers ? fakeTimers.clear(id) : clearTimeout(id);
let selectedFile = '/sandbox/backup-export.json';
let cloudStart = () => {}, cacheStart = () => {};
const syncInstances = [], cacheInstances = [];
const cloudSync = {
  SyncState: { UPLOADING:0, UPLOAD_FAILED:1, DOWNLOADING:2, DOWNLOAD_FAILED:3, COMPLETED:4, STOPPED:5 },
  ErrorType: { NO_ERROR:0, NETWORK_UNAVAILABLE:1, WIFI_UNAVAILABLE:2, BATTERY_LEVEL_LOW:3, BATTERY_LEVEL_WARNING:4, CLOUD_STORAGE_FULL:5, LOCAL_STORAGE_FULL:6, DEVICE_TEMPERATURE_TOO_HIGH:7, REMOTE_SERVER_ABNORMAL:8 },
  State: { RUNNING:0, COMPLETED:1, FAILED:2, STOPPED:3 }, DownloadErrorType: { NO_ERROR:0 },
  FileSync: class {
    constructor() { syncInstances.push(this); }
    on(event,callback) { this.callback=callback; }
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
const kits = {
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {}, warn() {} } },
  '@kit.CoreFileKit': { fileIo, cloudSync, fileUri: {getUriFromPath:p=>'file://'+p}, picker: { DocumentViewPicker: class { async save() {return [selectedFile];} async select() {return [selectedFile];} } } }, '@kit.ImageKit': { image: {} }, '@kit.NetworkKit': { http },
  '@kit.MediaLibraryKit': {}, '@kit.ShareKit': {},
  '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID(), TextEncoder: Encoder, TextDecoder: Decoder,
    Base64Helper: class { async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); } encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return Uint8Array.from(Buffer.from(text,'base64')); } } } },
  '@kit.AssetStoreKit': { asset: {} }, '@kit.BasicServicesKit': { zlib: {
    ReturnStatus: { STREAM_END: 1 }, CompressFlushMode: { FINISH: 4 }, createZipSync: () => { let current; return {
      inflateInit2: async()=>{}, inflateEnd: async()=>{}, getZStream:async()=>current,
      inflate:async stream=>{const bytes=zlib.inflateRawSync(Buffer.from(stream.nextIn),{maxOutputLength:stream.availableOut});new Uint8Array(stream.nextOut).set(bytes);current={totalOut:bytes.length};return 1;}
    }; }
  } },
  '@kit.PDFKit': { pdfService: {} },
  '@kit.CryptoArchitectureKit': { cryptoFramework: { createRandom:()=>({generateRandom:async n=>({data:Uint8Array.from(crypto.randomBytes(n))})}),
    createMd:()=>{const hash=crypto.createHash('sha256');return{update:async blob=>hash.update(blob.data),digest:async()=>({data:Uint8Array.from(hash.digest())})};} } },
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file,'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText;
  vm.runInNewContext(compiled, { exports, require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id],
    Observed: cls => cls, setTimeout: scheduleTimer, clearTimeout: cancelTimer, Uint8Array, ArrayBuffer, DataView, Map, Set, Object, JSON, Error, console }, { filename: file });
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
const { NativeWorkspaceFiles } = load(path.join(source,'services/NativeWorkspaceFiles'));
const secrets = new Map();
CredentialStore.prototype.read = async alias => secrets.get(alias) || (alias ? 'fixture-secret' : '');
CredentialStore.prototype.write = async (alias, secret) => { if (secrets.has(alias)) throw Error('duplicate secret'); secrets.set(alias,secret); };
CredentialStore.prototype.update = async (alias, secret) => { assert.ok(secrets.has(alias)); secrets.set(alias,secret); };
CredentialStore.prototype.remove = async alias => { secrets.delete(alias); };
const server = { id:'s',name:'Fixture',url:'https://fixture.invalid/mcp',enabled:true,credentialAlias:'fixture-key' };
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
let completedTests = 0;
async function test(name, run) { await run(); completedTests++; console.log('PASS '+name); }
(async () => {
  let store;
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
  await test('managed text attachments hydrate without mutating persisted history',async()=>{
    Attachments.configure(fixture);const incoming=path.join(fixture,'input.txt');fs.writeFileSync(incoming,'材料内容');
    const item=await Attachments.import(incoming,false);const messages=[{role:'user',content:'总结',attachments:[item]}];
    const hydrated=await Attachments.hydrate(messages);assert.match(hydrated[0].content,/材料内容/);assert.equal(messages[0].content,'总结');
    fs.writeFileSync(incoming,Buffer.from([0xff,0xff]));await assert.rejects(Attachments.import(incoming,false));
  });
  await test('empty workspace files round-trip with device encoder behavior',async()=>{
    fs.mkdirSync(nativePath('/sandbox/workspace/thread'),{recursive:true});
    const files=new NativeWorkspaceFiles('/sandbox/workspace/thread'), signal=new Cancellation();
    await files.write('empty.md','',signal);assert.equal(JSON.parse(await files.read('empty.md',signal)).content,'');
    await files.write('empty.md','# note',signal);assert.equal(JSON.parse(await files.read('empty.md',signal)).content,'# note');
    await assert.rejects(files.checkedPath('../escape'));
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
    const approval=new ToolApproval(),tools=new McpTools([server],approval),signal=new Cancellation();
    const call=(name,args)=>({id:'c',type:'function',function:{name,arguments:JSON.stringify(args)}});
    const action=call('mcp_call',{server:'s',tool:'read',arguments:'{}'});
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
  await test('baseline persists, hides metadata, detects stale restore and preserves original',async()=>{
    const root='/sandbox/workspace/review';fs.mkdirSync(nativePath(root),{recursive:true});fs.writeFileSync(nativePath(root+'/note.txt'),'before');
    const files=new NativeWorkspaceFiles(root),signal=new Cancellation();await files.write('note.txt','after',signal);
    assert.equal((await new NativeWorkspaceFiles(root).baseline('note.txt')).content,'before');
    await files.write('note.txt','later',signal);assert.equal((await files.baseline('note.txt')).content,'before');
    assert.ok(!JSON.parse(await files.list('.',signal)).entries.some(e=>e.name.startsWith('.tinybot-')));
    await assert.rejects(files.restore('note.txt','after'),/变化/);await files.restore('note.txt','later');
    assert.equal(fs.readFileSync(nativePath(root+'/note.txt'),'utf8'),'before');assert.equal(await files.baseline('note.txt'),undefined);
    await files.write('new.txt','new',signal);await files.restore('new.txt','new');assert.ok(!fs.existsSync(nativePath(root+'/new.txt')));
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
    const context={cacheDir:root+'/cache',getApplicationContext:()=>({filesDir:root})};await exportBackup(context,JSON.parse(JSON.stringify(data)));
    const exported=fs.readFileSync(nativePath(selectedFile),'utf8');assert.ok(!exported.includes('SECRET-ALIAS'));
    const restored=await readBackup(context,model.emptyData());assert.equal(restored.threads[0].id,'thread');assert.equal(restored.providerProfiles[0].enabled,false);
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
    const session=new SessionService(repository,{},vault,resources);await session.initialize();
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
    const backup=await createBackupFile(context,data);const original=JSON.parse(fs.readFileSync(nativePath(backup),'utf8'));
    const vault={read:async()=>'',write:async()=>{},remove:async()=>{}};
    const resources={createId:()=>crypto.randomUUID(),ensureWorkspace:async()=>{},configureProviders:()=>{},reportError:()=>{},tools:()=>({definitions:()=>[]})};
    const repository=new ConversationStore(nativePath(root));
    const local=JSON.parse(JSON.stringify(data));local.threads=local.threads.slice(0,1);local.threads[0].title='edited locally';
    local.productivity.templates.find(t=>t.id==='custom').content='edited locally';local.productivity.memories=[];
    await repository.save(local);const session=new SessionService(repository,{},vault,resources);await session.initialize();
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
    const restarted=new SessionService(repository,{},vault,resources);await restarted.initialize();
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
  await test('cloud snapshots are opt-in, immutable, credential-free and stay pending until native upload',async()=>{
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
    assert.equal(await CloudBackup.create(context,data),true);
    let items=await CloudBackup.list(context);assert.equal(items.length,1);assert.equal(items[0].location,1,'sync completion alone is not proof of upload');
    assert.equal(JSON.stringify(data),before,'export never mutates live configuration');
    const firstPath=context.cloudFileDir+'/tinybot-backups/'+items[0].name;
    const original=fs.readFileSync(nativePath(firstPath),'utf8');assert.ok(!original.includes('SECRET-CLOUD'));
    assert.equal(JSON.parse(original).data.providerProfiles[0].enabled,false);
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0,'temporary plaintext snapshot is removed');
    cloudLocations.set(firstPath,2);
    assert.equal((await CloudBackup.list(context))[0].location,2,'reopening lists cloud-only metadata without downloading');
    assert.equal(cacheInstances.length,0);
    cloudLocations.set(firstPath,3);
    await CloudBackup.create(context,data);items=await CloudBackup.list(context);
    assert.equal(items.length,2);assert.equal(fs.readFileSync(nativePath(firstPath),'utf8'),original);
    assert.equal(items.find(i=>i.name===path.basename(firstPath)).location,3);
    assert.ok(syncInstances.every(s=>!s.callback),'native listeners are removed');
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
  await test('cloud quota failure preserves the pending snapshot; failed writes never become restore points',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const before=(await CloudBackup.list(context)).length;
    cloudStart=async sync=>{sync.callback({state:cloudSync.SyncState.UPLOAD_FAILED,error:cloudSync.ErrorType.CLOUD_STORAGE_FULL});};
    await assert.rejects(CloudBackup.create(context,model.emptyData()),/云空间已满/);
    assert.equal((await CloudBackup.list(context)).length,before+1,'failed upload retains a retryable snapshot');
    failCloudCopy=true;
    try { await assert.rejects(CloudBackup.create(context,model.emptyData()),/injected cloud write/); } finally { failCloudCopy=false; }
    assert.equal((await CloudBackup.list(context)).length,before+1);
    assert.ok(fs.readdirSync(nativePath(context.cloudFileDir+'/tinybot-backups')).every(n=>!n.endsWith('.partial')));
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0);
    cloudCopyError=Object.assign(Error('Permission denied'),{code:13900012});
    try { await assert.rejects(CloudBackup.create(context,model.emptyData()),/13900012.*Tinybot/); } finally {cloudCopyError=undefined;}
    assert.equal((await CloudBackup.list(context)).length,before+1);
    assert.equal(fs.readdirSync(nativePath(context.cacheDir)).length,0);
  });
  await test('cloud restore awaits its own download completion and skips existing chats',async()=>{
    const {CloudBackup}=load(path.join(source,'services/CloudBackup'));
    const context={cloudFileDir:'/sandbox/cloud',cacheDir:'/sandbox/backup-app/cache',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
    const items=await CloudBackup.list(context);const item=items.find(i=>i.location===3);
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
    cloudLocations.set(file,3);const original=fs.readFileSync(nativePath(file),'utf8');const bad=JSON.parse(original);bad.files[0].path='../escape';
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
      await assert.rejects(CloudBackup.sync(),error=>/华为云空间/.test(cloudBackupError(error)));
      assert.equal(timers.size,0);assert.equal(syncInstances.at(-1).callback,undefined);
      const context={cloudFileDir:'/sandbox/cloud',getApplicationContext:()=>({filesDir:'/sandbox/backup-app'})};
      const item=(await CloudBackup.list(context))[0];cloudLocations.set('/sandbox/cloud/tinybot-backups/'+item.name,2);cacheStart=async()=>{};
      const download=CloudBackup.restore(context,item.name,model.emptyData());const rejected=assert.rejects(download,/下载超时/);
      while (!timers.size) await new Promise(setImmediate);
      assert.equal([...timers.values()][0].ms,60000);[...timers.values()][0].fn();await rejected;
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
  await test('image generation and edits require approval, persist outputs and send binary multipart',async()=>{
    const {ImageTools}=load(path.join(source,'services/ImageTools'));const root='/sandbox/workspace/images';fs.mkdirSync(nativePath(root),{recursive:true});Attachments.configure('/sandbox/backup-app');
    const jpeg=Uint8Array.from([255,216,255,217]).buffer;
    kits['@kit.ImageKit'].image={createImageSource:()=>({getImageInfo:async()=>({size:{width:1,height:1}}),createPixelMap:async()=>({release:async()=>{}}),release:async()=>{}}),createImagePacker:()=>({packing:async()=>jpeg,release:async()=>{}})};
    const approval=new ToolApproval();const profile={id:'image-provider',protocol:'chat-completions',baseUrl:'https://images.invalid/v1',credentialAlias:'fixture-key'};
    const tools=new ImageTools(profile,{providerId:profile.id,modelId:'image-test'},root,approval,[]);let requests=0;
    jsonScript=(url,options)=>{requests++;assert.equal(options.header.Authorization,'Bearer fixture-secret');
      if(url.endsWith('/generations')){assert.equal(JSON.parse(options.extraData).model,'image-test');}
      else {assert.equal(url,'https://images.invalid/v1/images/edits');assert.match(options.header['Content-Type'],/multipart/);const body=Buffer.from(options.extraData);assert.ok(body.includes(Buffer.from('name="image"')));assert.ok(body.includes(Buffer.from(jpeg)));}
      return{responseCode:200,result:JSON.stringify({data:[{b64_json:Buffer.from(jpeg).toString('base64')}]})};};
    const call=args=>({id:'image',type:'function',function:{name:'generate_image',arguments:JSON.stringify(args)}});
    const denied=tools.execute(call({prompt:'a circle'}),new Cancellation());approval.respond(false);await assert.rejects(denied);assert.equal(requests,0);
    const generated=tools.execute(call({prompt:'a circle'}),new Cancellation());approval.respond(true);const first=JSON.parse(await generated);assert.ok(fs.existsSync(nativePath(root+'/'+first.path)));
    const edited=tools.execute(call({prompt:'make it blue',source:first.path}),new Cancellation());approval.respond(true);const second=JSON.parse(await edited);assert.notEqual(second.path,first.path);assert.equal(requests,2);
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
      const provider=new ProtocolProvider({id:scenario,name:scenario,protocol,defaultBaseUrl:input.baseUrl,defaultModel:input.model});
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
  await test('Responses reasoning reaches the live process, survives completion and reload, and stays out of answer text', async () => {
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const {ProviderRegistry}=load(path.join(source,'services/providers/ProviderRegistry'));
    const {runAgentLoop}=load(path.join(source,'services/AgentLoop'));
    const {ThreadViewModel}=load(path.join(source,'viewmodel/SessionViewModels'));
    const {buildTimeline}=load(path.join(source,'model/ProcessPresentation'));
    const registry=new ProviderRegistry();
    registry.register(new ProtocolProvider({id:'responses-thinking',name:'Responses',protocol:'responses',defaultBaseUrl:'https://fixture.invalid/v1',defaultModel:'gpt-5.2'}));
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
        assert.equal(thread.messages[1].stepViews[0].reasoningContent,'先检查输入，再核对结果。');
        const thinking=buildTimeline(thread.messages[1].stepViews)[0];assert.equal(thinking.kind,'process');assert.equal(thinking.items[0].tool,-1);
        emit({type:type+'.done',...coordinates,text:'先检查输入，再核对结果。'});
        emit({type:'response.output_text.delta',delta:'最终回答。'});
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
  await test('provider keeps active streams beyond three minutes and stops idle or cancelled streams', async () => {
    const {ProtocolProvider}=load(path.join(source,'services/providers/ProtocolProvider'));
    const provider=new ProtocolProvider({id:'test',name:'Test',protocol:'chat-completions',defaultBaseUrl:'https://fixture.invalid/v1',defaultModel:'test'});
    const input={model:'test',baseUrl:'https://fixture.invalid/v1',apiKey:'',messages:[{role:'user',content:'hello'}],tools:[],usageOrigin:{threadId:'trace-thread',turnId:'trace-turn',purpose:'conversation',step:2}};
    const {UsageLedger}=load(path.join(source,'services/UsageLedger'));
    const recordsBefore=new Set(UsageLedger.list().map(item=>item.id));
    let now=0, sequence=0, transport; const timers=new Map();
    fakeTimers={set(fn,ms){const id=++sequence;timers.set(id,{fn,at:now+ms});return id;},clear(id){timers.delete(id);}};
    const advance=ms=>{now+=ms;for(const [id,item] of [...timers])if(item.at<=now){timers.delete(id);item.fn();}};
    const emit=text=>transport.emit('dataReceive',Uint8Array.from(Buffer.from(text)).buffer);
    httpScript=request=>{transport=request;request.callback(null,200);};
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
      const idle=provider.stream({...input, requestUsage: false},new Cancellation(),()=>{});
      const timedOut=assert.rejects(idle,/120/);
      await new Promise(setImmediate);
      assert.equal(JSON.parse(transport.options.extraData).stream_options, undefined);
      advance(119999);emit('');advance(1);
      await timedOut;assert.equal(timers.size,0);
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
      assert.equal(tracked.length,4);assert.equal(tracked.map(item=>item.status).sort().join(','),'cancelled,complete,failed,failed');
      assert.ok(tracked.every(item=>item.origin.threadId==='trace-thread'&&item.origin.turnId==='trace-turn'&&item.origin.step===2),'all outcomes keep their origin');
    } finally {fakeTimers=undefined;}
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
  });
  console.log(completedTests+' native adapter integration checks passed. Fixtures: '+fixture);
})().catch(error=>{console.error(error);process.exitCode=1;});
