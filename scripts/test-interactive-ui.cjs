// Protocol and session integration checks. No model/network/native UI required.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src');
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  let source = fs.readFileSync(file, 'utf8');
  if (file.endsWith('SessionService.test.ets')) source += '\nexport { Fixture, seed };';
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText;
  vm.runInNewContext(compiled, { exports, Observed: cls => cls, setTimeout, clearTimeout, console,
    require: id => { if (id === '@ohos/hypium') return {}; if (!id.startsWith('.')) throw Error('Unexpected platform dependency ' + id); return load(path.resolve(path.dirname(file), id)); }
  }, { filename: file });
  return exports;
}
const ui = load(path.join(root, 'main/ets/model/InteractiveUi'));
const { parseAppData, requestHistory } = load(path.join(root, 'main/ets/model/Conversation'));
const { parseUiScene } = load(path.join(root, 'main/ets/model/UiScene'));
const { Fixture, seed } = load(path.join(root, 'test/SessionService.test'));
const records = [
  { op: 'begin', version: 1, title: 'Bill splitter', state: { amount: 100, people: 2, result: 50, show: true } },
  { op: 'node', node: { id: 'card', kind: 'card' } },
  { op: 'node', node: { id: 'people', parent: 'card', kind: 'slider', text: 'People', bind: 'people', min: 1, max: 20, step: 1, action: 'calc' } },
  { op: 'node', node: { id: 'result', parent: 'card', kind: 'heading', text: 'Each: {{result}}', visibleKey: 'show', visibleValue: true } },
  { op: 'node', node: { id: 'send', kind: 'button', text: 'Send values', action: 'send' } },
  { op: 'action', action: { id: 'calc', kind: 'compute', code: 'input.result = input.amount / input.people; return input;' } },
  { op: 'action', action: { id: 'reset', kind: 'reset' } },
  { op: 'action', action: { id: 'hide', kind: 'set', values: { show: false } } },
  { op: 'action', action: { id: 'send', kind: 'submit', prompt: 'Explain these values' } },
  { op: 'end' }
];
const jsonl = rs => rs.map(r => JSON.stringify(r)).join('\n') + '\n';
const wire = jsonl(records);
const answer = 'A calculator:\n```tinybot-ui\n' + wire + '```\nAdjust the controls.';
const clone = x => JSON.parse(JSON.stringify(x));
const doc = new ui.UiCompiler().update(wire, true);
let checks = 0;
function test(name, fn) { fn(); checks++; console.log('PASS ' + name); }
async function asyncTest(name, fn) { await fn(); checks++; console.log('PASS ' + name); }
function broken(change) { const rs = clone(records); change(rs); return jsonl(rs); }
function fixture(source = answer) {
  const data = seed(); data.threads[0].messages = [
    { id: 'u', role: 'user', content: 'Create a calculator', status: 'complete', error: '' },
    { id: 'a', role: 'assistant', content: source, steps: [{ content: source, tools: [] }], status: 'complete', error: '' }
  ];
  const f = new Fixture(data); let executions = 0;
  f.resources.agentTools = { definitions: () => [], execute: async call => {
    executions++;
    const args = JSON.parse(call.function.arguments);
    const result = vm.runInNewContext('(function(input){' + args.code + '})(input)', { input: JSON.parse(args.input) }, { timeout: 100 });
    return JSON.stringify({ status: 'ok', result, resultTruncated: false, error: '' });
  } };
  f.executions = () => executions;
  return f;
}
(async () => {
  test('every character boundary renders only complete records', () => {
    const c = new ui.UiCompiler();
    for (let i = 0; i < wire.length; i++) { c.update(wire.slice(0, i), false); }
    assert.equal(c.update(wire, true).complete, true); assert.equal(c.document.nodes.length, 4);
  });
  test('mixed Markdown / UI remains stable through all chunk boundaries including closing fence', () => {
    let c;
    for (let i = 1; i <= answer.length; i++) {
      const parts = ui.uiParts(answer.slice(0, i), i < answer.length);
      const p = parts.find(p => p.kind === 'ui');
      if (p) { c ||= new ui.UiCompiler(); c.update(p.content, p.closed); }
    }
    assert.equal(c.document.complete, true);
    assert.equal(ui.uiParts(answer, false).length, 3);
  });
  test('UI examples inside longer or other code fences do not execute', () => {
    assert.equal(ui.uiParts('````markdown\n' + answer + '\n````', false).filter(p => p.kind === 'ui').length, 0);
    assert.equal(ui.uiParts('~~~\n' + answer + '\n~~~', false).filter(p => p.kind === 'ui').length, 0);
  });
  test('incomplete / malformed / unsupported versions fail explicitly', () => {
    for (const input of [jsonl(records.slice(0,-1)), broken(rs => rs[0].version = 2), '{invalid}\n', broken(rs => rs[1].node.kind = 'html')]) assert.throws(() => new ui.UiCompiler().update(input,true));
  });
  test('prefix rewriting, records after end, unknown fields and duplicate actions fail', () => {
    const c = new ui.UiCompiler(); c.update(wire,false); assert.throws(() => c.update('other',false));
    assert.throws(() => new ui.UiCompiler().update(wire+'{}\n',true));
    assert.throws(() => new ui.UiCompiler().update(broken(rs=>rs[1].node.onclick='evil'),true));
    assert.throws(() => new ui.UiCompiler().update(broken(rs=>rs.splice(6,0,rs[5])),true));
  });
  test('node upsert preserves position and replaces content', () => {
    const rs=clone(records); rs.splice(-1,0,{op:'node',node:{id:'result',parent:'card',kind:'heading',text:'Updated {{result}}'}});
    const c=new ui.UiCompiler().update(jsonl(rs),true); assert.equal(c.nodes.length,4); assert.equal(c.nodes[2].text,'Updated {{result}}');
  });
  test('invalid parent, self-parent, unknown bindings and implicit submit are rejected', () => {
    for(const change of [rs=>rs[1].node.parent='card',rs=>rs[2].node.parent='missing',rs=>rs[3].node.text='{{missing}}',rs=>rs[2].node.action='send']) assert.throws(()=>new ui.UiCompiler().update(broken(change),true));
  });
  test('state bounds, types and prototype keys are rejected', () => {
    assert.throws(()=>ui.validateUiValues(JSON.parse('{"__proto__":1}')));
    assert.throws(()=>ui.validateUiValues({x:Infinity}));
    assert.throws(()=>ui.validateUiState(doc,{amount:100,people:0,result:50,show:true}));
    assert.throws(()=>ui.validateUiState(doc,{amount:100,people:'2',result:50,show:true}));
    assert.throws(()=>ui.validateUiStates([{key:'0:0',values:{}},{key:'0:0',values:{}}]));
  });
  test('surface and node budgets are enforced', () => {
    assert.throws(()=>new ui.UiCompiler().update(' '.repeat(96001),false));
    const rs=[records[0],...Array.from({length:129},(_,i)=>({op:'node',node:{id:'n'+i,kind:'text',text:'x'}})),records.at(-1)];
    assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));
  });
  const nativeRecords = [
    {op:'begin',version:1,title:'Controls',state:{tab:'清单',people:4,each:30,buy:false,prepare:false,completed:0}},
    {op:'node',node:{id:'mode',kind:'segmented',text:'Mode',bind:'tab',options:['清单','对比']}},
    {op:'node',node:{id:'people',kind:'stepper',text:'People',bind:'people',min:1,max:12,action:'calculate'}},
    {op:'node',node:{id:'buy',kind:'checkbox',text:'Buy',bind:'buy',action:'calculate'}},
    {op:'node',node:{id:'prepare',kind:'checkbox',text:'Prepare',bind:'prepare',action:'calculate'}},
    {op:'node',node:{id:'progress',kind:'progress',text:'已完成 {{completed}} / 3 项',bind:'completed',min:0,max:3}},
    {op:'node',node:{id:'copy',kind:'button',text:'Copy',action:'copyResult'}},
    {op:'action',action:{id:'calculate',kind:'compute',code:'input.each = 120 / input.people; input.completed = Number(input.buy) + Number(input.prepare); return input;'}},
    {op:'action',action:{id:'copyResult',kind:'copy',text:'聚餐：{{people}} 人，每人 {{each}} 元。\n准备进度：{{completed}} / 3 项。'}},
    {op:'action',action:{id:'reset',kind:'reset'}},
    {op:'end'}
  ];
  const native = {records:nativeRecords,content:'```tinybot-ui\n'+jsonl(nativeRecords)+'\n```'};
  const nativeDoc = ui.parseUiSurface(native.content, '0');
  test('native selectors, steppers and checklists validate bound values and complete streams', () => {
    const compiler = new ui.UiCompiler(), source = jsonl(native.records);
    for (let i = 1; i < source.length; i += 17) compiler.update(source.slice(0,i),false);
    assert.equal(compiler.update(source,true).complete,true);
    for (const values of [{tab:'missing'},{people:0},{people:13},{buy:'true'}]) assert.throws(()=>ui.validateUiState(nativeDoc,{...nativeDoc.initial,...values}));
    for (const change of [rs=>rs[1].node.options=['same','same'],rs=>rs[1].node.options=Array.from({length:7},(_,i)=>String(i)),rs=>delete rs[2].node.max,rs=>rs[2].node.step=0,rs=>rs[2].node.action='copyResult']) {
      const rs=clone(native.records);change(rs);assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));
    }
  });
  test('stepper clamps bounds and progress retains its human-readable label', () => {
    const node={id:'rate',kind:'stepper',bind:'rate',min:0,max:1,step:0.1};
    assert.equal(ui.uiStepValue(node,{rate:0.2},1),0.3);
    assert.equal(ui.uiStepValue(node,{rate:0.95},1),1);
    assert.equal(ui.uiStepValue(node,{rate:0},-1),0);
    const progress=nativeDoc.nodes.find(n=>n.id==='progress');
    assert.equal(ui.uiNodeText(progress,{...nativeDoc.initial,completed:2}),'已完成 2 / 3 项');
  });
  test('copy validates template keys and requires an explicit button', () => {
    const copy=nativeDoc.actions.find(a=>a.kind==='copy');
    assert.equal(ui.uiText(copy.text,{...nativeDoc.initial,people:6,each:20,completed:2}),'聚餐：6 人，每人 20 元。\n准备进度：2 / 3 项。');
    for (const change of [rs=>rs.find(r=>r.action?.kind==='copy').action.text='{{missing}}',rs=>rs.find(r=>r.action?.kind==='copy').action.code='return input',rs=>rs[5].node.action='copyResult']) {
      const rs=clone(native.records);change(rs);assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));
    }
  });
  await asyncTest('native checklist and stepper events compute, persist and restore without a model request',async()=>{
    const f=fixture(native.content);await f.session.initialize();
    const values=await f.session.interactUi('thread-1','a','0:0',{...nativeDoc.initial,people:6,buy:true,prepare:true},'calculate');
    assert.equal(values.each,20);assert.equal(values.completed,2);assert.equal(f.provider.requests.length,0);
    const selected=await f.session.interactUi('thread-1','a','0:0',{...values,tab:'对比'});
    const reloaded=new Fixture(await f.repository.load());await reloaded.session.initialize();
    assert.deepEqual(JSON.parse(JSON.stringify(reloaded.session.snapshot().threads[0].messages[1].uiStates[0].values)),JSON.parse(JSON.stringify(selected)));
    await assert.rejects(f.session.interactUi('thread-1','a','0:0',selected,'copyResult'),/explicit client button/);
    const reset=await f.session.interactUi('thread-1','a','0:0',selected,'reset');assert.equal(reset.people,4);assert.equal(reset.completed,0);assert.equal(reset.tab,'清单');
  });
  await asyncTest('local compute saves derived state without a model request', async () => {
    const f=fixture(); await f.session.initialize(); const v=await f.session.interactUi('thread-1','a','0:0',{amount:100,people:4,result:50,show:true},'calc');
    assert.equal(v.result,25); assert.equal(f.provider.requests.length,0); assert.equal(f.executions(),1);
    const saved=await f.repository.load(); assert.equal(saved.threads[0].messages[1].uiStates[0].values.result,25);
    const reloaded=new Fixture(saved); await reloaded.session.initialize(); assert.equal(reloaded.session.snapshot().threads[0].messages[1].uiStates[0].values.people,4);
  });
  await asyncTest('set and reset are local, full state schema remains intact', async () => {
    const f=fixture(); await f.session.initialize(); let v=await f.session.interactUi('thread-1','a','0:0',doc.initial,'hide'); assert.equal(v.show,false);
    v=await f.session.interactUi('thread-1','a','0:0',v,'reset'); assert.equal(v.show,true); assert.equal(f.executions(),0);
  });
  await asyncTest('save failure leaves persisted and authoritative state unchanged and reports error', async () => {
    const f=fixture(); await f.session.initialize(); f.repository.beforeSave=async()=>{throw Error('disk failed');};
    await assert.rejects(f.session.interactUi('thread-1','a','0:0',doc.initial,'calc'),/disk failed/);
    assert.equal(f.session.snapshot().threads[0].messages[1].uiStates,undefined); assert.equal(f.resources.errors.length>0,true);
  });
  await asyncTest('failed / truncated / wrong-schema computation does not commit', async () => {
    for(const receipt of [{status:'timeout',error:'time limit'},{status:'ok',result:{result:1},resultTruncated:false},{status:'ok',result:doc.initial,resultTruncated:true}]) {
      const f=fixture(); await f.session.initialize(); f.resources.agentTools.execute=async()=>JSON.stringify(receipt);
      await assert.rejects(f.session.interactUi('thread-1','a','0:0',doc.initial,'calc'));
      assert.equal(f.session.snapshot().threads[0].messages[1].uiStates,undefined);
    }
  });
  await asyncTest('unknown action, missing surface, archived and stale-thread events fail', async () => {
    const f=fixture(); await f.session.initialize();
    await assert.rejects(f.session.interactUi('thread-1','a','0:0',doc.initial,'missing'));
    await assert.rejects(f.session.interactUi('thread-1','a','0:9',doc.initial,''));
    await f.session.newThread(); await assert.rejects(f.session.interactUi('thread-1','a','0:0',doc.initial,''));
  });
  await asyncTest('branch copies interaction state without sharing subsequent changes', async () => {
    const f=fixture(); await f.session.initialize(); await f.session.interactUi('thread-1','a','0:0',doc.initial,'hide');
    assert.equal(await f.session.forkThread('a'),true); const branch=f.session.snapshot().activeThreadId;
    await f.session.interactUi(branch,'a','0:0',{...doc.initial,show:false},'reset');
    const data=f.session.snapshot(); assert.equal(data.threads.find(t=>t.id==='thread-1').messages[1].uiStates[0].values.show,false);
    assert.equal(data.threads.find(t=>t.id===branch).messages[1].uiStates[0].values.show,true);
  });
  await asyncTest('submit produces a user event and preserves an unrelated composer draft', async () => {
    const f=fixture(); await f.session.initialize(); f.session.setDraft('unsent unrelated draft');
    await f.session.interactUi('thread-1','a','0:0',doc.initial,'send');
    const thread=f.session.snapshot().threads[0]; assert.equal(thread.draft,'unsent unrelated draft');
    assert.equal(thread.messages.length,4); assert.equal(thread.messages[2].role,'user');
    assert.match(thread.messages[2].content,/Explain these values/); assert.equal(f.provider.requests.length,1);
  });
  await asyncTest('a second click cannot run while the first action owns the save lane', async () => {
    const f=fixture(); await f.session.initialize(); let release;
    f.repository.beforeSave=()=>new Promise(r=>{release=r;});
    const first=f.session.interactUi('thread-1','a','0:0',doc.initial,'hide');
    await assert.rejects(f.session.interactUi('thread-1','a','0:0',doc.initial,'hide'));
    while(!release) await Promise.resolve(); release(); await first;
  });
  test('scene validation rejects bad geometry and supports declarative diagrams',()=>{
    const scene={width:400,height:240,shapes:[{id:'ball',kind:'circle',x:100,y:100,radius:30,text:'Ball',action:'hide'}]};
    assert.equal(parseUiScene(JSON.stringify(scene)).shapes.length,1);
    assert.throws(()=>parseUiScene(JSON.stringify({...scene,width:0})));
    assert.throws(()=>parseUiScene(JSON.stringify({...scene,shapes:[{...scene.shapes[0],radius:300}]})));
    const rs=clone(records);rs.splice(-1,0,{op:'node',node:{id:'diagram',kind:'scene',data:JSON.stringify(scene)}});
    assert.equal(new ui.UiCompiler().update(jsonl(rs),true).nodes.length,5);
    rs[rs.length-2].node.data=JSON.stringify({...scene,shapes:[{...scene.shapes[0],action:'unknown'}]});
    assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));
  });
  await asyncTest('later conversation context includes the committed user inputs',async()=>{
    const f=fixture();await f.session.initialize();await f.session.interactUi('thread-1','a','0:0',{...doc.initial,people:4},'calc');
    const history=requestHistory(f.session.snapshot().threads[0].messages,'test');
    assert.match(history.at(-1).content,/"result":25/);
  });
  await asyncTest('invalid generated UI fails the Agent turn before any tool is executed',async()=>{
    const f=fixture();await f.session.initialize();
    f.provider.respond=async()=>({content:'```tinybot-ui\n'+jsonl(records.slice(0,-1))+'```',toolCalls:[]});
    f.session.setDraft('new surface');await f.session.send();
    const message=f.session.snapshot().threads[0].messages.at(-1);
    assert.equal(message.status,'failed');assert.match(message.error,/incomplete surface/);assert.equal(f.executions(),0);
  });
  test('deterministic device fixture computes chart and diagram without a model',()=>{
    const fixture=require('./interactive-ui-fixture.cjs');ui.validateUiAnswer(fixture.content);
    const document=ui.parseUiSurface(fixture.content,'0');const action=document.actions.find(a=>a.id==='calculate');
    const input=clone(document.initial);input.people=4;
    const result=vm.runInNewContext('(function(input){'+action.code+'})(input)',{input},{timeout:100});
    ui.validateUiState(document,result);assert.equal(result.each,30);assert.equal(JSON.parse(result.scene).shapes.length,4);
  });
  test('the session prompt includes the UI instructions',()=>{
    const {sessionInstructions}=load(path.join(root,'main/ets/services/SessionContext'));
    const {INTERACTIVE_UI_INSTRUCTIONS}=load(path.join(root,'main/ets/model/InteractiveUiInstructions'));
    const data=seed();const instructions=sessionInstructions(data.config,data.extensions);
    assert.ok(instructions.includes(INTERACTIVE_UI_INSTRUCTIONS));
  });
  test('Web content validates before rendering and cannot bind code to mutable state',()=>{
    const spec={version:1,html:'<canvas></canvas>',css:'',js:'document.body.dataset.ready="yes"',library:'three',height:400};
    const rs=clone(records);rs.splice(-1,0,{op:'node',node:{id:'web',kind:'web',data:JSON.stringify(spec)}});
    assert.equal(new ui.UiCompiler().update(jsonl(rs),true).nodes.at(-1).kind,'web');
    rs.at(-2).node.bind='amount';assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));delete rs.at(-2).node.bind;
    rs.at(-2).node.data=JSON.stringify({...spec,library:'remote'});assert.throws(()=>new ui.UiCompiler().update(jsonl(rs),true));
  });
  await asyncTest('Web state saves use the existing durable isolated lane without model calls',async()=>{
    const example=JSON.parse(fs.readFileSync(path.join(root,'main/resources/rawfile/interactive-web/example.json'),'utf8')).content;
    const f=fixture(example);
    await f.session.initialize(); const initial=ui.parseUiSurface(example,'0').initial;
    const saved=await f.session.interactUi('thread-1','a','0:0',{...initial,speed:1.2});
    assert.equal(saved.speed,1.2);assert.equal(f.provider.requests.length,0);assert.equal(f.executions(),0);
    assert.equal(f.session.snapshot().threads[0].messages[1].uiStates[0].values.speed,1.2);
    await assert.rejects(f.session.interactUi('thread-1','a','0:0',{...initial,speed:'wrong type'}));
  });
  test('corrupt persisted UI state is rejected on load',()=>{
    const data=seed(); data.threads[0].messages=[{id:'u',role:'user',content:'x',status:'complete',error:'',uiStates:[{key:'bad',values:{}}]}];
    assert.throws(()=>parseAppData(JSON.stringify(data)));
  });
  console.log('Interactive UI: '+checks+' checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
