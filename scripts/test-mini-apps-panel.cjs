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
    node.getText(indexTree).includes('miniAppAddAvailable')) titleActions=node.arguments[0].getText(indexTree);
  ts.forEachChild(node,findTitleActions);
}
findTitleActions(indexTree);assert.ok(titleActions,'Preview availability must update the native title menu');
const titleGlobals={exports:{},t,SymbolGlyphModifier:class{}};
vm.runInNewContext(compile('exports.items=function(){return '+titleActions+';}'),titleGlobals);
const host={miniAppAddAvailable:false,miniAppAddRequest:0,app:{busy:false}};
assert.equal(titleGlobals.exports.items.call(host).length,0);
host.miniAppAddAvailable=true;const titleItem=titleGlobals.exports.items.call(host)[0];
assert.equal(titleItem.isEnabled,true);titleItem.action();assert.equal(host.miniAppAddRequest,1);
host.app.busy=true;assert.equal(titleGlobals.exports.items.call(host)[0].isEnabled,false);
console.log('PASS native title action appears only for available previews and dispatches the picker request');

const src=path.join(root,'entry/src/main/ets/views/MiniAppsPanel.ets');
const built=path.join(root,'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MiniAppsPanel.ts');
assert.ok(fs.statSync(built).mtimeMs>=fs.statSync(src).mtimeMs,'Build before testing');
const tree=ts.createSourceFile(built,fs.readFileSync(built,'utf8'),ts.ScriptTarget.Latest,true);
const cls=tree.statements.find(n=>ts.isClassDeclaration(n)&&n.name.text==='MiniAppsPanel');
const methods=['run','owner','metadata','entryKey','displayTitle','count','open','restore','rename','saveName','back',
  'refreshPreviews','updateAddAvailable','showPreviewPicker','reload','success','cardContent','entryCard','entryMenu','feedback'];
const selected=cls.members.filter(n=>methods.includes(n.name?.getText(tree))); assert.equal(selected.length,methods.length);
const nodes=[], stack=[]; let current;
const ui = name => new Proxy({}, {get:(_,key)=>{
  if (key==='canRetake') return ()=>false;
  if (key==='create'||key==='createWithChild'||key==='createWithLabel') return value=>{
    const node={type:name,parent:stack.at(-1),value}; nodes.push(node);
    if(!['SymbolGlyph','Image','LoadingProgress','Blank'].includes(name)) stack.push(node);
    current=node;
    if(typeof value==='function') value();
  };
  if(key==='pop') return ()=>{stack.pop();current=stack.at(-1);};
  return value=>{ if(current) current[key]=value; };
}});
const globals={exports:{},t,relativeTime,Diagnostics:{log(){}},miniAppInCollection:()=>true,
  miniAppCanRollback:app=>!!app.previousPage,
  ViewPU:{create(){}},ViewStackProcessor:{visualState(){}},
  Banner:class{constructor(_parent,props){nodes.push({type:'Banner',...props});}}};
