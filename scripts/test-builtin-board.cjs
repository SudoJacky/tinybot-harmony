const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),ets=path.join(root,'entry/src/main/ets');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const modules=new Map(),cards=new Map(),boards=[];let publishes=[],creates=0,failId='',accounts=[];
const copy=value=>JSON.parse(JSON.stringify(value));
function load(name){name=path.posix.normalize(name);if(modules.has(name))return modules.get(name);const exports={};modules.set(name,exports);
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(ets,name+'.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
 {exports,Date,TextDecoder,require:id=>id.startsWith('@kit.')?id==='@kit.ArkTS'?{util:{TextDecoder:{create:()=>({decodeToString:bytes=>new TextDecoder().decode(bytes)})}}}:{}:load(path.posix.join(path.posix.dirname(name),id))});return exports;}
modules.set('model/WorkspaceStore',{WorkspaceStore:class{async ensureThread(id){assert.equal(id,'tinybot-builtins');}}});
modules.set('services/ProviderBalanceSource',{ProviderBalanceSource:{accounts:()=>copy(accounts)}});
modules.set('services/LifePanels',{LifePanels:class{
 async list(){return [...cards.values()].map(copy);}
 repository(workspaceId){return {lookup:async id=>cards.get(workspaceId+'/'+id)?.panel,publish:async(id,definition,sourcePath,thread,update,signal,options)=>{
   signal.check();if(id===failId)throw Error('interrupted publication');const key=workspaceId+'/'+id,before=cards.get(key)?.panel;
   if(update)assert.equal(options.expectedRevision,before.configRevision);else assert.equal(before,undefined,'Never recreate an existing guide');
   const panel={...before,id,definition:copy(definition),sourcePath,sourceThreadId:thread,configRevision:(before?.configRevision||0)+1,data:before?.data||definition.data,viewState:before?.viewState};
   publishes.push(key);cards.set(key,{workspaceId,panel});return copy(panel);
 }};}
}});
modules.set('services/LifeBoards',{LifeBoards:class{async list(){return copy(boards);}async create(workspaceId,id,title,description,items,builtinRevision){creates++;boards.push({workspaceId,board:{id,title,description,items,builtinRevision,archived:false}});}
 async prependBuiltin(workspaceId,id,reference,height,revision){const board=boards.find(entry=>entry.workspaceId===workspaceId&&entry.board.id===id).board;
  if((board.builtinRevision||0)>=revision)return;board.items.unshift({...reference,x:0,y:-height,w:12,h:height});board.items.forEach(item=>item.y+=height);board.builtinRevision=revision;}
}});
const context={resourceManager:{getRawFileContent:async name=>new Uint8Array(fs.readFileSync(path.join(root,'entry/src/main/resources/rawfile',name)))},getApplicationContext:()=>({filesDir:'/files'})};
const {BuiltinBoard}=load('services/BuiltinBoard'),{BuiltinWidgets}=load('services/BuiltinWidgets'),{Cancellation}=load('services/Cancellation');
(async()=>{
 const saved={definition:{version:2,title:'Existing wallet',size:'M',nodes:[],data:{},view:{version:1,html:'old wallet',js:'',css:'',height:252,library:'none'},checks:[{action:'click',selector:'#privacy'}]},configRevision:2,data:{checkedAt:1},sourcePath:'builtin-widgets/balance.html',sourceThreadId:'',viewState:{value:{balanceHidden:true},revision:'saved'}};
 cards.set('user/wallet',{workspaceId:'user',panel:{...copy(saved),id:'wallet'}});
 cards.set('user/custom',{workspaceId:'user',panel:{...copy(saved),id:'custom',sourceThreadId:'editor',sourcePath:'custom.panel.json'}});
 cards.set('user/archived',{workspaceId:'user',panel:{...copy(saved),id:'archived',archived:true}});
 const service=new BuiltinBoard(context),signal=new Cancellation();
 const results=await Promise.all([service.prepare(signal),service.prepare(signal)]);
 assert.equal(creates,2);assert.equal(cards.size,11);assert.deepEqual(copy(results[0]),{workspaceId:'tinybot-builtins',boardId:'board-daily'});
 const daily=boards.find(entry=>entry.board.id==='board-daily');
 assert.equal(daily.board.title,'我的日常');
 assert.deepEqual(Array.from(daily.board.items,item=>item.panelId),['panel-default-ascii','panel-default-clock','panel-default-todo','panel-default-focus','panel-default-countdown']);
 assert.equal(daily.board.builtinRevision,1);assert.equal(daily.board.items[0].h,5);assert.equal(daily.board.items[0].w,12);
 assert.equal(daily.board.items[1].w,12,'An unconfigured balance never leaves a half-empty clock row');
 const {gridOverlap,validateGridRect}=load('model/PanelGrid');
 for(const item of daily.board.items)validateGridRect(item);
 for(let i=0;i<daily.board.items.length;i++)for(let j=i+1;j<daily.board.items.length;j++)assert.equal(gridOverlap(daily.board.items[i],daily.board.items[j]),false);
 const clock=cards.get('tinybot-builtins/panel-default-clock').panel;
 clock.viewState={value:{hour12:true},revision:'my-format'};
 daily.board.items=daily.board.items.filter(item=>!['panel-default-countdown','panel-default-ascii'].includes(item.panelId));daily.board.items[0].y=60;
 const savedDaily=copy(daily),savedClock=copy(clock);
 assert.equal(publishes.filter(key=>key==='user/wallet').length,1);assert.ok(!publishes.includes('user/custom'));assert.ok(!publishes.includes('user/archived'));
 assert.doesNotMatch(cards.get('user/wallet').panel.definition.view.html,/id="privacy"/);
 assert.deepEqual(cards.get('user/wallet').panel.data,saved.data);assert.deepEqual(cards.get('user/wallet').panel.viewState,saved.viewState);
 assert.equal(cards.get('user/wallet').panel.definition.title,'Existing wallet');
 const before=copy(boards[0]);boards[0].board.items[0].y=50;const changed=copy(boards[0]);
 const guideEntry=cards.get('tinybot-builtins/panel-guide-resize'),guide=guideEntry.panel;
 guide.definition.view.html=guide.definition.view.html.replace('height:var(--tinybot-card-height,auto)','height:100vh');
 guide.definition.view.height=503;guide.data={saved:42};guide.viewState={value:{custom:true},revision:'kept'};
 const customized=copy(guideEntry);customized.panel.id='custom-guide';customized.panel.sourceThreadId='editor';
 cards.set('user/custom-guide',customized);
 const previous=copy(guide),published=publishes.length;
 await service.prepare(signal);assert.deepEqual(copy(boards[0]),changed,'Reopening must preserve user layout');assert.equal(creates,2);
 assert.deepEqual(copy(daily),savedDaily,'Default boards retain moved/resized/removed cards');
 assert.deepEqual(copy(cards.get('tinybot-builtins/panel-default-clock').panel),savedClock,'Default cards retain user state');
 const migrated=cards.get('tinybot-builtins/panel-guide-resize').panel;
 assert.match(migrated.definition.view.html,/height:var\(--tinybot-card-height,auto\)/);
 assert.equal(migrated.definition.view.height,503,'Guide updates preserve the saved baseline');
 assert.deepEqual(migrated.data,previous.data);assert.deepEqual(migrated.viewState,previous.viewState);
 assert.equal(publishes.length,published+1,'Only outdated packaged guides are updated');
 assert.deepEqual(cards.get('user/custom-guide'),customized,'Edited guides retain their own content');
 await service.prepare(signal);assert.equal(publishes.length,published+1,'Packaged updates are idempotent');
 boards[0].board.archived=true;assert.equal((await service.prepare(signal)).boardId,'board-daily','Archiving the guide does not hide usable defaults');
 assert.equal(boards[0].board.archived,true,'Guide archives are preserved');
 daily.board.archived=true;assert.equal(await service.prepare(signal),undefined);assert.equal(creates,2,'Archived daily boards stay archived');
 const widgets=new BuiltinWidgets(context);
 for(const id of ['guide-welcome','guide-move','guide-resize']){const spec=await widgets.definition(id);assert.equal(spec.version,2);assert.equal(spec.source,undefined);assert.match(spec.view.html,/IntersectionObserver/);assert.match(spec.view.html,/prefers-reduced-motion/);assert.deepEqual(copy(spec.checks),[]);}
 boards.length=0;cards.clear();publishes=[];failId='panel-guide-move';
 await assert.rejects(service.prepare(signal),/interrupted publication/);assert.equal(cards.size,1);failId='';
 await service.prepare(signal);assert.equal(cards.size,8);assert.equal(publishes.filter(key=>key.endsWith('/panel-guide-welcome')).length,1,'Interrupted installs reuse completed cards');
 boards.length=0;cards.clear();publishes=[];creates=0;failId='panel-default-todo';
 await assert.rejects(service.prepare(signal),/interrupted publication/);assert.equal(boards.length,1,'Do not expose a half-installed daily board');
 failId='';await service.prepare(signal);assert.equal(cards.size,8);assert.equal(creates,2);
 assert.equal(publishes.filter(key=>key.endsWith('/panel-default-clock')).length,1,'Interrupted daily installs reuse completed cards');
 boards.length=0;cards.clear();publishes=[];creates=0;accounts=[{id:'configured',name:'Configured service'}];
 await service.prepare(signal);assert.equal(cards.size,9);assert.equal(creates,2);
 const connected=boards.find(entry=>entry.board.id==='board-daily').board;
 assert.equal(connected.items.length,6,'Configured providers receive the balance card without a manual add');
 const clockRect=connected.items.find(item=>item.panelId==='panel-default-clock'),balanceRect=connected.items.find(item=>item.panelId==='panel-default-balance');
 assert.equal(clockRect.w,6);assert.equal(balanceRect.x,6);assert.equal(balanceRect.y,5);assert.equal(balanceRect.h,clockRect.h);
 assert.deepEqual(copy(cards.get('tinybot-builtins/panel-default-balance').panel.definition.source.providerIds),['configured']);
 assert.deepEqual(copy(cards.get('tinybot-builtins/panel-default-balance').panel.data.amounts),[],'No account requests or fabricated balances during installation');
 const installed=publishes.length;await service.prepare(signal);assert.equal(publishes.length,installed,'Reopening never duplicates defaults');
 connected.items=connected.items.filter(item=>item.panelId!=='panel-default-ascii').map(item=>({...item,y:item.y-5}));delete connected.builtinRevision;
 const previousItems=copy(connected.items);await service.prepare(signal);
 assert.equal(connected.builtinRevision,1);assert.equal(connected.items[0].panelId,'panel-default-ascii');
 assert.deepEqual(copy(connected.items.slice(1)),previousItems.map(item=>({...item,y:item.y+5})),'Upgrade shifts the existing layout instead of replacing it');
 connected.items.shift();const userRemoved=copy(connected.items);await service.prepare(signal);assert.deepEqual(copy(connected.items),userRemoved,'A later user removal is retained');
 const cancel=new Cancellation();cancel.cancel();await assert.rejects(service.prepare(cancel));
 console.log('PASS ready-to-use daily board, configured balance, guide preservation, stable concurrent/retried installs, user layout/removal/state preservation, archives and scoped migrations');
})().catch(error=>{console.error(error);process.exitCode=1;});
