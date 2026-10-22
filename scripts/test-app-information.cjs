const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
let metadataError;
const exported = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/AppInformation.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exported, encodeURIComponent, require: id => {
  assert.equal(id, '@kit.AbilityKit');
  return { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelfSync: () => {
    if (metadataError) throw metadataError;
    return { name: 'com.sudojacky.tinybot', versionName: '1.0.4', versionCode: 1000004 };
  } } };
} });
const source = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
const start = source.indexOf('  private async openSupport(');
const end = source.indexOf('\n  private ', start + 1);
const ui = {};
const context = { requestAppReview: exported.requestAppReview, t: (text, values = []) => text.replace('{0}', values[0] ?? ''),
  $r: value => value, exports: ui };
vm.runInNewContext(ts.transpileModule('export class Probe {\n' + source.slice(start, end) + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, context);
async function main() {
  const probe = new ui.Probe(); probe.appearance = { surface: 0 }; probe.ratingOpen = false;
  const wants = [], dialogs = []; let finish, failure;
  probe.getUIContext = () => ({ getHostContext: () => ({ startAbility: want => {
    wants.push(want);
    if (failure) return Promise.reject(failure);
    return new Promise(resolve => { finish = resolve; });
  } }), showAlertDialog: dialog => dialogs.push(dialog) });
  const pending = probe.openSupport('rating');
  assert.equal(probe.ratingOpen, true);
  await probe.openSupport('rating'); assert.equal(wants.length, 1);
  const link = new URL(wants[0].uri);
  assert.equal(wants[0].action, 'ohos.want.action.appdetail');
  assert.equal(link.protocol, 'store:'); assert.equal(link.host, 'appgallery.huawei.com');
  assert.equal(link.pathname, '/app/detail');
  assert.equal(link.searchParams.get('id'), 'com.sudojacky.tinybot');
  assert.equal(link.searchParams.get('action'), 'write-review');
  finish(); await pending; assert.equal(probe.ratingOpen, false); assert.equal(dialogs.length, 0);
  failure = Object.assign(new Error('Store unavailable'), { code: 16000001 });
  await probe.openSupport('rating'); assert.equal(probe.ratingOpen, false);
  assert.match(dialogs[0].message, /16000001.*Store unavailable/);
  failure = undefined; metadataError = new Error('Bundle unavailable');
  await probe.openSupport('rating'); assert.equal(wants.length, 2);
  assert.match(dialogs[1].message, /Bundle unavailable/); assert.equal(probe.ratingOpen, false);
  metadataError = undefined;
  const retry = probe.openSupport('rating'); finish(); await retry; assert.equal(wants.length, 3);
  console.log('PASS actual rating callback opens the current app review page, deduplicates pending taps, reports launch/metadata failures and allows retry');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
