// Real cloud-backup code with controlled native snapshots, start acknowledgements and readiness.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
} }).outputText;
const serviceCode = compile(fs.readFileSync(path.join(root, 'services/CloudBackup.ets'), 'utf8'));
const startupCode = compile(fs.readFileSync(path.join(root, 'services/StartupBackup.ets'), 'utf8'));
const panelSource = fs.readFileSync(path.join(root, 'views/BackupPanel.ets'), 'utf8');
const panelCode = compile('export class Probe {\n' + panelSource.slice(
  panelSource.indexOf('  aboutToAppear()'), panelSource.indexOf('  @Builder')) + '\n}');
const tick = () => new Promise(setImmediate);
const t = (key, args = []) => key.replace(/\{(\d+)\}/g, (_, i) => args[i]);

function setup() {
  const timers = new Map(), instances = [], logs = [], state = new Map([['startupBackupState', 'pending']]);
  let timerId = 0;
  const control = { ready: true, accesses: 0, starts: 0, snapshot: { state: 4, error: 0 }, start: async () => {} };
  const fileIo = { access: async () => { control.accesses++; return control.ready; }, listFile: async () => [], accessSync: () => false };
  const cloudSync = {
    SyncState: { UPLOADING: 0, UPLOAD_FAILED: 1, DOWNLOADING: 2, DOWNLOAD_FAILED: 3, COMPLETED: 4, STOPPED: 5 },
    ErrorType: { NO_ERROR: 0, NETWORK_UNAVAILABLE: 1, WIFI_UNAVAILABLE: 2, BATTERY_LEVEL_LOW: 3,
      BATTERY_LEVEL_WARNING: 4, CLOUD_STORAGE_FULL: 5, LOCAL_STORAGE_FULL: 6, DEVICE_TEMPERATURE_TOO_HIGH: 7 },
    FileSync: class {
      constructor() { instances.push(this); }
      on(_event, callback) { this.callback = callback; queueMicrotask(() => this.callback?.(control.snapshot)); }
      off(_event, callback) { assert.equal(callback, this.callback); this.callback = undefined; }
      async start() { control.starts++; await control.start(this); }
    }
  };
  const exports = {};
  const imports = {
    '../model/Diagnostics': { Diagnostics: { log: (...args) => logs.push(args) } },
    '@kit.CoreFileKit': { cloudSync, fileIo }, '@kit.ArkTS': {},
    '../model/I18n': { t }, './Backup': {}, './FileBytes': {}
  };
  vm.runInNewContext(serviceCode, { exports, require: id => {
    assert.ok(id in imports, 'Unexpected import: ' + id); return imports[id];
  }, setTimeout: (callback, ms) => { const id = ++timerId; timers.set(id, { callback, ms }); return id; },
  clearTimeout: id => timers.delete(id) });
  const startupExports = {};
  const startupImports = {
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
      getBundleInfoForSelfSync: () => ({ installTime: 1, updateTime: 1 }) } },
    '@kit.ArkData': { preferences: { getPreferencesSync: () => ({ getSync: (key, fallback) => state.get(key) ?? fallback,
      putSync: (key, value) => state.set(key, value), flushSync() {} }) } },
    '@kit.CoreFileKit': { fileIo }, '../model/Onboarding': { isOnboardingCandidate: () => true },
    './CloudBackup': exports
  };
  vm.runInNewContext(startupCode, { exports: startupExports, require: id => {
    assert.ok(id in startupImports, 'Unexpected import: ' + id); return startupImports[id];
  } });
  return { ...exports, ...startupExports, control, timers, instances, state, logs,
    async timer(ms) {
      const entry = [...timers].find(([, timer]) => timer.ms === ms);
      assert.ok(entry, 'Expected timer: ' + ms); timers.delete(entry[0]); entry[1].callback(); await tick();
    }, emit(state, error = 0) { instances.at(-1).callback({ state, error }); }
  };
}

function panel(cloud) {
  const exports = {};
  vm.runInNewContext(panelCode, { exports, CloudBackup: cloud, cloudBackupError: error => error.message,
    Diagnostics: { log() {} }, t });
  return Object.assign(new exports.Probe(), { visible: true, foreground: true, busy: false,
    cloudError: '', cloudListError: '', cloudErrorCode: 0, cloudStatus: '', cloudLoaded: false,
    app: { busy: false, exportSnapshot: () => ({}) }, context: () => ({}) });
}

test('registration completion cannot hide a failed start or release the cloud lock', async () => {
  const h = setup(); h.control.start = async () => { throw Object.assign(Error('not ready'), { code: 22400001 }); };
  const pending = h.CloudBackup.sync(); pending.catch(() => {});
  await tick();
  await assert.rejects(h.CloudBackup.sync(), /另一项云备份/);
  for (const ms of [500, 1000, 2000]) await h.timer(ms);
  await assert.rejects(pending, error => error.code === 22400001);
  assert.equal(h.control.starts, 4); assert.equal(h.timers.size, 0);
  assert.ok(h.instances.every(instance => instance.callback === undefined));
});

