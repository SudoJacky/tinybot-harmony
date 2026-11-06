// Run after devecocli build. Exercise emitted native lifecycle and interaction code without a device.
const fs=require('node:fs'), path=require('node:path'), vm=require('node:vm'), assert=require('node:assert/strict');
const studio=process.env.DEVECO_STUDIO_HOME||path.join(process.env.ProgramFiles,'Huawei/DevEco Studio');
const ts=require(path.join(studio,'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root=path.resolve(__dirname,'..');
function emitted(relative) {
  const input=path.join(root,'entry/src/main/ets',relative+'.ets');
  const built=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets',relative+'.ts');
  assert.ok(fs.statSync(built).mtimeMs>=fs.statSync(input).mtimeMs,'Build before testing '+relative);
  return ts.createSourceFile(built,fs.readFileSync(built,'utf8'),ts.ScriptTarget.Latest,true);
}
function compile(source, globals={}) {
  const exports={};vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,
    {exports,console,Date,Math,Object,Map,Set,Error,...globals});return exports;
}
const modelCache=new Map();
function loadModel(name) {
  if(name==='I18n')return {t:(text,values=[])=>text.replace(/\{(\d+)\}/g,(_,i)=>String(values[i]))};
  if(!modelCache.has(name))modelCache.set(name,compile(fs.readFileSync(path.join(root,'entry/src/main/ets/model',name+'.ets'),'utf8'),{require:id=>loadModel(path.basename(id))}));
  return modelCache.get(name);
}
const model=loadModel('LifePanel');
const signal=compile(fs.readFileSync(path.join(root,'entry/src/main/ets/services/Cancellation.ets'),'utf8'),
  {require:()=>({ToolFailure:class extends Error {}})});
const tree=emitted('views/LifePanelsPanel'), panel=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='LifePanelsPanel');
const names=['stop','activityChanged','scan','reload','report','entryKey','refresh','change','refreshAll','visible','layouts','rect','columns','boardHeight','currentBoard','currentEditorThreadId','boardKey','sizeOnBoard','targetChanged','dropCard','layoutEntries','startMove','moveCard','resetGesture','resizeCard','heightOnBoard','entryFor','createCard','showEditor'];
const methods=panel.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name.getText(tree))).map(n=>n.getText(tree)).join('\n');
assert.equal(panel.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name.getText(tree))).length,names.length);
const timers=new Map(), logs=[];let timerId=0;
const {Probe}=compile('export class Probe {'+methods+'}',{...loadModel('I18n'),...model,...signal,...loadModel('LifeBoard'),...loadModel('PanelPresentation'),
  setTimeout:(fn,ms)=>{timers.set(++timerId,{fn,ms});return timerId;},clearTimeout:id=>timers.delete(id),
  Motion:{medium:180,thumb:'spring'},Diagnostics:{log:(...args)=>logs.push(args)}});
const turn=()=>new Promise(resolve=>setImmediate(resolve));
function entry(id,refreshMinutes=1) {return {workspaceId:'chat',panel:{id,configRevision:1,archived:false,createdAt:1,
  definition:{size:'S',source:{type:'workspace-json',path:'data.json'},refreshMinutes},refreshedAt:0,attemptedAt:0}};}
