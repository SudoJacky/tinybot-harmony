const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(file) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets', file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true }
  }).outputText, { exports, Observed: value => value, require: id => load(path.posix.normalize(path.posix.join(path.posix.dirname(file), id))) });
  return exports;
}
const { MarkdownDocument, markdownBlocks } = load('model/Markdown');
const { MarkdownChunkModel, MARKDOWN_CHUNK_BLOCKS } = load('viewmodel/MarkdownChunkModel');
const { StreamReveal } = load('model/StreamReveal');
const { highlightCode } = load('model/CodeHighlight');
const plain = value => JSON.parse(JSON.stringify(value));
// Compare against the existing full parser at every possible arrival boundary.
const documents = [
  '# 标题\r\n\r\n普通 **粗体** 和 `代码`🙂\n\n> 引用\n> 后续\n\n- [x] 完成\n  2. 嵌套\n---\n',
  '前文\n\n| Name | Value |\n| :--- | ---: |\n| A | 中文🙂 |\n\n尾部',
  '开头\n```ts\nconst x = 1;\n// 注释\n```\n尾部\n~~~py\nprint("你好")\n~~~',
  'A|B\n---|---\nx|y\n\n>quote\n\ntext\n\n',
  'A|B\n:---|---\nx|y\n'
];
for (const source of documents) {
  for (const chunk of [1, 2, 3, 7, 128]) {
    const document = new MarkdownDocument(); let blocks = [];
    for (let end = 0; end < source.length + chunk; end += chunk) {
      const text = source.slice(0, end), update = document.update(text);
      blocks.splice(update.start, blocks.length - update.start, ...update.blocks);
      assert.deepEqual(plain(blocks), plain(markdownBlocks(text)), `chunk ${chunk}, prefix ${end}: ${text}`);
    }
    for (const text of [source, source.slice(0, 6), '', 'replacement\n\n**new**', source]) {
      const update = document.update(text); blocks.splice(update.start, blocks.length - update.start, ...update.blocks);
      assert.deepEqual(plain(blocks), plain(markdownBlocks(text)), 'replacement/truncation/replay');
    }
  }
}
// Actual emitted ArkUI methods: exercise cache lifetime, clipped highlighting,
// streaming completion, code expansion, offscreen clocks and disposal.
function methods(file, name, names) {
  const source = path.join(root, 'entry/src/main/ets/views', file + '.ets');
  const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views', file + '.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build before renderer tests');
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === file);
  return `class ${name} { ${cls.members.filter(n => names.includes(n.name?.getText(tree))).map(n => n.getText(tree)).join('\n')} } exports.${name} = ${name};`;
}
let parseCalls = 0, highlightChars = 0, clock = 1000, timers = new Map(), nextTimer = 0;
const sandbox = { Diagnostics: load('model/Diagnostics').Diagnostics, exports: {}, StreamReveal, MarkdownDocument, MarkdownChunkModel, MARKDOWN_CHUNK_BLOCKS,
  markdownSpans: text => { parseCalls++; return load('model/Markdown').markdownSpans(text); },
  highlightCode: (text, language) => { highlightChars += text.length; return highlightCode(text, language); },
  NBSP: '\u00a0', CODE_PREVIEW_LINES: 18, Date: { now: () => clock },
  setTimeout: fn => { const id = ++nextTimer; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id) };
const areaCallbacks = [], visibilityCallbacks = [], placeholderHeights = [];
const noop = new Proxy({}, { get: () => () => {} });
const column = new Proxy({}, { get: (_target, key) => key === 'onAreaChange' ? fn => areaCallbacks.push(fn) : key === 'onVisibleAreaChange' ? (_thresholds, fn) => visibilityCallbacks.push(fn) : () => {} });
const blank = new Proxy({}, { get: (_target, key) => key === 'height' ? height => placeholderHeights.push(height) : () => {} });
Object.assign(sandbox, { Text: noop, ForEach: noop, Column: column, Blank: blank, HorizontalAlign: {}, Row: noop, SymbolGlyph: noop, Divider: noop, Scroll: noop, If: noop, Span: noop,
  CopyOptions: { LocalDevice: 1, None: 0 }, Space: {}, Radius: {}, Alignment: {}, BarState: {}, ScrollDirection: {}, Color: {}, FontWeight: {}, FontStyle: {}, TextDecorationType: {} });
