// Exercise packaged definitions and the actual install boundary without network/accounts.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),ets=path.join(root,'entry/src/main/ets');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const modules=new Map(),published=[],probes=[];let accounts=[],probeError=false,sequence=0;
const copy=value=>JSON.parse(JSON.stringify(value));
const stub=(name,value)=>modules.set(name,value);
function load(name){name=path.posix.normalize(name);if(modules.has(name))return modules.get(name);const exports={};modules.set(name,exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(ets,name+'.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
    {exports,Date,TextDecoder,require:id=>id.startsWith('@kit.')?id==='@kit.ArkTS'?{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}}:{}:load(path.posix.join(path.posix.dirname(name),id))});return exports;}
stub('model/WorkspaceStore',{WorkspaceStore:class{async requireWorkspace(id){assert.equal(id,'workspace');}}});
stub('services/ProviderBalanceSource',{ProviderBalanceSource:{accounts:()=>copy(accounts)}});
stub('services/LifePanels',{LifePanels:class{createId(){return 'widget-'+ ++sequence;}repository(){return {publish:async(id,definition,sourcePath,thread,update,signal)=>{
  signal.check();assert.equal(update,false);const record={id,definition,sourcePath,data:definition.data,viewState:undefined};published.push(record);return record;}};}}});
stub('services/WebUiPreflight',{WebUiPreflight:{validatePanel:async(content,storage,context,signal,options)=>{
  signal.check();probes.push({content,context,options});assert.equal((await storage.load()).value,null);await storage.save({probe:true},'initial');if(probeError)throw Error('probe failed');
}}});
const {BuiltinWidgets}=load('services/BuiltinWidgets'),{builtinWidgets}=load('model/BuiltinWidgets');
const {Cancellation}=load('services/Cancellation');
const context={resourceManager:{getRawFileContent:async name=>new Uint8Array(fs.readFileSync(path.join(root,'entry/src/main/resources/rawfile',name)))},getApplicationContext:()=>({filesDir:'/files'})};
(async()=>{
 const service=new BuiltinWidgets(context);assert.equal(builtinWidgets().length,6);
 await assert.rejects(service.definition('unknown'),/Unknown/);
 await assert.rejects(service.definition('balance'),/余额查询/);
 for(const id of ['ascii','clock','focus','todo','countdown']){
  const spec=await service.definition(id);assert.equal(spec.version,2);assert.equal(spec.source,undefined);assert.equal(spec.view.library,'none');
  assert.ok(spec.checks.length);assert.doesNotMatch(spec.view.html,/BUILTIN_(?:STYLE|RUNTIME)/);assert.doesNotMatch(spec.view.html,/<script[^>]+src=/);
  const entry=await service.add(id,'workspace',new Cancellation());assert.equal(entry.workspaceId,'workspace');assert.equal(entry.panel.viewState,undefined,'probe state must never seed a real card');
 }
 const first=await service.add('todo','workspace',new Cancellation()),second=await service.add('todo','workspace',new Cancellation());assert.notEqual(first.panel.id,second.panel.id);
 const count=published.length;probeError=true;await assert.rejects(service.add('todo','workspace',new Cancellation()),/probe failed/);assert.equal(published.length,count);probeError=false;
 const signal=new Cancellation();signal.cancel();await assert.rejects(service.add('clock','workspace',signal));assert.equal(published.length,count);
 accounts=[{id:'provider-a',name:'Service A',presetId:'deepseek'},{id:'provider-b',name:'Service B'}];
 const balance=await service.definition('balance');assert.deepEqual(copy(balance.source),{type:'provider-balance',providerIds:['provider-a','provider-b']});
 assert.deepEqual(copy(balance.data.amounts),[],'Never fabricate a balance');assert.equal(balance.data.checkedAt,0);assert.equal(balance.inputs.providerId.default,'provider-a');
 assert.match(balance.view.html,/tinybot\.panel\.refresh/);assert.ok(!JSON.stringify(balance).includes('credentialAlias'));
 assert.doesNotMatch(balance.view.html,/id="privacy"|privateMode|balanceHidden|tinybot\.storage/);
 await service.add('balance','workspace',new Cancellation());
 assert.equal(probes.at(-1).context.canRefresh,true);assert.equal(probes[0].context.canRefresh,false);
 const ascii=await service.definition('ascii');assert.equal(ascii.view.height,208);assert.equal(builtinWidgets().find(widget=>widget.id==='ascii').width,12);
 assert.match(ascii.view.html,/tinybot\.animate/);assert.match(ascii.view.html,/prefers-reduced-motion/);
 console.log('PASS six built-ins: 12x5 ASCII animation, offline definitions, real balance allowlist, detached probes, failed/cancelled installs, independent instances and no fabricated balances');
})().catch(error=>{console.error(error);process.exitCode=1;});
