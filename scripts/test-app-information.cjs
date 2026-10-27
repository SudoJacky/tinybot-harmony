const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '..');
let metadataError;
let request;
const exported = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services/AppInformation.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, { exports: exported, encodeURIComponent, require: id => {
  if (id === '@kit.AppGalleryKit') return { commentManager: { showCommentDialog: context => request(context) } };
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
  Diagnostics: { log() {} },
  $r: value => value, exports: ui };
vm.runInNewContext(ts.transpileModule('export class Probe {\n' + source.slice(start, end) + '\n}', {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText, context);
async function main() {
  const probe = new ui.Probe(); probe.appearance = { surface: 0 }; probe.ratingOpen = false;
  const requests = [], dialogs = []; let finish, failure, stopped = 0;
  probe.reviewPreferences = () => ({ stopInvitations: () => { stopped++; } });
  probe.reviewSaveFailed = error => { throw error; };
  const host = { ability: 'host' };
  request = context => {
    requests.push(context);
    if (failure) return Promise.reject(failure);
    return new Promise(resolve => { finish = resolve; });
  };
  const toasts = [];
  probe.getUIContext = () => ({ getHostContext: () => host, showAlertDialog: dialog => dialogs.push(dialog),
    getPromptAction: () => ({ showToast: toast => toasts.push(toast) }) });
  const pending = probe.openSupport('rating');
  assert.equal(probe.ratingOpen, true);
  await probe.openSupport('rating'); assert.equal(requests.length, 1);
  assert.equal(requests[0], host);
  finish(); await pending; assert.equal(probe.ratingOpen, false); assert.equal(dialogs.length, 0);
  assert.equal(stopped, 1, 'Successful system flow stops invitations without claiming submission');
  failure = Object.assign(new Error('Store unavailable'), { code: 16000001 });
  await probe.openSupport('rating'); assert.equal(probe.ratingOpen, false);
  assert.match(dialogs[0].message, /16000001.*Store unavailable/);
  assert.equal(stopped, 1, 'Service failure preserves eligibility for a later invitation');
  for (const code of [1021500007, 1021500009]) {
    failure = Object.assign(new Error('Already reviewed'), { code });
    await probe.openSupport('rating');
  }
  assert.equal(stopped, 3, 'Both already-reviewed responses suppress further invitations');
  assert.equal(dialogs.length, 1, 'Already-reviewed results show an acknowledgement instead of an error dialog');
  assert.equal(toasts.length, 2);
  failure = undefined;
  const retry = probe.openSupport('rating'); finish(); await retry; assert.equal(requests.length, 5);
  assert.equal(exported.readAppInformation().versionCode, 1000004);
  metadataError = new Error('Bundle unavailable');
  assert.throws(() => exported.readAppInformation(), /Bundle unavailable/);
  console.log('PASS in-app system review, duplicate taps, service errors, already-reviewed responses, manual retry and package metadata');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