const source = methods('MarkdownView', 'DocumentView', ['refresh', 'syncChunks', 'aboutToAppear', 'aboutToDisappear']) + '\n' +
  methods('MarkdownChunkView', 'BlockView', ['refresh', 'refreshCode', 'inlineSpans', 'proseText', 'prose', 'initialRender', 'invalidateMeasure', 'codeBlock', 'codeShown', 'codeLines', 'codeColor', 'revealColor', 'columnWidths', 'scheduleReveal', 'aboutToAppear', 'aboutToDisappear']) + '\n' + methods('ChatPanel', 'ChatLayout', ['messageAreaChanged']);
vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, sandbox);
const makeBlock = (block, animate = false) => Object.assign(new sandbox.exports.BlockView(), {
  model: new MarkdownChunkModel([block], animate), streaming: true, index: 0, mounted: false, visible: true,
  inlineCache: new Map(), highlighted: new Map(), tableWidths: [], reveal: new StreamReveal(), expanded: [], codeTokens: [], revealTimer: -1, copyTimer: -1
});
const paragraph = '普通 **粗体** `代码`🙂';
const row = makeBlock(markdownBlocks(paragraph)[0]); row.aboutToAppear();
const spans = row.inlineSpans(paragraph), calls = parseCalls;
assert.equal(row.inlineSpans(paragraph), spans); assert.equal(parseCalls, calls);
row.model.update(markdownBlocks(paragraph + '新')); clock += 10; row.refresh();
assert.equal(row.inlineSpans(paragraph + '新').map(x => x.text).join(''), '普通 粗体 \u00a0代码\u00a0🙂新');
assert.equal(row.reveal.active(clock), true);
clock += 64;
const fadingOpacity = row.reveal.spans('0', row.inlineSpans(paragraph + '新'), clock).at(-1).opacity;
row.streaming = false; row.refresh();
assert.equal(row.reveal.spans('0', row.inlineSpans(paragraph + '新'), clock).at(-1).opacity, fadingOpacity,
  'completion must preserve the final chunk fade instead of jumping to opaque');
assert.equal(row.reveal.active(clock), true); assert.equal(timers.size, 1);
let revealTicks = 0;
while (timers.size) {
  assert.ok(revealTicks++ < 20, 'completion must stop scheduling once the fade settles');
  const [id, tick] = timers.entries().next().value; timers.delete(id); clock += 16; tick();
}
assert.equal(row.reveal.spans('0', row.inlineSpans(paragraph + '新'), clock).at(-1).opacity, 1);
assert.equal(row.reveal.active(clock), false); assert.equal(row.revealTimer, -1);
row.streaming = true; row.visible = false; clock += 10; row.model.update(markdownBlocks(paragraph + '新尾')); row.refresh();
assert.equal(timers.size, 0, 'offscreen updates must not schedule reveal clocks');
const code = Array.from({ length: 2000 }, (_, i) => `const x${i} = ${i};`).join('\n');
const codeRow = makeBlock(markdownBlocks('```ts\n' + code + '\n```')[0]);
const beforeHighlight = highlightChars; codeRow.aboutToAppear();
const preview = code.split('\n').slice(0, 18).join('\n');
assert.equal(codeRow.codeTokens[0].map(x => x.text).join(''), preview);
assert.equal(highlightChars - beforeHighlight, preview.length);
codeRow.expanded = [0]; codeRow.refreshCode(); assert.equal(codeRow.codeTokens[0].map(x => x.text).join(''), code);
codeRow.expanded = []; codeRow.refreshCode(); assert.equal(codeRow.codeTokens[0].map(x => x.text).join(''), preview);
codeRow.model.update(markdownBlocks('prefix\n\n```ts\n' + code + '\n```')); codeRow.refresh();
assert.ok(codeRow.highlighted.has(1));
codeRow.model.update(markdownBlocks('only plain text')); codeRow.refresh(); assert.equal(codeRow.highlighted.size, 0, 'removed code must release retained highlight cache keys');
const documentView = Object.assign(new sandbox.exports.DocumentView(), { document: new MarkdownDocument(), blocks: [], chunks: [], mounted: false,
  renderTimer: -1, content: 'first\n\nsecond\n\nthird', streaming: true });
