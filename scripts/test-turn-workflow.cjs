// View-model regression checks; ArkUI rendering is verified separately on device.
// Run: node scripts/test-chat-disclosures.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {};
  cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(compiled, { exports, Observed: cls => cls,
    require: id => {
      if (!id.startsWith('.')) throw Error('Unexpected platform dependency: ' + id);
      return load(path.resolve(path.dirname(file), id));
    }
  }, { filename: file });
  return exports;
}

const { buildTimeline, turnPhase, workflowEntryState } = load(path.join(root, 'model/ProcessPresentation'));
const { MessageViewModel } = load(path.join(root, 'viewmodel/SessionViewModels'));
const { ChatViewModel } = load(path.join(root, 'viewmodel/ChatViewModel'));
const chat = new ChatViewModel();
const state = { phase: 'running', ready: true, acceptingSteering: true, error: '', saveError: '',
  contextStatus: '', contextTokens: 120, contextSource: 'estimate',
  contextBreakdown: [{ id: 'prompt', kind: 'message', tokens: 120, messageId: 'm', step: 0, name: 'Prompt' }] };
chat.project({ kind: 'state', state });
const contextItems = chat.contextItems;
for (let i = 0; i < 1000; i++) chat.project({ kind: 'reasoning', state: JSON.parse(JSON.stringify(state)) });
assert.equal(chat.contextItems, contextItems, 'Token snapshots retain equal observed context rows');
for (const [field, value] of Object.entries({ id: 'next', kind: 'tool', tokens: 121, messageId: 'n', step: 1, name: 'Tool' })) {
  const changed = JSON.parse(JSON.stringify(state)); changed.contextBreakdown[0][field] = value;
  chat.project({ kind: 'state', state: changed });
  assert.equal(chat.contextItems[0][field], value, 'Changed context field updates: ' + field);
  chat.project({ kind: 'state', state });
}
chat.project({ kind: 'state', state: { ...state, phase: 'idle', acceptingSteering: false, contextTokens: 0, contextBreakdown: [] } });
assert.equal(chat.contextItems.length, 0); assert.equal(chat.contextTokens, 0);
assert.equal(chat.generating, false); assert.equal(chat.acceptingSteering, false);
console.log('PASS stream snapshots retain equal context rows while projecting changed rows, tokens and run state');
const tool = (id, status = 'running') => ({ call: { id, type: 'function', function: { name: 'read_file', arguments: '{}' } }, status, output: '' });
const step = (content = '', tools = [], reasoningContent = '') => ({ content, tools, reasoningContent });
const steps = [];
assert.equal(turnPhase('generating', steps), 'waiting');
steps.push(step('', [], 'Plan'));
assert.equal(turnPhase('generating', steps), 'thinking');
steps[0].content = 'Read files'; steps[0].tools.push(tool('one'), tool('two', 'pending'));
assert.equal(turnPhase('generating', steps), 'tools');
steps[0].tools[0].status = 'complete';
assert.equal(turnPhase('generating', steps), 'tools', 'Pending sibling keeps the turn active');
steps[0].tools[1].status = 'complete';
assert.equal(turnPhase('generating', steps), 'waiting');
steps.push(step('', [], 'Check results'));
const group = buildTimeline(steps).find(e => e.kind === 'process' && e.items.some(i => i.tool >= 0));
assert.equal(workflowEntryState(group, steps, 'generating'), 'active', 'Group spanning two model steps tracks newest thought');
assert.equal(workflowEntryState(group, steps, 'stopped'), 'stopped');
steps[1].content = 'Answer';
assert.equal(turnPhase('generating', steps), 'answer');
assert.equal(workflowEntryState(group, steps, 'generating'), 'complete');
steps[0].tools[0].status = 'failed';
assert.equal(workflowEntryState(group, steps, 'complete'), 'failed', 'Recovered failures remain visible');
steps[0].tools[0].status = 'interrupted';
assert.equal(workflowEntryState(group, steps, 'complete'), 'stopped');
steps.push(step()); steps[2].retries = [{ waiting: true, attempt: 1, delayMs: 1000 }];
assert.equal(turnPhase('generating', steps), 'retry');
for (const status of ['stopped', 'failed', 'complete']) assert.equal(turnPhase(status, steps), status);

// Exercise the real stream projection methods, including first deltas that change
// grouping, long later thoughts, whitespace removal and a completed publication.
const streaming = new MessageViewModel({ id: 'stream', role: 'assistant', content: '', error: '', status: 'generating',
  steps: [step('', [], '')] });
