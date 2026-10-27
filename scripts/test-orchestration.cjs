// Real AgentLoop/tool policies/receipts; JS execution here is a deterministic adapter double.
// Native engine behavior is covered separately by cpp/tests/orchestration_test.cpp.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src/main/ets'), cache = new Map();
let nativeJob;
const native = {
  orchestrate(id, source, catalog, invoke) { return new Promise((resolve,reject)=>{ nativeJob={id,invoke,resolve,reject,cancels:0,replies:[]}; }); },
  cancelOrchestration(id) { assert.equal(id,nativeJob.id);nativeJob.cancels++; },
  settle(id,callId,output,error) { nativeJob.replies.push({id,callId,output,error}); }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText,
    { exports, setTimeout, clearTimeout, console, Observed: cls => cls, require: id => {
      if(id==='libtinybot_sandbox.so')return {default:native};
      if(id==='@kit.ArkTS')return {util:{generateRandomUUID:require('node:crypto').randomUUID,TextEncoder:class {encodeInto(s){return Buffer.from(s);}}}};
      return load(path.resolve(path.dirname(file), id));
    } }, { filename: file });
  return exports;
}
const { OrchestrationTools } = load(root + '/services/OrchestrationTools');
const { executeToolBatch, ToolPersistenceError } = load(root + '/services/ToolExecution');
const { runAgentLoop } = load(root + '/services/AgentLoop');
const { RuleTools } = load(root + '/services/RuleTools');
const { TeamTools, TeamToolLane } = load(root + '/services/TeamCoordinator');
const { Cancellation } = load(root + '/services/Cancellation');
const { validateSteps, interruptTools, stepMessages } = load(root + '/model/Agent');
const { stepEntry } = load(root + '/model/ContextProjection');
const { collectFileOperations } = load(root + '/model/FileOperations');
const { emptyData, parseAppData } = load(root + '/model/Conversation');
const executor = { async execute(code, catalog, invoke) {
  const tools = Object.fromEntries(JSON.parse(catalog).map(tool => [tool.name, async args => {
    const result = await invoke(tool.name, JSON.stringify(args));
    try { return JSON.parse(result); } catch { return result; }
  }]));
  try { return JSON.stringify({ status: 'ok', result: await vm.runInNewContext('(async()=>{' + code + '})()', { tools, ALL_TOOLS: JSON.parse(catalog) }) }); }
  catch (e) { return JSON.stringify({ status: 'error', error: e.message }); }
} };
const call = code => ({ id: 'outer', type: 'function', function: { name: 'orchestrate', arguments: JSON.stringify({ code }) } });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixture({ readOnly = false, team = false, persist = async () => {} } = {}) {
  const saved = [], files = new Map([['a.json', '[1,2]'], ['b.json', '[3,4]']]); let active = 0, peak = 0; const order = [];
  const base = { definitions: () => ['read_file', 'write_file'].map(name => ({ type: 'function', executionMode: name === 'write_file' ? 'sequential' : 'parallel', function: { name, description: name, parameters: {} } })),
    execute: async (call, signal) => {
      const args = JSON.parse(call.function.arguments);
      const snapshot = saved.at(-1);
      assert.ok(snapshot && snapshot.tools[0].children.some(child => child.call.id === call.id && child.status === 'running'), 'intent persisted before effects');
      order.push('start:' + args.path); peak = Math.max(peak, ++active);
      try {
        await sleep(8); signal.check();
        if (call.function.name === 'read_file') { if (!files.has(args.path)) throw Error('missing file'); return JSON.stringify({ content: files.get(args.path) }); }
        files.set(args.path, args.content); return JSON.stringify({ written: args.path });
      } finally { active--; order.push('end:' + args.path); }
    }
  };
  const policy = new RuleTools(base, readOnly);
  const inner = team ? new TeamTools(policy, new TeamToolLane()) : policy;
  const tools = new OrchestrationTools(inner, executor);
  let step;
  return { files, saved, order, tools, peak: () => peak, async run(code, signal = new Cancellation()) {
    step = { content: '', tools: [{ call: call(code), status: 'pending', output: '' }] };
    await executeToolBatch(step, 0, tools, tools.definitions(), signal, { event: () => {}, checkpoint: async () => {
      await persist(step); saved.push(JSON.parse(JSON.stringify(step)));
    } }); return step;
  } };
}
async function main() {
  await visualizeScenarios();
  const f = fixture({ team: true });
  const step = await f.run(`const r=await Promise.all(['a.json','b.json'].map(path=>tools.read_file({path})));
    const total=r.flatMap(x=>JSON.parse(x.content)).reduce((a,b)=>a+b,0);
    await tools.write_file({path:'sum.json',content:JSON.stringify({total})}); return {total,path:'sum.json'};`);
  assert.equal(JSON.parse(step.tools[0].output).result.total, 10); assert.equal(f.peak(), 2);
  assert.equal(f.files.get('sum.json'), '{"total":10}'); assert.equal(step.tools[0].children.length, 3);
  assert.ok(step.tools[0].children.every(c => c.status === 'complete')); validateSteps([step]);
  assert.equal(stepMessages(step).length, 2, 'model sees only outer call/result');
  const receiptEntry = stepEntry('u', 'a', step, 0);
  assert.equal(receiptEntry.results.length, 4);
  assert.deepEqual(JSON.parse(JSON.stringify(collectFileOperations(receiptEntry.results))).modifiedFiles, ['sum.json']);
  console.log('PASS parallel reads, dependent write, Team lane, checkpoint receipts and compact model output');

  const data = emptyData(); data.activeThreadId = 'thread'; data.threads = [{ id:'thread',title:'Orchestration',updatedAt:1,messages:[
    {id:'u',role:'user',content:'sum',status:'complete',error:''}, {id:'a',role:'assistant',content:'done',status:'complete',error:'',steps:[step]}] }];
  const restored = parseAppData(JSON.stringify(data));
  assert.equal(restored.threads[0].messages[1].steps[0].tools[0].children.length, 3);
  const interrupted = JSON.parse(JSON.stringify(step)); interrupted.tools[0].status = 'running'; interrupted.tools[0].children[2].status = 'running';
  interruptTools([interrupted]); assert.equal(interrupted.tools[0].children[0].status, 'complete'); assert.equal(interrupted.tools[0].children[2].status, 'interrupted');
  const corrupt = JSON.parse(JSON.stringify(step)); corrupt.tools[0].children[0].children = []; assert.throws(()=>validateSteps([corrupt]));
  console.log('PASS persisted child receipts, retrieval, compaction file evidence and interrupted-state recovery');

  const ro = fixture({readOnly:true}); const denied = await ro.run(`return await tools.write_file({path:'bad',content:'bad'});`);
  assert.equal(JSON.parse(denied.tools[0].output).status, 'error'); assert.equal(ro.files.has('bad'), false);
  assert.equal(denied.tools[0].status,'failed');
  const fail = fixture(); const partial = await fail.run(`return (await Promise.allSettled([tools.read_file({path:'a.json'}),tools.read_file({path:'missing'})])).map(x=>x.status);`);
  assert.deepEqual(JSON.parse(partial.tools[0].output).result, ['fulfilled','rejected']);
  assert.deepEqual(Array.from(partial.tools[0].children,x=>x.status), ['complete','failed']);
  const partialReceipt=JSON.parse(partial.tools[0].output);
  assert.equal(partialReceipt.conclusion.status,'partial');
  assert.equal(partialReceipt.issues[0].tool,'read_file');
  assert.equal(partialReceipt.issues[0].receipt.error,'missing file');
  console.log('PASS read-only policy and inspectable partial failures');

  const bounds = fixture(); await bounds.run(`await Promise.all(Array.from({length:12},()=>tools.read_file({path:'a.json'}))); return 12;`);
  assert.ok(bounds.peak() <= 4); assert.ok(bounds.peak() > 1);
  const serial = fixture(); await serial.run(`await Promise.all([tools.read_file({path:'a.json'}),tools.write_file({path:'x',content:'x'}),tools.read_file({path:'x'})]);`);
  assert.ok(serial.order.indexOf('end:a.json') < serial.order.indexOf('start:x'));
  const exhausted = fixture(); const exhaustedStep = await exhausted.run(`for(let i=0;i<33;i++) await tools.read_file({path:'a.json'});`);
  assert.equal(exhaustedStep.tools[0].children.length, 32); assert.equal(JSON.parse(exhaustedStep.tools[0].output).status, 'error');
  console.log('PASS bounded concurrency, exclusive barriers and nested call budget');

  const broken = fixture({persist:async step=> { if(step.tools[0].children?.length) throw Error('disk full'); }});
  await assert.rejects(broken.run(`try {await tools.write_file({path:'bad',content:'bad'});} catch {} return 'hidden';`), /disk full/);
  assert.equal(broken.files.has('bad'),false);
  const signal = new Cancellation(); let persistedWrite = false;
  const cancelled = fixture({persist:async step=> { if(step.tools[0].children?.some(c=>c.status==='complete')) { persistedWrite = true; signal.cancel(); } }});
  await assert.rejects(cancelled.run(`await tools.write_file({path:'kept',content:'yes'}); await tools.write_file({path:'later',content:'no'});`, signal));
  assert.equal(persistedWrite,true); assert.equal(cancelled.files.get('kept'),'yes'); assert.equal(cancelled.files.has('later'),false);
  console.log('PASS persistence failure cannot be caught by script; cancellation preserves committed writes');

  const turn={content:'',steps:[]}; let rounds=0;
  const tools = new OrchestrationTools({definitions:()=>[],execute:async()=>{throw Error('unexpected');}},executor);
  await runAgentLoop({ model:{stream:async messages=> ++rounds===1 ? {content:'',toolCalls:[call('return {total:10};')]} :
    (assert.equal(JSON.parse(messages.at(-1).content).result.total,10),{content:'Total: 10',toolCalls:[]})},
    tools,turn,messages:[],maxSteps:3 },new Cancellation(),{event:()=>{},checkpoint:async()=>{}});
  assert.equal(turn.content,'Total: 10'); assert.equal(rounds,2);
  console.log('PASS actual AgentLoop orchestration -> one result -> final model answer');

  const { NativeOrchestrationExecutor }=load(root+'/services/NativeOrchestrationExecutor');
  const adapter=new NativeOrchestrationExecutor(), cancelledSignal=new Cancellation();
  let releaseHost, hostCalls=0, finished=false;
  const adapterPending=adapter.execute('return await tools.read_file({});','[]',async()=>{
    hostCalls++;await new Promise(resolve=>{releaseHost=resolve;});return '{"content":"done"}';
  },cancelledSignal);
  const observation=adapterPending.then(()=>{finished=true;},()=>{finished=true;});
  nativeJob.invoke(1,'read_file','{}');await sleep(0);cancelledSignal.cancel();
  assert.equal(nativeJob.cancels,1);assert.equal(finished,false);
  nativeJob.resolve('{"status":"cancelled"}');await sleep(0);assert.equal(finished,false,'wait for admitted host work');
  releaseHost();await observation;assert.equal(finished,true);
  nativeJob.invoke(2,'read_file','{}');await sleep(0);assert.equal(hostCalls,1,'late callbacks cannot dispatch tools');
  console.log('PASS Native adapter propagates cancel, waits for JS and host cleanup, and rejects late dispatch');
  const largeReply='x'.repeat(1200000);
  const largePending=adapter.execute('return await tools.read_file({});','[]',async()=>largeReply,new Cancellation());
  nativeJob.invoke(1,'read_file','{}');await sleep(0);
  assert.equal(nativeJob.replies[0].output,largeReply);assert.equal(nativeJob.replies[0].error,false);
  nativeJob.resolve('{"status":"ok"}');await largePending;
  const {ToolFailure}=load(root+'/model/ToolFailure');
  const longError='native child diagnostic '.repeat(600);
  const errorPending=adapter.execute('return await tools.read_file({});','[]',async()=>{
    throw new ToolFailure('FS_STALE_VERSION',longError,'read_file',{path:'large.js',version:'v2'});
  },new Cancellation());
  nativeJob.invoke(1,'read_file','{}');await sleep(0);
  const errorReply=JSON.parse(nativeJob.replies[0].output);
  assert.equal(errorReply.error,longError);assert.equal(errorReply.code,'FS_STALE_VERSION');
  assert.equal(errorReply.details.version,'v2');assert.equal(errorReply.conclusion.status,'failed');
  nativeJob.resolve('{"status":"error"}');await errorPending;
  console.log('PASS native adapter retains multi-megabyte replies and complete structured child failure diagnostics');
  const { Diagnostics } = load(root+'/model/Diagnostics');
  const logs=[]; Diagnostics.configureLogSink(record=>logs.push(record));
  const failed=adapter.execute('return 1;','[]',async()=>'',new Cancellation());
  const failure=Object.assign(new Error('Native orchestration failed: Cannot dispatch host tool'),{code:'NATIVE_EXCEPTION'});
  nativeJob.reject(failure);
  await assert.rejects(failed,error=>error===failure);
  assert.equal(logs.at(-1).event,'orchestration_failed');
  assert.equal(logs.at(-1).fields.errorCode,'NATIVE_EXCEPTION');
  assert.ok(!JSON.stringify(logs).includes(failure.message));
  console.log('PASS native orchestration failures preserve the original error and emit sanitized diagnostics');
}

