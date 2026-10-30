// Build first. Exercise the actual emitted collection UI and async action paths.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const compile = source => ts.transpileModule(source, {compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const t = (key, values=[]) => key.replace(/\{(\d+)\}/g, (_,n)=>String(values[n]));
let locale = 'zh-CN';
const themeFile = path.join(root,'entry/src/main/ets/common/Theme.ets');
const theme = ts.createSourceFile(themeFile, fs.readFileSync(themeFile,'utf8'), ts.ScriptTarget.Latest, true);
const timeGlobals = {exports:{},t,getLocale:()=>locale};
vm.runInNewContext(compile('const DAY=86400000;'+theme.statements.filter(n=>ts.isFunctionDeclaration(n) &&
  ['startOfDay','pad','shortTime','relativeTime'].includes(n.name?.text)).map(n=>n.getText(theme).replace(/^export /,'')).join('\n')+
  '\nexports.relativeTime=relativeTime;'),timeGlobals);
const {relativeTime} = timeGlobals.exports;
const noon = new Date(2026,9,29,12).getTime();
assert.equal(relativeTime(noon-20000,noon),'刚刚');
assert.equal(relativeTime(noon-180000,noon),'3 分钟前');
assert.equal(relativeTime(noon-7200000,noon),'2 小时前');
assert.equal(relativeTime(new Date(2026,9,28,23).getTime(),noon),'昨天');
assert.equal(relativeTime(new Date(2026,9,20).getTime(),noon),'10月20日');
assert.equal(relativeTime(new Date(2025,9,20).getTime(),noon),'2025/10/20');
assert.equal(relativeTime(noon+60000,noon),'刚刚');
locale='en'; assert.equal(relativeTime(new Date(2026,9,20).getTime(),noon),'Oct 20'); locale='zh-CN';
console.log('PASS localized relative dates, day/year boundaries and future clock skew');

const indexBuilt=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/pages/Index.ts');
const indexTree=ts.createSourceFile(indexBuilt,fs.readFileSync(indexBuilt,'utf8'),ts.ScriptTarget.Latest,true);
let titleActions;
function findTitleActions(node){
  if(ts.isCallExpression(node)&&node.expression.getText(indexTree)==='NavDestination.menus'&&
    node.getText(indexTree).includes('miniAppCreateAvailable')) titleActions=node.arguments[0].getText(indexTree);
  ts.forEachChild(node,findTitleActions);
}
findTitleActions(indexTree);assert.ok(titleActions,'Collection visibility must update the native Create menu');
const titleGlobals={exports:{},t,SymbolGlyphModifier:class{}};
vm.runInNewContext(compile('exports.items=function(){return '+titleActions+';}'),titleGlobals);
const host={miniAppCreateAvailable:false,miniAppCreateRequest:0,app:{busy:false,ready:true}};
assert.equal(titleGlobals.exports.items.call(host).length,0);
host.miniAppCreateAvailable=true;const titleItem=titleGlobals.exports.items.call(host)[0];
assert.equal(titleItem.value,'创建');assert.equal(titleItem.isEnabled,true);titleItem.action();assert.equal(host.miniAppCreateRequest,1);
host.app.busy=true;assert.equal(titleGlobals.exports.items.call(host)[0].isEnabled,false);
host.app.busy=false;host.app.ready=false;assert.equal(titleGlobals.exports.items.call(host)[0].isEnabled,false);
console.log('PASS native Create action, request dispatch, readiness and busy guards');

const src=path.join(root,'entry/src/main/ets/views/MiniAppsPanel.ets');
const built=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MiniAppsPanel.ts');
assert.ok(fs.statSync(built).mtimeMs>=fs.statSync(src).mtimeMs,'Build before testing');
const tree=ts.createSourceFile(built,fs.readFileSync(built,'utf8'),ts.ScriptTarget.Latest,true);
const cls=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='MiniAppsPanel');
const methods=['run','owner','metadata','usedAt','entryIconColor','iconColorChoices','iconPalette','iconColor','iconChoices','iconSymbol','changeIcon','iconChanged','saveIcon','iconPicker','entryKey','displayTitle','count','open','restore','rename','saveName','back',
  'refreshPreviews','updateCreateAvailable','createRequested','showPreviewPicker','reload','success','cardContent','entryCard','entryMenu','feedback','collection','previewPicker'];
