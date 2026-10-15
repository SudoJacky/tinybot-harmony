// Build first. Exercise the real command transformation, view model and emitted picker callbacks.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets'), cache = new Map();
const compile = code => ts.transpileModule(code, { compilerOptions: { module: ts.ModuleKind.CommonJS,
  target: ts.ScriptTarget.ES2021, experimentalDecorators: true } }).outputText;
function load(file) {
  file = path.resolve(file + '.ets'); if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  vm.runInNewContext(compile(fs.readFileSync(file, 'utf8')), { exports,
    require: id => load(path.resolve(path.dirname(file), id)) });
  return exports;
}
const plain = value => JSON.parse(JSON.stringify(value));
const { skillQuery, skillDraft, matchingSkills, skillDisplayName } = load(root + '/model/SkillCompletion');
const { parseSkill } = load(root + '/model/Skills');
const { seedBuiltinSkills, builtinSkillInfo } = load(root + '/model/BuiltinSkills');
const settings = { webEnabled: true, skills: [] }; seedBuiltinSkills(settings);
for (const text of ['$20', 'US$20', 'cost$20', '$20.50', 'abc$notes', '\\$notes', '$ ', 'hello']) assert.equal(skillQuery(text), undefined, text);
assert.deepEqual(plain(skillQuery('$')), { start: 0, end: 1, text: '' });
assert.equal(skillQuery('整理\n$随手').text, '随手');
assert.equal(skillQuery('$', 99), undefined);
const mid = '帮我 $notes-to-actions 整理这段记录', query = skillQuery(mid, '帮我 $notes'.length);
assert.equal(mid.slice(query.start, query.end), '$notes-to-actions');
const selected = skillDraft(mid, 'notes-to-actions', query);
assert.equal(selected.text, '/skill:notes-to-actions 帮我 整理这段记录');
assert.equal(selected.text.slice(selected.caret), '整理这段记录');
assert.equal(skillDraft('$data', 'data-analysis', skillQuery('$data')).text, '/skill:data-analysis ');
const replace = '/skill:web-research 原有内容 $随手 保留后文';
assert.equal(skillDraft(replace, 'notes-to-actions', skillQuery(replace, replace.indexOf(' 保留后文'))).text,
  '/skill:notes-to-actions 原有内容 保留后文');
assert.equal(skillDraft('/skill:web-research 原有内容', 'data-analysis').text, '/skill:data-analysis 原有内容');
const manual = parseSkill('---\nname: custom-notes\ndescription: 自定义随手记\ndisable-model-invocation: true\n---\nCustom instructions.');
settings.skills.push(manual);
assert.equal(matchingSkills(settings.skills, '随手').length, 2);
assert.equal(matchingSkills(settings.skills, 'DATA-ANALYSIS')[0].name, 'data-analysis');
manual.enabled = false; assert.equal(matchingSkills(settings.skills, '随手').length, 1);
assert.equal(matchingSkills(settings.skills, 'nothing-matches').length, 0);
manual.enabled = true;
console.log('PASS cursor-aware $ queries, currency boundaries, Chinese/name/description search, enabled/manual-only Skills and command replacement preserve surrounding text');

const emitted = path.resolve(root, '../../../build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/ChatPanel.ts');
assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(root + '/views/ChatPanel.ets').mtimeMs, 'Rebuild ChatPanel');
const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ChatPanel');
const method = name => component.members.find(node => node.name?.getText(tree) === name).getText(tree);
const viewTree = ts.createSourceFile('ChatViewModel.ts', fs.readFileSync(root + '/viewmodel/ChatViewModel.ets', 'utf8'), ts.ScriptTarget.Latest, true);
const viewModel = viewTree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ChatViewModel');
const use = viewModel.members.find(node => node.name?.getText(viewTree) === 'useSkill').getText(viewTree);
const frames = [], focus = [], caret = [], nodes = []; let active;
const scope = { exports: {}, skillQuery, skillDraft, matchingSkills, skillDisplayName, builtinSkillInfo, t: value => value,
  FrameCallback: class {}, HorizontalAlign: {}, TextOverflow: {}, BarState: {}, Radius: {}, Font: {} };
for (const kind of ['Column', 'Row', 'Text', 'SymbolGlyph', 'Scroll', 'If', 'ForEach']) scope[kind] = new Proxy({}, {
  get: (_, name) => value => { if (['id', 'onClick'].includes(name)) active[name] = value; }
});
const helper = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'ComposerKeyboardFrame');
vm.runInNewContext(compile(`${helper.getText(tree)}; class Model { ${use} } exports.Model = Model;
class Panel { ${['speechActive','currentSkillQuery','skillSuggested','skillMatches','selectSkill','skillSuggestions'].map(method).join('\n')} } exports.Panel = Panel;`), scope);
const app = new scope.exports.Model(); let mutable = true;
Object.assign(app, { extensions: settings, active: { archived: false }, draft: '$随手', busy: false, saveError: '',
  requireSession: () => ({ canMutate: mutable }), setDraft(text) { this.draft = text; }, send() { throw Error('Picker must not send'); } });
const panel = new scope.exports.Panel();
Object.assign(panel, { app, thread: { id: 'chat', archived: false }, appearance: {}, voiceMode: false, speech: { phase: 'idle' },
  composerSelectionStart: -1, composerSelectionEnd: -1, keyboardFocusRequest: 0,
  composerController: { caretPosition: value => caret.push(value) },
  getUIContext: () => ({ postFrameCallback: frame => frames.push(frame), getFocusController: () => ({ requestFocus: id => focus.push(id) }) }),
  observeComponentCreation2(callback) { active = {}; nodes.push(active); callback(nodes.length, true); },
  ifElseBranchUpdateFunction(_branch, build) { build(); }, forEachUpdateFunction(_id, items, build) { items.forEach(build); } });
assert.equal(panel.skillSuggested(), true);
for (const field of ['busy', 'saveError']) {
  app[field] = field === 'busy' ? true : 'disk full'; assert.equal(panel.skillSuggested(), false); app[field] = field === 'busy' ? false : '';
}
panel.thread.archived = true; assert.equal(panel.skillSuggested(), false); panel.thread.archived = false;
panel.voiceMode = true; assert.equal(panel.skillSuggested(), false); panel.voiceMode = false;
panel.speech.phase = 'listening'; assert.equal(panel.skillSuggested(), false); panel.speech.phase = 'idle';
panel.composerSelectionStart = 0; panel.composerSelectionEnd = 2; assert.equal(panel.skillSuggested(), false);
panel.composerSelectionStart = -1; panel.composerSelectionEnd = -1;
panel.skillSuggestions();
const row = nodes.find(node => node.id === 'mention-skill-notes-to-actions'); assert.ok(row?.onClick);
mutable = false; row.onClick(); assert.equal(app.draft, '$随手'); assert.equal(frames.length, 0); mutable = true;
row.onClick(); assert.equal(app.draft, '/skill:notes-to-actions '); assert.equal(focus.length, 0);
frames.shift().onIdle(); assert.deepEqual(focus, ['composer']); assert.equal(caret[0], app.draft.length);
assert.equal(panel.skillSuggested(), false);
app.draft = '$'; panel.composerSelectionStart = -1; panel.composerSelectionEnd = -1; panel.selectSkill('data-analysis');
panel.thread.id = 'different-chat'; frames.shift().onIdle(); assert.equal(focus.length, 1);
console.log('PASS emitted picker rows use the guarded view model, never send, focus after rendering and suppress stale-thread focus');