documentView.aboutToAppear(); const first = documentView.chunks[0], firstBlock = first.blocks[0];
documentView.content += ' grows\n\nfourth'; documentView.refresh();
assert.equal(documentView.chunks[0], first); assert.equal(first.blocks[0], firstBlock, 'stable prefix must retain its block identity');
assert.equal(documentView.blocks.length, 4);
documentView.content = ''; documentView.refresh(); assert.equal(documentView.chunks.length, 0);
// Stream through several group boundaries using the actual document view.
const longSource = (paragraph + '\n\n').repeat(100);
for (let end = 128; end < longSource.length + 128; end += 128) {
  documentView.content = longSource.slice(0, end); documentView.refresh();
  assert.deepEqual(plain(documentView.blocks), plain(markdownBlocks(documentView.content)));
  assert.ok(documentView.chunks.every(chunk => chunk.blocks.length <= MARKDOWN_CHUNK_BLOCKS));
  assert.deepEqual(plain(documentView.chunks.flatMap(chunk => chunk.blocks)), plain(documentView.blocks));
}
const stableGroup = documentView.chunks[0].blocks;
documentView.content += '\n\nlast'; documentView.refresh();
assert.equal(documentView.chunks[0].blocks, stableGroup, 'stable groups must not notify or invalidate their measured height');
// A one-shot answer mounts in bounded batches. Queued work always reads the
// newest document, stops on disposal, and resumes after reappearance.
const drainDocument = () => { let runs = 0; while (documentView.renderTimer !== -1) {
  assert.ok(runs++ < 100); const id = documentView.renderTimer, fn = timers.get(id); timers.delete(id); fn();
} };
documentView.content = ''; documentView.refresh(); drainDocument();
documentView.content = (paragraph + '\n\n').repeat(200); documentView.refresh();
assert.ok(documentView.chunks.flatMap(chunk => chunk.blocks).length <= 32);
assert.ok(documentView.renderTimer !== -1);
const pending = documentView.chunks.length;
documentView.streaming = false; documentView.refresh(); assert.equal(documentView.chunks.length, pending, 'completion must respect the current mount budget');
documentView.content += 'appended during batched rendering'; documentView.refresh(); drainDocument();
assert.deepEqual(plain(documentView.chunks.flatMap(chunk => chunk.blocks)), plain(markdownBlocks(documentView.content)));
documentView.content = (paragraph + '\n\n').repeat(300); documentView.refresh(); documentView.aboutToDisappear();
assert.equal(documentView.renderTimer, -1); const stopped = documentView.chunks.length;
documentView.aboutToAppear(); drainDocument(); assert.ok(documentView.chunks.length > stopped);
documentView.content = (paragraph + '\n\n').repeat(400); documentView.refresh();
assert.ok(documentView.renderTimer !== -1);
documentView.content = 'replacement while queued'; documentView.refresh(); drainDocument();
assert.equal(documentView.chunks.length, 1); assert.equal(documentView.chunks[0].blocks[0].text, documentView.content);
const layout = Object.assign(new sandbox.exports.ChatLayout(), { thread: { messages: [{ id: 'old' }, { id: 'new' }] }, follow: () => follows++ });
let follows = 0;
layout.messageAreaChanged('old', { height: 10 }, { height: 20 });
layout.messageAreaChanged('new', { height: 10 }, { height: 10 });
assert.equal(follows, 0);
layout.messageAreaChanged('new', { height: 10 }, { height: 20 }); assert.equal(follows, 1);
// Re-run retained callbacks, as ArkUI does. Builder arguments from the first
// call stay captured, so callbacks must resolve text from the current model.
const callbacks = [], rendered = [];
Object.assign(row, { appearance: {}, observeComponentCreation2: fn => { callbacks.push(fn); fn(1, true); },
  forEachUpdateFunction: (_id, spans) => rendered.push(spans), ifElseBranchUpdateFunction: (_id, fn) => fn() });
