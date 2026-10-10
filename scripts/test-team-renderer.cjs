// Execute real DevEco-emitted callbacks with keyed ArkUI reuse; native painting needs a device.
// Run devecocli build first, then node scripts/test-team-renderer.cjs.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
const source = path.join(root, 'entry/src/main/ets/views/ChatTeamCard.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatTeamCard.ts');
if (!fs.existsSync(emitted) || fs.statSync(source).mtimeMs > fs.statSync(emitted).mtimeMs) throw Error('Build ChatTeamCard before this test.');
let serial = 0, currentView;
class Property {
  constructor(value) { this.value = value; }
  get() { return this.value; }
  set(value) { this.value = value; }
  reset(value) { this.value = value; }
}
class ViewPU {
  constructor(parent, storage, id) { this.parent = parent; this.id = id; this.effects = new Map(); this.childViews = new Map(); this.lists = new Map(); this.branches = new Map(); this.texts = new Map(); this.loadingMounts = 0; }
  finalizeConstruction() {}
  declareWatch() {}
  observeComponentCreation2(callback, component) { const id = ++serial; this.effects.set(id, callback); this.currentElmt = id; currentView = this; if (component === globals.LoadingProgress) this.loadingMounts++; callback(id, true); }
  forEachUpdateFunction(id, items, create, key) {
    const previous = this.lists.get(id) || new Set(), next = new Set();
    items.forEach((item, index) => { const identity = key ? key(item, index) : index + ':' + JSON.stringify(item); next.add(identity); if (!previous.has(identity)) create(item, index); });
    this.lists.set(id, next);
  }
  ifElseBranchUpdateFunction(branch, create) { const id = this.currentElmt; if (this.branches.get(id) !== branch) { this.branches.set(id, branch); create(); } }
  updateStateVarsOfChildByElmtId(id, params) { this.childViews.get(id).updateStateVars(params); }
  static create(child) { child.parent.childViews.set(child.id, child); child.aboutToAppear?.(); }
  flush() { for (const [id, effect] of [...this.effects]) { this.currentElmt = id; currentView = this; effect(id, false); } }
}
class Child extends ViewPU {
  constructor(parent, params, storage, id) { super(parent, storage, id); Object.assign(this, params); }
  updateStateVars(params) { Object.assign(this, params); }
}
class MarkdownView extends Child {}
class TeamMemberAvatar extends Child {}
class ToolReceipt extends Child {}
const disclosureExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/viewmodel/DisclosureState.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
}).outputText, {exports: disclosureExports, Observed: cls => cls});
const noUi = () => new Proxy({}, { get: () => () => {} });
const globals = { exports: {}, ViewPU, SynchedPropertyNesedObjectPU: Property, SynchedPropertySimpleOneWayPU: Property,
  SynchedPropertyObjectOneWayPU: Property,
  ObservedPropertySimplePU: Property, ObservedPropertyObjectPU: Property,
  ObservedObject: { GetRawObject: value => value },
  makeBuilderParameterProxy: (name, getters) => new Proxy({}, { get: (_, key) => getters[key]() }),
  TransitionEffect: { OPACITY: { combine() { return this; } }, translate() {} },
  require: id => {
    if (id.includes('I18n&')) return { t: text => text };
    if (id.includes('Team&')) return { teamStatus: status => status };
    if (id.includes('Theme&')) return { Font: {}, Motion: {}, Radius: {}, Space: {}, compactNumber: String };
    if (id.includes('MarkdownView&')) return { MarkdownView };
    if (id.includes('TeamMemberAvatar&')) return { TeamMemberAvatar };
    if (id.includes('ToolReceipt&')) return { ToolReceipt };
    if (id.includes('DisclosureState&')) return disclosureExports;
    if (id.includes('/model/ToolPresentation&')) return loadModel('model/ToolPresentation');
    if (id.includes('/model/ToolDetailContent&')) return loadModel('model/ToolDetailContent');
    if (id.includes('/services/Attachments&')) return { Attachments: { path: () => { throw Error('Unexpected file access'); } } };
    if (id.includes('/views/DataViewCard&')) return { DataViewCard: Child };
    if (id === '@ohos:arkui.node') return { LengthMetrics: { vp: n => n } };
    throw Error('Unexpected dependency ' + id);
  }
};
for (const name of ['Column','Row','Stack','Text','SymbolGlyph','LoadingProgress','Progress','Divider','If','ForEach','Flex','Button','Scroll','Image']) globals[name] = noUi();
globals.Text = new Proxy({}, { get: (_, name) => name === 'create' ? text => currentView.texts.set(currentView.currentElmt, text) : () => {} });
for (const name of ['FlexAlign','HorizontalAlign','VerticalAlign','FontWeight','TextOverflow','CopyOptions','FlexWrap','ProgressType','WordBreak','Color','ButtonType','Alignment','BarState','ImageFit']) globals[name] = {};
globals.Scroller = class { scrollTo() {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(emitted, 'utf8') + '\nexport { ChatTeamRun };', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, globals, { filename: emitted });
const { ChatTeamRun } = globals.exports;
function seed() {
  return { id: 'run', status: 'running', goal: 'test', error: '', planning: {steps:[]}, members: [{id:'worker',name:'Lin'}], tasks: [{
    task: {id:'task',memberId:'worker',title:'Inspect',instructions:'Read files',dependencies:[]}, status:'running', attempts:[{
      id:'attempt', status:'running', startedAt:1, error:'', turn:{content:'first chunk', steps:[{content:'first chunk',tools:[{
        call:{id:'call',function:{name:'read_file',arguments:'{}'}},status:'running',output:'first result'
      }]}]}
    }]
  }] };
}
function mount(expanded = true, run = seed()) {
  const app = {teams:[run],busy:true}; const view = new ChatTeamRun(null, {app,runId:'run'});
  view.aboutToAppear(); view.expanded = expanded; view.expandedTasks = ['task']; view.expandedLogs = ['attempt']; view.expandedBriefs = ['task']; view.initialRender();
  return {app,view};
}
function update(fixture, change) { const next = JSON.parse(JSON.stringify(fixture.app.teams[0])); change(next); fixture.app.teams = [next]; fixture.view.flush(); }
let failures = 0;
function test(name, run) { try { run(); console.log('PASS '+name); } catch (error) { failures++; console.error('FAIL '+name+'\n'+error.stack); } }
test('worker chunks preserve avatar, Markdown and loading component instances', () => {
  const f=mount(), children=[...f.view.childViews.values()], mounts=f.view.loadingMounts;
  for(let i=0;i<10;i++) update(f, run=>{const attempt=run.tasks[0].attempts[0];attempt.turn.content+=' chunk';attempt.turn.steps[0].content+=' chunk';attempt.turn.steps[0].tools[0].output+=' result';});
  assert.equal(f.view.childViews.size,children.length,'streaming must not remount task/attempt children');
  children.forEach(child=>assert.equal(f.view.childViews.get(child.id),child));
  assert.equal(f.view.loadingMounts,mounts,'streaming must not restart loading animations');
  assert.equal(children.find(v=>v instanceof MarkdownView).content,f.app.teams[0].tasks[0].attempts[0].turn.content);
  assert.equal(children.find(v=>v instanceof ToolReceipt).execution.output,f.app.teams[0].tasks[0].attempts[0].turn.steps[0].tools[0].output,'tool output must update through retained rows');
  assert.deepEqual(f.view.expandedTasks,['task']);assert.deepEqual(f.view.expandedLogs,['attempt']);
});
test('completion reaches retained avatars and task status', () => {
  const f=mount(), avatars=[...f.view.childViews.values()].filter(v=>v instanceof TeamMemberAvatar);
  update(f, run=>{run.status='completed';run.tasks[0].status='succeeded';const a=run.tasks[0].attempts[0];a.status='succeeded';a.finishedAt=100; a.turn.steps[0].tools[0].status='complete';});
  assert.equal([...f.view.childViews.values()].filter(v=>v instanceof TeamMemberAvatar).length,avatars.length);
  assert.equal(avatars[0].busy,false);assert.equal(avatars[0].ring,false);
  assert.ok([...f.view.texts.values()].some(text=>String(text).includes('Lin · succeeded')));
});
test('collapsed team updates busy rings and member names without remounting portraits', () => {
  const f=mount(false), avatar=[...f.view.childViews.values()][0];
  update(f, run=>{run.members[0].name='Updated name';run.tasks[0].status='succeeded';});
  assert.equal(f.view.childViews.size,1);assert.equal(avatar.busy,false);assert.equal(avatar.label,'Updated name');
});
test('one worker streams without rebuilding another worker row', () => {
  const run=seed();const other=JSON.parse(JSON.stringify(run.tasks[0]));other.task.id='other-task';other.task.memberId='other-worker';other.attempts[0].id='other-attempt';
  run.members.push({id:'other-worker',name:'Other'});run.tasks.push(other);
  const f=mount(true,run), avatars=[...f.view.childViews.values()].filter(v=>v instanceof TeamMemberAvatar), count=f.view.childViews.size, mounts=f.view.loadingMounts;
  update(f, next=>{next.tasks[0].attempts[0].turn.content='new output';});
  assert.equal(f.view.childViews.size,count);assert.equal(f.view.loadingMounts,mounts);
  avatars.forEach(avatar=>assert.equal(f.view.childViews.get(avatar.id),avatar));
});
test('new tool steps and retry attempts append without resetting existing output', () => {
  const f=mount(), children=[...f.view.childViews.values()], mounts=f.view.loadingMounts;
  update(f, run=>{run.tasks[0].attempts[0].turn.steps.push({content:'next step',tools:[{call:{id:'next-call',function:{name:'read_file',arguments:'{}'}},status:'running',output:'next result'}]});});
  assert.equal(f.view.childViews.size,children.length+1);assert.equal(f.view.loadingMounts,mounts);
  const nextTool=[...f.view.childViews.values()].find(v=>v instanceof ToolReceipt && v.execution.call.id==='next-call');
  assert.equal(nextTool.execution.output,'next result');
  update(f, run=>{run.tasks[0].attempts[0].turn.steps[1].tools[0].output='updated next result';});
  assert.equal(f.view.loadingMounts,mounts);assert.equal(nextTool.execution.output,'updated next result');
  update(f, run=>{const previous=run.tasks[0].attempts[0];previous.status='failed';const retry=JSON.parse(JSON.stringify(previous));retry.id='retry';retry.status='running';retry.turn.content='retry output';retry.turn.steps=[];run.tasks[0].attempts.push(retry);});
  assert.equal(f.view.childViews.size,children.length+2);children.forEach(child=>assert.equal(f.view.childViews.get(child.id),child));
  const retry=[...f.view.childViews.values()].at(-1);assert.equal(retry.content,'retry output');
  update(f, run=>{run.tasks[0].attempts[1].turn.content='retry finished';});
  assert.equal(retry.content,'retry finished');assert.equal(f.view.childViews.size,children.length+2);
});
test('Team receipts retain reading state while same call IDs in retries are isolated', () => {
  const f=mount(), receipt=[...f.view.childViews.values()].find(v=>v instanceof ToolReceipt);
  receipt.disclosure.open=true;receipt.disclosure.detailTab='raw';receipt.disclosure.detailPage=2;
  update(f, run=>{run.tasks[0].attempts[0].turn.steps[0].tools[0].status='complete';});
  assert.equal(receipt.execution.status,'complete');assert.equal(receipt.disclosure.open,true);assert.equal(receipt.disclosure.detailPage,2);
  update(f, run=>{const retry=JSON.parse(JSON.stringify(run.tasks[0].attempts[0]));retry.id='retry';run.tasks[0].attempts.push(retry);});
  const a=f.view.disclosures.get('attempt:0:call'),b=f.view.disclosures.get('retry:0:call');
  assert.equal(a,receipt.disclosure);assert.notEqual(a,b);assert.equal(b.open,false);
});
const modelCache = new Map();
function loadModel(name) {
  const file=path.resolve(root,'entry/src/main/ets',name+'.ets');
  if(modelCache.has(file))return modelCache.get(file);
  const exports={};modelCache.set(file,exports);
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,
    {exports,require:id=>id.endsWith('/I18n')?{t:text=>text}:loadModel(path.relative(path.join(root,'entry/src/main/ets'),path.resolve(path.dirname(file),id))) });
  return exports;
}
function loadView(name) {
  const file=path.join(path.dirname(emitted),name+'.ts'), source=path.join(root,'entry/src/main/ets/views',name+'.ets');
  if(fs.statSync(source).mtimeMs>fs.statSync(file).mtimeMs)throw Error('Rebuild '+name+' before this test.');
  const context={...globals,exports:{}};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText,context);
  return context.exports[name];
}
test('expanded result sections and rows update without stale ForEach captures', () => {
  const ToolDetails=loadView('ToolDetails'),disclosure=new disclosureExports.DisclosureState();
  const args={disclosure,name:'execute_code',argumentsText:'{"code":"return 1"}',output:'{"result":{"value":1}}',status:'complete',identity:'call'};
  const view=new ToolDetails(null,args);view.aboutToAppear();view.initialRender();
  const section=[...view.childViews.values()][0];section.initialRender();
  assert.ok([...section.texts.values()].includes('1'));
  view.updateStateVars({...args,output:'{"result":{"value":2}}'});view.refresh();view.flush();section.flush();
  assert.equal([...view.childViews.values()][0],section);assert.ok([...section.texts.values()].includes('2'));
  assert.ok(![...section.texts.values()].includes('1'),'retained result fields must display the latest receipt');
  view.select('input');assert.equal(view.pages[0].body,'return 1');view.select('raw');assert.ok(view.pages.some(page=>page.body.includes('2')));
});
test('orchestration child snapshots refresh retained receipt rows', () => {
  const Receipts=loadView('OrchestrationReceipts'),initial=seed().tasks[0].attempts[0].turn.steps[0].tools[0];
  const view=new Receipts(null,{children:[initial],disclosures:new disclosureExports.DisclosureStore()});view.initialRender();
  const child=[...view.childViews.values()][0];child.disclosure.open=true;
  view.updateStateVars({children:[{...initial,status:'complete',output:'final child result'}]});view.flush();
  assert.equal([...view.childViews.values()][0],child);assert.equal(child.execution.output,'final child result');assert.equal(child.execution.status,'complete');assert.equal(child.disclosure.open,true);
});
if(failures)process.exitCode=1;
