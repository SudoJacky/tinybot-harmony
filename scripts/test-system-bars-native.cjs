// Exercise the real ability callbacks with the old context and the incoming new theme.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const file = path.resolve(__dirname, '../entry/src/main/ets/entryability/EntryAbility.ets');
const colors = [], failures = [];
const kits = {
  '@kit.AbilityKit': {
    UIAbility: class {},
    ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } }
  },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error: (...args) => failures.push(args) } },
  '../services/LanguagePreferences': { LanguagePreferences: { refresh() {} } }
};
const exportsObject = {};
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
} }).outputText;
vm.runInNewContext(compiled, { exports: exportsObject, require: id => kits[id] }, { filename: file });
const ability = new exportsObject.default();
const nativeWindow = { setWindowSystemBarProperties: properties => {
  colors.push(properties.statusBarContentColor);
  return Promise.resolve();
} };
const stage = { loadContent: (_page, callback) => callback({ code: 0 }), getMainWindowSync: () => nativeWindow };

ability.context = { config: { colorMode: 1 } };
ability.onWindowStageCreate(stage);
assert.equal(colors.at(-1), '#000000', 'Light startup must use dark status text');
ability.onConfigurationUpdate({ colorMode: 0 });
assert.equal(colors.at(-1), '#FFFFFF', 'Dark event must override the still-light context');
ability.context.config.colorMode = 0;
ability.onConfigurationUpdate({ colorMode: 1 });
assert.equal(colors.at(-1), '#000000', 'Light event must override the still-dark context');
ability.onWindowStageCreate(stage);
assert.equal(colors.at(-1), '#FFFFFF', 'Dark startup must use light status text');
assert.equal(failures.length, 0);
console.log('PASS light/dark startup and both theme transitions while context.config is stale');
