// Real AgentLoop/tool policies/receipts; JS execution here is a deterministic adapter double.
// Native engine behavior is covered separately by cpp/tests/orchestration_test.cpp.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(studio + '/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve('entry/src/main/ets'), cache = new Map();
let nativeJob;
const native = {
  orchestrate(id, source, catalog, invoke) { return new Promise(resolve=>{ nativeJob={id,invoke,resolve,cancels:0,replies:[]}; }); },
  cancelOrchestration(id) { assert.equal(id,nativeJob.id);nativeJob.cancels++; },
  settle(id,callId,output,error) { nativeJob.replies.push({id,callId,output,error}); }
};
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText,
    { exports, setTimeout, clearTimeout, console, require: id => {
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
const { ContextTools } = load(root + '/services/ContextTools');
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
  const retrieval = new ContextTools(f.tools, () => [receiptEntry], 200000);
  const retrieved = JSON.parse(await retrieval.execute({ function: { name: 'read_tool_result', arguments: JSON.stringify({ messageId: 'a', callId: step.tools[0].children[0].call.id }) } }, new Cancellation()));
  assert.equal(JSON.parse(retrieved.content).content, '[1,2]');
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
}
main().catch(e=>{console.error(e);process.exitCode=1;});
