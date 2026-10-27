// Deterministic agent repair and device-probe lifecycle tests; no network/model required.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(studio+'/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root=path.resolve('entry/src/main/ets'),cache=new Map();
function load(file){
 file=path.resolve(file.endsWith('.ets')?file:file+'.ets');if(cache.has(file))return cache.get(file);
 const exports={};cache.set(file,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
  {exports,setTimeout,clearTimeout,console,require:id=>load(path.resolve(path.dirname(file),id))},{filename:file});return exports;
}
const {WebUiPreflight}=load(root+'/services/WebUiPreflight');
const {Cancellation}=load(root+'/services/Cancellation');
const {runAgentLoop}=load(root+'/services/AgentLoop');
const {stepMessages,validateSteps,validateToolCalls}=load(root+'/model/Agent');
const surface=js=>'```tinybot-ui\n'+[
 {op:'begin',version:1,title:'Probe',state:{}},
 {op:'node',node:{id:'web',kind:'web',data:JSON.stringify({version:1,html:'',css:'',js,library:'three',height:360})}},
 {op:'end'}].map(r=>JSON.stringify(r)).join('\n')+'\n```';
const bad=surface('new THREE.OrbitControls();'),good=surface('new OrbitControls(camera, canvas);');
const tools={definitions:()=>[],execute:async()=>{throw Error('unexpected tool')}};
const observer={event:()=>{},checkpoint:async()=>{}};
async function main(){
 let probes=[];let detach=WebUiPreflight.subscribe(items=>probes=items);
 const firstSignal=new Cancellation();
 const first=WebUiPreflight.validate(bad,firstSignal);const rejected=assert.rejects(first,/已停止/);
 const old=probes[0].id;
 const second=WebUiPreflight.validate(good,new Cancellation());
 assert.equal(probes[0].id,old);firstSignal.cancel();await rejected;
 assert.notEqual(probes[0].id,old);WebUiPreflight.complete(old,'stale error');assert.equal(probes.length,1);
 WebUiPreflight.complete(probes[0].id);await second;assert.equal(probes.length,0);
 const lost=WebUiPreflight.validate(good,new Cancellation());const lostCheck=assert.rejects(lost,/detached/);detach();await lostCheck;
 await assert.rejects(WebUiPreflight.validate(good,new Cancellation()),/unavailable/);
 console.log('PASS preflight queue, cancellation, stale events, detach, unavailable host');

 const inputs=[],turn={content:'',steps:[]};
 const model={stream:async messages=>{inputs.push(JSON.parse(JSON.stringify(messages)));return {content:inputs.length===1?bad:'Use a source file.',toolCalls:[]};}};
 await runAgentLoop({model,tools,messages:[{role:'user',content:'build a model'}],turn,maxSteps:5,
  validateAnswer:async()=>{throw Error('Legacy code must not run');},recoverUi:async()=>{throw Error('Legacy code must not be migrated');}},new Cancellation(),observer);
 assert.equal(inputs.length,2);assert.ok(inputs[1].at(-1).content.includes('UNSUPPORTED_PREVIEW_FORMAT'));
 assert.equal(JSON.parse(turn.steps[0].uiValidation).category,'UNSUPPORTED_PREVIEW_FORMAT');assert.equal(turn.steps[1].uiValidation,'');assert.equal(turn.content,'Use a source file.');
 validateSteps(turn.steps);const reloaded=JSON.parse(JSON.stringify(turn.steps));assert.ok(stepMessages(reloaded[0]).at(-1).content.includes('publish_preview'));
 console.log('PASS legacy inline UI is rejected without executing/migrating; repair guidance survives replay');

 const endless={content:'',steps:[]};let count=0;
 await assert.rejects(runAgentLoop({model:{stream:async()=>{count++;return {content:bad,toolCalls:[]};}},tools,messages:[],turn:endless,maxSteps:20},new Cancellation(),observer),/repair attempts/);
 assert.equal(count,3);assert.equal(endless.content,'');
 const signal=new Cancellation(),cancelled={content:'',steps:[]};let requests=0;
 await assert.rejects(runAgentLoop({model:{stream:async()=>{requests++;signal.cancel();return {content:bad,toolCalls:[]};}},tools,messages:[],turn:cancelled,maxSteps:5},signal,observer),/已停止/);
 assert.equal(requests,1);assert.equal(cancelled.steps[0].uiValidation,'pending');
 console.log('PASS repairs bounded, cancellation is not retried, pending surface remains withheld');
 const call={id:'large',type:'function',function:{name:'execute_code',arguments:JSON.stringify({code:' '.repeat(128*1024)+'return 42;'})}};
  validateToolCalls([call]);call.function.name='write_file';validateToolCalls([call]);
  console.log('PASS tool arguments exceed the old 96 KiB cap while structural validation remains active');
  call.function.name='execute_code';
  const {ChatStream}=load(root+'/services/ChatStream');const chat=new ChatStream(()=>{});
  chat.push('data: '+JSON.stringify({choices:[{index:0,delta:{tool_calls:[{...call,index:0}]}}]})+'\n\n');
  chat.push('data: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:'tool_calls'}]})+'\n\ndata: [DONE]\n\n');
  assert.equal(chat.finish().toolCalls[0].function.arguments,call.function.arguments);
  const {AnthropicStream}=load(root+'/services/providers/EventStreams');const anthropic=new AnthropicStream(()=>{});
  for(const event of [{type:'message_start'},{type:'content_block_start',index:0,content_block:{type:'tool_use',id:'large',name:'execute_code',input:{}}},
   {type:'content_block_delta',index:0,delta:{type:'input_json_delta',partial_json:call.function.arguments}},{type:'content_block_stop',index:0},
   {type:'message_delta',delta:{stop_reason:'tool_use'}},{type:'message_stop'}])anthropic.push('data: '+JSON.stringify(event)+'\n\n');
  assert.equal(anthropic.finish().toolCalls[0].function.arguments,call.function.arguments);
  console.log('PASS large execute_code arguments survive OpenAI and Anthropic streaming assembly');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
