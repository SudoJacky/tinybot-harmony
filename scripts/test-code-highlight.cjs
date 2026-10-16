// Exercise the native lexer without an emulator. Run with DEVECO_STUDIO_HOME set if needed.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(name) {
  const file = path.resolve(__dirname, '../entry/src/main/ets/model', name + '.ets'), exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports }, { filename: file });
  return exports;
}
const { highlightCode } = load('CodeHighlight');
const { StreamReveal } = load('StreamReveal');
const has = (spans, text, kind) => assert.ok(spans.some(s => s.text.includes(text) && s.kind === 'syntax-' + kind), `${text}: ${kind}`);
const cases = [
  ['ts', 'const answer = call("hello \\"world\\""); // comment\nreturn true;', [['const', 'keyword'], ['call', 'function'], ['// comment', 'comment'], ['true', 'number']]],
  ['arkts', '@Component struct Demo { value: number = 42; }', [['42', 'number']]],
  ['py', '# class Fake\ndef hello():\n  return "hi"', [['# class Fake', 'comment'], ['def', 'keyword'], ['hello', 'function'], ['"hi"', 'string']]],
  ['python', 'value = """first\n# still a string\nlast"""', [['# still a string', 'string']]],
  ['json', '{"name": "value", "ok": true, "count": 12}', [['"name"', 'property'], ['"value"', 'string'], ['true', 'number']]],
  ['jsonc', '{/* comment */"x": 1}', [['/* comment */', 'comment']]],
  ['sh', '#!/bin/sh\nif true; then echo "hi"; fi', [['#!/bin/sh', 'comment'], ['then', 'keyword']]],
  ['sql', "SELECT * FROM users WHERE name = 'it''s ok'; -- comment", [['SELECT', 'keyword'], ["'it''s ok'", 'string'], ['-- comment', 'comment']]],
  ['rust', 'pub fn run() { let value = 0xff; /* hi\nthere */ }', [['pub', 'keyword'], ['run', 'function'], ['0xff', 'number'], ['/* hi\nthere */', 'comment']]],
  ['yaml', 'name: "value"\nenabled: true # hi', [['name', 'property'], ['true', 'number'], ['# hi', 'comment']]],
  ['html', '<!-- hi -->\n<div class="box">hello</div>', [['<!-- hi -->', 'comment'], ['<div', 'keyword'], ['class', 'property']]],
  ['css', '.box { color: #abcdef; margin: 12px; }', [['color', 'property'], ['#abcdef', 'number']]]
];
for (const [language, source, expected] of cases) {
  const spans = highlightCode(source, language);
  assert.equal(spans.map(s => s.text).join(''), source);
  for (const [text, kind] of expected) has(spans, text, kind);
  // Every possible stream chunk boundary must preserve exact source text.
  for (let end = 0; end <= source.length; end++) {
    const prefix = source.slice(0, end);
    assert.equal(highlightCode(prefix, language).map(s => s.text).join(''), prefix);
  }
}
for (const language of ['', 'text', 'unknown']) {
  const source = 'const plain = "你好🙂";';
  assert.ok(highlightCode(source, language).every(s => s.kind === 'text'));
}
assert.equal(highlightCode('', 'ts').length, 0);
has(highlightCode('const x = 1', ' TypeScript title="example"'), 'const', 'keyword');
const comment = highlightCode('/* const fake = "hi";\nreturn 12; */', 'ts');
assert.equal(comment.length, 1); has(comment, 'return 12', 'comment');
const string = highlightCode('"// not a comment, const 12"', 'ts');
assert.equal(string.length, 1); has(string, '// not a comment', 'string');
// Preview and expansion run through emitted MarkdownChunkView in test-markdown-performance.cjs.
const reveal = new StreamReveal();
reveal.update('code', 'const x = ', 1000, false);
reveal.update('code', 'const x = "hi"', 1100, true);
const faded = reveal.spans('code', highlightCode('const x = "hi"', 'ts'), 1100);
assert.equal(faded.map(s => s.text).join(''), 'const x = "hi"');
assert.ok(faded.filter(s => s.opacity < 1).every(s => s.kind === 'syntax-string'));
assert.ok(faded.filter(s => s.kind === 'syntax-keyword').every(s => s.opacity === 1));
// Ensure syntax text remains readable against both code backgrounds.
function luminance(hex) {
  const c = hex.slice(1).match(/../g).map(x => parseInt(x, 16) / 255).map(x => x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4);
  return c[0] * .2126 + c[1] * .7152 + c[2] * .0722;
}
for (const theme of ['base', 'dark']) {
  const colors = JSON.parse(fs.readFileSync(path.resolve(__dirname, `../entry/src/main/resources/${theme}/element/color.json`))).color;
  const bg = luminance(colors.find(c => c.name === 'surface_variant').value);
  for (const c of colors.filter(c => c.name.startsWith('code_'))) {
    const fg = luminance(c.value), ratio = (Math.max(fg, bg) + .05) / (Math.min(fg, bg) + .05);
    assert.ok(ratio >= 4.5, `${theme} ${c.name} contrast ${ratio}`);
  }
}
console.log('PASS code highlighting: languages, exact text, all streaming prefixes, multiline tokens, reveal, theme contrast');
