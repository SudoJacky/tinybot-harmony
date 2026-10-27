// Source-level preview browser integration: real tools/session/receipts, controlled native effects.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const Ajv=require(require.resolve('ajv',{paths:[path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader')]}));
const root=path.resolve(__dirname,'../entry/src/main/ets'),cache=new Map();
function load(file){file=path.resolve(file+'.ets');if(cache.has(file))return cache.get(file);const exports={};cache.set(file,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,
 {exports,Error,Date,setTimeout,clearTimeout,Observed:c=>c,require:id=>load(path.resolve(path.dirname(file),id))},{filename:file});return exports;}
const from=name=>load(path.join(root,name));
const {BrowserSession}=from('services/BrowserSession'),{BrowserTools}=from('services/BrowserTools');
const {Cancellation}=from('services/Cancellation'),{PreviewTools}=from('services/PreviewTools');
const {resolveBrowserPreview}=from('model/BrowserPreview'),{stepMessages,validateSteps}=from('model/Agent');
const {PreviewBrowserRuntime}=from('services/PreviewBrowserRuntime');
const {chatRequest}=from('services/providers/ChatCompletionsProtocol'),{responsesRequest,anthropicRequest}=from('services/providers/WireProtocols');
const {ProviderRegistry}=from('services/providers/ProviderRegistry');
const {parseWebUiMessage}=from('model/WebUi');
const {conversationSections}=from('model/ConversationExport');
const call=(name,args={})=>({id:name,type:'function',function:{name,arguments:JSON.stringify(args)}});
const publication={call:call('publish_preview',{path:'counter.html'}),status:'running',output:''};
const previewTools=new PreviewTools({read:async()=>({content:'<button>Add</button>',version:'v1'})},async()=>{});
function fixture(preview){
 const browser=new BrowserSession(),signal=new Cancellation();let count=0,captures=0;
 const driver={effects:[],async open(url){browser.preview=undefined;this.url=url;},
  async openPreview(value){browser.preview=value;browser.previewInstance++;this.url='Preview: '+value.title;},
  async snapshot(id){return {snapshotId:id,url:this.url,title:'Counter',text:'Count '+count,elements:[{id:1,role:'button',label:'Add',type:'',value:String(count)}],truncated:false,embeddedFrames:0,trust:'untrusted',errors:['observable error']};},
  async act(action){this.effects.push(action.action);count++;},
  async captureFrame(){captures++;return {image:{id:'frame-'+captures,name:'frame.jpg',mime:'image/jpeg',path:'frame-'+captures+'.jpg',size:100},width:400,height:360,viewportWidth:400,elapsedMs:0,capturedAt:Date.now()};},
  userBack(){return false;},close(){}};
 browser.attach(driver,()=>browser.setPresentation(true,true));browser.updatePolicy('enabled');
 const tools=new BrowserTools(browser,'thread',false,id=>{if(id!==preview.previewId)throw Error('Wrong preview');return preview;});
 return {browser,driver,tools,signal};
}
async function execute(f,name,args){const execution={call:call(name,args),status:'running',output:''};
 try{execution.output=await f.tools.execute(execution.call,f.signal,{execution});execution.status='complete';}
 catch(error){execution.status='failed';execution.output=error.output||JSON.stringify({error:error.message,code:error.code});throw Object.assign(error,{execution});}
 return execution;}