const selected=cls.members.filter(n=>methods.includes(n.name?.getText(tree))); assert.equal(selected.length,methods.length);
const nodes=[], stack=[]; let current;
const ui = name => new Proxy({}, {get:(_,key)=>{
  if (key==='canRetake') return ()=>false;
  if (key==='create'||key==='createWithChild'||key==='createWithLabel') return value=>{
    const node={type:name,parent:stack.at(-1),value}; nodes.push(node);
    if(!['SymbolGlyph','Image','LoadingProgress'].includes(name)) stack.push(node);
    current=node;
    if(typeof value==='function') value();
  };
  if(key==='pop') return ()=>{stack.pop();current=stack.at(-1);};
  return value=>{ if(current) current[key]=value; };
}});
const globals={exports:{},t,relativeTime,Diagnostics:{log(){}},miniAppInCollection:()=>true,
  MINI_APP_ICON_COLOR_IDS:['green','blue','orange','purple','rose'],
  BreakpointsReference:{ComponentSize:'component'},
  miniAppCanRollback:app=>!!app.previousPage,
  ViewPU:{create(){}},ViewStackProcessor:{visualState(){}},
  Banner:class{constructor(_parent,props){nodes.push({type:'Banner',...props});}}};
for(const name of ['Column','Row','Stack','Text','Button','Menu','MenuItem','If','Blank','SymbolGlyph','Image','LoadingProgress','GridRow','GridCol','ForEach','List','ListItem','Scroll']) globals[name]=ui(name);
for(const name of ['Space','Radius','Btn','Alignment','ButtonType','FontWeight','HorizontalAlign','FlexAlign','TextOverflow','TextAlign','Color','Visibility','BarState']) globals[name]={};
// Run the real emitted Builder: a stub would hide a missing page receiver and its device crash.
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(path.dirname(built),'../common/MaterialMenu.ts'),'utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText,globals);
globals.materialMenuContent=function(options){
  current.menuContent=options;
  return globals.exports.materialMenuContent.call(this,options);
};
vm.runInNewContext(compile('class Panel{'+selected.map(n=>n.getText(tree)).join('\n')+'}\nexports.Panel=Panel;'),globals);
function panel() {
  return Object.assign(new globals.exports.Panel(),{
    mounted:true,busy:false,busyLabel:'',error:'',notice:'',removed:false,currentIcon:'default',currentIconColor:'green',entries:[],availablePreviews:[],now:noon,appearance:{accent:'accent',accentContainer:'selected'},
    app:{busy:false,ready:true,projects:[{workspaceId:'project',name:'Project'}],threads:[{id:'source',displayTitle:'Actual source'}]},
    onCreateAvailable(){},previews:()=>[],previewPage:()=>({}),
    observeComponentCreation2(callback){callback(1,true);},ifElseBranchUpdateFunction(_branch,render){render();},
    forEachUpdateFunction(_id,items,render,key){this.lastKeys=items.map(key);items.forEach(render);}
  });
}
function draw(p, method, entry){nodes.length=0;stack.length=0;current=undefined;p[method](entry);return nodes;}
const entry={workspaceId:'project',app:{id:'same',title:'Counter',description:'long description',sourceThreadId:'source',createdAt:1,updatedAt:noon-7200000,lastOpenedAt:noon-180000,archived:false}};
const p=panel();p.entries=[entry,{workspaceId:'other',app:{...entry.app,title:'Other',archived:true}}];
const modelFile=path.join(root,'entry/src/main/ets/model/MiniApp.ets');
const modelTree=ts.createSourceFile(modelFile,fs.readFileSync(modelFile,'utf8'),ts.ScriptTarget.Latest,true);
const iconIds=modelTree.statements.filter(ts.isVariableStatement).flatMap(n=>[...n.declarationList.declarations])
  .find(n=>n.name.getText(modelTree)==='MINI_APP_ICON_IDS').initializer.getText(modelTree);