async function visualizeScenarios() {
  const { ToolSet } = load(root + '/services/ToolSet');
  const { WorkspaceTools } = load(root + '/services/WorkspaceTools');
  const { PreviewTools } = load(root + '/services/PreviewTools');
  const { PresentTools } = load(root + '/services/PresentTools');
  const { InteractionTools } = load(root + '/services/InteractionTools');
  const { CodeExecutionTools } = load(root + '/services/CodeExecutionTools');
  const { SelectedTools } = load(root + '/services/SelectedTools');
  const { ToolApproval } = load(root + '/services/ToolApproval');
  const { ToolFailure } = load(root + '/model/ToolFailure');
  const { latestPreviewIds, stepPreviews, stepDisplayContent, publishedAnswerParts } = load(root + '/model/PublishedPreview');
  const { deliveredFiles } = load(root + '/model/Deliverables');
  const { persistentTools, persistentTool, buildTimeline } = load(root + '/model/ProcessPresentation');
  const { conversationSections } = load(root + '/model/ConversationExport');
  const image = { id:'visual-shot',name:'preview.jpg',path:'visual-shot.jpg',mime:'image/jpeg',size:32 };
  const source = '<input id="slider" type="range" min="-10" max="10" value="2"><output id="result">4</output>' +
    '<script>slider.oninput=()=>result.textContent=String(Number(slider.value)**2)</script>';
  let sequence = 0;
  function visualFixture(options = {}) {
    const files = new Map(), versions = new Map(), saved = [], events = [];
    let revision = 0, step;
    const read = async path => {
      if (!files.has(path)) throw new ToolFailure('FS_NOT_FOUND','missing','check_path');
      events.push('read:' + path); return { path,content:files.get(path),version:versions.get(path) };
    };
    const store = {
      read,
      write: async (path,content,_signal,guard) => {
        const before=files.get(path);
        assert.ok(guard.version === null ? before === undefined : guard.version === versions.get(path));
        const version='v'+ ++revision;files.set(path,content);versions.set(path,version);events.push('write:'+path);
        return { path,version,written:true,bytes:content.length,before:before||'',after:content,created:before===undefined };
      },
      edit: async (path,edits,version) => {
        assert.equal(version,versions.get(path));const before=files.get(path);
        let after=before;for(const edit of edits){assert.ok(after.includes(edit.oldText));after=after.replace(edit.oldText,edit.newText);}
        files.set(path,after);versions.set(path,'v'+ ++revision);events.push('edit:'+path);
        return {path,version:versions.get(path),written:true,bytes:after.length,before,after};
      }
    };
    const preview = new PreviewTools(store, async content => {
      events.push('startup');if(content.includes('BROKEN'))throw Error('fixture startup failed');
    }, async () => {
      events.push('capture');if(options.captureFailure)throw Error('fixture capture failed');
      return {image,width:360,height:240,viewportWidth:360};
    });
    const calculate = new CodeExecutionTools({ execute: async (code,input) => {
      events.push('calculate');return JSON.stringify({status:'ok',result:vm.runInNewContext('(function(){'+code+'})()', {input:JSON.parse(input)})});
    } });
    const base = new SelectedTools(new RuleTools(new ToolSet([new WorkspaceTools(store),preview,calculate,
      new InteractionTools(new ToolApproval()),new PresentTools(async path=>{await read(path);return path;})]),options.readOnly===true),
      options.disabled ? {agentMode:'custom',disabledTools:options.disabled} : {});
    const tools = new OrchestrationTools(base,executor);
    return {files,saved,events,tools,step:()=>step,async run(code,signal=new Cancellation(),onCheckpoint=()=>{}) {
      step={content:'',tools:[{call:{...call(code),id:'visual-'+ ++sequence},status:'pending',output:''}]};
      await executeToolBatch(step,0,tools,tools.definitions(),signal,{event(){},checkpoint:async()=>{
        validateSteps([step]);saved.push(JSON.parse(JSON.stringify(step)));onCheckpoint(step);
      }});return step;
    }};
  }
  const chart={kind:'bar',title:'Squares',source:'Computed fixture values',columns:[{key:'x',label:'x',type:'string'},{key:'square',label:'square',type:'number'}],
    rows:[{values:['2',4]},{values:['3',9]}]};
  const f=visualFixture();
  const step=await f.run(`const check=await tools.execute_code({code:'return input.map(x=>x*x);',input:[2,3]});
    await tools.write_file({path:'square.html',content:${JSON.stringify(source)}});
    const preview=await tools.publish_preview({path:'square.html',title:'Squares'});
    const csv=${JSON.stringify('"x","square"\r\n')}+[2,3].map((x,i)=>'"'+x+'",'+check.result[i]).join(${JSON.stringify('\r\n')});
    await tools.write_file({path:'squares.csv',content:csv});
    await tools.present_files({files:[{path:'square.html',description:'Interactive source'},{path:'squares.csv',description:'Computed data'}]});return {check,preview};`);
  assert.equal(step.tools[0].status,'complete',step.tools[0].output);
  assert.deepEqual(JSON.parse(step.tools[0].output).result.check.result,[4,9]);
  assert.deepEqual(Array.from(step.tools[0].children,x=>x.call.function.name),['execute_code','write_file','publish_preview','write_file','present_files']);
  const receipt=JSON.parse(step.tools[0].output).result.preview;
  assert.equal(receipt.version,'v1');assert.deepEqual(receipt.verification,{startup:'passed',screenshot:'captured',interaction:'not_checked'});
  assert.ok(f.events.indexOf('write:square.html')<f.events.indexOf('startup'));
  assert.ok(f.events.indexOf('startup')<f.events.indexOf('capture'));
  assert.equal(stepMessages(step).filter(x=>x.previewScreenshot).length,1);
  assert.ok(!JSON.stringify(stepMessages(step)).includes(source),'Model gets compact receipts and image, not another source copy');
  const latest=latestPreviewIds([{id:'answer',steps:[step]}]);
  assert.equal(stepPreviews('answer',step,0,latest).length,0,'Tool phase does not mount referenced previews');
  assert.equal(stepDisplayContent(step),'');
  assert.equal(deliveredFiles([step])[0].path,'square.html');
  assert.equal(deliveredFiles([step])[1].path,'squares.csv');
  assert.equal(f.files.get('squares.csv'),'"x","square"\r\n"2",4\r\n"3",9');
  assert.equal(persistentTools(step.tools).length,0);assert.equal(persistentTool(step.tools[0]),false);
  assert.ok(!buildTimeline([step]).some(x=>x.kind==='text'),'Prepared child previews stay inside the tool record');
  const data=emptyData();data.activeThreadId='visual-thread';data.threads=[{id:'visual-thread',title:'Visual',updatedAt:1,messages:[
    {id:'user',role:'user',content:'Make a square slider',status:'complete',error:''},
    {id:'answer',role:'assistant',content:'',status:'complete',error:'',steps:[step,{content:'Before\n\n'+receipt.reference+'\n\nAfter',tools:[]}]}]}];
  const restored=parseAppData(JSON.stringify(data));const restoredStep=restored.threads[0].messages[1].steps[0];
  assert.equal(stepPreviews('answer',restoredStep,0,latest,true)[0].screenshot.image.id,image.id);
  const exported=conversationSections(restored.threads[0]);
  assert.ok(exported.some(x=>x.kind==='attachment-image'&&x.attachment.id===image.id));
  assert.ok(!exported.some(x=>x.kind==='data-view'), 'New visualizations use the preview snapshot');
  // Historical receipts are fixtures, never new calls to the retired tool.
  for (const nested of [false,true]) {
    const legacy=JSON.parse(JSON.stringify(data)),legacyStep=legacy.threads[0].messages[1].steps[0];
    const savedChart={call:{id:'legacy-chart',type:'function',function:{name:'publish_data_view',arguments:JSON.stringify(chart)}},
      status:'complete',output:JSON.stringify(chart)};
    if(nested){legacyStep.tools[0].children.push(savedChart);legacyStep.tools[0].status='failed';}
    else{legacyStep.tools.push(savedChart);}
    const history=parseAppData(JSON.stringify(legacy)),historyStep=history.threads[0].messages[1].steps[0];
    assert.equal(persistentTools(historyStep.tools).length,1);assert.equal(persistentTool(nested?historyStep.tools[0]:historyStep.tools.at(-1)),true);
    const section=conversationSections(history.threads[0]).find(x=>x.kind==='data-view');
    assert.ok(section,'Historical top-level and orchestrated charts still export after reload');
    assert.ok(JSON.stringify(section).includes('Squares'));
  }
  const retired=await f.run(`if(ALL_TOOLS.some(t=>t.name==='publish_data_view'))throw Error('retired schema leaked');
    return await tools.publish_data_view({});`);
  assert.equal(retired.tools[0].status,'failed');assert.equal(retired.tools[0].children.length,0);
  const revision=await f.run(`await tools.read_file({path:'square.html'});
    await tools.edit_file({path:'square.html',oldText:'<output id="result">4</output>',newText:'<output id="result">9</output>'});
    return await tools.publish_preview({path:'square.html'});`);
  const revisions=latestPreviewIds([{id:'old',steps:[step]},{id:'new',steps:[revision]}]);
  const oldPreview=stepPreviews('old',step,0,revisions,true)[0],newPreview=stepPreviews('new',revision,0,revisions,true)[0];
  assert.equal(oldPreview.superseded,true);assert.equal(newPreview.superseded,false);
  assert.ok(oldPreview.content.includes('>4</output>'));assert.ok(newPreview.content.includes('>9</output>'));
  assert.ok(oldPreview.content.includes('>4</output>'),'Later edits never mutate the published child snapshot');
  for(const mutate of [s=>s.tools[0].children[2].status='failed',s=>s.tools[0].children[2].call.function.name='read_file',
    s=>s.tools[0].children[2].previewScreenshot.width=0,s=>s.tools[0].children[2].call.id=s.tools[0].call.id]) {
    const corrupt=JSON.parse(JSON.stringify(step));mutate(corrupt);assert.throws(()=>validateSteps([corrupt]));
  }
  console.log('PASS unified compute/write/preview/CSV/delivery; retired entry rejected; historical charts restore, stay visible and export');
  const runtime=visualFixture(),turn={content:'',steps:[]};let requests=0;
  await runAgentLoop({model:{stream:async messages=>{
    if(requests++===0)return {content:'',toolCalls:[{...call(`await tools.write_file({path:'runtime.html',content:${JSON.stringify(source)}});
      return await tools.publish_preview({path:'runtime.html'});`),id:'runtime-visual'}]};
    assert.equal(messages.filter(x=>x.previewScreenshot).length,1,'Next model request receives the actual child screenshot');
    assert.equal(messages.filter(x=>x.role==='tool').length,1,'Child calls do not become unmatched provider tool messages');
    return {content:'Published\n\n'+JSON.parse(messages.filter(x=>x.role==='tool').at(-1).content).result.reference,toolCalls:[]};
  }},tools:runtime.tools,turn,messages:[],maxSteps:4},new Cancellation(),{event(){},checkpoint:async()=>validateSteps(turn.steps)});
  assert.equal(requests,2);assert.ok(turn.content.startsWith('Published\n\n[[tinybot-preview:'));
  assert.equal(publishedAnswerParts('answer',turn.steps,1,'complete',[]).filter(x=>x.kind==='preview').length,1);
  console.log('PASS actual AgentLoop orchestrated publication -> screenshot in next model request -> final answer');
  const recovery=visualFixture(),recoveryTurn={content:'',steps:[]};let recoveryRequests=0;
  await runAgentLoop({model:{stream:async messages=>{
    const round=recoveryRequests++;
    if(round===0)return {content:'',toolCalls:[{...call(`await tools.write_file({path:'recover.html',content:'BROKEN'});
      return await tools.publish_preview({path:'recover.html',height:300});`),id:'recovery-first'}]};
    if(round===1){
      const failed=JSON.parse(messages.filter(x=>x.role==='tool').at(-1).content);
      const diagnostic=failed.issues.find(issue=>issue.tool==='publish_preview').receipt,retry=diagnostic.details.repair.retry;
      assert.equal(diagnostic.details.version,'v1');assert.equal(retry.arguments.path,'recover.html');
      return {content:'',toolCalls:[{...call(`await tools.read_file({path:'recover.html'});
        await tools.edit_file({path:'recover.html',oldText:'BROKEN',newText:'<p>Repaired</p>'});
        return await tools.publish_preview(${JSON.stringify(retry.arguments)});`),id:'recovery-retry'}]};
    }
    assert.equal(messages.filter(x=>x.previewScreenshot).length,1);
    assert.equal(JSON.parse(messages.filter(x=>x.role==='tool').at(-1).content).result.published,true);
    return {content:'Repaired and published\n\n'+JSON.parse(messages.filter(x=>x.role==='tool').at(-1).content).result.reference,toolCalls:[]};
  }},tools:recovery.tools,turn:recoveryTurn,messages:[],maxSteps:5},new Cancellation(),
    {event(){},checkpoint:async()=>validateSteps(recoveryTurn.steps)});
  assert.equal(recoveryRequests,3);assert.equal(recovery.events.filter(x=>x==='write:recover.html').length,1);
  assert.equal(recoveryTurn.steps[0].tools[0].status,'failed');assert.equal(recoveryTurn.steps[1].tools[0].status,'complete');
  const badCheck=visualFixture();
  const blocked=await badCheck.run(`await tools.execute_code({code:'throw Error("failed logic check")'});
    await tools.write_file({path:'not-written.html',content:'no'});await tools.publish_preview({path:'not-written.html'});`);
  assert.equal(blocked.tools[0].status,'failed');assert.equal(blocked.tools[0].children.length,1);assert.equal(badCheck.files.size,0);
  console.log('PASS actual AgentLoop failure receipt -> versioned local repair -> retry -> screenshot feedback; failed checks stop dependent publication');
  const fail=visualFixture();
  const failed=await fail.run(`await tools.write_file({path:'repair.html',content:'BROKEN'});await tools.publish_preview({path:'repair.html',height:300});
    await tools.present_files({files:[{path:'repair.html'}]});`);
  assert.equal(failed.tools[0].status,'failed');assert.equal(failed.tools[0].children.length,2);
  assert.equal(stepPreviews('answer',failed,0,[]).length,0);assert.equal(fail.files.get('repair.html'),'BROKEN');
  const failure=JSON.parse(failed.tools[0].children[1].output);assert.equal(failure.details.repair.retry.arguments.path,'repair.html');
  assert.equal(failure.details.repair.retry.arguments.height,300);assert.equal(failure.details.version,'v1');
  const repaired=await fail.run(`await tools.read_file({path:'repair.html'});await tools.edit_file({path:'repair.html',oldText:'BROKEN',newText:'<p>Ready</p>'});
    return await tools.publish_preview({path:'repair.html',height:300});`);
  assert.equal(repaired.tools[0].status,'complete');assert.equal(fail.events.filter(x=>x==='write:repair.html').length,1);
  assert.equal(JSON.parse(repaired.tools[0].output).result.version,'v2');
  const capture=visualFixture({captureFailure:true});
  const uncaptured=await capture.run(`await tools.write_file({path:'square.html',content:'<p>Ready</p>'});return await tools.publish_preview({path:'square.html'});`);
  assert.equal(uncaptured.tools[0].children[1].previewContent,undefined);
  assert.equal(JSON.parse(uncaptured.tools[0].children[1].output).details.category,'SCREENSHOT_FAILED');
  const partial=await f.run(`await tools.publish_preview({path:'square.html'});throw Error('later task failed');`);
  assert.equal(partial.tools[0].status,'failed');assert.equal(stepPreviews('answer',partial,0,latestPreviewIds([{id:'answer',steps:[partial]}])).length,0);
  assert.equal(stepMessages(partial).filter(x=>x.previewScreenshot).length,1);validateSteps([partial]);
  const cancelled=new Cancellation();
  await assert.rejects(f.run(`await tools.publish_preview({path:'square.html'});await tools.write_file({path:'never.html',content:'no'});`,cancelled,s=>{
    if(s.tools[0].children?.some(x=>x.call.function.name==='publish_preview'&&x.status==='complete'))cancelled.cancel();
  }));
  assert.equal(f.files.has('never.html'),false);assert.equal(f.step().tools[0].children[0].status,'complete');validateSteps([f.step()]);
  for(const options of [{disabled:['publish_preview']},{readOnly:true}]) {
    const denied=visualFixture(options);
    const attempt=await denied.run(options.readOnly?`await tools.write_file({path:'blocked',content:'no'});`:`await tools.publish_preview({path:'blocked.html'});`);
    assert.equal(attempt.tools[0].status,'failed');assert.equal(denied.files.size,0);
    assert.ok(!denied.tools.definitions().find(x=>x.function.name==='orchestrate').function.description.includes('request_user_input,'));
  }
  console.log('PASS structured preview failure -> observed local edit -> republish; capture failure, partial success, cancellation and permissions');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
