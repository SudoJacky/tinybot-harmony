// Exercise the real ability callbacks with the old context and the incoming new theme.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || 'C:/Program Files/Huawei/DevEco Studio';
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const file = path.resolve(__dirname, '../entry/src/main/ets/entryability/EntryAbility.ets');
const colors = [], failures = []; let dark = false, pc = false;
const storage = new Map(), notificationForeground = [], transferForeground = [];
const windowEvents = { SHOWN: 1, HIDDEN: 4 };
const noOp = () => {};
const kits = {
  '../common/DeviceForm': { get IS_PC() { return pc; } },
  '../common/ApiLevel': { ApiLevel: { sdk: 26 } },
  '../model/Diagnostics': require('./load-diagnostics.cjs'),
  '../services/AppearancePreferences': { AppearancePreferences: { refresh: config => { dark = config.colorMode === 0; }, activate: () => { dark = ability.context.config.colorMode === 0; } } },
  '@kit.AbilityKit': {
    UIAbility: class {},
    ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } }
  },
  '@kit.PerformanceAnalysisKit': { hilog: { info() {}, error: (...args) => failures.push(args) } },
  '@kit.ArkUI': { window: { WindowStageLifecycleEventType: windowEvents, PixelUnit: { VP: 1 } } },
  '../services/LanguagePreferences': { LanguagePreferences: { refresh: noOp } },
  '../services/AutoCloudBackup': { autoCloudBackup: { setForeground: noOp } },
  '../services/BackgroundGeneration': { backgroundGeneration: { setForeground: value => transferForeground.push(value) } },
  '../services/CompletionNotifications': { completionNotifications: { setForeground: value => notificationForeground.push(value) } },
  '../services/HostedPrivacy': { hostedPrivacy: { allowed: false } },
  '../services/WebUiPreflight': { WebUiPreflight: { setForeground: noOp } },
  '../services/PreviewCapture': { PreviewCapture: { setForeground: noOp } },
  '../services/LaunchActions': { LaunchActions: { setForeground: noOp } }
};
const exportsObject = {};
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
} }).outputText;
vm.runInNewContext(compiled, { AppStorage: { get: () => dark, setOrCreate: (key, value) => storage.set(key, value) },
  exports: exportsObject, require: id => kits[id] }, { filename: file });
const ability = new exportsObject.default();
const backgrounds = [];
const nativeWindow = { setWindowBackgroundColor: color => backgrounds.push(color), setWindowSystemBarProperties: properties => {
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
assert.deepEqual(backgrounds,['#F7F8FA','#151719','#F7F8FA','#151719']);
assert.equal(failures.length, 0);
console.log('PASS light/dark startup and both theme transitions while context.config is stale');

async function checkPcWindow() {
  pc = true;
  let listener, limits;
  const pcStage = {
    ...stage,
    on(event, callback) { assert.equal(event, 'windowStageLifecycleEvent'); listener = callback; },
    off(event, callback) { assert.equal(event, 'windowStageLifecycleEvent'); assert.equal(callback, listener); listener = undefined; },
    getMainWindowSync: () => ({
      ...nativeWindow,
      async setWindowLimits(value) { limits = { ...value }; return value; }
    })
  };
  ability.onWindowStageCreate(pcStage);
  ability.onForeground();
  await Promise.resolve();
  assert.deepEqual(limits, { minWidth: 360, minHeight: 420, pixelUnit: 1 });
  listener(windowEvents.HIDDEN);
  assert.equal(storage.get('tinybot.pcWindowVisible'), false);
  assert.equal(storage.get('tinybot.foreground'), true);
  assert.equal(notificationForeground.at(-1), false);
  listener(windowEvents.SHOWN);
  assert.equal(storage.get('tinybot.pcWindowVisible'), true);
  assert.equal(notificationForeground.at(-1), true);
  assert.deepEqual(transferForeground, [true], 'Window visibility must not put active transfers in the background');
  ability.onWindowStageWillDestroy(pcStage);
  assert.equal(listener, undefined);
  console.log('PASS PC window limits, visibility, completion notification routing, and listener teardown');
}
checkPcWindow().catch(error => { console.error(error); process.exitCode = 1; });