for(const name of ['Column','Row','Stack','Text','Button','Menu','MenuItem','If','Blank','SymbolGlyph','Image','LoadingProgress']) globals[name]=ui(name);
for(const name of ['Space','Radius','Btn','Alignment','ButtonType','FontWeight','HorizontalAlign','TextOverflow','Color','Visibility']) globals[name]={};
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
    mounted:true,busy:false,busyLabel:'',error:'',notice:'',entries:[],availablePreviews:[],now:noon,appearance:{},
    app:{busy:false,projects:[{workspaceId:'project',name:'Project'}],threads:[{id:'source',displayTitle:'Actual source'}]},
    onAddAvailable(){},previews:()=>[],previewPage:()=>({}),
    observeComponentCreation2(callback){callback(1,true);},ifElseBranchUpdateFunction(_branch,render){render();}
  });
}
function draw(p, method, entry){nodes.length=0;stack.length=0;current=undefined;p[method](entry);return nodes;}
const entry={workspaceId:'project',app:{id:'same',title:'Counter',description:'long description',sourceThreadId:'source',createdAt:1,updatedAt:noon-7200000,lastOpenedAt:noon-180000,archived:false}};
const p=panel();p.entries=[entry,{workspaceId:'other',app:{...entry.app,title:'Other',archived:true}}];
assert.equal(p.owner(entry),'Actual source'); assert.equal(p.count(false),1);assert.equal(p.count(true),1);
assert.equal(p.metadata(entry),'来源：Actual source · 使用于 3 分钟前');
assert.equal(p.metadata({...entry,app:{...entry.app,lastOpenedAt:0}}),'来源：Actual source · 更新于 2 小时前');
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
assert.equal(nodes.find(n=>n.type==='Text'&&n.value==='long description').maxLines,2);
const archived={workspaceId:'other',app:{...entry.app,archived:true}};
draw(p,'entryCard',archived);assert.ok(!nodes.some(n=>String(n.id).startsWith('mini-app-open-')));
assert.ok(nodes.some(n=>n.id==='mini-app-restore-other:same'));
draw(p,'entryMenu',entry);
assert.equal(nodes.find(n=>n.id==='mini-app-remove-project:same').menuContent.danger,true);
assert.ok(!nodes.some(n=>String(n.id).startsWith('mini-app-rollback-')));
draw(p,'entryMenu',{...entry,app:{...entry.app,previousPage:{}}});
assert.ok(nodes.some(n=>n.id==='mini-app-rollback-project:same'));
p.error='failed';p.notice='Data is not migrated';draw(p,'feedback');
nodes.find(n=>n.compId==='mini-app-error').onAction();assert.equal(p.error,'');assert.equal(p.notice,'Data is not migrated');
nodes.find(n=>n.compId==='mini-app-notice').onAction();assert.equal(p.notice,'');
console.log('PASS real card/menu composition, archive actions, source labels, bounded descriptions and dismissible feedback');
(async()=>{
  await open.onClick();assert.deepEqual(calls,['正在打开「Counter」…','open:project:same']);
  const p=panel();let resolve, actions=0, add=[];
  p.availablePreviews=[{id:'preview'}];p.onAddAvailable=value=>add.push(value);p.notice='Important data note';
  const running=p.run(()=>{actions++;return new Promise(done=>resolve=done);},'Opening Counter');
  assert.equal(p.busy,true);assert.equal(p.busyLabel,'Opening Counter');assert.equal(add.at(-1),false);
  await p.run(async()=>{actions++;});assert.equal(actions,1,'Repeated taps cannot launch a second action');
  resolve();await running;assert.equal(p.busy,false);assert.equal(add.at(-1),true);assert.equal(p.notice,'Important data note');
  await p.run(async()=>{throw Error('read failed');});assert.equal(p.error,'read failed');assert.equal(p.busy,false);
  let scans=0;p.previews=()=>{scans++;return [{id:'new'}];};p.refreshPreviews();assert.equal(scans,1);
  p.showPreviewPicker();assert.equal(scans,2);assert.equal(p.adding,true);
  p.app.busy=true;p.showPreviewPicker();assert.equal(scans,2,'Do not open a picker during generation');p.app.busy=false;
  p.previews=()=>[];p.refreshPreviews();assert.equal(add.at(-1),false,'No plus action without a preview');
  let changes=[],bound=false;
  const repo={load:async()=>{},change:async(id,action)=>{changes.push([id,action]);return entry.app;},binding:()=>{bound=true;return {};}};
  p.apps=()=>({repository:workspace=>{assert.equal(workspace,'project');return repo;}});
  await p.run(()=>p.open(entry),'Opening');assert.equal(p.selected.workspaceId,'project');assert.equal(bound,true);assert.equal(add.at(-1),false);
  p.selected=undefined;p.mounted=false;bound=false;await p.open(entry);assert.equal(bound,false,'Late open cannot mount a web page after leaving');
  console.log('PASS async busy labels, duplicate-action guard, errors, preserved notices, preview availability and navigation lifecycle');
})().catch(error=>{console.error(error);process.exitCode=1;});
