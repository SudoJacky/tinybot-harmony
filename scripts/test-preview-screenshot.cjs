// Publication -> durable screenshot -> next model request, through the actual tool/queue/protocol modules.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root=path.resolve(__dirname,'../entry/src/main/ets'),cache=new Map();
function load(file){file=path.resolve(file+'.ets');if(cache.has(file))return cache.get(file);const exports={};cache.set(file,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText,
 {exports,Error,setTimeout,clearTimeout,Observed:c=>c,require:id=>load(path.resolve(path.dirname(file),id))},{filename:file});return exports;}
const from=name=>load(path.join(root,name));
const {PreviewCapture}=from('services/PreviewCapture'),{PreviewTools}=from('services/PreviewTools');
const {Cancellation}=from('services/Cancellation'),{runAgentLoop}=from('services/AgentLoop');
const {stepMessages,validateSteps}=from('model/Agent'),{ProviderRegistry}=from('services/providers/ProviderRegistry');
const {chatRequest}=from('services/providers/ChatCompletionsProtocol'),{responsesRequest,anthropicRequest}=from('services/providers/WireProtocols');
const snapshot={image:{id:'preview-image',name:'Preview screenshot.jpg',mime:'image/jpeg',path:'preview-image.jpg',size:128},width:1100,height:840,viewportWidth:344};
const call={id:'preview-call',type:'function',function:{name:'publish_preview',arguments:'{"path":"art.svg"}'}};
const files={read:async()=>({content:'<svg viewBox="0 0 100 50" xmlns="http://www.w3.org/2000/svg"></svg>',version:'v1'})};
const tools=new PreviewTools(files,async()=>{},(content,signal)=>PreviewCapture.capture(content,signal));
(async()=>{
 await assert.rejects(PreviewCapture.capture('x',new Cancellation()),/unavailable/);
 let current=[];const stop=PreviewCapture.subscribe(requests=>{current=requests;});
 const cancelled=new Cancellation();const first=PreviewCapture.capture('first',cancelled),second=PreviewCapture.capture('second',new Cancellation());
 assert.equal(current[0].content,'first');const oldId=current[0].id;cancelled.cancel();await assert.rejects(first);
 assert.equal(current[0].content,'second');PreviewCapture.complete(oldId,snapshot);assert.equal(current.length,1);
 PreviewCapture.complete(current[0].id,snapshot);assert.equal(await second,snapshot);assert.equal(current.length,0);
 const pending=PreviewCapture.capture('detached',new Cancellation());stop();await assert.rejects(pending,/detached/);
 console.log('PASS screenshot queue serializes renders and handles cancellation, stale callbacks and host detachment');
 let captures=0;const detach=PreviewCapture.subscribe(requests=>{if(requests[0]){captures++;setTimeout(()=>PreviewCapture.complete(requests[0].id,snapshot),0);}});
 const turn={content:'',steps:[]},requests=[],checkpoints=[];
 await runAgentLoop({turn,tools,maxSteps:3,messages:[],model:{stream:async messages=>{requests.push(JSON.parse(JSON.stringify(messages)));
   const reference=requests.length>1?JSON.parse(turn.steps[0].tools[0].output).reference:'';
   return requests.length===1?{content:'',toolCalls:[call]}:{content:'Inspected the card.\n\n'+reference,toolCalls:[]};}}},new Cancellation(),
 {event(){},checkpoint:async()=>checkpoints.push(JSON.parse(JSON.stringify(turn)))});
 assert.equal(captures,1);assert.equal(turn.steps[0].tools[0].status,'complete');assert.ok(checkpoints.some(c=>c.steps[0].tools[0]?.previewScreenshot));
 validateSteps(turn.steps);const restored=JSON.parse(JSON.stringify(turn.steps[0]));
 assert.deepEqual(JSON.parse(JSON.stringify(stepMessages(restored))),requests[1]);
 const screenshotMessage=requests[1].find(m=>m.previewScreenshot);assert.equal(screenshotMessage.attachments[0].path,'preview-image.jpg');
 const output=JSON.parse(turn.steps[0].tools[0].output);assert.equal(output.screenshot.viewportWidth,344);assert.ok(!JSON.stringify(output).includes('base64'));
 const imageUrl='data:image/jpeg;base64,aW1hZ2U=';
 const hydrated=requests[1].map(m=>m.previewScreenshot?{...m,images:[imageUrl]}:m);
 const chat=chatRequest('vision',hydrated,[]);assert.equal(chat.messages.at(-1).content.at(-1).image_url.url,imageUrl);
 const responses=responsesRequest('vision',hydrated,[]);assert.equal(responses.input.at(-1).content.at(-1).image_url,imageUrl);
 const anthropic=anthropicRequest('vision',hydrated,[]);assert.equal(anthropic.messages.at(-1).content.at(-1).source.data,'aW1hZ2U=');
 assert.ok(responses.input.some(m=>m.type==='function_call_output'&&m.call_id===call.id));
 console.log('PASS successful publication checkpoints/replays screenshot attachments and sends images after tool results in all three protocols');
 let delivered;const registry=new ProviderRegistry();registry.register({info:{id:'test',name:'Test'},endpoint:()=>'',stream:async request=>{delivered=request.messages;return {content:'done',toolCalls:[]};}});
 const textModel=registry.bind({providerId:'test',model:'text',baseUrl:'',credentialAlias:'',images:false},{read:async()=>''});
 await textModel.stream(requests[1],[],new Cancellation(),()=>{});
 assert.equal(delivered.at(-1).attachments,undefined);assert.match(delivered.at(-1).content,/screenshot was not sent/);
 await assert.rejects(textModel.stream([{role:'user',content:'Uploaded image',attachments:[snapshot.image]}],[],new Cancellation(),()=>{}),/不支持图片/);
 console.log('PASS text-only models receive an explicit unavailable-image notice while uploaded images retain their capability check');
 detach();
 const failure=new PreviewTools(files,async()=>{},async()=>{throw Error('Surface capture failed');});
 const receipt={call,status:'running',output:''};await assert.rejects(failure.execute(call,new Cancellation(),{execution:receipt}),e=>e.details.category==='SCREENSHOT_FAILED');
 assert.equal(receipt.previewContent,undefined);assert.equal(receipt.previewScreenshot,undefined);
 const broken=JSON.parse(JSON.stringify(restored));broken.tools[0].previewScreenshot.image.path='../escape.jpg';assert.throws(()=>validateSteps([broken]));
 console.log('PASS capture failures never publish a fake screenshot and persisted image paths are validated');
})().catch(error=>{console.error(error);process.exitCode=1;});
