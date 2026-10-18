// Build first: exercise the actual emitted legal reader with both packaged documents.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const compile = source => ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const source = path.join(root, 'entry/src/main/ets/views/LegalDocumentPanel.ets');
const emitted = path.join(root, 'entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/LegalDocumentPanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build the legal reader first');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(n => ts.isClassDeclaration(n) && n.name.text === 'LegalDocumentPanel');
const method = component.members.find(n => n.name?.getText(tree) === 'aboutToAppear');
const exportsObject = {};
vm.runInNewContext(compile('class Probe {' + method.getText(tree) + '} exports.Probe = Probe;'), {
  exports: exportsObject, t: text => text, util: { TextDecoder: class {
    decodeToString(bytes) { return new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
  } }
});
const markdown = {};
vm.runInNewContext(compile(fs.readFileSync(path.join(root, 'entry/src/main/ets/model/Markdown.ets'), 'utf8')), { exports: markdown });
function reader(kind, read) {
  return Object.assign(new exportsObject.Probe(), { kind, content: '', error: '',
    getUIContext: () => ({ getHostContext: () => ({ resourceManager: { getRawFileContentSync: read } }) }) });
}
for (const [kind, file] of [['privacy', 'privacy-policy.md'], ['terms', 'user-agreement.md']]) {
  const bytes = fs.readFileSync(path.join(root, 'entry/src/main/resources/rawfile', file));
  const view = reader(kind, resource => { assert.equal(resource, file); return bytes; });
  view.aboutToAppear(); assert.equal(view.error, ''); assert.equal(view.content, bytes.toString('utf8'));
  const blocks = markdown.markdownBlocks(view.content);
  const rendered = blocks.map(block => markdown.markdownSpans(block.text).map(span => span.text).join('')).join('');
  const plain = view.content.replace(/^#{1,6} /gm, '').replace(/\*\*/g, '');
  assert.equal(rendered.replace(/\s+/g, ''), plain.replace(/\s+/g, ''), 'No text is lost while parsing ' + file);
  for (const read of [() => { throw Error('resource unavailable'); }, () => Buffer.alloc(0), () => Buffer.from([0xff])]) {
    const failed = reader(kind, read); failed.aboutToAppear(); assert.ok(failed.error, 'Missing, empty and invalid resources must show an error');
  }
}
console.log('PASS both emitted document readers, complete Markdown text, and visible missing/empty/invalid resource errors');