function view(entries=[],repository={}) {
  const page=new Probe();Object.assign(page,{mounted:true,active:true,foreground:true,timer:-1,cancellation:new signal.Cancellation(),scanning:false,
    getUIContext:()=>({getFocusController:()=>({clearFocus(){}}),animateTo:(_options,action)=>action()}),layoutSaving:false,dragging:'',resizing:'',dragBefore:'',resizeSize:'',cardHeights:{},entries:[],pending:[],error:'',selected:'',removed:false,boardWidth:360,boards:[],boardSelection:'',requestedTarget:'',lastTarget:''});
  page.boardStore=()=>({list:async()=>[]});
  page.panels=()=>({list:async()=>entries,repository:()=>repository});return page;
}
async function main() {
  let count=0;const card=entry('due');const page=view([card],{refresh:async(id,cancel)=>{cancel.check();count++;card.panel.refreshedAt=Date.now();}});
  page.activityChanged();await turn();await turn();assert.equal(count,0);assert.equal(page.pending.length,0);
  assert.equal(timers.get(page.timer).ms,30000,'One expiry scan timer follows completion');
  const next=timers.get(page.timer);timers.delete(page.timer);next.fn();await turn();await turn();assert.equal(count,0,'Collection reload never duplicates app-owned automatic tasks');
  page.active=false;page.activityChanged();assert.equal(timers.size,0);assert.equal(page.cancellation.cancelled,true);
  page.foreground=false;page.active=true;page.activityChanged();assert.equal(timers.size,0,'Hidden/background page schedules no work');
  page.foreground=true;card.panel.refreshedAt=0;page.activityChanged();await turn();await turn();assert.equal(count,0,'Foreground collection entry only reloads shared data');
  page.stop();timers.clear();
  // Hide while the source is waiting, then show again before that request finishes.
  let release, sawSignal, requests=0;
  const slowCard=entry('slow'), slow=view([slowCard],{refresh:async(id,cancel)=>{requests++;sawSignal=cancel;await new Promise(r=>release=r);cancel.check();}});
  const slowRun=slow.refresh(slowCard);await turn();await turn();assert.equal(requests,1);slow.foreground=false;slow.activityChanged();
  assert.equal(sawSignal.cancelled,true);slow.foreground=true;slow.activityChanged();await turn();await turn();assert.equal(timers.size,1);
  release();await slowRun;await turn();await turn();assert.equal(slow.error,'','Expected cancellation is not displayed as a source failure');
  assert.equal(slow.pending.length,0);assert.equal(timers.size,1,'Cancelled scan cannot add another timer after re-entry');
  slow.stop();timers.clear();
  const bad=entry('bad'), other=entry('other');let continued=0;
  const failing=view([bad,other],{refresh:async id=>{if(id==='bad')throw Error('Source unavailable');continued++;}});
  await failing.refreshAll();await turn();await turn();assert.equal(continued,1,'One failed card does not stop other manual refreshes');
  assert.equal(failing.error,'Source unavailable');assert.ok(logs.some(log=>log[2]==='action_failed'));
  failing.stop();timers.clear();
  let saved;const editable=view([card],{toggle:async(...args)=>saved=args});
  await editable.change(card,'toggle','tasks','walk',true);assert.deepEqual(saved,['due',1,'tasks','walk',true]);assert.equal(editable.pending.length,0);
  editable.foreground=false;await editable.change(card,'toggle','tasks','walk',false);assert.equal(saved[4],true,'Background view cannot mutate user state');
  editable.entries=[entry('one'),entry('two'),entry('three')];editable.entries[1].panel.definition.size='L';
  assert.equal(editable.columns(),2);assert.equal(editable.layouts()[1].width,360);assert.ok(editable.boardHeight()>0);
  console.log('PASS emitted native expiry scheduling, foreground re-entry, cancellation race, visible errors, independent cards and checklist persistence dispatch');
  const {PanelChanges}=compile(fs.readFileSync(path.join(root,'entry/src/main/ets/services/PanelChanges.ets'),'utf8'));
  const {PanelExpiryUpdates}=compile(fs.readFileSync(path.join(root,'entry/src/main/ets/services/PanelExpiryUpdates.ets'),'utf8'),{
    require:id=>id.includes('LifePanel')?model:id.includes('Cancellation')?signal:id.includes('PanelChanges')?{PanelChanges}:{Diagnostics:{log:(...args)=>logs.push(args)}},
    setTimeout:(fn,ms)=>{timers.set(++timerId,{fn,ms});return timerId;},clearTimeout:id=>timers.delete(id)});
  let fetched=0, globalSignal, finish;
  const global=new PanelExpiryUpdates({list:async()=>[entry('global')],repository:()=>({refresh:async(id,cancel,trigger)=>{
    assert.equal(trigger,'automatic','Scheduler requests authoritative automatic admission rather than an unrestricted manual refresh');
    fetched++;globalSignal=cancel;await new Promise(r=>finish=r);cancel.check();
  }})});
  global.setActive(true);await turn();assert.equal(fetched,1,'App foreground updates cards without opening the collection');
  global.setActive(true);await turn();assert.equal(fetched,1,'Repeated foreground callbacks do not duplicate work');
  global.setActive(false);assert.equal(globalSignal.cancelled,true);finish();await turn();await turn();assert.equal(timers.size,0);
  global.setActive(true);await turn();assert.equal(fetched,2);finish();await turn();await turn();assert.equal(timers.size,1);
  PanelChanges.emit();await turn();assert.equal(fetched,3,'Publishing/resuming a card wakes the foreground scheduler');
  global.setActive(false);finish();await turn();await turn();assert.equal(timers.size,0);
  console.log('PASS app-level foreground refresh without collection navigation, duplicate activation, background cancellation and restart');
  const connectionTree=emitted('views/PanelConnectionPanel');
  const connectionClass=connectionTree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='PanelConnectionPanel');
  const connectionMethods=connectionClass.members.filter(n=>ts.isMethodDeclaration(n)&&['run','aboutToDisappear'].includes(n.name.getText(connectionTree)))
    .map(n=>n.getText(connectionTree)).join('\n');
  const {Connection}=compile('export class Connection {'+connectionMethods+'}',{Diagnostics:{log:(...args)=>logs.push(args)}});
  const connection=new Connection();let secretSaved,loggedIn=false,completed=0,disconnects=0;
  Object.assign(connection,{busy:false,error:'',secret:'',connected:false,cancellation:new signal.Cancellation(),entry:entry('connection'),
    context:()=>({}),onConnected:()=>completed++,credentials:()=>({
      connected:async()=>loggedIn,save:async(id,source,secret)=>{secretSaved=secret;loggedIn=true;},
      login:async(id,source,context,cancel)=>{assert.equal(cancel,connection.cancellation);loggedIn=true;},
      disconnect:async()=>{disconnects++;loggedIn=false;}
    })});
  await connection.run('status');assert.equal(connection.connected,false);assert.equal(connection.secret,'','Stored credentials never populate the editor');
  connection.secret='device-only-key';await connection.run('save');assert.equal(secretSaved,'device-only-key');assert.equal(connection.secret,'');assert.equal(completed,1);
  await connection.run('disconnect');assert.equal(disconnects,1);assert.equal(connection.connected,false);
  await connection.run('login');assert.equal(connection.connected,true);assert.equal(completed,2);
  connection.secret='unfinished';connection.aboutToDisappear();assert.equal(connection.secret,'');assert.equal(connection.cancellation.cancelled,true);
  console.log('PASS emitted API connection editor: explicit key save, secret clearing, OAuth dispatch, status, disconnect and dismissal cancellation');
  const mailTree=emitted('views/MailSettingsPanel'),mailClass=mailTree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='MailSettingsPanel');
  const mailMethods=mailClass.members.filter(n=>ts.isMethodDeclaration(n)&&['edit','save','reload','report','remove','activityChanged','aboutToDisappear'].includes(n.name.getText(mailTree)))
    .map(n=>n.getText(mailTree)).join('\n');
  let savedMail,mailChecks=0,mailDeletes=0,mailMode='success',mailSignal;
  const {MailEditor}=compile('export class MailEditor {'+mailMethods+'}',{...signal,t:(text,values=[])=>text.replace(/\{(\d+)\}/g,(_,i)=>String(values[i])),
    util:{generateRandomUUID:()=> 'new-mail'},Diagnostics:{log:(...args)=>logs.push(args)},
    MailService:class {async query(query,cancel){mailChecks++;mailSignal=cancel;assert.equal(query.accountId,'new-mail');assert.equal(query.folder,'INBOX');if(mailMode==='error')throw Error('IMAP login rejected');
      if(mailMode==='wait')return new Promise((resolve,reject)=>cancel.onCancel(()=>reject(Error('cancelled'))));return {total:9,unread:3};}}});
  const mailEditor=new MailEditor();Object.assign(mailEditor,{mounted:true,foreground:true,busy:false,error:'',notice:'',editing:false,secret:'',accounts:[],cancellation:new signal.Cancellation(),
    store:{save:async(account,secret)=>{savedMail={account,secret};},list:async()=>savedMail?[savedMail.account]:[],remove:async()=>mailDeletes++}});
  mailEditor.edit();assert.equal(mailEditor.accessEnabled,false);assert.equal(mailEditor.allowBody,false,'Mailbox/body access requires explicit opt-in');
  Object.assign(mailEditor,{name:'Work',host:'IMAP.EXAMPLE.COM',username:'user@example.com',secret:'device-only-mail-code',accessEnabled:true});
  await mailEditor.save(true);assert.equal(savedMail.account.host,'imap.example.com');assert.equal(savedMail.secret,'device-only-mail-code');assert.equal(mailChecks,1);
  assert.equal('folders' in savedMail.account,false,'Settings no longer save a folder allowlist');
  assert.equal(mailEditor.secret,'');assert.ok(mailEditor.notice.includes('9'));assert.equal(mailEditor.accountId,'new-mail');
  mailMode='error';await mailEditor.save(true);assert.equal(mailEditor.error,'IMAP login rejected');assert.equal(mailEditor.busy,false,'Failed connection check leaves the editor usable');
  mailMode='wait';const mailPending=mailEditor.save(true);await turn();assert.ok(mailSignal);
  mailEditor.foreground=false;mailEditor.activityChanged();await mailPending;assert.equal(mailSignal.cancelled,true);assert.equal(mailEditor.error,'','Background cancellation is not reported as a connection failure');
  const checksBefore=mailChecks;await mailEditor.save(true);assert.equal(mailChecks,checksBefore,'Hidden mailbox editor cannot start a check');
  mailEditor.foreground=true;await mailEditor.remove();assert.equal(mailDeletes,1);assert.equal(mailEditor.editing,false);
  mailEditor.secret='unfinished-mail-code';mailEditor.aboutToDisappear();assert.equal(mailEditor.secret,'');assert.equal(mailEditor.mounted,false);
  console.log('PASS emitted mailbox editor: explicit access, secure save, connection check, visible failure, background cancellation, removal and secret clearing');
  const arranged=view();arranged.entries=[entry('a'),entry('b')];
  arranged.boards=[{workspaceId:'owner',board:{id:'board',items:[{workspaceId:'chat',panelId:'b',size:'L'},{workspaceId:'chat',panelId:'a',size:'S'}]}}];
  arranged.boardSelection='owner/board';assert.equal(arranged.visible()[0].panel.id,'b');assert.equal(arranged.sizeOnBoard(arranged.visible()[0]),'L');
  let reorder;arranged.boardStore=()=>({arrange:async(...args)=>reorder=args,list:async()=>arranged.boards});arranged.panels=()=>({list:async()=>arranged.entries});
  arranged.feedback='Layout saved';
  arranged.startMove('chat/a',{fingerList:[{globalX:100,globalY:300}]});arranged.moveCard({offsetX:999,offsetY:999,fingerList:[{globalX:100,globalY:108}]});assert.equal(arranged.dragY,-192);assert.equal(arranged.dragX,0,'Window coordinates keep the card under the finger despite changing local coordinates');assert.equal(arranged.layoutEntries()[0].panel.id,'a');await arranged.dropCard(arranged.visible()[1],1,{offsetX:0,offsetY:-192});assert.ok(reorder,'Dragging invokes persisted board arrangement');
  assert.equal(arranged.dragging,'');
  assert.equal(arranged.feedback,'布局已保存','Drop retains the feedback row instead of shifting the board during the next drag');
  arranged.startMove('chat/a',{fingerList:[{globalX:100,globalY:300}]});arranged.moveCard({offsetX:999,offsetY:999,fingerList:[{globalX:100,globalY:108}]});arranged.resetGesture();assert.equal(arranged.visible()[0].panel.id,'b','Cancel leaves saved ordering alone');
  arranged.entries[0].panel.definition.view={height:320};
  await arranged.resizeCard('chat/a',{offsetX:100,offsetY:80,fingerList:[{globalX:300,globalY:400}]},false);assert.equal(arranged.resizeWidth,274);assert.equal(arranged.resizeHeight,400);assert.equal(arranged.sizeOnBoard(arranged.entries[0]),'M');
  await arranged.resizeCard('chat/a',{offsetX:100,offsetY:80,fingerList:[{globalX:300,globalY:400}]},true);assert.equal(reorder[4],'M');assert.equal(reorder[5],400);assert.equal(arranged.resizing,'');
  await arranged.resizeCard('chat/a',{offsetX:0,offsetY:20,fingerList:[{globalX:300,globalY:400}]},false,220);
  assert.equal(arranged.resizeHeight,240,'First manual resize uses measured content height, not the old definition viewport');
  arranged.resetGesture();
  const grid=view();grid.entries=[entry('A'),entry('B'),entry('C')];grid.entries[2].panel.definition.size='M';
  grid.boards=[{workspaceId:'owner',board:{id:'grid',items:grid.entries.map(e=>({workspaceId:e.workspaceId,panelId:e.panel.id,size:e.panel.definition.size}))}}];
  grid.boardSelection='owner/grid';grid.cardHeights={'chat/A':150,'chat/B':150,'chat/C':200};grid.feedback='Layout saved';
  let gridDrop;grid.boardStore=()=>({arrange:async(...args)=>{gridDrop=args;},list:async()=>grid.boards});grid.panels=()=>({list:async()=>grid.entries});
  grid.startMove('chat/B',{fingerList:[{globalX:280,globalY:100}]});
  assert.equal(grid.feedback,'Layout saved','Starting a drag must not remove the feedback row and shift every card');
  grid.moveCard({fingerList:[{globalX:280,globalY:500}]});
  assert.equal(grid.dragBefore,'$end','Dragging B below C accepts the blank bottom area');
  assert.deepEqual(grid.layoutEntries().map(e=>e.panel.id),['A','C','B']);
  await grid.dropCard(grid.entries[1],1,{});
  assert.equal(gridDrop[2].panelId,'B');assert.equal(gridDrop[3],'','Moving B to the end persists an empty before-key');
  assert.equal(gridDrop[4],undefined,'Reordering does not change the card size');
  arranged.requestedTarget=JSON.stringify({workspaceId:'chat',panelId:'a'});arranged.targetChanged();assert.equal(arranged.selected,'chat/a');assert.equal(arranged.boardSelection,'');
  arranged.requestedTarget=JSON.stringify({workspaceId:'owner',boardId:'board'});arranged.targetChanged();assert.equal(arranged.boardSelection,'owner/board');assert.equal(arranged.selected,'');
  const composing=view();let sent=0,createdThreads=0,selectedThread='',editorSaved='',chatOpened=0;
  composing.boards=[{workspaceId:'owner',board:{id:'board',title:'Daily',items:[],editorThreadId:'editor'}}];composing.boardSelection='owner/board';
  composing.prompt='Create a counter';composing.editTarget='';composing.onChat=()=>chatOpened++;
  composing.app={ready:true,busy:false,threads:[{id:'editor',draft:'',attachments:[]}],runningThreadIds:[],active:{id:'editor'},
    selectThread:async id=>{selectedThread=id;return true},newThread:async()=>{createdThreads++;composing.app.active={id:'new'};return true},
    setDraft:draft=>{composing.app.draft=draft},setPanelContext:context=>{composing.app.context=context},flushDraft:async()=>{},send:async()=>{sent++}};
  composing.boardStore=()=>({list:async()=>composing.boards,setEditor:async(w,b,id)=>editorSaved=id});
  await composing.createCard();assert.equal(sent,1);assert.equal(createdThreads,0);assert.equal(selectedThread,'editor');assert.equal(chatOpened,0);assert.match(composing.app.context,/validate_life_panel/);
  composing.prompt='Improve it';composing.app.threads[0].attachments=[{id:'unsent'}];await composing.createCard();assert.equal(createdThreads,1);assert.equal(editorSaved,'new');assert.equal(sent,2,'Unsent attachments are never submitted with panel prompt');
  composing.boards[0].board.editorThreadId='new';await composing.showEditor();assert.equal(selectedThread,'new');assert.equal(chatOpened,1);
  console.log('PASS board generation sends directly, reuses its editor, preserves unrelated drafts/attachments and routes back to its conversation');
  const scoped=view();let nextThread=0;const submissions=[],selections=[],associations=[];
  scoped.boards=['a','b'].map(id=>({workspaceId:'owner',board:{id,title:id,items:[]}}));
  scoped.onChat=()=>{};scoped.editTarget='';
  scoped.app={ready:true,busy:false,threads:[],runningThreadIds:[],active:{id:''},
    selectThread:async id=>{selections.push(id);scoped.app.active=scoped.app.threads.find(thread=>thread.id===id);return !!scoped.app.active},
    newThread:async()=>{const thread={id:'editor-'+ ++nextThread,draft:'',attachments:[]};scoped.app.threads.push(thread);scoped.app.active=thread;return true},
    setDraft:()=>{},setPanelContext:()=>{},flushDraft:async()=>{},send:async()=>submissions.push(scoped.app.active.id)};
  scoped.boardStore=()=>({list:async()=>scoped.boards,setEditor:async(w,b,id)=>{associations.push([w,b,id]);scoped.boards.find(item=>item.board.id===b).board.editorThreadId=id}});
  scoped.boardSelection='owner/a';scoped.prompt='Create A';await scoped.createCard();assert.equal(scoped.error,'');
  scoped.boardSelection='owner/b';await scoped.showEditor();assert.deepEqual(selections,[],'A board without an editor must not open another board conversation');
  scoped.prompt='Create B';await scoped.createCard();assert.equal(scoped.error,'');
  assert.deepEqual(submissions,['editor-1','editor-2'],'Different boards get independent editing conversations');
  assert.deepEqual(associations,[['owner','a','editor-1'],['owner','b','editor-2']]);
  scoped.editorThreadId='';await scoped.showEditor();assert.equal(selections.at(-1),'editor-2','Board association survives clearing component state');
  scoped.boardSelection='owner/a';scoped.prompt='Improve A';await scoped.createCard();assert.equal(submissions.at(-1),'editor-1');
  scoped.boardSelection='';scoped.editorThreadId='editor-2';scoped.prompt='All cards';await scoped.createCard();
  assert.equal(submissions.at(-1),'editor-2','All-cards view retains the component editor fallback');
  console.log('PASS independent board editors, persisted reopening, board reuse and all-cards fallback');
  console.log('PASS emitted shared-board ordering/sizing, drag persistence dispatch and chat card/board navigation');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
