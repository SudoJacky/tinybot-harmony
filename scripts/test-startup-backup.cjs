const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
let saved, working, files, info, failFlush, syncs, listings, synced, items, syncError;
const store = { getSync: (k,d) => working.has(k) ? working.get(k) : d, putSync: (k,v) => working.set(k,v),
  flushSync() { if(failFlush) throw Error('flush failed'); saved=new Map(working); } };
const cloud = { sync:async()=>{syncs++;if(syncError)throw syncError;return synced;},list:async()=>{listings++;return items;} };
const cache = new Map();
function compile(text) {return ts.transpileModule(text,{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;}
function load(name) {
  const file=path.resolve(root,name.endsWith('.ets')?name:name+'.ets');if(cache.has(file))return cache.get(file);
  const exports={};cache.set(file,exports);
  vm.runInNewContext(compile(fs.readFileSync(file,'utf8')),{exports,require:id=>{
    if(id==='@kit.AbilityKit')return{bundleManager:{BundleFlag:{GET_BUNDLE_INFO_DEFAULT:0},getBundleInfoForSelfSync:()=>info}};
    if(id==='@kit.ArkData')return{preferences:{getPreferencesSync:()=>store}};
    if(id==='@kit.CoreFileKit')return{fileIo:{accessSync:p=>files.has(p)}};
    if(id==='./CloudBackup')return{CloudBackup:cloud};
    if(id.startsWith('.'))return load(path.resolve(path.dirname(file),id));
    throw Error(id);
  }});return exports;
}
const {StartupBackup}=load('services/StartupBackup');
const context={filesDir:'/app'};
const fresh=()=>({config:{configured:false},threads:[],projects:[],providerProfiles:[]});
function reset(){saved=new Map();working=new Map();files=new Set();info={installTime:100,updateTime:100};failFlush=false;syncs=0;listings=0;synced=true;items=[{name:'tinybot-latest.tinybot',createdAt:100,size:100,location:2}];syncError=undefined;}
async function main(){
  reset();let state=new StartupBackup(context);assert.equal(saved.get('startupBackupState'),'pending');
  // Session initialization creates a manifest, but first-run identity has already been captured.
  files.add('/app/sessions-v2/index.json');working=new Map(saved);state=new StartupBackup(context);
  assert.equal((await state.find(fresh())).name,'tinybot-latest.tinybot');assert.equal(syncs,1);
  state.finish();working=new Map(saved);state=new StartupBackup(context);assert.equal(await state.find(fresh()),undefined);assert.equal(syncs,1);
  for(const upgrade of ['timestamp','manifest','legacy','completed','pending-upgrade']){
    reset();
    if(upgrade==='timestamp') info.updateTime=200;
    if(upgrade==='manifest') files.add('/app/sessions-v2/index.json');
    if(upgrade==='legacy') files.add('/app/tinybot-v1.json');
    if(upgrade==='completed') working.set('onboardingComplete',true);
    if(upgrade==='pending-upgrade'){working.set('startupBackupState','pending');info.updateTime=200;}
    state=new StartupBackup(context);assert.equal(await state.find(fresh()),undefined,upgrade);assert.equal(syncs,0,upgrade);
  }
  for(const data of [{...fresh(),providerProfiles:[{id:'saved'}]},{...fresh(),threads:[{messages:[],draft:'new work'}]},
    {...fresh(),config:{configured:false,userDocument:'personal'}},{...fresh(),productivity:{servers:[{}]}},
    {...fresh(),productivity:{memories:[{}]}}]){
    reset();state=new StartupBackup(context);assert.equal(await state.find(data),undefined);assert.equal(syncs,0);assert.equal(saved.get('startupBackupState'),'done');
  }
  reset();state=new StartupBackup(context);items=[];assert.equal(await state.find(fresh()),undefined);assert.equal(saved.get('startupBackupState'),'done');
  reset();state=new StartupBackup(context);items=[];synced=false;await state.find(fresh());assert.equal(saved.get('startupBackupState'),'pending','incomplete sync can retry later');
  syncError=Error('cloud unavailable');await assert.rejects(state.find(fresh()),/cloud unavailable/);assert.equal(saved.get('startupBackupState'),'pending');
  reset();failFlush=true;assert.throws(()=>new StartupBackup(context),/flush failed/);assert.equal(working.get('startupBackupState'),'');
  failFlush=false;state=new StartupBackup(context);failFlush=true;assert.throws(()=>state.finish(),/flush failed/);assert.equal(working.get('startupBackupState'),'pending');
  console.log('PASS fresh-install capture, upgrade exclusion, durable one-time decision, changed-data suppression, cloud retries and marker failures');
  if(process.argv.includes('--ui'))await uiTest();
}
async function uiTest(){
  const source=path.join(root,'pages/Index.ets');
  const emitted=path.resolve(root,'../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts');
  assert.ok(fs.statSync(emitted).mtimeMs>=fs.statSync(source).mtimeMs,'Rebuild Index');
  const tree=ts.createSourceFile('Index.ts',fs.readFileSync(emitted,'utf8'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='Index');
  const methods=['canOfferStartupBackup','offerStartupBackup','restoreStartupBackup'];
  const exports={},dialogs=[];let restore;
  vm.runInNewContext(compile('class Probe {'+methods.map(name=>component.members.find(n=>n.name?.getText(tree)===name).getText(tree)).join('\n')+'} exports.Probe=Probe;'),{
    exports,t:(s,values=[])=>s.replace(/\{(\d+)\}/g,(_,i)=>values[i]),getLocale:()=> 'zh-CN',
    ShareInbox:{peek:()=>undefined},WorkbenchLayout:{dialogWidth:()=>0},DialogAlignment:{Center:0},Diagnostics:{log(){}},
    cloudBackupError:e=>e.message,CloudBackup:{restore:()=>restore()},StartupBackupDialog:class{},
    CustomDialogController:class{constructor(options){this.options=options;dialogs.push(this);}open(){this.options.onDidAppear();}close(){this.options.onDidDisappear();}}
  });
  function page(){let finished=0,commits=0;const entries=['onboarding'];const data=fresh();
    const view=Object.assign(new exports.Probe(),{privacy:{allowed:true},foreground:true,reviewDisposed:false,appearance:{surface:{}},
      onboardingActive:true,app:{ready:true,canNavigate:true,busy:false,exportSnapshot:()=>data,importSnapshot:async()=>{commits++;return true;}},
      startupBackup:{find:async()=>({name:'tinybot-latest.tinybot',createdAt:100}),untouched:d=>!d.providerProfiles.length,finish:()=>finished++},
      paths:{size:()=>entries.length,clear:()=>entries.length=0},onboardingPreferences:()=>({complete(){}}),
      getUIContext:()=>({getHostContext:()=>context,getPromptAction:()=>({showToast(){}})}),receiveShare(){},receiveLaunch(){},offerAnnouncement(){}});
    return{view,data,finished:()=>finished,commits:()=>commits,entries};}
  let p=page();await p.view.offerStartupBackup();assert.equal(p.finished(),1);assert.ok(p.view.startupBackupDialog);
  restore=async()=>({threads:[]});await p.view.restoreStartupBackup({name:'tinybot-latest.tinybot'});assert.equal(p.commits(),1);assert.equal(p.entries.length,0);
  p=page();let resolve;p.view.startupBackup.find=()=>new Promise(r=>resolve=r);const lookup=p.view.offerStartupBackup();
  p.data.providerProfiles.push({id:'configured-during-lookup'});resolve({name:'backup',createdAt:100});await lookup;assert.equal(p.finished(),0);assert.equal(p.view.startupBackupDialog,undefined);
  p=page();p.view.startupBackup.find=()=>new Promise(r=>resolve=r);const pending=p.view.offerStartupBackup();p.view.privacy.allowed=false;resolve({name:'backup',createdAt:100});await pending;assert.equal(p.finished(),0);
  p=page();restore=()=>new Promise(r=>resolve=r);const importing=p.view.restoreStartupBackup({name:'backup'});p.view.privacy.allowed=false;resolve({threads:[]});await assert.rejects(importing);assert.equal(p.commits(),0);
  p=page();restore=async()=>{throw Error('download failed');};await assert.rejects(p.view.restoreStartupBackup({name:'backup'}),/download failed/);assert.equal(p.commits(),0);assert.equal(p.view.startupBackupRestoring,false);
  console.log('PASS compiled startup dialog, explicit restore, delayed lookup/configuration race, privacy revocation and restore failure');
  await accountBackupUiTest();
}
async function accountBackupUiTest(){
  const source=path.join(root,'views/BackupPanel.ets');
  const emitted=path.resolve(root,'../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/BackupPanel.ts');
  assert.ok(fs.statSync(emitted).mtimeMs>=fs.statSync(source).mtimeMs,'Rebuild BackupPanel');
  const tree=ts.createSourceFile('BackupPanel.ts',fs.readFileSync(emitted,'utf8'),ts.ScriptTarget.Latest,true);
  const component=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name?.text==='BackupPanel');
  const methods=['locked','backup','cloud','aboutToDisappear'];
  const exports={},calls=[];const data={};let imports=0;
  vm.runInNewContext(compile('class Probe {'+methods.map(name=>component.members.find(n=>n.name?.getText(tree)===name).getText(tree)).join('\n')+'} exports.Probe=Probe;'),{
    exports,t:s=>s,cloudBackupError:e=>e.message,
    exportBackup:async(_context,_data,password)=>calls.push(['export',password]),
    readBackup:async(_context,_data,password)=>{calls.push(['read',password]);return data;},
    CloudBackup:{create:async(_context,_data,password)=>{calls.push(['create',password]);return true;},
      restore:async(_context,_name,_data,password)=>{calls.push(['restore',password]);return data;}}
  });
  const panel=Object.assign(new exports.Probe(),{visible:true,busy:false,appearance:{surface:{}},
    app:{busy:false,providerProfiles:[{noApiKey:false}],exportSnapshot:()=>data,importSnapshot:async()=>{imports++;return true;}},
    context:()=>context,loadCloudList:async()=>{},getUIContext:()=>({getHostContext:()=>context,getPromptAction:()=>({showToast(){}})})});
  await panel.backup(false);await panel.cloud('create');await panel.backup(true);await panel.cloud('restore','backup');
  assert.deepEqual(calls,[['export',undefined],['create',undefined],['read',undefined],['restore',undefined]]);assert.equal(imports,2);
  panel.aboutToDisappear();assert.equal(panel.visible,false);
  console.log('PASS compiled password-free local/cloud backup and restore actions');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
