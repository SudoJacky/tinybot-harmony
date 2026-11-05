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
const names=['stop','activityChanged','scan','reload','report','entryKey','refresh','change','refreshAll','visible','layouts','rect','columns','boardHeight','currentBoard','boardKey','sizeOnBoard','targetChanged','dropCard'];
const methods=panel.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name.getText(tree))).map(n=>n.getText(tree)).join('\n');
assert.equal(panel.members.filter(n=>ts.isMethodDeclaration(n)&&names.includes(n.name.getText(tree))).length,names.length);
const timers=new Map(), logs=[];let timerId=0;
const {Probe}=compile('export class Probe {'+methods+'}',{...model,...signal,...loadModel('LifeBoard'),...loadModel('PanelPresentation'),
  setTimeout:(fn,ms)=>{timers.set(++timerId,{fn,ms});return timerId;},clearTimeout:id=>timers.delete(id),
  Diagnostics:{log:(...args)=>logs.push(args)}});
const turn=()=>new Promise(resolve=>setImmediate(resolve));
function entry(id,refreshMinutes=1) {return {workspaceId:'chat',panel:{id,configRevision:1,archived:false,createdAt:1,
  definition:{size:'S',source:{type:'workspace-json',path:'data.json'},refreshMinutes},refreshedAt:0,attemptedAt:0}};}
function view(entries=[],repository={}) {
  const page=new Probe();Object.assign(page,{mounted:true,active:true,foreground:true,timer:-1,cancellation:new signal.Cancellation(),scanning:false,
    cardHeights:{},entries:[],pending:[],error:'',selected:'',removed:false,boardWidth:360,boards:[],boardSelection:'',requestedTarget:'',lastTarget:''});
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
    MailService:class {async query(query,cancel){mailChecks++;mailSignal=cancel;assert.equal(query.accountId,'new-mail');if(mailMode==='error')throw Error('IMAP login rejected');
      if(mailMode==='wait')return new Promise((resolve,reject)=>cancel.onCancel(()=>reject(Error('cancelled'))));return {total:9,unread:3};}}});
  const mailEditor=new MailEditor();Object.assign(mailEditor,{mounted:true,foreground:true,busy:false,error:'',notice:'',editing:false,secret:'',accounts:[],cancellation:new signal.Cancellation(),
    store:{save:async(account,secret)=>{savedMail={account,secret};},list:async()=>savedMail?[savedMail.account]:[],remove:async()=>mailDeletes++}});
  mailEditor.edit();assert.equal(mailEditor.accessEnabled,false);assert.equal(mailEditor.allowBody,false,'Mailbox/body access requires explicit opt-in');
  Object.assign(mailEditor,{name:'Work',host:'IMAP.EXAMPLE.COM',username:'user@example.com',secret:'device-only-mail-code',accessEnabled:true});
  await mailEditor.save(true);assert.equal(savedMail.account.host,'imap.example.com');assert.equal(savedMail.secret,'device-only-mail-code');assert.equal(mailChecks,1);
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
  await arranged.dropCard(arranged.visible()[1],1,{offsetX:0,offsetY:-192});assert.ok(reorder,'Dragging invokes persisted board arrangement');
  arranged.requestedTarget=JSON.stringify({workspaceId:'chat',panelId:'a'});arranged.targetChanged();assert.equal(arranged.selected,'chat/a');assert.equal(arranged.boardSelection,'');
  arranged.requestedTarget=JSON.stringify({workspaceId:'owner',boardId:'board'});arranged.targetChanged();assert.equal(arranged.boardSelection,'owner/board');assert.equal(arranged.selected,'');
  console.log('PASS emitted shared-board ordering/sizing, drag persistence dispatch and chat card/board navigation');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