streaming.updateReasoning(0, 'First thought');
assert.equal(streaming.timeline[0].items[0].tool, -1);
const thoughtTimeline = streaming.timeline;
for (let i = 0; i < 1000; i++) streaming.updateReasoning(0, 'First thought ' + i);
assert.equal(streaming.timeline, thoughtTimeline, 'Further thought deltas retain the derived timeline');
assert.equal(streaming.reasoningContent, 'First thought 999');
streaming.updateText('Narration', 0, 'Narration');
assert.equal(streaming.timeline.map(e => e.kind).join(','), 'process,text');
const narrationTimeline = streaming.timeline;
streaming.updateText('Narration continued', 0, 'Narration continued');
assert.equal(streaming.timeline, narrationTimeline);
streaming.updateText(' ', 0, ' ');
assert.equal(streaming.timeline.map(e => e.kind).join(','), 'process');
streaming.updateReasoning(0, ' '); assert.equal(streaming.timeline.length, 0);
const publication = { ...tool('published', 'complete'), previewContent: '```tinybot-ui\n' + 'x'.repeat(30000),
  call: { id: 'published', function: { name: 'publish_preview', arguments: '{}' } }, output: '{"path":"view.html","title":"View"}' };
streaming.update({ id: 'stream', role: 'assistant', content: '', error: '', status: 'generating', steps: [step('', [publication])] });
assert.equal(streaming.timeline.map(e => e.kind).join(','), 'text,process', 'Publication creates a text entry without narration');
console.log('PASS actual message projection caches streaming structure and refreshes first text/thought, removals and publication');

// Exercise the actual compiled view methods, including stale keyed-group callbacks and live completion.
const source = path.join(root, 'views/MessageBubble.ets');
const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/MessageBubble.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before testing');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'MessageBubble');
const methods = ['aboutToAppear', 'syncWorkflow', 'timeline', 'foldable', 'folded', 'entryVisible', 'traceState'];
const context = { exports: {}, ...load(path.join(root, 'model/ProcessPresentation')),
  stepDisplayContent: s => s.content, Motion: { standard: 'ease' } };
