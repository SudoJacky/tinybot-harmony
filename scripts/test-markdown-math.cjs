const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(name, modules = {}) {
  const file = path.join(root, 'entry/src/main/ets', name + '.ets'), exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, setTimeout, clearTimeout,
    require: id => modules[id] || load(path.posix.join(path.posix.dirname(name), id), modules) });
  return exports;
}
const { markdownSpans, markdownBlocks, MarkdownDocument } = load('model/Markdown');
const { mathBitmapSize } = load('model/MathContent');
const plain = value => JSON.parse(JSON.stringify(value));
const math = text => plain(markdownSpans(text).filter(span => span.kind === 'math').map(span => span.text));
assert.deepEqual(math('质能 $E=mc^2$，以及 \\(a^2+b^2=c^2\\)。'), ['E=mc^2', 'a^2+b^2=c^2']);
assert.deepEqual(math('**结论 $x=2$ 成立**'), ['x=2']);
assert.deepEqual(math('括号允许空格 \\( x^2 \\)'), [' x^2 ']);
assert.deepEqual(math('价格 $5 和 $10，转义 \\$x\\$，`$code$`，``$other$``，[链接 $x$](https://example.com/$y$)'), []);
assert.deepEqual(math('$unfinished'), []);
assert.deepEqual(math('$2+2$ 与 $x_1$'), ['2+2', 'x_1']);
assert.deepEqual(math('$a*b*c$ 和 \\(\\text{use `code`}\\)'), ['a*b*c', '\\text{use `code`}']);
assert.deepEqual(math('$x$2'), []);
assert.deepEqual(math('`\\(code\\)`'), []);
assert.equal(markdownBlocks('```latex\n$$x$$\n```')[0].kind, 'code');
for (const source of ['$$x^2$$', '\\[x^2\\]', '$$\n\\frac{a}{b}\n$$', '\\[\n\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}\n\\]']) {
  assert.equal(markdownBlocks(source)[0].kind, 'math');
  const document = new MarkdownDocument(); let blocks = [];
  const full = '前文\n\n' + source + '\n\n尾部\n普通\n文本';
  for (let end = 0; end <= full.length; end++) {
    const update = document.update(full.slice(0, end)); blocks.splice(update.start, blocks.length - update.start, ...update.blocks);
    assert.deepEqual(plain(blocks), plain(markdownBlocks(full.slice(0, end))), 'stream boundary ' + end);
  }
  for (const replacement of ['', source, 'new', full]) {
    const update = document.update(replacement); blocks.splice(update.start, blocks.length - update.start, ...update.blocks);
    assert.deepEqual(plain(blocks), plain(markdownBlocks(replacement)));
  }
}
assert.equal(markdownBlocks('$$\nx\ny\nz')[0].kind, 'math-pending');
assert.deepEqual(plain(mathBitmapSize({ width: 8, height: 2, descent: .3 }, 56)), [448, 112]);
for (const dims of [[256, 1], [256, 48], [1, 48], [.002, .002]]) {
  const [width, height] = mathBitmapSize({ width: dims[0], height: dims[1], descent: 0 }, 120);
  assert.ok(width > 0 && height > 0 && Math.max(width, height) <= 8192 && width * height <= 2 * 1024 * 1024);
}
async function checkTypesetting() {
  const { typesetMath } = await import('../entry/src/main/ets/workers/MathEngine.js');
  const examples = ['E=mc^2', '\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}', '\\sum_{n=1}^{\\infty}\\frac{1}{n^2}=\\frac{\\pi^2}{6}',
    '\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}', '\\text{当 }x\\ge 0'];
  for (const tex of examples) {
    for (const display of [false, true]) {
      const { svg, width, height, descent } = typesetMath(tex, display, '#123456');
      assert.match(svg, /^<svg .*viewBox=/);
      assert.match(svg, /<path /);
      assert.match(svg, /fill="#123456"/);
      assert.ok(width > 0 && height > 0 && Number.isFinite(descent));
      assert.doesNotMatch(svg, /<script|<foreignObject|<use| href=/);
    }
  }
  assert.ok(typesetMath('\\frac{a}{b}', true, '#000000').height > typesetMath('\\frac{a}{b}', false, '#000000').height);
  const numbered = typesetMath('\\begin{align}a&=1\\tag{1}\\\\b&=2\\tag{2}\\end{align}', true, '#000000');
  assert.match(numbered.svg, /data-labels="true"/);
  assert.equal((numbered.svg.match(/<svg/g) || []).length, 1, 'equation numbers share the image viewBox');
  assert.match(typesetMath('x\\coloneqq 1', false, '#000000').svg, /<path /);
  assert.throws(() => typesetMath('\\frac{a}{', true, '#000000'));
  assert.throws(() => typesetMath('\\href{https://example.com}{x}', false, '#000000'));
  assert.throws(() => typesetMath('\\require{html}x', false, '#000000'));
  typesetMath('\\newcommand{\\tmp}{x}\\tmp', false, '#000000');
  assert.throws(() => typesetMath('\\tmp', false, '#000000'), 'macro definitions must stay inside the source formula');
  const tagged = typesetMath('\\newtagform{brackets}{[}{]}\\usetagform{brackets}x\\tag{5}', true, '#000000');
  assert.match(tagged.svg, /data-c="5B"/);
  assert.throws(() => typesetMath('\\usetagform{brackets}x\\tag{5}', true, '#000000'), { message: /Undefined tag form/ });
  if (global.gc) {
    global.gc();
    const before = process.memoryUsage().heapUsed;
    for (let i = 0; i < 400; i++) {
      typesetMath(`\\frac{${i}x^2+1}{x^2+1}+\\text{ for }x\\geq 0`, i % 3 === 0, '#123456');
    }
    global.gc();
    assert.ok(process.memoryUsage().heapUsed - before < 16 * 1024 * 1024, 'MathJax must release old TeX parsers');
  }
}
async function checkWorkerCache() {
  const posts = [];
  const removed = [];
  let thread;
  class ThreadWorker {
    constructor() { thread = this; }
    postMessage(job) { posts.push(job); }
    terminate() {}
    finish(bytes = 32) {
      const pixelMap = { release: async () => removed.push(pixelMap) };
      this.onmessage({ data: { bytes, width: 2, height: 1, descent: 0.2, pixelMap } });
    }
  }
  const { acquireCachedMath, acquireMath } = load('services/MathResources', {
    '@kit.ArkTS': { worker: { ThreadWorker } },
    '../model/Diagnostics': { Diagnostics: { log: () => {} } },
  });
  assert.equal(acquireCachedMath('a', false, '#000000', 56), undefined);
  assert.equal(posts.length, 0, 'cold first layout must not enqueue offscreen work');
  const first = acquireMath('a', false, '#000000', 56);
  const same = acquireMath('a', false, '#000000', 56);
  const offscreen = acquireMath('b', false, '#000000', 56);
  const cancelled = assert.rejects(offscreen.result, /cancelled/);
  offscreen.release();
  await cancelled;
  assert.deepEqual(posts.map(job => job.tex), ['a']);
  thread.finish();
  assert.equal((await first.result).pixelMap, (await same.result).pixelMap);
  first.release(); same.release();
  const reused = acquireCachedMath('a', false, '#000000', 56);
  assert.equal(reused.image, await first.result, 'warm first layout gets dimensions and the existing bitmap immediately');
  assert.equal((await reused.result).pixelMap, (await first.result).pixelMap);
  assert.equal(posts.length, 1, 'returning to a rendered formula reuses the image');
  reused.release();
  const display = acquireMath('a', true, '#000000', 56);
  const dark = acquireMath('a', true, '#ffffff', 56);
  assert.equal(posts.at(-1).display, true);
  thread.finish();
  assert.equal(posts.at(-1).color, '#ffffff');
  thread.finish();
  assert.notEqual((await display.result).pixelMap, (await dark.result).pixelMap);
  display.release(); dark.release();
  const larger = acquireMath('a', true, '#000000', 72);
  assert.equal(posts.at(-1).emPixels, 72);
  thread.finish();
  assert.notEqual((await larger.result).pixelMap, (await display.result).pixelMap);
  larger.release();

  const loaded = acquireMath('visible', false, '#000000', 56);
  thread.finish();
  await loaded.result;
  loaded.release();
  const pinned = acquireCachedMath('visible', false, '#000000', 56);
  const pinnedBitmap = (await pinned.result).pixelMap;
  for (let i = 0; i < 20; i++) {
    const unused = acquireMath('x_' + i, false, '#000000', 56);
    thread.finish(2 * 1024 * 1024);
    await unused.result;
    unused.release();
  }
  assert.ok(removed.length >= 4, 'cache releases evicted bitmaps when exceeding the byte budget');
  assert.ok(!removed.includes(pinnedBitmap), 'visible images remain pinned while the view uses them');
  pinned.release();
}

checkTypesetting().then(checkWorkerCache).then(() => {
  console.log('PASS Markdown formulas, offline SVG, isolated macros, Worker deduplication, cancellation and cache eviction');
}).catch(error => { console.error(error); process.exitCode = 1; });
