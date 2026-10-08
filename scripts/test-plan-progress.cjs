// Plan projection and emitted ArkUI callback regressions; native painting is tested separately.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root=path.resolve(__dirname,'../entry/src/main/ets'),cache=new Map();
function load(file){file=path.resolve(file.endsWith('.ets')?file:file+'.ets');if(cache.has(file))return cache.get(file);const exports={};cache.set(file,exports);
  const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
  vm.runInNewContext(code,{exports,Observed:cls=>cls,require:id=>load(path.resolve(path.dirname(file),id))},{filename:file});return exports;}
const {MessageViewModel,ThreadViewModel}=load(path.join(root,'viewmodel/SessionViewModels'));
const {persistentTool}=load(path.join(root,'model/ProcessPresentation'));
const plan=(a='in_progress',b='pending')=>({explanation:'Inspect then verify',steps:[{step:'Inspect',status:a},{step:'Verify',status:b}]});
const tool=(id,value,status='complete')=>({call:{id,type:'function',function:{name:'update_plan',arguments:'{}'}},status,output:JSON.stringify(value)});
const message=(id='reply',tools=[tool('first',plan())],status='generating')=>({id,role:'assistant',content:'',error:'',status,steps:[{content:'',tools}]});
let failures=0;function test(name,fn){try{fn();console.log('PASS '+name);}catch(error){failures++;console.error('FAIL '+name+'\n'+error.stack);}}
test('latest completed update reaches one retained plan without resetting disclosure',()=>{
  const data=message(),view=new MessageViewModel(data),progress=view.plan;assert.equal(progress.currentStep,'Inspect');assert.equal(progress.expanded,false);progress.expanded=true;
  data.steps[0].tools.push(tool('next',plan('completed','in_progress')));view.update(data);
  assert.equal(view.plan,progress);assert.equal(progress.currentStep,'Verify');assert.equal(progress.completed,1);assert.equal(progress.expanded,true);
  const steps=progress.steps;data.content+='streamed answer';view.update(data);assert.equal(progress.steps,steps);
  data.steps[0].tools.push(tool('failed',{},'failed'),tool('pending',{},'running'));view.update(data);assert.equal(progress.steps,steps);
  data.steps[0].tools.push(tool('finish',plan('completed','completed')));view.update(data);assert.equal(progress.finished,true);assert.equal(progress.running,false);
});
test('stopping never marks unfinished steps complete or leaves a running indicator',()=>{
  const data=message(),view=new MessageViewModel(data);data.status='stopped';view.update(data);
  assert.equal(view.plan.running,false);assert.equal(view.plan.finished,false);assert.equal(view.plan.currentStep,'Inspect');assert.equal(view.plan.completed,0);
});
test('new turns and threads do not inherit another plan or its disclosure state',()=>{
  const data={id:'thread',title:'test',updatedAt:1,messages:[message()]},thread=new ThreadViewModel(data);thread.messages[0].plan.expanded=true;
  const first=thread.messages[0].plan;data.messages.push(message('new-reply',[]));thread.update(data);
  assert.equal(thread.messages[0].plan,first);assert.equal(thread.messages[1].plan.available,false);assert.equal(thread.messages[1].plan.expanded,false);
  const other=new ThreadViewModel({...data,id:'other'});assert.notEqual(other.messages[0].plan,first);assert.equal(other.messages[0].plan.expanded,false);
});
test('saved history reconstructs plan progress without persisting presentation state',()=>{
  const data=message('history',[tool('saved',plan('completed','in_progress'))],'complete');const before=JSON.stringify(data),view=new MessageViewModel(data);view.plan.expanded=true;
  const reloaded=new MessageViewModel(JSON.parse(before));assert.equal(reloaded.plan.currentStep,'Verify');assert.equal(reloaded.plan.expanded,false);assert.equal(reloaded.plan.running,false);assert.equal(JSON.stringify(data),before);
});
test('malformed latest plan is visible as an error rather than replaced by stale progress',()=>{
  const data=message(),view=new MessageViewModel(data);data.steps[0].tools.push(tool('broken',{}));view.update(data);
  assert.equal(view.plan.available,true);assert.match(view.plan.error,/计划读取失败/);assert.equal(view.plan.steps.length,0);assert.equal(view.plan.running,false);
  data.steps[0].tools.push(tool('fixed',plan()));view.update(data);assert.equal(view.plan.error,'');assert.equal(view.plan.currentStep,'Inspect');
});
test('plans leave the transcript while charts and forms remain',()=>{
  assert.equal(persistentTool(tool('plan',plan())),false);
  const chart=tool('chart',{});chart.call.function.name='publish_data_view';assert.equal(persistentTool(chart),true);
  const form=tool('form',{},'interrupted');form.call.function.name='request_user_input';assert.equal(persistentTool(form),true);
});
if(failures)process.exitCode=1;
// Build first: exercise the actual emitted bindings, branch removal and keyed row reuse.
if (!process.argv.includes('--model-only')) {
  const emitted=path.resolve(__dirname,'../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPlanPanel.ts');
  const source=path.join(root,'views/ChatPlanPanel.ets');
  if(!fs.existsSync(emitted)||fs.statSync(source).mtimeMs>fs.statSync(emitted).mtimeMs)throw Error('Run devecocli build before the panel regression (or use --model-only).');
  let serial=0,currentView;
  class Property{constructor(value){this.value=value;}get(){return this.value;}set(value){this.value=value;}}
  class ViewPU{
    constructor(){this.effects=new Map();this.nodes=new Map();this.branches=new Map();this.lists=new Map();this.scopes=[];}
    finalizeConstruction(){}
    getUIContext(){return{animateTo:(_options,change)=>change()};}
    observeComponentCreation2(callback){const id=++serial;for(const scope of this.scopes)scope.add(id);this.effects.set(id,{callback,owners:[...this.scopes]});this.run(id,true);}
    run(id,initial){const saved=this.scopes,previous=this.current;this.scopes=[...this.effects.get(id).owners];this.current=id;currentView=this;this.effects.get(id).callback(id,initial);this.scopes=saved;this.current=previous;}
    collect(create){const ids=new Set();this.scopes.push(ids);create();this.scopes.pop();return ids;}
    remove(ids){for(const id of ids){this.effects.delete(id);this.nodes.delete(id);this.branches.delete(id);this.lists.delete(id);}}
    ifElseBranchUpdateFunction(branch,create){const id=this.current,old=this.branches.get(id);if(old?.branch===branch)return;if(old)this.remove(old.ids);const ids=this.collect(create);this.branches.set(id,{branch,ids});}
    forEachUpdateFunction(id,items,create,key){const old=this.lists.get(id)||new Map(),next=new Map();const keys=items.map((item,index)=>key(item,index));for(const [identity,ids]of old)if(!keys.includes(identity))this.remove(ids);items.forEach((item,index)=>{const identity=keys[index];next.set(identity,old.get(identity)||this.collect(()=>create(item,index)));});this.lists.set(id,next);}
    flush(){for(const id of [...this.effects.keys()])if(this.effects.has(id))this.run(id,false);}
    find(id){return [...this.nodes.values()].find(node=>node.id===id);}
  }
  const globals={exports:{},ViewPU,SynchedPropertyNesedObjectPU:Property,
    makeBuilderParameterProxy:(_name,getters)=>new Proxy({},{get:(_,key)=>getters[key]()}),
    require:id=>{if(id.includes('I18n&'))return {t:text=>text};if(id.includes('Theme&'))return {Font:{},Motion:{},Radius:{},Space:{}};throw Error('Unexpected dependency '+id);}};
  for(const type of ['If','Column','Row','Button','SymbolGlyph','Text','LoadingProgress','Scroll','ForEach'])globals[type]=new Proxy({},{get:(_,property)=>(...args)=>{
    if(property==='pop')return;const id=currentView.current;let node=currentView.nodes.get(id);if(!node){node={type,elementId:id};currentView.nodes.set(id,node);}node[property==='create'?'value':property]=args[0];
  }});
  for(const name of ['ButtonType','Color','HorizontalAlign','VerticalAlign','FontWeight','TextOverflow','TextDecorationType','CopyOptions','BarState','Alignment'])globals[name]={};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,globals,{filename:emitted});
  const {ChatPlanPanel}=globals.exports;
  const mounted=(data=message())=>{const model=new MessageViewModel(data),panel=new ChatPlanPanel(null,{plan:model.plan});panel.initialRender();return {model,panel,data};};
  const change=(f,value,status='generating')=>{f.data=message('reply',[tool('update-'+serial,value)],status);f.model.update(f.data);f.panel.flush();};
  test('fixed panel toggles and receives progress without remounting its header spinner',()=>{
    const f=mounted();assert.equal(f.panel.find('chat-plan-steps'),undefined);assert.equal(f.panel.find('chat-plan-current-step').value,'Inspect');
    f.panel.find('chat-plan-toggle').onClick();f.panel.flush();assert.ok(f.panel.find('chat-plan-steps'));
    const spinner=[...f.panel.nodes.values()].find(node=>node.type==='LoadingProgress').elementId;
    change(f,plan('completed','in_progress'));assert.equal(f.model.plan.expanded,true);assert.equal(f.panel.find('chat-plan-current-step').value,'Verify');assert.equal(f.panel.find('chat-plan-count').value,'1 / 2');
    assert.ok(f.panel.nodes.has(spinner));assert.equal(f.panel.find('chat-plan-steps').constraintSize.maxHeight,200);
    change(f,plan('completed','completed'),'complete');assert.equal([...f.panel.nodes.values()].filter(node=>node.type==='LoadingProgress').length,0);assert.ok([...f.panel.nodes.values()].some(node=>node.value==='计划已完成'));
    f.panel.find('chat-plan-toggle').onClick();f.panel.flush();assert.equal(f.panel.find('chat-plan-steps'),undefined);
  });
  test('plan row edits, additions and removals update retained keyed rows',()=>{
    const f=mounted();f.model.plan.expanded=true;f.panel.flush();
    change(f,{steps:[{step:'Changed task',status:'in_progress'},...Array.from({length:19},(_,i)=>({step:'Later '+i,status:'pending'}))]});
    assert.equal(f.panel.find('chat-plan-current-step').value,'Changed task');assert.equal(f.panel.find('chat-plan-count').value,'0 / 20');
    assert.ok([...f.panel.nodes.values()].some(node=>node.value==='Later 18'));
    change(f,{steps:[{step:'Only task',status:'completed'}]},'complete');assert.equal(f.panel.find('chat-plan-count').value,'1 / 1');assert.equal([...f.panel.nodes.values()].some(node=>node.value==='Later 18'),false);
  });
  test('stopped plan has no spinner; a new empty turn has no panel',()=>{
    const f=mounted();change(f,plan(),'stopped');assert.equal([...f.panel.nodes.values()].filter(node=>node.type==='LoadingProgress').length,0);assert.ok([...f.panel.nodes.values()].some(node=>node.value==='计划未完成'));
    const empty=mounted(message('new',[]));assert.equal(empty.panel.find('chat-plan-panel'),undefined);
  });
}
if(failures)process.exitCode=1;
