// Exercise emitted ArkUI update callbacks while retaining ForEach rows by key.
// Method-only controller tests cannot detect stale objects captured by those rows.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
function renderer(name) {
  const input = path.join(root, 'entry/src/main/ets/views', name + '.ets');
  const built = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views', name + '.ts');
  assert.ok(fs.statSync(built).mtimeMs >= fs.statSync(input).mtimeMs, 'Build before rendering tests');
  const tree = ts.createSourceFile(built, fs.readFileSync(built, 'utf8'), ts.ScriptTarget.Latest, true);
  const klass = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  const methods = klass.members.filter(ts.isMethodDeclaration).map(n => n.getText(tree)).join('\n');
  let active = 0, next = 0;
  const observers = new Map(), branches = new Map(), rows = new Map(), children = new Map(), texts = new Map(), sheets = new Map(), buttons = new Map(), checks = new Map();
  const noop = () => {};
  const renderedItems = new Set();
  const element = kind => new Proxy({}, { get: (_, method) => {
    if (method === 'create' && kind === 'ListItem') return render => {
      if (render && !renderedItems.has(active)) { renderedItems.add(active); render(active, true); }
    };
    if (method === 'create' && kind === 'Text') return value => texts.set(active, value);
    if (method === 'createWithLabel') return value => buttons.set(active, value);
    if (kind === 'Checkbox' && (method === 'select' || method === 'onChange')) return value => {
      checks.set(active, { ...checks.get(active), [method]: value });
    };
    if (method === 'bindSheet') return (...args) => {
      const bindings = sheets.get(active) || []; bindings.push(args); sheets.set(active, bindings);
    };
    return noop;
  } });
  const globals = { exports: {}, console, Date, Math, Object, Map, Set, Error,
    ViewStackProcessor: { StartGetAccessRecordingFor: noop, StopGetAccessRecording: noop },
    gradientColor: () => '#FFFFFF', getLocale: () => 'zh-CN', panelRunTrigger: () => '手动触发', panelErrorText: text => text,
    t: (text, args = []) => text.replace(/\{(\d+)\}/g, (_, i) => args[i]), relativeTime: time => String(time),
    IconButton: class {}, ButtonType: {}, EdgeEffect: {}, Axis: {}, Color: {}, HitTestMode: {}, ScrollAlign: {}, Btn: {}, ViewPU: { create: noop }, ObservedObject: { GetRawObject: value => value }, referenceKey: item => item.workspaceId + '/' + item.panelId,
    LifePanelCard: class { constructor(parent, params, _storage, id) { children.set(id, { ...params }); } },
    LongPressGesture: element('gesture'), PanGesture: element('gesture'), GestureGroup: element('gesture'),
    GestureMode: {}, ScrollDirection: {}, BarState: {}, FontWeight: {}, FlexAlign: {}, TextAlign: {}, HorizontalAlign: {}, Alignment: {},
    GesturePriority: {}, GestureMask: {}, SheetSize: {}, Gesture: element('gesture') };
  for (const name of ['Column','Row','Scroll','Stack','Button','Blank','Text','TextInput','If','ForEach','Checkbox','List','ListItem','Refresh','SymbolGlyph']) globals[name] = element(name);
  vm.runInNewContext(ts.transpileModule('export class Probe {' + methods + '}', { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, globals);
  const view = new globals.exports.Probe();
  const invoke = (id, callback, initial) => { const previous = active; active = id; try { callback(id, initial); } finally { active = previous; } };
  Object.assign(view, {
    observeComponentCreation2(callback) { const id = ++next; observers.set(id, callback); invoke(id, callback, true); },
    ifElseBranchUpdateFunction(branch, build) { if (branches.get(active) !== branch) { branches.set(active, branch); build(); } },
    forEachUpdateFunction(id, items, build, key) {
      if (!rows.has(id)) rows.set(id, new Set());
      for (const [index,item] of items.entries()) { const k = key(item); if (!rows.get(id).has(k)) { rows.get(id).add(k); build(item,index); } }
    },
    updateStateVarsOfChildByElmtId(id, params) { if (children.has(id)) Object.assign(children.get(id), params); }
  });
  return { view, children, texts, sheets, buttons, checks, update() {
    for (const [id,callback] of [...observers]) invoke(id,callback,false);
  } };
}

const h = renderer('LifePanelsPanel'), p = h.view;
let running = false;
const first = { workspaceId:'workspace', panel:{id:'metric',configRevision:1,archived:false,refreshedAt:10,
  data:{total:42},runs:[],definition:{title:'Metric',size:'M',source:{type:'workspace-json'}}} };
Object.assign(p,{entries:[first],boards:[],boardSelection:'',selected:'',removed:false,error:'',pending:[],now:10,
  boardScroller:{scrollToIndex(){}},appearance:{},boardWidth:360,refreshing:false,cardHeights:{},dragging:'',dragX:0,dragY:0,creating:false,app:{ready:true,busy:false},sheetOpen:false,sheetKind:'',
  rect:()=>({x:0,y:0,width:360,height:180}),boardHeight:()=>180,
  panels:()=>({repository:()=>({isRefreshing:()=>running})})});
p.initialRender();
assert.equal(h.children.size,1);
const childId = [...h.children.keys()][0];
assert.equal(h.children.get(childId).panel.data.total,42);
p.entries=[{...first,panel:{...first.panel,data:{total:50},refreshedAt:20,user:{item:true}}}];
h.update();
assert.equal(h.children.size,1,'Data refresh must retain the existing card component');
assert.equal(h.children.get(childId).panel.data.total,50,'Retained card must receive current data');
assert.match(h.children.get(childId).timestamp,/20/);
assert.equal(h.children.get(childId).panel.user.item,true);
let refreshed;
p.refresh = entry => { refreshed = entry; };
h.children.get(childId).onRefresh();
assert.equal(refreshed.panel.data.total,50,'Retained event handlers must also use current records');
assert.equal(h.sheets.size,1,'A panel owns one sheet host');
for (const bindings of h.sheets.values()) assert.equal(bindings.length,2,'One binding per render, never four competing bindings');
let connectionChecks = 0;
const originalDetailChanged = p.detailChanged;
p.detailChanged = () => { connectionChecks++; };
[...h.sheets.values()][0].at(-1)[2].onDisappear();
assert.equal(connectionChecks, 1, 'Closing connection settings refreshes the detail connection status');
p.detailChanged = originalDetailChanged;
for (const kind of ['connection','board','pin','task']) { p.openSheet(kind); assert.equal(p.sheetKind,kind); assert.equal(p.sheetOpen,true); assert.ok(p.sheetTitle()); p.sheetOpen=false; }
console.log('PASS retained card renders refreshed data/time/user state without remounting; actions use current state; sheets share one host');

p.boards=[{workspaceId:'workspace',board:{id:'board',title:'Before',archived:false,items:[]}}];
h.update();
const boardButton=[...h.buttons].find(([,title])=>title==='Before')[0];
p.boards=[{...p.boards[0],board:{...p.boards[0].board,title:'After'}}];
h.update();
assert.equal(h.buttons.get(boardButton),'After','Retained board tab must reflect saved title');
p.pinEntry=first;p.pinPicker();
const checkbox=[...h.checks.keys()][0];
let pins=0;
p.pinOnBoard=(board,entry,present)=>{
  pins++;p.boards=[{...board,board:{...board.board,items:present?[{workspaceId:entry.workspaceId,panelId:entry.panel.id}]:[]}}];
};
h.checks.get(checkbox).onChange(true);h.update();
assert.equal(h.checks.get(checkbox).select,true);
h.checks.get(checkbox).onChange(false);h.update();
assert.equal(h.checks.get(checkbox).select,false);
assert.equal(pins,2,'Unpin in the same open sheet must use the updated board items');
console.log('PASS retained board title and pin/unpin checkbox update without reopening');

const receipt = renderer('PublishedPanelCard'), preview = receipt.view;
Object.assign(preview, { boards: [{workspaceId:'workspace',board:{id:'board',title:'Before',archived:false,items:[]}}],
  reference:{target:{workspaceId:'workspace',panelId:'metric'}}, boardTitle:'', error:'' });
preview.boardPicker();
const receiptCheck = [...receipt.checks.keys()][0];
let receiptPins = 0;
preview.pin = (board, present) => {
  receiptPins++; preview.boards = [{...board,board:{...board.board,title:'After',items:present?[{workspaceId:'workspace',panelId:'metric'}]:[]}}];
};
receipt.checks.get(receiptCheck).onChange(true); receipt.update();
assert.equal(receipt.checks.get(receiptCheck).select, true);
assert.ok([...receipt.texts.values()].includes('After'));
receipt.checks.get(receiptCheck).onChange(false); receipt.update();
assert.equal(receipt.checks.get(receiptCheck).select, false);
assert.equal(receiptPins, 2);
console.log('PASS chat preview pin/unpin and board title update while the sheet stays open');

const tasks = renderer('PanelTaskPanel'), task = tasks.view;
Object.assign(task,{entry:first,error:'',record:{definition:{title:'Metric',refreshMinutes:1,source:{type:'workspace-json'}},
  runs:[{id:'same-run',startedAt:1000,status:'running'}]},panels:()=>({repository:()=>({isRefreshing:()=>running})})});
running=true;task.initialRender();
const statusId=[...tasks.texts].find(([,text])=>text.startsWith('运行中'))[0];
task.record={...task.record,runs:[{id:'same-run',startedAt:1000,finishedAt:2000,status:'complete'}]};
running=false;tasks.update();
assert.match(tasks.texts.get(statusId),/^已完成/,'Same run id must update its retained status row');
assert.ok([...tasks.texts.values()].some(text=>text==='耗时 1 秒'));
task.record={...task.record,runs:[{id:'same-run',startedAt:1000,finishedAt:3000,status:'failed',error:'Source failed',failure:{stage:'read',code:'DATA_UNAVAILABLE'}}]};
tasks.update();
assert.match(tasks.texts.get(statusId),/^失败/);
assert.ok([...tasks.texts.values()].includes('Source failed'));
assert.ok([...tasks.texts.values()].includes('read · DATA_UNAVAILABLE'));
console.log('PASS retained task row updates running → complete/failed, duration and detailed error without reopening');
