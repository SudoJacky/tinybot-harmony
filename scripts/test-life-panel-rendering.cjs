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
  const attributes = new Map();
  const noop = () => {};
  const renderedItems = new Set();
  const listScopes = new Map();
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
    return value => attributes.set(active, { ...attributes.get(active), kind, [method]: value });
  } });
  const globals = { exports: {}, console, Date, Math, Object, Map, Set, Error, Context: { animation: noop },
    ViewStackProcessor: { StartGetAccessRecordingFor: noop, StopGetAccessRecording: noop },
    gradientColor: () => '#FFFFFF', getLocale: () => 'zh-CN', resolvePanelInputs: (_definition, inputs) => inputs,
    panelRunTrigger: () => '手动触发', panelErrorText: text => text,
    t: (text, args = []) => text.replace(/\{(\d+)\}/g, (_, i) => args[i]), relativeTime: time => String(time),
    Motion:{rise:()=>({}),medium:180,fast:100,thumb:'spring',standard:'ease'},IconButton: class {}, ButtonType: {}, EdgeEffect: {}, Axis: {}, Color: {}, HitTestMode: {}, ScrollAlign: {}, Btn: {}, Radius: {}, TextOverflow: {}, VerticalAlign: {}, ViewPU: { create: noop }, ObservedObject: { GetRawObject: value => value }, referenceKey: item => item.workspaceId + '/' + item.panelId,
    LifePanelCard: class { constructor(parent, params, _storage, id) { children.set(id, { ...params }); } },
    WebUiView: class { constructor(parent, params, _storage, id) { children.set(id, { ...params }); } },
    Diagnostics: { log: noop }, systemInsets: async () => [0, 24],
    LongPressGesture: element('gesture'), PanGesture: element('gesture'), GestureGroup: element('gesture'),
    GestureMode: {}, ScrollDirection: {}, BarState: {}, FontWeight: {}, FlexAlign: {}, TextAlign: {}, HorizontalAlign: {}, Alignment: {},
    GesturePriority: {}, GestureMask: {}, GestureJudgeResult: { REJECT: 0, CONTINUE: 1 }, SheetSize: {}, Gesture: element('gesture') };
  for (const name of ['Column','Row','Scroll','Stack','Button','Blank','Text','TextInput','If','ForEach','Checkbox','List','ListItem','Refresh','SymbolGlyph','LoadingProgress','Menu','MenuItem','MenuItemGroup']) globals[name] = element(name);
  vm.runInNewContext(ts.transpileModule('export class Probe {' + methods + '}', { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText, globals);
  const view = new globals.exports.Probe();
  const invoke = (id, callback, initial) => { const previous = active; active = id; try { callback(id, initial); } finally { active = previous; } };
  Object.assign(view, {
    observeComponentCreation2(callback) { const id = ++next; observers.set(id, callback); invoke(id, callback, true); },
    ifElseBranchUpdateFunction(branch, build) { if (branches.get(active) !== branch) { branches.set(active, branch); build(); } },
    forEachUpdateFunction(id, items, build, key = item => JSON.stringify(item)) {
      if (!rows.has(id)) rows.set(id, new Set());
      if (!listScopes.has(id)) listScopes.set(id, new Map());
      const nextKeys = new Set(items.map(key)), scopes = listScopes.get(id);
      for (const previous of rows.get(id)) {
        if (nextKeys.has(previous)) continue;
        for (const child of scopes.get(previous) || []) {
          for (const map of [observers, branches, rows, children, texts, sheets, buttons, checks]) map.delete(child);
        }
        scopes.delete(previous); rows.get(id).delete(previous);
      }
      for (const [index,item] of items.entries()) { const k = key(item); if (!rows.get(id).has(k)) {
        rows.get(id).add(k); const start = next; build(item,index);
        scopes.set(k, Array.from({ length: next - start }, (_, offset) => start + offset + 1));
      } }
    },
    updateStateVarsOfChildByElmtId(id, params) { if (children.has(id)) Object.assign(children.get(id), params); }
  });
  return { view, children, texts, sheets, buttons, checks, attributes, globals, update() {
    for (const [id,callback] of [...observers]) if (observers.has(id)) invoke(id,callback,false);
  } };
}

const h = renderer('LifePanelsPanel'), p = h.view;
let running = false;
const first = { workspaceId:'workspace', panel:{id:'metric',configRevision:1,archived:false,refreshedAt:10,
  data:{total:42},runs:[],definition:{title:'Metric',size:'M',source:{type:'workspace-json'}}} };
const panelState={entries:[first],boards:[],boardSelection:'',selected:'',removed:false,error:'',pending:[],now:10,
  boardScroller:{scrollToIndex(){}},appearance:{},boardWidth:360,refreshing:false,cardHeights:{},dragging:'',resizing:'',dragBefore:'',cardQuery:'',dragX:0,dragY:0,creating:false,app:{ready:true,busy:false},sheetOpen:false,sheetKind:'',
  rect:()=>({x:0,y:0,width:360,height:180}),boardHeight:()=>180,
  panels:()=>({repository:()=>({isRefreshing:()=>running,binding:()=>undefined})})};
Object.assign(p,panelState);
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

for(const selected of ['', 'workspace/metric']) {
  const layout=renderer('LifePanelsPanel'),page=layout.view;
  const html={...first,panel:{...first.panel,definition:{...first.panel.definition,view:{height:320}}}};
  Object.assign(page,panelState,{selected,entries:[html],detailHeight:500,
    panels:()=>({repository:()=>({isRefreshing:()=>false,binding:(id,revision)=>({id,revision})})})});
  page.initialRender();const id=[...layout.children.keys()][0],storage=layout.children.get(id).storage;
  assert.equal(layout.children.get(id).cardSize,'M','Legacy cards use the definition size before user customization');
  assert.equal(layout.children.get(id).viewHeight, selected ? 500 : 0, 'Only expanded cards force a viewport height');
  for(const size of ['S','L','M']) {
    page.entries=[{...html,panel:{...html.panel,layout:{size}}}];layout.update();
    assert.equal(layout.children.size,1,'Layout changes retain both list and detail card instances');
    assert.equal(layout.children.get(id).cardSize,size,'Retained cards receive the new layout size');
    assert.equal(layout.children.get(id).storage,storage,'Resizing retains the valid storage binding and HTML session');
    assert.equal(layout.children.get(id).panel.configRevision,storage.revision);
  }
  page.boards=[{workspaceId:'workspace',board:{id:'layout',items:[{workspaceId:'workspace',panelId:'metric',size:'S'}]}}];
  page.boardSelection='workspace/layout';assert.equal(page.sizeOnBoard(page.entries[0]),'S','Board-specific dimensions take precedence');
  assert.equal(page.heightOnBoard(page.entries[0]),0,'Unresized board cards fit their content');
  page.boards[0].board.items[0].height=410;
  assert.equal(page.heightOnBoard(page.entries[0]),410,'Manual board height takes precedence over content height');
}
console.log('PASS layout resizing updates retained list/detail cards without replacing their HTML storage binding');

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
preview.pinTarget = { workspaceId: 'workspace', panelId: 'metric' };
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

const inline = renderer('PublishedPanelCard'), inlineView = inline.view;
const htmlEntry = { ...first, panel: { ...first.panel, definition: { ...first.panel.definition, view: { height: 280 } } } };
Object.assign(inlineView, { entries: [htmlEntry], reference: { target: { workspaceId: 'workspace', panelId: 'metric' } },
  appearance: {}, error: '', loading: false, pinOpen: false,
  panels: () => ({ repository: () => ({ binding: (id, revision) => ({ id, revision }), isRefreshing: () => false }) }) });
inlineView.initialRender();
const inlineId = [...inline.children.keys()][0], storage = inline.children.get(inlineId).storage;
const initialCard = inline.children.get(inlineId);
assert.equal(storage.id, 'metric'); assert.equal(storage.revision, 1);
assert.equal(inline.children.get(inlineId).interactive, false);
assert.equal(inline.children.get(inlineId).showFooter, false);
assert.equal(inline.children.get(inlineId).viewHeight, undefined, 'Chat previews use the card default content height');
assert.deepEqual([...inline.buttons.values()], ['固定到看板'], 'One pin action below a self-opening preview, with no duplicate open button');
inlineView.entries = [{ ...htmlEntry, panel: { ...htmlEntry.panel, data: { total: 88 } } }]; inline.update();
assert.equal(inline.children.size, 1); assert.equal(inline.children.get(inlineId).panel.data.total, 88);
assert.equal(inline.children.get(inlineId).storage, storage, 'Data updates retain the existing HTML session');
const changed = { ...htmlEntry, panel: { ...htmlEntry.panel, configRevision: 2 } };
inlineView.entries = [changed]; inline.update();
assert.ok([...inline.children.values()].some(child => child.storage.revision === 2), 'A new configuration gets a fresh revision-bound storage capability');

const card = renderer('LifePanelCard');
Object.assign(card.view, { ...initialCard, appearance: {}, dark: false, editing: false, detail: false, timestamp: '', viewHeight: 0 });
card.view.initialRender();
assert.equal(card.children.size, 1, 'The real card mounts its Web UI automatically');
assert.equal([...card.children.values()][0].storage, storage);
assert.ok(![...card.buttons.values()].includes('打开交互卡片'));
assert.ok(![...card.texts.values()].includes('生活看板'));
assert.ok(![...card.texts.values()].includes('Metric'), 'HTML supplies its own title without a native duplicate');
const web = [...card.children.values()][0];
assert.equal(JSON.parse(web.content).autoHeight,true,'Existing fixed-height HTML cards also shrink to content');
assert.equal(web.viewportHeight,0);
web.onHeight(192); assert.equal(card.view.contentHeight,192,'Resizing starts from the measured HTML content');
let opened=0; card.view.onOpen=()=>opened++;
const cardRoot = [...card.attributes.values()].find(a=>'bindContextMenu' in a);
cardRoot.onClick();
assert.equal(opened,1,'Noninteractive chat previews open when tapped');
const menuGesture={getTag:()=> 'panel-menu'};
assert.equal(cardRoot.onGestureRecognizerJudgeBegin({},menuGesture),0,'Preview taps and parent message gestures remain available');
card.view.interactive=true;card.view.timestamp='Updated just now';card.view.onRefresh=()=>opened++;
assert.equal(cardRoot.onGestureRecognizerJudgeBegin({},menuGesture),1,'Interactive HTML gets priority over Web text selection');
card.view.editing=true;
assert.equal(cardRoot.onGestureRecognizerJudgeBegin({},menuGesture),0,'Layout editing retains its drag gestures');
card.view.editing=false;
card.view.menu();
const menuItems=[...card.attributes.values()].filter(a=>a.kind==='MenuItem'&&a.create);
menuItems.find(a=>a.create.content==='展开卡片').onClick();
menuItems.find(a=>a.create.content==='刷新').onClick();
assert.equal(opened,3,'The HTML context menu exposes working open and refresh actions');
assert.ok([...card.attributes.values()].some(a=>a.kind==='MenuItemGroup'&&a.create?.footer==='Updated just now'));
const failed=renderer('LifePanelCard');
Object.assign(failed.view,{...initialCard,panel:{...initialCard.panel,runtimeError:'Broken script',error:'Network unavailable'},appearance:{},interactive:true,showFooter:true});
failed.view.initialRender();
assert.ok([...failed.texts.values()].includes('Broken script'));
assert.ok([...failed.texts.values()].includes('Network unavailable'),'Removing the frame must retain visible failure messages');
console.log('PASS published HTML cards mount real content automatically, retain data updates, replace edited configurations, and expose one pin action');

const tasks = renderer('PanelTaskPanel'), task = tasks.view;
Object.assign(task,{entry:first,error:'',record:{definition:{title:'Metric',refreshMinutes:1,source:{type:'workspace-json'}},
  runs:[{id:'same-run',startedAt:1000,status:'running'}]},panels:()=>({repository:()=>({isRefreshing:()=>running,binding:()=>undefined})})});
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

(async () => {
  const controller = renderer('PublishedPanelCard'), view = controller.view;
  const target = { workspaceId: 'workspace', panelId: 'metric' };
  let records = [
    { workspaceId: 'workspace', board: { id: 'one', title: 'One', archived: false, items: [target] } },
    { workspaceId: 'other', board: { id: 'two', title: 'Two', archived: false, items: [] } }
  ];
  let failPin = false, writes = 0;
  const store = {
    list: async () => JSON.parse(JSON.stringify(records)),
    get: async (workspaceId, id) => records.find(entry => entry.workspaceId === workspaceId && entry.board.id === id).board,
    save: async (workspaceId, _id, title) => {
      const board = { id: 'new', title, archived: false, items: [] }; records.push({ workspaceId, board }); return board;
    },
    pin: async (workspaceId, id, reference, present) => {
      writes++;
      if (failPin) throw Error('Injected pin write failure');
      const entry = records.find(entry => entry.workspaceId === workspaceId && entry.board.id === id);
      entry.board.items = entry.board.items.filter(item => item.workspaceId !== reference.workspaceId || item.panelId !== reference.panelId);
      if (present) entry.board.items.push(reference);
    }
  };
  controller.globals.LifeBoards = class { constructor() { return store; } };
  const loaded = [];
  Object.assign(view, { entries: [], mounted: true, generation: 0, loading: true, pinSaving: false, pinLoading: false,
    reference: { target }, root: () => '/app', getUIContext: () => ({}),
    panels: () => ({ repository: workspaceId => ({ get: async id => {
      loaded.push(workspaceId + '/' + id); return { ...htmlEntry.panel, id };
    } }) })
  });
  await view.reload(); assert.equal(view.entries.length, 1); assert.equal(view.loading, false);
  await view.openPicker(view.entries[0]);
  assert.equal(view.pinOpen, true); assert.equal(view.pinned('workspace/one'), true); assert.equal(view.pinned('other/two'), false);
  await view.pin(view.board('other/two'), true);
  assert.equal(view.pinned('workspace/one'), true); assert.equal(view.pinned('other/two'), true);
  await view.pin(view.board('workspace/one'), false);
  assert.equal(view.pinned('workspace/one'), false); assert.equal(view.pinned('other/two'), true);
  view.boardTitle = 'New'; await view.pin(); assert.equal(view.pinned('workspace/new'), true);
  failPin = true; await view.pin(view.board('other/two'), false);
  assert.match(view.pinError, /Injected pin write failure/); assert.equal(view.pinned('other/two'), true);
  assert.equal(view.pinSaving, false); failPin = false;
  view.pinSaving = true; const before = writes; await view.pin(view.board('other/two'), false); assert.equal(writes, before); view.pinSaving = false;
  // Board-only edits preview every current card, including cross-workspace references.
  records[0].board.items = [{ workspaceId: 'workspace', panelId: 'metric' }, { workspaceId: 'other', panelId: 'second' }];
  view.reference = { target: { workspaceId: 'workspace', boardId: 'one' } };
  await view.reload(); assert.equal(view.title, 'One'); assert.equal(view.entries.length, 2);
  assert.equal(view.entries[1].workspaceId, 'other'); assert.equal(view.entries[1].panel.id, 'second');
  await view.openPicker(view.entries[1]); assert.equal(view.pinTarget.panelId, 'second');
  records[0].board.items = []; await view.reload(); assert.equal(view.entries.length, 0);
  // An older asynchronous refresh must not replace a newer card snapshot.
  let finishOld;
  view.reference = { target };
  view.panels = () => ({ repository: () => ({ get: () => new Promise(resolve => { finishOld = resolve; }) }) });
  const oldReload = view.reload();
  view.panels = () => ({ repository: () => ({ get: async () => ({ ...htmlEntry.panel, data: { total: 99 } }) }) });
  await view.reload(); finishOld({ ...htmlEntry.panel, data: { total: 1 } }); await oldReload;
  assert.equal(view.entries[0].panel.data.total, 99);
  assert.ok(loaded.includes('other/second'));
  console.log('PASS preview loading, cross-workspace board contents, stale refresh rejection, multi-board pin/unpin, creation and visible failure recovery');
})().catch(error => { console.error(error); process.exitCode = 1; });
