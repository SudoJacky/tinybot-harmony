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
const snapshots = {};
vm.runInNewContext(compile(fs.readFileSync(path.join(root, 'model/BackupSnapshots.ets'), 'utf8')), { exports: snapshots });
const startupCode = compile(fs.readFileSync(path.join(root, 'services/StartupBackup.ets'), 'utf8'));
const panelSource = fs.readFileSync(path.join(root, 'views/BackupPanel.ets'), 'utf8');
const panelCode = compile('export class Probe {\n' + panelSource.slice(
  panelSource.indexOf('  aboutToAppear()'), panelSource.indexOf('  @Builder')) + '\n}');
const tick = () => new Promise(setImmediate);
const t = (key, args = []) => key.replace(/\{(\d+)\}/g, (_, i) => args[i]);
class BackupLoginRequired extends Error {}
const deviceId = '11111111-1111-4111-8111-111111111111';
const otherDevice = '22222222-2222-4222-8222-222222222222';
const configName = (timestamp, owner = deviceId) => `tinybot-config-${owner}-${timestamp}-${deviceId}.tinybot`;

function setup() {
  const timers = new Map(), instances = [], logs = [], state = new Map([['startupBackupState', 'pending']]);
  let timerId = 0;
  const control = { ready: true, accesses: 0, starts: 0, snapshot: { state: 4, error: 0 }, start: async () => {}, files: new Map(),
    restores: [], archives: 0, staged: [], unlinked: [], released: [], verified: [], downloaded: [], releaseError: undefined };
  const fileIo = { access: async file => { control.accesses++; return control.ready &&
    (!/\.(tinybot|partial)$/.test(file) || control.files.has(path.basename(file))); }, listFile: async () => [...control.files.keys()], accessSync: () => false,
    lstat: async file => {
      const name = path.basename(file);
      if (name === control.removedDuringListing) {
        control.files.delete(name);
        throw Object.assign(Error('No such file'), { code: 13900002 });
      }
      return { ...control.files.get(name), isFile: () => true, isSymbolicLink: () => false };
    },
    stat: async file => control.files.get(path.basename(file)),
    async rename(source, target) {
      const name = path.basename(target);
      control.files.set(name, control.files.get(path.basename(source)));
      control.files.delete(path.basename(source));
      control.staged.push(name);
    },
    async unlink(file) {
      const name = path.basename(file);
      control.unlinked.push(file);
      control.files.delete(name);
      if (name === control.removedDuringCleanup) throw Object.assign(Error('No such file'), { code: 13900002 });
    } };
  const cloudSync = {
    SyncState: { UPLOADING: 0, UPLOAD_FAILED: 1, DOWNLOADING: 2, DOWNLOAD_FAILED: 3, COMPLETED: 4, STOPPED: 5 },
    ErrorType: { NO_ERROR: 0, NETWORK_UNAVAILABLE: 1, WIFI_UNAVAILABLE: 2, BATTERY_LEVEL_LOW: 3,
      BATTERY_LEVEL_WARNING: 4, CLOUD_STORAGE_FULL: 5, LOCAL_STORAGE_FULL: 6, DEVICE_TEMPERATURE_TOO_HIGH: 7 },
    State: { COMPLETED: 1, FAILED: 2, STOPPED: 3 },
    DownloadErrorType: { NO_ERROR: 0 },
    CloudFileCache: class {
      on(_event, callback) { this.callback = callback; }
      off(_event, callback) { assert.equal(callback, this.callback); this.callback = undefined; }
      async start(uri) {
        const name = path.basename(uri);
        control.downloaded.push(name);
        control.files.get(name).location = 3;
        this.callback({ uri, state: 1, error: 0, processed: 100 });
      }
      cleanFileCache(file) {
        const name = path.basename(file), entry = control.files.get(name);
        assert.equal(entry.location, 3, 'The system must confirm a cloud copy before releasing its local cache');
        if (control.releaseError) throw control.releaseError;
        entry.location = 2;
        control.released.push(name);
      }
    }, FileSync: class {
      constructor() { instances.push(this); }
      on(_event, callback) { this.callback = callback; queueMicrotask(() => this.callback?.(control.snapshot)); }
      off(_event, callback) { assert.equal(callback, this.callback); this.callback = undefined; }
      async start() { control.starts++; await control.start(this); }
    }
  };
  const exports = {};
  let operating = false;
  const imports = {
    '../model/BackupSnapshots': snapshots,
    './BackupSnapshotNames': { backupDeviceId: () => deviceId, newBackupSnapshot: (_context, previous = 0) =>
      configName(Math.max(1800000000000, previous + 1)) },
    '../model/Diagnostics': { Diagnostics: { log: (...args) => logs.push(args) } },
    '@kit.CoreFileKit': { cloudSync, fileIo, fileUri: { getUriFromPath: file => file } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => deviceId } },
    '../model/I18n': { t }, './Backup': {
      backupBusy: () => operating,
      async withBackupOperation(action) {
        if (operating) throw Error('另一项备份操作正在进行');
        operating = true;
        try { return await action(); } finally { operating = false; }
      },
      async createConfigurationFile() { control.archives++; return '/cache/configuration.tinybot'; },
      async verifyConfigurationBackup(_context, file, openID) {
        const name = path.basename(file);
        assert.equal(openID, 'fixture-openid');
        assert.equal(control.files.get(name).location, 3);
        control.verified.push(name);
        await control.verify?.(name);
      },
      readBackupFile: async (_context, file, local) => { control.restores.push(file); return { ...local, restored: true }; }
    }, './FileBytes': { async copyFileBytes(_source, target) {
      control.files.set(path.basename(target), { size: 100, mtime: 1, location: 1 });
    } },
    './HuaweiAccount': { huaweiAccount: { async backupOpenID() {
      if (control.signedOut) throw new BackupLoginRequired('请先登录华为账号');
      return 'fixture-openid';
    } } }
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

function panel(cloud, local = {}) {
  const exports = {};
  const account = { backupOpenID: async () => 'account' };
  vm.runInNewContext(panelCode, { exports, CloudBackup: cloud, cloudBackupError: error => error.message,
    latestCloudBackup: items => items.find(item => item.location === 2 || item.location === 3), getLocale: () => 'en-US',
    Diagnostics: { log() {} }, BackupLoginRequired, t, reviewBackupRestore: async () => true,
    huaweiAccount: account, NativeData: { forFilesDir: () => ({ allowAutoBackup() {} }) },
    withBackupOperation: action => action(), ...local });
  return Object.assign(new exports.Probe(), { visible: true, foreground: true, busy: false,
    error: '', status: '', statusError: false, backupDate: '', account,
    app: { busy: false, get sharedBusy(){return this.busy;}, configurationSnapshot: () => ({}), exportSnapshot: () => ({}) }, automatic: { confirmUploaded() {} }, context: () => ({}), getUIContext: () => ({}) });
}

test('local file actions can run while cloud status is pending and require confirmation before importing', async () => {
  let finishCloudRead, imported = 0, confirm = false;
  const restored = { source: 'file' };
  const p = panel({ list: () => new Promise(resolve => { finishCloudRead = resolve; }) }, {
    exportBackup: async () => true, readBackup: async () => restored, reviewBackupRestore: async () => confirm
  });
  p.app.importSnapshot = async data => { assert.equal(data, restored); imported++; return true; };
  const reading = p.refreshStatus();
  await p.localBackup(false);
  assert.equal(p.status, '完整备份已保存。');
  finishCloudRead([]); await reading;
  await p.localBackup(true);
  assert.equal(imported, 0); assert.equal(p.status, '');
  confirm = true; await p.localBackup(true);
  assert.equal(imported, 1); assert.equal(p.busy, false);
});

test('version selection requires login, excludes pending snapshots, and never reuses a stale listing',async()=>{
  let reads=0,selection;
  const cloud={sync:async()=>true,list:async()=>{reads++;return [{name:'pending',location:1},{name:'chosen',location:3}];},
    restore:async(_context,name,_local,mode)=>{selection={name,mode};return{};}};
  const p=panel(cloud);p.account.backupOpenID=async()=>{throw new BackupLoginRequired('login required');};
  await p.chooseRestore();assert.equal(reads,0);assert.equal(p.needsLogin,true);
  p.account.backupOpenID=async()=>'account';await p.chooseRestore();
  assert.equal(p.showVersions,true);assert.deepEqual(Array.from(p.versions,item=>item.name),['chosen']);
  p.app.importSnapshot=async()=>true;await p.cloud(true,'chosen');assert.deepEqual(selection,{name:'chosen',mode:'copy'});
  cloud.list=async()=>{throw Error('Listing failed');};await p.chooseRestore();
  assert.equal(p.versions.length,0);assert.equal(p.showVersions,false);assert.equal(p.error,'Listing failed');
});

test('registration completion cannot hide a failed start or release the cloud lock', async () => {
  const h = setup(); h.control.start = async () => { throw Object.assign(Error('not ready'), { code: 22400001 }); };
  const pending = h.CloudBackup.sync(); pending.catch(() => {});
  await tick();
  await assert.rejects(h.CloudBackup.sync(), /另一项备份/);
  for (const ms of [500, 1000, 2000]) await h.timer(ms);
  await assert.rejects(pending, error => error.code === 22400001);
  assert.equal(h.control.starts, 4); assert.equal(h.timers.size, 0);
  assert.ok(h.instances.every(instance => instance.callback === undefined));
});

test('cloud backup, restore and upload retry require an account before cloud I/O', async () => {
  const h = setup(); h.control.signedOut = true;
  const context = { cloudFileDir: '/cloud' };
  await assert.rejects(h.CloudBackup.create(context, {}), BackupLoginRequired);
  await assert.rejects(h.CloudBackup.restore(context, 'tinybot-latest.tinybot', {}), BackupLoginRequired);
  await assert.rejects(h.CloudBackup.restoreLatest(context, {}), BackupLoginRequired);
  await assert.rejects(h.CloudBackup.retryUpload(context), BackupLoginRequired);
  assert.equal(h.control.accesses, 0);
  assert.equal(h.control.starts, 0);
  assert.equal(h.CloudBackup.busy, false);
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

test('successful status lookup clears availability errors while retaining action failures', async () => {
  let unavailable = true;
  const p = panel({ list: async () => { if (unavailable) throw Error('not ready'); return []; }, create: async () => { throw Error('upload failed'); } });
  await p.refreshStatus(); assert.equal(p.error, 'not ready'); unavailable = false; await p.refreshStatus(); assert.equal(p.error, '');
  await p.cloud(false); assert.equal(p.error, 'upload failed'); await p.refreshStatus(); assert.equal(p.error, 'upload failed');
});
test('restore downloads the latest cloud backup and imports it without a file picker or list selection', async () => {
  const restored = { source: 'cloud' }; let imports = 0, restores = 0;
  const p = panel({ list: async () => [], restoreLatest: async () => { restores++; return restored; } });
  p.app.importSnapshot = async data => { assert.equal(data, restored); imports++; return true; };
  await p.cloud(true); assert.equal(restores, 1); assert.equal(imports, 1); assert.match(p.status, /已恢复/); assert.equal(p.error, '');
  p.app.importSnapshot = async () => false; p.app.error = 'merge failed'; await p.cloud(true); assert.equal(p.error, 'merge failed'); assert.equal(p.status, '');
});
test('backup reports uploaded only after the cloud service confirms its location', async () => {
  let result = 'pending';
  const p = panel({ list: async () => [], create: async () => result });
  await p.cloud(false); assert.match(p.status, /备份已保存在本机/);
  result = 'blocked'; await p.cloud(false); assert.match(p.status, /已有配置备份等待上传/);
  result = 'uploaded'; await p.cloud(false); assert.match(p.status, /已上传到云端/);
});
test('restore failures do not import data and busy or running sessions cannot start another action', async () => {
  let calls = 0, imports = 0;
  const p = panel({ list: async () => [], restoreLatest: async () => { calls++; throw Error('download failed'); } });
  p.app.importSnapshot = async () => { imports++; return true; };
  await p.cloud(true); assert.equal(imports, 0); assert.equal(p.error, 'download failed');
  p.busy = true; await p.cloud(true); p.busy = false; p.app.busy = true; await p.cloud(true); assert.equal(calls, 1);
});
test('foreground recovery waits for earlier reads and refreshes metadata without overlapping', async () => {
  let release, reads = 0, active = 0, maximum = 0;
  const p = panel({ list: async () => { reads++; active++; maximum = Math.max(maximum, active); try { if (reads === 1) return await new Promise(resolve => release = resolve); return [{ createdAt: 1000, location: 3 }]; } finally { active--; } } });
  const older = p.refreshStatus(), first = p.foregroundChanged(), second = p.foregroundChanged(); await tick(); assert.equal(reads, 1);
  release([]); await Promise.all([older, first, second]); assert.equal(reads, 2); assert.equal(maximum, 1); assert.ok(p.backupDate);
});
test('latest selection ignores pending local snapshots and reads both historical and automatic backups', async () => {
  const h = setup();
  assert.equal(h.latestCloudBackup([{ name: 'pending', createdAt: 9999, location: 1 }, { name: 'old-auto', createdAt: 20, location: 3 }, { name: 'old-json', createdAt: 10, location: 2 }]).name, 'old-auto');
  assert.equal(h.latestCloudBackup([{ name: 'pending', createdAt: 9999, location: 1 }]), undefined);
});
test('restoreLatest synchronizes before choosing a remote file and never restores stale cached metadata', async () => {
  const h = setup(); const name = 'tinybot-auto-11111111-1111-4111-8111-111111111111.tinybot';
  const pending = h.CloudBackup.restoreLatest({ cloudFileDir: '/cloud' }, { kept: true }); await tick();
  assert.equal(h.control.accesses, 0); assert.equal(h.control.restores.length, 0);
  h.control.files.set(name, { mtime: 1000, size: 100, location: 3 }); h.emit(4);
  const value = await pending; assert.equal(value.kept, true); assert.equal(value.restored, true); assert.equal(h.control.restores[0], '/cloud/tinybot-backups/' + name);
  assert.equal(h.control.files.get(name).location, 2, 'Restoring a cached archive frees its local copy after reading');
});
test('restoreLatest stops on incomplete sync and explains a genuinely empty cloud', async () => {
  const h = setup(); let pending = h.CloudBackup.restoreLatest({ cloudFileDir: '/cloud' }, {}); const rejected = assert.rejects(pending, /同步尚未完成/);
  await tick(); await h.timer(30000); await rejected; assert.equal(h.control.restores.length, 0);
  h.control.start = async sync => sync.callback({ state: 4, error: 0 });
  await assert.rejects(h.CloudBackup.restoreLatest({ cloudFileDir: '/cloud' }, {}), /暂无可恢复/);
});

test('a local-only configuration blocks new archives until the previous upload finishes', async () => {
  const h = setup(), context = { cloudFileDir: '/cloud' };
  const pending = configName(1790000000000), next = configName(1800000000000);
  const other = configName(1790000000001, otherDevice);
  h.control.files.set(pending, { location: 1, size: 100 });
  h.control.files.set(other, { location: 1, size: 100 });
  h.control.start = async sync => sync.callback({ state: 5, error: 0 });
  let staged = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    assert.equal(await h.CloudBackup.create(context, {}, { onStaged: () => staged++ }), 'blocked');
  }
  assert.equal(h.control.archives, 0);
  assert.equal(staged, 0);
  assert.deepEqual(h.control.unlinked, []);
  assert.deepEqual(h.control.released, []);
  h.control.start = async sync => {
    for (const name of [pending, next]) { if (h.control.files.has(name)) h.control.files.get(name).location = 3; }
    sync.callback({ state: 4, error: 0 });
  };
  assert.equal(await h.CloudBackup.create(context, {}, { onStaged: () => staged++ }), 'uploaded');
  assert.deepEqual(h.control.staged, [next]);
  assert.equal(staged, 1);
  assert.equal(h.control.files.has(pending), false);
  assert.equal(h.control.files.get(next).location, 2);
  assert.equal(h.control.files.get(other).location, 1);
});

test('verified backup replaces every older cloud backup across devices and preserves pending uploads and unrelated files', async () => {
  const h = setup(), context = { cloudFileDir: '/cloud' };
  const legacy = `tinybot-device-${deviceId}-1700000000000-${deviceId}.tinybot`;
  const conflict = 'tinybot-latest(1).tinybot';
  const pendingConflict = 'tinybot-latest(2).tinybot';
  const other = configName(1810000000000, otherDevice);
  const configConflict = other.replace('.tinybot', '(1).tinybot');
  const older = [legacy, conflict, other, configConflict, configName(1740000000000),
    'tinybot-latest.tinybot', 'tinybot-auto-' + deviceId + '.tinybot', 'tinybot-1710000000000-' + deviceId + '.json'];
  for (const name of older) h.control.files.set(name, { location: 2, size: 100, mtime: 1 });
  h.control.files.set(pendingConflict, { location: 1, size: 100, mtime: 1 });
  h.control.files.set('notes.txt', { location: 3, size: 100 });
  assert.ok(!(await h.CloudBackup.list(context)).some(item => item.name === conflict));
  h.control.start = async sync => {
    for (const name of h.control.staged) {
      const item = h.control.files.get(name);
      if (item.location === 1) item.location = 3;
    }
    sync.callback({ state: 4, error: 0 });
  };
  const keeper = configName(1810000000001);
  h.control.verify = () => { for (const name of older) assert.ok(h.control.files.has(name), 'Verification precedes deletion'); };
  const staged = [];
  assert.equal(await h.CloudBackup.create(context, {}, { onStaged: name => staged.push(name) }), 'uploaded');
  assert.deepEqual(staged, [keeper], 'A slow device clock still publishes a newer backup');
  assert.deepEqual(h.control.verified, [keeper]);
  assert.deepEqual([...h.control.files.keys()].sort(), [keeper, pendingConflict, 'notes.txt'].sort());
  assert.equal(h.control.files.get(keeper).location, 2);
  assert.equal(h.control.files.get(pendingConflict).location, 1);
  assert.equal(h.control.starts, 2, 'Upload and deletions both sync before reporting success');
});

test('an incomplete sync or invalid replacement never deletes uploaded backups', async () => {
  const h = setup(), context = { cloudFileDir: '/cloud' };
  const keeper = configName(1800000000000), prior = 'tinybot-latest.tinybot';
  h.control.files.set(prior, { location: 2, size: 100, mtime: 1 });
  h.control.start = async sync => {
    h.control.files.get(keeper).location = 3;
    sync.callback({ state: 5, error: 0 });
  };
  assert.equal(await h.CloudBackup.create(context, {}), 'pending', 'Published metadata alone does not complete sync');
  assert.deepEqual(h.control.verified, []);
  h.control.start = async sync => sync.callback({ state: 4, error: 0 });
  h.control.verify = () => { throw Error('invalid backup checksum'); };
  await assert.rejects(h.CloudBackup.retryUpload(context, { name: keeper }), /清理未完成.*invalid backup checksum/);
  assert.deepEqual(h.control.verified, [keeper]);
  assert.deepEqual([...h.control.files.keys()].sort(), [keeper, prior].sort());
  assert.ok(h.logs.some(entry => entry[2] === 'retire_failed'));
});

test('concurrent writers agree on a keeper at equal timestamps and an older retry cannot remove it', async () => {
  const h = setup(), context = { cloudFileDir: '/cloud' };
  const first = configName(1800000000000), second = configName(1800000000000, otherDevice);
  const legacy = 'tinybot-latest.tinybot';
  const conflict = 'tinybot-latest(1).tinybot';
  for (const name of [first, second, legacy, conflict]) h.control.files.set(name, { location: 2, size: 100, mtime: 1 });
  h.control.start = async sync => sync.callback({ state: 4, error: 0 });
  const items = await h.CloudBackup.list(context);
  assert.equal(h.latestCloudConfiguration(items).name, second);
  assert.equal(h.latestCloudConfiguration(items.reverse()).name, second);
  h.control.removedDuringListing = conflict;
  h.control.removedDuringCleanup = legacy;
  assert.equal(await h.CloudBackup.retryUpload(context, { name: second }), true);
  assert.deepEqual(h.control.downloaded, [second]);
  assert.deepEqual(h.control.verified, [second]);
  assert.deepEqual([...h.control.files.keys()], [second]);
  assert.equal(await h.CloudBackup.retryUpload(context, { name: first }), true);
  assert.deepEqual([...h.control.files.keys()], [second]);
  assert.equal(await h.CloudBackup.retryUpload(context, { name: configName(1800000000001) }), false);
});

test('a local cache release error is reported separately from a confirmed upload', async () => {
  const h = setup();
  const name = configName(1790000000000);
  h.control.files.set(name, { location: 3, size: 100 });
  h.control.releaseError = Error('cache busy');
  h.control.start = async sync => sync.callback({ state: 4, error: 0 });
  assert.equal(await h.CloudBackup.retryUpload({ cloudFileDir: '/cloud' }, { name }), true);
  assert.equal(h.control.files.get(name).location, 3);
  assert.ok(h.logs.some(entry => entry[2] === 'cache_release_failed'));
  assert.deepEqual(h.control.unlinked, []);
});
