// Exercise preference persistence and system changes with the actual adapter and isolated platform shims.
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
