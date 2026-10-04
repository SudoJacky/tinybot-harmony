// Arrival tracking is platform-independent; rendering still requires ArkUI.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const file = path.resolve(__dirname, '../entry/src/main/ets/model/StreamReveal.ets');
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText;
const exportsObject = {};
vm.runInNewContext(compiled, { exports: exportsObject }, { filename: file });
const { StreamReveal, STREAM_REVEAL_MS } = exportsObject;
const reveal = new StreamReveal();
const spans = text => [{ text, kind: 'text', url: '' }];
const shown = (text, now) => reveal.spans('0', spans(text), now);

reveal.update('0', '旧内容', 1000, false);
assert.equal(shown('旧内容', 1000)[0].opacity, 1);
reveal.update('0', '旧内容新增', 1100, true);
let parts = shown('旧内容新增', 1100);
assert.equal(parts[0].text, '旧内容');
assert.equal(parts[0].opacity, 1);
assert.ok(parts[1].opacity < 0.21);
const priorOpacity = shown('旧内容新增', 1180)[1].opacity;
reveal.update('0', '旧内容新增文字', 1180, true);
parts = shown('旧内容新增文字', 1180);
assert.equal(parts[1].opacity, priorOpacity, 'another chunk must not restart an earlier fade');
assert.ok(parts[2].opacity < parts[1].opacity);
assert.equal(parts.map(p => p.text).join(''), '旧内容新增文字');
assert.equal(reveal.active(1180 + STREAM_REVEAL_MS), false);
assert.ok(shown('旧内容新增文字', 1400).every(p => p.opacity === 1));

// Restyling a readable prefix preserves its arrival time and link metadata.
reveal.update('0', '旧内容新增文字', 1400, true);
const styled = reveal.spans('0', [{ text: '旧内容', kind: 'bold', url: '' },
  { text: '新增文字', kind: 'link', url: 'https://example.com' }], 1400);
assert.equal(styled[0].opacity, 1);
assert.equal(styled[1].url, 'https://example.com');
reveal.update('0', '旧内容🙂', 1410, true);
assert.equal(shown('旧内容🙂', 1410).map(p => p.text).join(''), '旧内容🙂');
reveal.update('0', '旧内容🙃', 1420, true);
assert.equal(shown('旧内容🙃', 1420).map(p => p.text).join(''), '旧内容🙃');
assert.ok(shown('旧内容🙃', 1420).every(p => p.opacity === 1));

const markdownFile = path.resolve(__dirname, '../entry/src/main/ets/model/Markdown.ets');
const markdownExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(markdownFile, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: markdownExports }, { filename: markdownFile });
for (const [before, after] of [['**hello', '**hello**'], ['[hello](https://example.com', '[hello](https://example.com)']]) {
  const plain = source => markdownExports.markdownSpans(source).map(p => p.text).join('');
  reveal.update('format', plain(before), 1420, false);
  reveal.update('format', plain(after), 1421, true);
  assert.ok(reveal.spans('format', markdownExports.markdownSpans(after), 1421).every(p => p.opacity === 1),
    'closing Markdown syntax must not replay the readable text');
}

// Stop/completion and removed blocks cannot leave text faded or timers active.
reveal.update('0', '旧内容🙃', 1430, false);
assert.equal(reveal.active(1430), false);
assert.equal(shown('旧内容🙃', 1430)[0].opacity, 1);
reveal.update('1', 'new block', 1440, true);
assert.equal(reveal.active(1440), true);
reveal.retain(['0']);
assert.equal(reveal.active(1440), false);
console.log('PASS stream reveal: history, overlapping chunks, formatting, Unicode, completion, cleanup');