test('completion waits for this start acknowledgement and rejects its late failure', async () => {
  const h = setup(); let rejectStart, settled = false;
  h.control.start = () => new Promise((_, reject) => { rejectStart = reject; });
  const pending = h.CloudBackup.sync(); pending.then(() => { settled = true; }, () => { settled = true; });
  await tick(); h.emit(4); await tick(); assert.equal(settled, false);
  rejectStart(Object.assign(Error('IPC failed'), { code: 13600001 }));
  await assert.rejects(pending, error => error.code === 13600001);
  assert.equal(h.timers.size, 0);
});

test('a cached failure is ignored; a new completion before start acknowledgement is retained', async () => {
  const h = setup(); h.control.snapshot = { state: 1, error: 5 }; let acceptStart, settled = false;
  h.control.start = () => new Promise(resolve => { acceptStart = resolve; });
  const pending = h.CloudBackup.sync(); pending.then(() => { settled = true; }, () => { settled = true; });
  await tick(); h.emit(4); await tick(); assert.equal(settled, false);
  acceptStart(); assert.equal(await pending, true); assert.equal(h.timers.size, 0);
});

test('first-run discovery cannot mark an empty cloud as final before real synchronization', async () => {
  const h = setup(); const startup = new h.StartupBackup({ cloudFileDir: '/cloud' });
  const pending = startup.find({ config: {} }); await tick();
  assert.equal(h.state.get('startupBackupState'), 'pending'); assert.equal(h.control.accesses, 0);
  h.emit(2); h.emit(4); await pending;
  assert.equal(h.state.get('startupBackupState'), 'done');
});

test('a temporarily unavailable directory becomes readable without restarting', async () => {
  const h = setup(); h.control.ready = false;
  const pending = h.CloudBackup.list({ cloudFileDir: '/cloud' }); pending.catch(() => {});
  await tick(); h.control.ready = true; await h.timer(500);
  assert.equal((await pending).length, 0); assert.equal(h.control.accesses, 3);
});

test('transient start failures retry, while unsupported capability fails immediately', async () => {
  const h = setup();
  h.control.start = async instance => {
    if (h.control.starts === 1) throw Object.assign(Error('not ready'), { code: 22400001 });
    instance.callback({ state: 4, error: 0 });
  };
  const pending = h.CloudBackup.sync(); await tick(); await h.timer(500);
  assert.equal(await pending, true); assert.equal(h.control.starts, 2);
  h.control.start = async () => { throw Object.assign(Error('unsupported'), { code: 801 }); };
  await assert.rejects(h.CloudBackup.sync(), error => error.code === 801);
  assert.equal(h.timers.size, 0); assert.match(h.cloudBackupError({ code: 801 }), /不支持/);
});

test('a missing completion times out and keeps first-run discovery pending', async () => {
  const h = setup(); const startup = new h.StartupBackup({ cloudFileDir: '/cloud' });
  const pending = startup.find({ config: {} }); await tick(); await h.timer(30000); await pending;
  assert.equal(h.state.get('startupBackupState'), 'pending');
  assert.equal(h.timers.size, 0); assert.equal(h.instances.at(-1).callback, undefined);
});

test('successful listing clears a stale list error but preserves a failed backup action', async () => {
  let unavailable = true;
  const p = panel({ list: async () => { if (unavailable) throw Error('not ready'); return []; },
    create: async () => { throw Error('upload failed'); } });
  await p.loadCloudList(); unavailable = false; await p.loadCloudList();
  assert.equal(p.cloudError || p.cloudListError, ''); assert.equal(p.cloudLoaded, true);
  await p.cloud('create'); assert.equal(p.cloudError, 'upload failed');
});

test('returning from settings reloads availability and only clears recovered readiness errors', async () => {
  const p = panel({ list: async () => [], create: async () => { throw Object.assign(Error('not ready'), { code: 22400001 }); } });
  await p.cloud('create'); assert.equal(p.cloudError, 'not ready', 'The failed backup must remain visible');
  p.foregroundChanged(); await tick(); assert.equal(p.cloudError, '');
  p.cloudError = 'upload failed'; p.cloudErrorCode = 0;
  p.foregroundChanged(); await tick(); assert.equal(p.cloudError, 'upload failed');
  p.visible = false; p.cloudLoaded = false; p.foregroundChanged(); await tick(); assert.equal(p.cloudLoaded, false);
});

test('foreground recovery waits for an older read, then queries fresh settings without overlapping readers', async () => {
  let release, reads = 0, active = 0, maxActive = 0;
  const p = panel({ list: async () => {
    reads++; active++; maxActive = Math.max(maxActive, active);
    try {
      if (reads === 1) return await new Promise(resolve => { release = resolve; });
      return [{ name: 'remote-backup' }];
    } finally { active--; }
  } });
  p.cloudError = 'not ready'; p.cloudErrorCode = 22400001;
  const older = p.loadCloudList();
  const firstResume = p.foregroundChanged(), secondResume = p.foregroundChanged();
  await tick(); assert.equal(reads, 1); release([]);
  await Promise.all([older, firstResume, secondResume]);
  assert.equal(reads, 2); assert.equal(maxActive, 1);
  assert.equal(p.cloudItems[0].name, 'remote-backup'); assert.equal(p.cloudError, '');
});
