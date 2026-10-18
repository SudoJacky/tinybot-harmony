// Build first. Exercise preference persistence, system changes and the emitted settings-page controller.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'D:/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map(), stored = new Map(), visible = new Map();
let systemLanguage = 'zh-Hans-CN', failFlush = false;
const preferenceStore = {
  getSync: (key, fallback) => stored.has(key) ? stored.get(key) : fallback,
  putSync: (key, value) => stored.set(key, value),
  flushSync: () => { if (failFlush) throw new Error('Injected storage failure'); }
};
const kits = {
  '@kit.ArkData': { preferences: { getPreferencesSync: () => preferenceStore } },
  '@kit.LocalizationKit': { i18n: { System: { getSystemLanguage: () => systemLanguage } } }
};
function load(relative) {
  const file = path.resolve(relative.endsWith('.ets') ? relative : relative + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText;
  vm.runInNewContext(compiled, { exports, require: id => id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id],
    AppStorage: { setOrCreate: (key, value) => visible.set(key, value) }, Error }, { filename: file });
  return exports;
}
const { LanguagePreferences: language } = load(path.join(root, 'services/LanguagePreferences'));
const { getLocale, t } = load(path.join(root, 'model/I18n'));
language.initialize({});
assert.equal(getLocale(), 'zh-CN');
systemLanguage = 'en-US'; language.refresh();
assert.equal(t('保存'), 'Save');
language.select('zh-CN');
assert.equal(stored.get('language'), 'zh-CN');
systemLanguage = 'en-GB'; language.refresh();
assert.equal(t('保存'), '保存');
language.initialize({});
assert.equal(getLocale(), 'zh-CN');
failFlush = true;
assert.throws(() => language.select('en'), /Injected/);
assert.equal(stored.get('language'), 'zh-CN');
assert.equal(visible.get('tinybot.locale'), 'zh-CN');
failFlush = false;
language.select('system');
assert.equal(getLocale(), 'en');
systemLanguage = 'zh-TW'; language.refresh();
assert.equal(getLocale(), 'zh-CN');
stored.set('language', 'unsupported'); language.initialize({});
assert.equal(visible.get('tinybot.language'), 'system');
console.log('PASS system changes, explicit override, restart persistence, save failure rollback and invalid preference fallback');

async function testLanguagePage() {
  const source = path.join(root, 'views/LanguagePanel.ets');
  const emitted = path.resolve(__dirname, '../entry/build/default/cache/default/default@CompileArkTS/esmodule/debug/entry/src/main/ets/views/LanguagePanel.ts');
  assert.ok(fs.statSync(emitted).mtimeMs >= fs.statSync(source).mtimeMs, 'Build language page before testing');
  const tree = ts.createSourceFile(emitted, fs.readFileSync(emitted, 'utf8'), ts.ScriptTarget.Latest, true);
  const component = tree.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'LanguagePanel');
  const sandbox = { exports: {}, LanguagePreferences: language, t };
  vm.runInNewContext(ts.transpileModule(`class Page {
    ${component.members.filter(node => ['canEdit', 'select', 'aboutToDisappear'].includes(node.name?.getText(tree))).map(node => node.getText(tree)).join('\n')}
  } exports.Page = Page;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText, sandbox);
  function page(flushDraft = async () => {}) {
    return Object.assign(new sandbox.exports.Page(), { disposed: false, selecting: false, error: '',
      app: { busy: false, saving: false, saveError: '', flushDraft } });
  }
  let release, flushes = 0;
  const gate = new Promise(resolve => { release = resolve; });
  const live = page(() => { flushes++; return gate; });
  const pending = live.select('en');
  assert.equal(live.selecting, true); assert.equal(visible.get('tinybot.language'), 'system');
  await live.select('zh-CN'); assert.equal(flushes, 1, 'Repeated selection cannot race a pending draft save');
  release(); await pending;
  assert.equal(visible.get('tinybot.language'), 'en'); assert.equal(live.selecting, false);
  failFlush = true; await live.select('zh-CN'); failFlush = false;
  assert.ok(live.error); assert.equal(visible.get('tinybot.language'), 'en');
  await live.select('zh-CN'); assert.equal(live.error, ''); assert.equal(visible.get('tinybot.language'), 'zh-CN');
  const rejected = page(async () => { rejected.app.saveError = 'draft save failed'; });
  await rejected.select('en'); assert.equal(visible.get('tinybot.language'), 'zh-CN');
  const busy = page(() => { throw Error('Busy page must not attempt saving'); }); busy.app.busy = true;
  await busy.select('en'); assert.equal(visible.get('tinybot.language'), 'zh-CN');
  let finish;
  const leaving = page(() => new Promise(resolve => { finish = resolve; }));
  const late = leaving.select('en'); leaving.aboutToDisappear(); finish(); await late;
  assert.equal(visible.get('tinybot.language'), 'zh-CN', 'Leaving during draft persistence cancels the later selection');
  assert.equal(leaving.selecting, false);
  console.log('PASS language page: immediate selection, draft-save ordering, duplicate clicks, save failure/retry, busy guard and navigation cleanup');
}
testLanguagePage().catch(error => { console.error(error); process.exitCode = 1; });