row.prose('STALE captured text', 16, false, {}, '0');
row.model.update(markdownBlocks('changed **bold** text')); row.refresh();
rendered.length = 0; callbacks.forEach(fn => fn(1, false));
assert.equal(rendered.at(-1).map(x => x.text).join(''), 'changed bold text', 'retained prose callback must display the complete current block');
row.model.update(markdownBlocks('Name|Value\n---|---\nA|initial')); row.refresh();
callbacks.length = 0; row.prose('STALE table cell', 14, false, {}, '0:1:1');
row.model.update(markdownBlocks('Name|Value\n---|---\nA|completed cell')); row.refresh();
rendered.length = 0; callbacks.forEach(fn => fn(1, false));
assert.equal(rendered.at(-1).map(x => x.text).join(''), 'completed cell');
// Test emitted mount/unmount branches and the exact-height spacer, including
// completion while offscreen and width/theme invalidation.
callbacks.length = 0; areaCallbacks.length = 0; row.visible = true; row.measuredHeight = 0; row.measuredWidth = 0;
const branches = []; row.ifElseBranchUpdateFunction = (id, fn) => { branches.push(id); fn(); };
row.initialRender(); const rootBranch = callbacks[1];
const outerArea = areaCallbacks.find(fn => fn.toString().includes('measuredWidth'));
const innerArea = areaCallbacks.find(fn => !fn.toString().includes('measuredWidth'));
innerArea({}, { width: 400, height: 120 }); outerArea({}, { width: 400, height: 120 });
visibilityCallbacks.at(-1)(false); rootBranch(1, false);
assert.equal(branches.at(-1), 1); assert.equal(placeholderHeights.at(-1), 120);
row.streaming = false; row.refresh(); assert.equal(row.measuredHeight, 120, 'completion must not remount all offscreen content');
row.invalidateMeasure(); assert.equal(row.measuredHeight, 0); rootBranch(1, false); assert.equal(branches.at(-1), 0);
areaCallbacks.at(-1)({}, { width: 400, height: 130 });
outerArea({}, { width: 500, height: 130 }); assert.equal(row.measuredHeight, 0, 'width change must remeasure');
row.measuredHeight = 130; row.model.update(markdownBlocks('new content')); row.refresh(); assert.equal(row.measuredHeight, 0);
visibilityCallbacks.at(-1)(true); row.aboutToDisappear(); codeRow.aboutToDisappear(); assert.equal(timers.size, 0);
sandbox.Diagnostics.start();
const same = { width: 400, height: 120 };
for (let index = 0; index < 1000; index++) { innerArea(same, same); layout.messageAreaChanged('old', same, same); }
let diagnostics = sandbox.Diagnostics.snapshot();
assert.equal(diagnostics.metrics.find(m => m.name === 'layout.chunkCallback').count, 1000);
assert.equal(diagnostics.metrics.find(m => m.name === 'layout.messageCallback').count, 1000);
assert.equal(diagnostics.events.filter(e => e.name.startsWith('layout.')).length, 0, 'Unchanged geometry must aggregate instead of flooding the timeline');
innerArea(same, { width: 400, height: 121 });
assert.equal(sandbox.Diagnostics.snapshot().events.filter(e => e.name === 'layout.chunk').length, 1);
documentView.content = 'diagnostic **render**'; documentView.refresh();
diagnostics = sandbox.Diagnostics.snapshot();
assert.ok(diagnostics.metrics.some(m => m.name === 'markdown.sourceChars' && m.max === documentView.content.length));
assert.ok(diagnostics.events.some(e => e.name === 'markdown.parse'));
sandbox.Diagnostics.stop();
console.log('PASS actual emitted layout callbacks aggregate unchanged geometry; changed geometry and document size survive in diagnostics');
console.log('PASS Markdown: all stream boundaries, tables/fences/CRLF/Unicode, replacement, stable groups, live render callbacks, span cache, code preview/expansion, exact-height offscreen release, remeasure, batched mount/cancel/resume and layout following');