assert.equal(JSON.stringify(p.iconChoices().map(item=>item.id)),JSON.stringify(vm.runInNewContext(iconIds)),
  'Every persisted icon ID has a native picker option');
assert.equal(new Set(p.iconChoices().map(item=>item.id)).size,16);
const colorIds=modelTree.statements.filter(ts.isVariableStatement).flatMap(n=>[...n.declarationList.declarations])
  .find(n=>n.name.getText(modelTree)==='MINI_APP_ICON_COLOR_IDS').initializer.getText(modelTree);
assert.equal(JSON.stringify(p.iconColorChoices().map(item=>item.id)),JSON.stringify(vm.runInNewContext(colorIds)));
assert.equal(JSON.stringify(globals.MINI_APP_ICON_COLOR_IDS),JSON.stringify(vm.runInNewContext(colorIds)));
assert.throws(()=>p.iconPalette('unknown'),/Invalid mini app icon color/);
assert.equal(JSON.stringify(p.iconSymbol()),JSON.stringify(p.iconSymbol('default')),'Old apps use the default icon');
assert.throws(()=>p.iconSymbol('missing'),/Invalid mini app icon/);
assert.equal(p.owner(entry),'Actual source'); assert.equal(p.count(false),1);assert.equal(p.count(true),1);
assert.equal(p.metadata(entry),'来源：Actual source · 使用于 3 分钟前');
assert.equal(p.metadata({...entry,app:{...entry.app,lastOpenedAt:0}}),'来源：Actual source · 更新于 2 小时前');
assert.equal(p.usedAt(entry),'使用于 3 分钟前');
assert.equal(JSON.stringify(p.iconColor(entry,true)),JSON.stringify(p.iconColor({...entry,app:{...entry.app,title:'Renamed',lastOpenedAt:noon}},true)));
assert.equal(JSON.stringify(p.iconColor({...entry,app:{...entry.app,iconColor:'blue'}},true)),JSON.stringify(p.iconPalette('blue').background));
const duplicate={...entry,app:{...entry.app,id:'second',createdAt:2}};
p.entries.push(duplicate);assert.equal(p.displayTitle(entry),'Counter（1）');assert.equal(p.displayTitle(duplicate),'Counter（2）');
p.entries.reverse();assert.equal(p.displayTitle(entry),'Counter（1）','Recency reordering cannot swap same-name labels');
p.entries=p.entries.filter(item=>item!==duplicate);
assert.notEqual(p.entryKey(entry),p.entryKey(p.entries.find(item=>item.workspaceId==='other')),'Same app ID in different workspaces has different UI identity');
let calls=[];p.run=(action,label)=>{calls.push(label);return action();};p.open=async item=>calls.push('open:'+p.entryKey(item));
draw(p,'entryCard',entry);
const open=nodes.find(n=>n.id==='mini-app-open-project:same'), menu=nodes.find(n=>n.id==='mini-app-menu-project:same');
const nativeParent=node=>node.parent?.type==='If'?nativeParent(node.parent):node.parent;
assert.ok(open&&menu);assert.equal(nativeParent(open),nativeParent(menu),'Menu is a sibling, not nested inside the open button');
assert.equal(menu.onClick,undefined,'Showing the menu does not invoke Open');
assert.equal(menu.width,44);assert.equal(menu.height,44);
assert.equal(nodes.find(n=>n.type==='Text'&&n.value==='long description').maxLines,2);
assert.ok(nodes.some(n=>n.type==='Text'&&n.value==='来源：Actual source'));
assert.ok(nodes.some(n=>n.type==='Text'&&n.value==='使用于 3 分钟前'),'Source and time are independently readable');
const archived={workspaceId:'other',app:{...entry.app,archived:true}};
draw(p,'entryCard',archived);assert.ok(!nodes.some(n=>String(n.id).startsWith('mini-app-open-')));
assert.ok(nodes.some(n=>n.id==='mini-app-restore-other:same'));
draw(p,'entryMenu',entry);
const changeIcon=nodes.find(n=>n.id==='mini-app-change-icon-project:same');
assert.ok(changeIcon);changeIcon.onClick();assert.equal(p.choosingIcon,true);assert.equal(p.currentIcon,'default');
assert.equal(nodes.find(n=>n.id==='mini-app-remove-project:same').menuContent.danger,true);
assert.ok(!nodes.some(n=>String(n.id).startsWith('mini-app-rollback-')));
draw(p,'entryMenu',{...entry,app:{...entry.app,previousPage:{}}});
assert.ok(nodes.some(n=>n.id==='mini-app-rollback-project:same'));
p.error='failed';p.notice='Data is not migrated';draw(p,'feedback');
nodes.find(n=>n.compId==='mini-app-error').onAction();assert.equal(p.error,'');assert.equal(p.notice,'Data is not migrated');
nodes.find(n=>n.compId==='mini-app-notice').onAction();assert.equal(p.notice,'');
console.log('PASS real card/menu composition, archive actions, source labels, bounded descriptions and dismissible feedback');
const collection=panel();collection.entries=[entry];draw(collection,'collection');
const grid=nodes.find(n=>n.id==='mini-app-grid');
assert.deepEqual(JSON.parse(JSON.stringify(grid.value.columns)),{xs:1,sm:2,md:3,lg:4});
assert.equal(grid.value.breakpoints.reference,'component','Grid adapts to its panel, not the full window');
assert.ok(nodes.some(n=>n.id==='mini-app-open-project:same'));assert.ok(!nodes.some(n=>n.id==='mini-app-add-preview'));
const beforeIconKey=collection.lastKeys[0];collection.entries=[{...entry,app:{...entry.app,icon:'list'}}];draw(collection,'collection');
assert.notEqual(collection.lastKeys[0],beforeIconKey,'A new icon refreshes the emitted card without changing user data timestamps');
assert.ok(nodes.some(n=>n.type==='SymbolGlyph'&&JSON.stringify(n.value)===JSON.stringify(collection.iconSymbol('list'))));
const beforeColorKey=collection.lastKeys[0];collection.entries=[{...entry,app:{...entry.app,icon:'list',iconColor:'blue'}}];draw(collection,'collection');
assert.notEqual(collection.lastKeys[0],beforeColorKey,'Color-only changes refresh the card');
collection.availablePreviews=[{id:'preview'}];draw(collection,'collection');
const addPreview=nodes.find(n=>n.id==='mini-app-add-preview');assert.equal(addPreview.enabled,true);
addPreview.onClick();assert.equal(collection.adding,false,'Picker refreshes available previews before opening');
collection.availablePreviews=[{id:'preview'}];collection.app.busy=true;draw(collection,'collection');assert.equal(nodes.find(n=>n.id==='mini-app-add-preview').enabled,false);
collection.app.busy=false;collection.entries=[];draw(collection,'collection');assert.ok(nodes.some(n=>n.id==='mini-app-create-empty'));
collection.removed=true;draw(collection,'collection');assert.ok(!nodes.some(n=>n.id==='mini-app-create-empty'||n.id==='mini-app-add-preview'));
collection.availablePreviews=[];draw(collection,'previewPicker');assert.ok(nodes.some(n=>n.value==='添加后可从集合页重新打开。预览里的临时数据不会自动迁移。'));
console.log('PASS responsive tool grid, empty-state Create action, contextual preview action and advance data notice');
const iconPanel=panel(), styledEntry={...entry,app:{...entry.app,icon:'list',iconColor:'blue'}};
iconPanel.changeIcon(styledEntry);draw(iconPanel,'iconPicker');
const iconButtons=()=>nodes.filter(n=>iconPanel.iconChoices().some(choice=>n.id==='mini-app-icon-'+choice.id));
assert.equal(iconButtons().length,16);
assert.equal(JSON.stringify(nodes.find(n=>n.id==='mini-app-icon-list').backgroundColor),JSON.stringify(iconPanel.iconPalette('blue').background));
assert.equal(nodes.find(n=>n.id==='mini-app-icon-list').accessibilityText,'清单，已选中');
assert.equal(nodes.find(n=>n.id==='mini-app-color-blue').accessibilityText,'蓝色，已选中');
assert.equal(nodes.find(n=>n.id==='mini-app-icon-save').enabled,false,'Unchanged appearance needs no write');
let picked;iconPanel.run=action=>action();iconPanel.saveIcon=async()=>{picked=[iconPanel.currentIcon,iconPanel.currentIconColor];};
nodes.find(n=>n.id==='mini-app-icon-star').onClick();nodes.find(n=>n.id==='mini-app-color-rose').onClick();
assert.equal(picked,undefined,'Selecting icon and color only changes the draft');
assert.equal(iconPanel.currentIcon,'star');assert.equal(iconPanel.currentIconColor,'rose');
draw(iconPanel,'iconPicker');
assert.equal(JSON.stringify(nodes.find(n=>n.id==='mini-app-icon-preview').backgroundColor),JSON.stringify(iconPanel.iconPalette('rose').background));
const saveAppearance=nodes.find(n=>n.id==='mini-app-icon-save');assert.equal(saveAppearance.enabled,true);
nodes.find(n=>n.id==='mini-app-icon-cancel').onClick();assert.equal(iconPanel.choosingIcon,false);assert.equal(picked,undefined);
iconPanel.changeIcon(styledEntry);assert.equal(iconPanel.currentIcon,'list');assert.equal(iconPanel.currentIconColor,'blue','Cancel discards both draft selections');
iconPanel.currentIcon='star';iconPanel.currentIconColor='rose';
iconPanel.busy=true;draw(iconPanel,'iconPicker');
assert.ok(iconButtons().every(n=>n.enabled===false));
assert.ok(nodes.filter(n=>String(n.id).startsWith('mini-app-color-')).every(n=>n.enabled===false));
assert.equal(nodes.find(n=>n.id==='mini-app-icon-save').enabled,false);iconPanel.busy=false;
console.log('PASS icon/color catalog, draft preview, cancel, accessibility labels and busy state');
(async()=>{
  await saveAppearance.onClick();assert.deepEqual(picked,['star','rose'],'Save dispatches the selected icon and color together');
  await open.onClick();assert.deepEqual(calls,['正在打开「Counter」…','open:project:same']);
  const p=panel();let resolve, actions=0, add=[];
  p.availablePreviews=[{id:'preview'}];p.onCreateAvailable=value=>add.push(value);p.notice='Important data note';
  const running=p.run(()=>{actions++;return new Promise(done=>resolve=done);},'Opening Counter');
  assert.equal(p.busy,true);assert.equal(p.busyLabel,'Opening Counter');assert.equal(add.at(-1),false);
  await p.run(async()=>{actions++;});assert.equal(actions,1,'Repeated taps cannot launch a second action');
  resolve();await running;assert.equal(p.busy,false);assert.equal(add.at(-1),true);assert.equal(p.notice,'Important data note');
  await p.run(async()=>{throw Error('read failed');});assert.equal(p.error,'read failed');assert.equal(p.busy,false);
  let scans=0;p.previews=()=>{scans++;return [{id:'new'}];};p.refreshPreviews();assert.equal(scans,1);
  p.showPreviewPicker();assert.equal(scans,2);assert.equal(p.adding,true);
  p.app.busy=true;p.showPreviewPicker();assert.equal(scans,2,'Do not open a picker during generation');p.app.busy=false;
  p.previews=()=>[];p.refreshPreviews();assert.equal(add.at(-1),true,'Create is available without existing previews');
  let changes=[],bound=false;
  const repo={load:async()=>{},change:async(id,action)=>{changes.push([id,action]);return entry.app;},binding:()=>{bound=true;return {};}};
  p.apps=()=>({repository:workspace=>{assert.equal(workspace,'project');return repo;}});
  await p.run(()=>p.open(entry),'Opening');assert.equal(p.selected.workspaceId,'project');assert.equal(bound,true);assert.equal(add.at(-1),false);
  p.selected=undefined;p.mounted=false;bound=false;await p.open(entry);assert.equal(bound,false,'Late open cannot mount a web page after leaving');
  console.log('PASS async busy labels, duplicate-action guard, errors, preserved notices, preview availability and navigation lifecycle');
  const creator=panel();let completion,events=[];
  const run=creator.run.bind(creator);creator.run=(...args)=>(completion=run(...args));
  creator.app.newThread=async()=>{events.push('new');return true;};
  creator.app.setDraft=value=>events.push(value);creator.app.flushDraft=async()=>events.push('flush');creator.onChat=()=>events.push('chat');
  creator.createRequested();await completion;
  assert.deepEqual(events,['new','我想创建一个可以反复使用的小程序。请先和我确认用途，再开始制作。','flush','chat']);
  for(const state of [{busy:true},{mounted:false},{selected:entry},{app:{...creator.app,busy:true}},{app:{...creator.app,ready:false}}]){
    const guarded=Object.assign(panel(),state);guarded.run=()=>assert.fail('Blocked Create must not create a thread');guarded.createRequested();
  }
  events=[];creator.app.newThread=async()=>false;creator.app.error='cannot save';creator.createRequested();await completion;
  assert.equal(creator.error,'cannot save');assert.deepEqual(events,[],'Creation failure does not replace a draft or navigate');
  creator.app.newThread=async()=>true;creator.app.flushDraft=async()=>{throw Error('draft failed');};
  creator.createRequested();await completion;assert.equal(creator.error,'draft failed');assert.ok(!events.includes('chat'));
  console.log('PASS conversational Create, persisted draft before navigation, blocked states and observable failures');
  const iconSave=panel();let committed;
  iconSave.changeIcon(entry);iconSave.apps=()=>({repository:workspace=>{
    assert.equal(workspace,entry.workspaceId);return {setIcon:async(id,icon,color)=>{committed=[id,icon,color];}};
  }});iconSave.reload=async()=>{};iconSave.success=()=>{};
  iconSave.currentIcon='star';iconSave.currentIconColor='blue';
  await iconSave.run(()=>iconSave.saveIcon());assert.deepEqual(committed,[entry.app.id,'star','blue']);assert.equal(iconSave.choosingIcon,false);
  iconSave.changeIcon(entry);iconSave.apps=()=>({repository:()=>({setIcon:async()=>{throw Error('icon disk failure');}})});
  iconSave.currentIcon='clock';iconSave.currentIconColor='rose';await iconSave.run(()=>iconSave.saveIcon());
  assert.equal(iconSave.error,'icon disk failure');assert.equal(iconSave.choosingIcon,true,'Failed save keeps the picker open for retry');
  assert.equal(iconSave.currentIcon,'clock');assert.equal(iconSave.currentIconColor,'rose','Failed save retains both choices for retry');
  assert.equal(entry.app.icon,undefined);assert.equal(entry.app.iconColor,undefined,'Failed save does not change the committed card');
  console.log('PASS paired icon/color persistence, success dismissal and visible retryable save failures');
})().catch(error=>{console.error(error);process.exitCode=1;});
