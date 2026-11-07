const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(name) {
  const file = path.join(root, 'entry/src/main/ets', name + '.ets'), exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, require: id => load(path.posix.join(path.posix.dirname(name), id)) });
  return exports;
}
const { markdownSpans, markdownBlocks, MarkdownDocument } = load('model/Markdown');
const { hasMath, mathHost } = load('model/MathContent');
const plain = value => JSON.parse(JSON.stringify(value));
const math = text => plain(markdownSpans(text).filter(span => span.kind === 'math').map(span => span.text));
assert.deepEqual(math('质能 $E=mc^2$，以及 \\(a^2+b^2=c^2\\)。'), ['E=mc^2', 'a^2+b^2=c^2']);
assert.deepEqual(math('**结论 $x=2$ 成立**'), ['x=2']);
assert.deepEqual(math('括号允许空格 \\( x^2 \\)'), [' x^2 ']);
assert.deepEqual(math('价格 $5 和 $10，转义 \\$x\\$，`$code$`，``$other$``，[链接 $x$](https://example.com/$y$)'), []);
assert.equal(hasMath('$unfinished'), false);
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
const assets = path.join(root, 'entry/src/main/resources/rawfile/math');
const katex = require(path.join(assets, 'katex.min.js'));
for (const tex of ['E=mc^2', '\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}', '\\sum_{n=1}^{\\infty}\\frac{1}{n^2}=\\frac{\\pi^2}{6}', '\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}']) {
  const html = katex.renderToString(tex, { displayMode: true, trust: false });
  assert.match(html, /katex-html/); assert.match(html, /<math/);
}
const css = fs.readFileSync(path.join(assets, 'katex.min.css'), 'utf8');
assert.ok((css.match(/@font-face/g) || []).length > 10, 'all font-face rules must survive bundling');
assert.match(css, /\.katex\{/);
assert.ok([...css.matchAll(/url\(([^)]+)\)/g)].every(match => match[1].startsWith('data:font/woff2;base64,')));
const host = mathHost(fs.readFileSync(path.join(assets, 'katex.min.js'), 'utf8'), css, fs.readFileSync(path.join(assets, 'host.js'), 'utf8'));
assert.match(host, /Content-Security-Policy/);
assert.doesNotMatch(host, /<script[^>]+src=/);
console.log('PASS formula delimiters, currency/escapes/code/links, display matrices, every stream boundary/replacement, offline KaTeX/fonts');