vm.runInNewContext(ts.transpileModule(`class Probe { ${component.members.filter(n => methods.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} } exports.Probe = Probe;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const messageData = { id: 'workflow', role: 'assistant', content: '', error: '', status: 'generating', steps: [step('', [tool('read')])] };
const message = new MessageViewModel(messageData);
const calls = [];
const probe = Object.assign(new context.exports.Probe(), { message, turnStatus: 'generating', workflowCollapsed: false,
  getUIContext: () => ({ animateTo: (options, update) => { calls.push(options); update(); } }) });
probe.aboutToAppear();
const capturedGroup = probe.timeline()[0];
messageData.steps[0].tools[0].status = 'complete';
messageData.steps.push(step('', [], 'Continue')); message.update(messageData);
assert.equal(probe.traceState(capturedGroup), 'active', 'Retained ForEach resolves live items');
messageData.steps[1].tools.push({ ...tool('preview', 'complete'), call: { id: 'preview', function: { name: 'publish_data_view', arguments: '{}' } } });
messageData.steps.push(step('Final answer'));
messageData.status = 'complete'; message.update(messageData); probe.turnStatus = 'complete'; probe.syncWorkflow();
assert.equal(probe.folded(), true); assert.equal(calls[0].duration, 280);
assert.equal(probe.entryVisible(capturedGroup, 0, probe.timeline().length), true, 'Published preview survives folding even in a retained group');
message.processOpen = true;
assert.equal(probe.folded(), false, 'Explicit reading survives completion');
probe.workflowCollapsed = true; message.status = probe.turnStatus = 'failed'; probe.syncWorkflow();
assert.equal(probe.folded(), false, 'Errors reopen a manually collapsed live trace');
probe.turnStatus = 'complete'; probe.aboutToAppear(); assert.equal(probe.settled, true, 'History initializes settled');
console.log('PASS turn workflow: actual phases, parallel tools, retry/stop/failure, retained groups, persistent preview, animated completion and manual reading');

// Opening the turn reveals sibling thought/tool rows, without another group toggle.
const processComponent = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ProcessGroup');
const processMethods = ['items', 'toolAt', 'richTools', 'thinkingNow', 'initialRender'];
let serial = 0, activeView, activeElement;
class RenderView {
  constructor() { this.effects = new Map(); this.branches = new Map(); this.lists = new Map(); this.texts = new Map(); this.rows = new Map(); this.children = new Map(); }
  observeComponentCreation2(fn) { const id = ++serial; this.effects.set(id, fn); activeView = this; activeElement = id; fn(id, true); }
  ifElseBranchUpdateFunction(branch, create) {
    const id = activeElement;
    if (this.branches.get(id) !== branch) { this.branches.set(id, branch); create(); }
  }
  forEachUpdateFunction(id, items, create, key) {
    const previous = this.lists.get(id) || new Set(), next = new Set();
    items.forEach(item => { const identity = key(item); next.add(identity); if (!previous.has(identity)) create(item); });
    this.lists.set(id, next);
  }
  updateStateVarsOfChildByElmtId(id, params) { Object.assign(this.children.get(id), params); }
  flush() { for (const [id, fn] of [...this.effects]) { activeView = this; activeElement = id; fn(id, false); } }
  static create(child) { child.parent.children.set(child.id, child); }
}
class Child {
  constructor(parent, params, _storage, id) { this.parent = parent; this.id = id; Object.assign(this, params); }
}
class ToolRow extends Child {}
class RichToolResult extends Child {}
class ThinkingDisclosure extends Child {}
const noUi = new Proxy({}, { get: () => () => {} });
const textUi = new Proxy({}, { get: (_target, name) => value => {
  const node = activeView.texts.get(activeElement) || {}; node[name] = value; activeView.texts.set(activeElement, node);
} });
Object.assign(context, { RenderView, ViewPU: RenderView, ToolRow, RichToolResult, ThinkingDisclosure, Column: noUi, ForEach: noUi, If: noUi,
  Text: textUi, HorizontalAlign: {}, CopyOptions: {}, Space: {}, t: text => text });
vm.runInNewContext(ts.transpileModule(`class ProcessProbe extends RenderView {
  ${processComponent.members.filter(n => processMethods.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')}
} exports.ProcessProbe = ProcessProbe;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const { DisclosureStore } = load(path.join(root, 'viewmodel/DisclosureState'));
const processData = { id: 'turn', role: 'assistant', content: '', error: '', status: 'generating', steps: [step('', [tool('one')], '思'.repeat(5100))] };
const processMessage = new MessageViewModel(processData);
function mountProcess(richOnly = false) {
  const view = Object.assign(new context.exports.ProcessProbe(), { message: processMessage, richOnly,
    groupKey: buildTimeline(processMessage.stepViews)[0].key, appearance: {}, onInspect() {} });
  view.initialRender(); return view;
}
const processView = mountProcess();
const firstThought = [...processView.children.values()].find(child => child instanceof ThinkingDisclosure);
assert.equal(firstThought.disclosure.open, false, 'Thought starts folded, like a tool row');
assert.equal(processView.texts.size, 0, 'No intermediate process group heading');
const firstTool = [...processView.children.values()].find(child => child instanceof ToolRow);
assert.equal(firstTool.execution.call.id, 'one', 'Tool row is visible without a group click');
assert.equal(firstTool.disclosure.open, false);
firstThought.disclosure.open = true; firstThought.disclosure.limit = 8000;
processData.steps[0] = step('', [{ ...tool('one', 'complete'), output: 'latest' }, tool('two', 'failed')], '最新思考');
processData.steps.push(step('', [], '下一步思考')); processMessage.update(processData);
processView.flush();
assert.equal(firstThought.content, '最新思考');
assert.equal(firstThought.disclosure.open, true, 'Live updates preserve an explicitly opened thought');
assert.equal([...processView.children.values()].find(child => child instanceof ToolRow && child.execution.call.id === 'one'), firstTool);
assert.equal(firstTool.execution.output, 'latest');
assert.equal([...processView.children.values()].filter(child => child instanceof ToolRow).length, 2);
const nextThought = [...processView.children.values()].find(child => child instanceof ThinkingDisclosure && child.identity === 'turn-1');
assert.equal(nextThought.content, '下一步思考'); assert.equal(nextThought.disclosure.open, false);
assert.equal(nextThought.streaming, true); assert.equal(firstThought.streaming, false);
const preview = tool('preview', 'complete'); preview.call.function.name = 'publish_data_view';
processData.steps[1].tools.push(preview); processMessage.update(processData);
const foldedView = mountProcess(true);
assert.equal(foldedView.texts.size, 0, 'Folding hides all ordinary process text');
assert.equal([...foldedView.children.values()].filter(child => child instanceof ToolRow).length, 0);
assert.equal([...foldedView.children.values()].filter(child => child instanceof ThinkingDisclosure).length, 0);
assert.equal([...foldedView.children.values()].filter(child => child instanceof RichToolResult).length, 1,
  'Published content remains available while the process is folded');

// The actual thought component handles its own compact toggle and bounded body.
const thoughtSource = path.join(root, 'views/ThinkingDisclosure.ets');
const thoughtEmitted = emitted.replace(/MessageBubble\.ts$/, 'ThinkingDisclosure.ts');
assert.ok(fs.statSync(thoughtEmitted).mtimeMs >= fs.statSync(thoughtSource).mtimeMs, 'Build thought component before testing');
const thoughtTree = ts.createSourceFile(thoughtEmitted, fs.readFileSync(thoughtEmitted, 'utf8'), ts.ScriptTarget.Latest, true);
const thoughtComponent = thoughtTree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ThinkingDisclosure');
const rowUi = new Proxy({}, { get: (_target, name) => value => {
  const node = activeView.rows.get(activeElement) || {}; node[name] = value; activeView.rows.set(activeElement, node);
} });
const transition = { combine() { return this; }, animation() { return this; } };
Object.assign(context, { Row: rowUi, Blank: noUi, Stack: noUi, SymbolGlyph: noUi, TextOverflow: {}, Alignment: {},
  Context: noUi, ThinkingLine: class extends Child {}, TransitionEffect: { OPACITY: transition, translate() {} } });
vm.runInNewContext(ts.transpileModule(`class ThoughtProbe extends RenderView {
  ${thoughtComponent.members.find(n => n.name?.getText(thoughtTree) === 'initialRender').getText(thoughtTree)}
} exports.ThoughtProbe = ThoughtProbe;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const thoughtDisclosure = new DisclosureStore().get('thought');
function mountThought() {
  const view = Object.assign(new context.exports.ThoughtProbe(), { content: '思'.repeat(5100), identity: 'thought', streaming: false,
    disclosure: thoughtDisclosure, appearance: {}, onInspect() {}, getUIContext: () => ({ animateTo: (_options, update) => update() }) });
  view.initialRender(); return view;
}
const thoughtView = mountThought();
const thoughtBody = () => [...thoughtView.texts.values()].find(node => node.id === 'thinking-content-thought');
const thoughtToggle = [...thoughtView.rows.values()].find(node => node.id === 'thinking-toggle-thought');
assert.equal(thoughtToggle.height, 32); assert.equal(thoughtBody(), undefined);
thoughtToggle.onClick(); thoughtView.flush();
assert.equal(thoughtDisclosure.open, true); assert.equal(thoughtBody().create.length, 4000);
[...thoughtView.texts.values()].find(node => node.id === 'thinking-more-thought').onClick(); thoughtView.flush();
assert.equal(thoughtBody().create.length, 5100);
thoughtView.content = '更新后的思考'; thoughtView.flush(); assert.equal(thoughtBody().create, '更新后的思考');
thoughtToggle.onClick(); thoughtView.flush(); assert.equal(thoughtDisclosure.open, false);
assert.ok(![...mountThought().texts.values()].some(node => node.id === 'thinking-content-thought'), 'Remount preserves explicit collapse');
thoughtToggle.onClick(); assert.equal(thoughtDisclosure.limit, 8000, 'Reopening retains the reading limit');
assert.ok([...mountThought().texts.values()].some(node => node.id === 'thinking-content-thought'), 'Remount preserves explicit expansion');
console.log('PASS process rows: sibling collapsed thought/tools, compact thought toggle/continuation, retained live rows, later steps and persistent results');

// Tool rows actually connect their execution state to the shared motion component.
const toolComponent = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'ToolRow');
const toolMethods = ['aboutToAppear', 'statusChanged', 'name', 'stat', 'initialRender'];
class MotionLine extends Child {}
Object.assign(context, { ThinkingLine: MotionLine, LoadingProgress: noUi, activeTool: execution => ['pending', 'running'].includes(execution.status),
  toolTitle: name => name, toolDetail: () => '', toolStat: () => '', toolStatusLabel: status => status, toolIcon: () => ({ id: 'tool-icon' }),
  t: (text, args = []) => text.replace(/\{(\d+)\}/g, (_match, index) => String(args[index])) });
vm.runInNewContext(ts.transpileModule(`class ToolProbe extends RenderView {
  ${toolComponent.members.filter(n => toolMethods.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')}
} exports.ToolProbe = ToolProbe;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, context);
const toolView = Object.assign(new context.exports.ToolProbe(), { execution: tool('animated'), appearance: {},
  disclosure: new DisclosureStore().get('tool'), glyphShift: 0, glyphOpacity: 1,
  getUIContext: () => ({ animateTo: (_options, update) => update() }) });
toolView.aboutToAppear(); toolView.initialRender();
const toolLine = [...toolView.children.values()].find(child => child instanceof MotionLine);
assert.equal(toolLine.working, true); assert.equal(toolLine.label, '正在read_file');
toolView.execution.status = 'complete'; toolView.statusChanged(); toolView.flush();
assert.equal(toolLine.working, false); assert.equal(toolLine.label, 'read_file');
assert.notEqual(toolLine.icon.id, 'tool-icon', 'Completed tool uses a completion mark');
toolView.execution.status = 'failed'; toolView.statusChanged(); toolView.flush();
assert.equal(toolLine.danger, true); assert.equal(toolLine.working, false);
toolView.execution.status = 'pending'; toolView.statusChanged(); toolView.flush();
assert.equal(toolLine.danger, false); assert.equal(toolLine.working, true);
assert.equal([...toolView.children.values()].find(child => child instanceof MotionLine), toolLine, 'Status updates retain the motion component');
console.log('PASS actual tool row motion: live title, completion mark, failure warning, pending state and retained component');