(async()=>{
 publication.output=await previewTools.execute(publication.call,new Cancellation(),{execution:publication});publication.status='complete';
 const previewId=JSON.parse(publication.output).previewId;
 const preview=resolveBrowserPreview([{steps:[{content:'',tools:[publication]}]}],previewId);
 assert.equal(preview.version,'v1');assert.match(preview.content,/<button>Add/);
 assert.throws(()=>resolveBrowserPreview([],previewId),/not a successful publication/);
 const child={call:call('orchestrate'),status:'complete',output:'{}',children:[publication]};
 assert.equal(resolveBrowserPreview([{steps:[{content:'',tools:[child]}]}],previewId).previewId,previewId);
 console.log('PASS preview lookup resolves exact current/history/orchestration receipts and rejects other chats');
 const f=fixture(preview);await execute(f,'browser_open',{previewId,reason:'Verify interaction'});
 const ajv=new Ajv({strict:true});
 for(const definition of f.tools.definitions()) ajv.compile(JSON.parse(JSON.stringify(definition.function.parameters)));
 let page=JSON.parse((await execute(f,'browser_snapshot')).output).page;
 const action=await execute(f,'browser_action',{action:'click',snapshotId:page.snapshotId,elementId:1,capture:{count:2,intervalMs:250}});
 assert.deepEqual(f.driver.effects,['click']);assert.equal(action.browserObservation.frames.length,2);
 assert.equal(action.browserObservation.previewId,previewId);assert.equal(action.browserObservation.version,'v1');
 assert.ok(action.browserObservation.frames[1].elapsedMs>=240);assert.deepEqual(Array.from(action.browserObservation.errors),['observable error']);
 await execute(f,'browser_wait',{condition:{type:'text',text:'Count 1'},timeoutMs:0});
 await execute(f,'browser_wait',{condition:{type:'value',text:'Add',value:'1'},timeoutMs:0});
 await assert.rejects(execute(f,'browser_wait',{condition:{type:'text',text:'never'},timeoutMs:0}),error=>error.code==='TIMEOUT');
 await assert.rejects(execute(f,'browser_capture',{count:7,intervalMs:250}),error=>error.code==='INVALID_ARGUMENTS');
 await assert.rejects(execute(f,'browser_action',{action:'click',snapshotId:page.snapshotId,elementId:1,capture:null}),error=>error.code==='INVALID_ARGUMENTS');
 await assert.rejects(execute(f,'browser_open',{url:'https://example.com',previewId,reason:'Ambiguous'}),error=>error.code==='INVALID_ARGUMENTS');
 console.log('PASS preview browser runs one effect with local timestamped sampling and explicit wait/argument failures');
 const restored=JSON.parse(JSON.stringify({content:'',tools:[action]}));validateSteps([restored]);
 const exported=conversationSections({title:'Test',messages:[{id:'answer',role:'assistant',status:'complete',steps:[restored],content:''}]});
 assert.equal(exported.filter(section=>section.kind==='attachment-image').length,2);
 const messages=stepMessages(restored);assert.equal(messages.filter(m=>m.previewScreenshot).length,2);
 const hydrated=messages.map(m=>m.previewScreenshot?{...m,images:['data:image/jpeg;base64,aW1hZ2U=']}:m);
 assert.equal(chatRequest('vision',hydrated,[]).messages.filter(m=>Array.isArray(m.content)).length,2);
 assert.equal(responsesRequest('vision',hydrated,[]).input.filter(m=>Array.isArray(m.content)&&m.content.some(part=>part.type==='input_image')).length,2);
 assert.ok(JSON.stringify(anthropicRequest('vision',hydrated,[])).includes('aW1hZ2U='));
 const registry=new ProviderRegistry();let delivered;
 registry.register({info:{id:'test',name:'Test'},endpoint:()=>'',stream:async request=>{delivered=request.messages;return {content:'',toolCalls:[]};}});
 await registry.bind({providerId:'test',model:'text',baseUrl:'',credentialAlias:'',images:false},{read:async()=>''}).stream(messages,[],new Cancellation(),()=>{});
 assert.equal(delivered.filter(m=>m.attachments).length,0);assert.match(delivered.at(-1).content,/screenshot was not sent/);
 const broken=JSON.parse(JSON.stringify(restored));broken.tools[0].browserObservation.frames[0].image.path='../escape.jpg';assert.throws(()=>validateSteps([broken]));
 console.log('PASS durable multi-frame observations replay through all model protocols and text-only models receive an explicit notice');
 f.driver.captureFrame=async()=>{throw Error('Surface failed');};
 page=JSON.parse((await execute(f,'browser_snapshot')).output).page;
 await assert.rejects(execute(f,'browser_action',{action:'click',snapshotId:page.snapshotId,elementId:1,capture:{count:1,intervalMs:250}}),error=>{
  assert.equal(JSON.parse(error.output).completed,true);assert.equal(error.execution.browserObservation.frames.length,0);return true;});
 assert.deepEqual(f.driver.effects,['click','click'],'post-effect capture failure must never repeat the action');
 let frames=0;const g=fixture(preview);await execute(g,'browser_open',{previewId,reason:'Test cancellation'});
 const original=g.driver.captureFrame.bind(g.driver);g.driver.captureFrame=async()=>{const frame=await original();if(++frames===1)setTimeout(()=>g.browser.setPresentation(false,true),0);return frame;};
 await assert.rejects(execute(g,'browser_capture',{count:3,intervalMs:250}),error=>{
  assert.equal(error.execution.browserObservation.frames.length,1);const step={content:'',tools:[error.execution]};validateSteps([step]);assert.equal(stepMessages(step).filter(m=>m.previewScreenshot).length,1);return true;});
 const h=fixture(preview);await execute(h,'browser_open',{previewId,reason:'Test stop'});
 const originalH=h.driver.captureFrame.bind(h.driver);h.driver.captureFrame=async()=>{const frame=await originalH();setTimeout(()=>h.signal.cancel(),0);return frame;};
 await assert.rejects(execute(h,'browser_capture',{count:3,intervalMs:250}),error=>error.code==='CANCELLED'&&error.execution.browserObservation.frames.length===1);
 console.log('PASS action completion survives screenshot failure; collapse and cancellation preserve partial frames');
 const runtime=new PreviewBrowserRuntime();let pending;
 runtime.attach((id,operation,args)=>{pending={id,operation,args};},async()=>({}));runtime.ready();
 const snap=runtime.snapshot('runtime');runtime.receive(pending.id,JSON.stringify({snapshotId:'runtime',text:'ok',elements:[]}));assert.equal((await snap).text,'ok');
 const stale=runtime.snapshot('released');runtime.detach();await assert.rejects(stale,/released/);
 const attachment=runtime.attach(()=>{},async()=>({}));runtime.ready();
 runtime.attach(()=>{},async()=>({}));runtime.ready();runtime.detach(attachment);
 assert.equal(runtime.isReady,true,'an old view releasing cannot detach a replacement page');runtime.detach();
 assert.throws(()=>parseWebUiMessage('{"type":"browserResult","id":0,"message":"{}"}'));
 console.log('PASS preview transport drains pending requests on release and validates bridge results');
 f.browser.release(f.signal);g.browser.release(g.signal);h.browser.release(h.signal);
})().catch(error=>{console.error(error);process.exitCode=1;});
