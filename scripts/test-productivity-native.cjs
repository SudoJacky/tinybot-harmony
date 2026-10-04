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
const nativePath = p => p.startsWith('/sandbox/') ? path.join(fixture, p.slice(1)) : p;
const fileIo = {
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8, NOFOLLOW: 16 },
  access: async p => fs.existsSync(nativePath(p)), mkdir: p => fs.promises.mkdir(nativePath(p)), readText: p => fs.promises.readFile(nativePath(p), 'utf8'),
  listFile: async p => fs.promises.readdir(nativePath(p)),
  open: async (p, flags) => { const h = await fs.promises.open(nativePath(p), flags & 4 ? 'w' : 'r'); handles.set(h.fd, h); return { fd: h.fd }; },
  read: async (fd, bytes) => (await handles.get(fd).read(new Uint8Array(bytes))).bytesRead,
  write: async (fd, bytes, options) => (await handles.get(fd).write(new Uint8Array(bytes), 0, bytes.byteLength, options.offset)).bytesWritten,
  close: async file => { const fd = typeof file === 'number' ? file : file.fd; await handles.get(fd).close(); handles.delete(fd); },
  stat: async fd => typeof fd === 'number' ? handles.get(fd).stat() : fs.promises.stat(nativePath(fd)),
  lstat: async p => { try { return await fs.promises.lstat(nativePath(p)); } catch(e) { if(e.code==='ENOENT')e.code=13900002;throw e; } },
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
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error() {} } },
  '@kit.CoreFileKit': { fileIo, picker: { DocumentViewPicker: class { async save() {return [selectedFile];} async select() {return [selectedFile];} } } }, '@kit.ImageKit': { image: {} }, '@kit.NetworkKit': { http },
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
async function test(name, run) { await run(); console.log('PASS '+name); }
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
  await test('backup restores independent conversations, attachments, files and scoped memory without secrets',async()=>{
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
    const restored=await readBackup(context);assert.notEqual(restored.threads[0].id,'thread');assert.equal(restored.providerProfiles[0].enabled,false);
    assert.equal(JSON.parse(exported).data.config.userDocument, data.config.userDocument);
    assert.equal(restored.config.userDocument, data.config.userDocument);
    assert.equal(restored.productivity.memories[0].threadId,restored.threads[0].id);assert.equal(restored.productivity.memories[0].sourceMessageId,restored.threads[0].messages[0].id);
    assert.equal(fs.readFileSync(nativePath(root+'/workspace/'+restored.threads[0].id+'/note.txt'),'utf8'),'workspace');
    const restoredAttachment=restored.threads[0].messages[0].attachments[0];assert.notEqual(restoredAttachment.id,id);assert.equal(fs.readFileSync(nativePath(root+'/attachments/'+restoredAttachment.path),'utf8'),'sample');
    model.parseAppData(JSON.stringify(restored));const bad=JSON.parse(exported);bad.files[0].path='../escape';fs.writeFileSync(nativePath(selectedFile),JSON.stringify(bad));await assert.rejects(readBackup(context),/路径/);
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
  console.log('18 native adapter integration checks passed. Fixtures: '+fixture);
})().catch(error=>{console.error(error);process.exitCode=1;});
