// Storage scan and safe-cleanup contract with a deterministic in-memory filesystem; no phone involved.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');
const cache = new Map();
function load(file) {
  file = path.resolve(file.endsWith('.ets') ? file : file + '.ets');
  if (cache.has(file)) return cache.get(file);
  const exports = {}; cache.set(file, exports);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
  } }).outputText;
  vm.runInNewContext(js, { exports, console, require: id => {
    if (id === '@kit.CoreFileKit') return { fileIo: fake, storageStatistics: stats };
    if (id === '@kit.AbilityKit') return {};
    if (id === '@kit.BasicServicesKit') return { BusinessError: class {} };
    if (id === '../model/WorkspaceStore') return { WorkspaceStore: class { constructor(filesDir) { this.rootDir = filesDir + '/workspace'; } pathFor(id) { return this.rootDir + '/' + id; } } };
    if (id === '../model/Agent') return { toolReceipts: tools => tools || [] };
    if (id === '../model/I18n') return { t: value => value };
    if (id.startsWith('.')) return load(path.resolve(path.dirname(file), id));
    throw new Error('Unexpected import: ' + id);
  } }, { filename: file });
  return exports;
}

const files = new Map(), dirs = new Set(['/', '/app', '/files', '/cache']);
const now = Date.now();
let failPath = '', failUnlink = '', failMetric = '';
function put(file, size, ageMs = 0) {
  files.set(file, { size, modifiedAt: now - ageMs });
  const parts = file.split('/');
  for (let i = 1; i < parts.length; i++) dirs.add(parts.slice(0, i).join('/') || '/');
}
// Ability-level private data: conversations, usage, feedback, performance logs.
put('/files/sessions-v2/index.json', 20);
put('/files/sessions-v2/thread-1.json', 80);
put('/files/usage-records/index.json', 15);
put('/files/feedback-files/f.jpg', 5);
put('/files/performance-current.jsonl', 25);
// Application-level private data: workspaces, attachments, CPU profile.
put('/app/workspace/thread-1/notes.md', 100);
put('/app/workspace/thread-1/.tinybot-review/notes.md.json', 50);
put('/app/workspace/thread-1/.tinybot-old.tmp', 10, 2 * 60 * 60 * 1000);
put('/app/workspace/orphan/old.md', 200);
put('/app/workspace/kept/old.md', 30);
put('/app/workspace/kept/.tinybot-review/old.md.json', 40);
put('/app/attachments/a.jpg', 30);
put('/app/attachments/b.jpg', 40);
put('/app/attachments/c.jpg', 12);
put('/app/tinybot-cpu.json', 7);
put('/cache/old.bin', 500, 60 * 60 * 1000);
put('/cache/new.bin', 60, 60 * 1000);
const fake = {
  access: async p => files.has(p) || dirs.has(p),
  lstat: async p => {
    if (files.has(p)) { const item = files.get(p); return { size: item.size, mtime: Math.floor(item.modifiedAt / 1000),
      isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false }; }
    if (dirs.has(p)) return { size: 0, mtime: 0, isFile: () => false, isDirectory: () => true, isSymbolicLink: () => false };
    throw new Error('ENOENT ' + p);
  },
  listFile: async p => {
    if (failPath && p === failPath) throw Object.assign(new Error('EIO PRIVATE_PATH ' + p), { code: 13900013 });
    if (!dirs.has(p)) throw new Error('ENOTDIR ' + p);
    const prefix = p === '/' ? '/' : p + '/';
    return [...files.keys(), ...dirs].filter(item => item !== p && item.startsWith(prefix) &&
      !item.substring(prefix.length).includes('/')).map(item => item.substring(prefix.length));
  },
  readText: async p => JSON.stringify({ threads: [{ id: 'thread-1', file: 'thread-1.json' }] }),
  unlink: async p => {
    if (failUnlink && p === failUnlink) throw Object.assign(new Error('EACCES PRIVATE_PATH ' + p), { code: 13900013 });
    if (!files.delete(p)) throw new Error('ENOENT ' + p);
  },
  rmdir: async p => {
    if (!dirs.has(p)) throw new Error('ENOENT ' + p);
    if ([...files.keys(), ...dirs].some(item => item !== p && item.startsWith(p + '/'))) throw new Error('ENOTEMPTY ' + p);
    dirs.delete(p);
  }
};
const stats = {
  getCurrentBundleStats: async () => ({ appSize: 300, dataSize: 1000, cacheSize: 560 }),
  getFreeSize: async () => { if (failMetric) throw Object.assign(Error('PRIVATE_METRIC_PATH'), { code: 201 }); return 8000; },
  getTotalSize: async () => 10000
};
const { StorageUsage } = load(path.join(sourceRoot, 'services/StorageUsage'));
const diagnosticLogs = [];
load(path.join(sourceRoot, 'model/Diagnostics')).Diagnostics.configureLogSink(data => diagnosticLogs.push(data));
const plan = load(path.join(sourceRoot, 'model/StoragePlan'));
const data = {
  version: 2, activeThreadId: 'thread-1', projects: [],
  config: {}, threads: [{
    id: 'thread-1', title: 'Notes', updatedAt: 1, messages: [{
      id: 'm1', role: 'user', content: 'hi', status: 'complete', error: '',
      attachments: [
        { id: 'a', name: 'a.jpg', mime: 'image/jpeg', path: 'a.jpg', size: 30 }
      ],
      steps: [{ content: '', tools: [{ browserObservation: { frames: [
        { image: { id: 'c', name: '', mime: 'image/jpeg', path: 'c.jpg', size: 12 } }
      ] } }] }]
    }], pendingInputs: []
  }]
};
(async () => {
  assert.deepEqual(plan.orphanAttachmentPaths(['a.jpg', 'b.jpg'], ['a.jpg']), ['b.jpg']);
  assert.deepEqual(plan.orphanWorkspaceIds(['thread-1', 'project-1', 'orphan'], ['thread-1'], ['project-1']), ['orphan']);
  assert.equal(plan.isStaleTemporary('.tinybot-x.tmp', now - 2 * 60 * 60 * 1000, now), true);
  assert.equal(plan.isStaleTemporary('.tinybot-x.tmp', now - 1000, now), false);
  assert.equal(plan.isStaleTemporary('notes.md', now - 60 * 60 * 1000, now), false);
  assert.equal(plan.isCacheCleanable(now - 9 * 60 * 1000, now), false);
  assert.equal(plan.isCacheCleanable(now - 11 * 60 * 1000, now), true);

  const context = { filesDir: '/files', cacheDir: '/cache', getApplicationContext: () => ({ filesDir: '/app' }) };
  const report = await StorageUsage.scan(context, data);
  assert.equal(report.totalBytes, 100 + 340 + 90 + 82 + 15 + 32 + 560 + 5);
  assert.equal(report.categories.find(item => item.id === 'workspace').bytes, 340);
  assert.equal(report.categories.find(item => item.id === 'backups').bytes, 90);
  assert.equal(report.categories.find(item => item.id === 'attachments').bytes, 82);
  assert.equal(report.categories.find(item => item.id === 'diagnostics').bytes, 32, 'CPU profile lives in the app directory');
  assert.equal(report.cacheCleanBytes, 500);
  assert.equal(report.orphanAttachmentBytes, 40);
  assert.equal(report.orphanWorkspaceBytes, 200);
  assert.equal(report.tempBytes, 10);
  assert.equal(report.orphanAttachments, 1);
  assert.equal(report.orphanWorkspaces, 1);
  assert.equal(report.safeBytes, 750, 'a leftover folder with edit baselines is not counted as cleanable');
  assert.equal(report.incomplete, false);
  assert.equal(report.freeBytes, 8000);
  assert.equal(report.deviceBytes, 10000);

  const attachments = await StorageUsage.entries(context, data, 'attachments');
  assert.equal(attachments.entries.find(item => item.label === 'a.jpg').removable, false);
  assert.equal(attachments.entries.find(item => item.label === 'b.jpg').removable, true);
  assert.equal(attachments.entries.find(item => item.label === 'c.jpg').removable, false, 'empty display names still count as referenced');
  assert.equal(attachments.entries.find(item => item.label === 'c.jpg').detail, '使用中');
  const sessions = await StorageUsage.entries(context, data, 'sessions');
  assert.ok(sessions.entries.length === 1 && sessions.entries[0].removable === false && sessions.entries[0].label === 'Notes');
  const cacheEntries = await StorageUsage.entries(context, data, 'cache');
  assert.equal(cacheEntries.entries.find(item => item.label === 'old.bin').removable, true);
  assert.equal(cacheEntries.entries.find(item => item.label === 'new.bin').removable, false);

  failPath = '/app/workspace/kept/.tinybot-review';
  const protectedScan = await StorageUsage.scan(context, data);
  assert.equal(protectedScan.incomplete, true);
  assert.equal(protectedScan.orphanWorkspaces, 1, 'only the folder without baselines remains cleanable');
  assert.equal(protectedScan.safeBytes, 750, 'an unreadable review folder keeps its workspace out of cleanup');
  failPath = '';
  assert.equal(diagnosticLogs.findLast(data => data.event === 'scan_failed').fields.errorCode, 13900013);
  failMetric = 'free'; await StorageUsage.scan(context, data); failMetric = '';
  const metricFailure = diagnosticLogs.findLast(data => data.event === 'metric_failed');
  assert.equal(metricFailure.fields.operation, 'free_size'); assert.equal(metricFailure.fields.errorCode, 201);

  const result = await StorageUsage.cleanSafe(context, data);
  assert.equal(result.freedBytes, 750); assert.equal(result.removed, 4); assert.equal(result.failed, 0);
  assert.ok(files.has('/files/sessions-v2/index.json'), 'cleanup never touches conversation history');
  assert.ok(files.has('/app/workspace/thread-1/notes.md'), 'cleanup never touches workspace files');
  assert.ok(files.has('/app/attachments/a.jpg') && files.has('/app/attachments/c.jpg'), 'referenced attachments stay');
  assert.ok(files.has('/cache/new.bin'), 'recent cache stays');
  assert.ok(!files.has('/cache/old.bin') && !files.has('/app/attachments/b.jpg'));
  assert.ok(!files.has('/app/workspace/orphan/old.md'), 'leftover workspace without baselines is removed');
  assert.ok(files.has('/app/workspace/kept/old.md') && files.has('/app/workspace/kept/.tinybot-review/old.md.json'),
    'edit baselines inside a leftover workspace are preserved');
  const after = await StorageUsage.scan(context, data);
  assert.equal(after.safeBytes, 0);
  assert.equal(after.orphanWorkspaces, 0);
  assert.equal(after.categories.find(item => item.id === 'backups').bytes, 90, 'edit baselines remain in their own category');

  // Deleting the last baseline leaves an empty review folder; it must not block the workspace.
  put('/app/workspace/emptied/old.md', 25);
  dirs.add('/app/workspace/emptied/.tinybot-review');
  const emptiedScan = await StorageUsage.scan(context, data);
  assert.equal(emptiedScan.orphanWorkspaces, 1);
  assert.equal(emptiedScan.safeBytes, 25);
  const emptied = await StorageUsage.cleanSafe(context, data);
  assert.equal(emptied.freedBytes, 25);
  assert.equal(emptied.failed, 0);
  assert.ok(!files.has('/app/workspace/emptied/old.md'));
  assert.ok(!dirs.has('/app/workspace/emptied/.tinybot-review'));

  // A partially deleted tree reports the bytes it did remove.
  put('/app/workspace/partial/a.md', 100);
  put('/app/workspace/partial/b.md', 50);
  failUnlink = '/app/workspace/partial/b.md';
  const partialEntry = { path: '/app/workspace/partial', label: 'partial', detail: '', bytes: 150,
    category: 'workspace', removable: true, directory: true };
  const partial = await StorageUsage.remove(context, [partialEntry]);
  assert.equal(partial.freedBytes, 100);
  assert.equal(partial.failed, 1);
  assert.equal(partial.removed, 0);
  assert.ok(!files.has('/app/workspace/partial/a.md'));
  assert.ok(files.has('/app/workspace/partial/b.md'));
  const cleanupFailure = diagnosticLogs.find(data => data.event === 'cleanup_failed' && data.fields.operation === 'unlink');
  assert.equal(cleanupFailure.fields.errorCode, 13900013);
  assert.ok(!JSON.stringify(diagnosticLogs).includes('PRIVATE_'));
  failUnlink = '';
  const rest = await StorageUsage.remove(context, [partialEntry]);
  assert.equal(rest.freedBytes, 50);
  assert.equal(rest.failed, 0);
  assert.equal(rest.removed, 1);

  // Cleanup must carry scan failures so the UI can say it may be incomplete.
  put('/app/workspace/fresh/x.md', 20);
  put('/cache/fresh.bin', 30, 60 * 60 * 1000);
  failPath = '/app/attachments';
  const incompleteClean = await StorageUsage.cleanSafe(context, data);
  assert.equal(incompleteClean.incomplete, true);
  assert.ok(incompleteClean.failedPaths.includes('/app/attachments'));
  assert.equal(incompleteClean.freedBytes, 50);
  assert.equal(incompleteClean.failed, 0);
  failPath = '';

  failPath = '/app/attachments';
  const broken = await StorageUsage.scan(context, data);
  assert.equal(broken.incomplete, true);
  assert.ok(broken.failedPaths.includes('/app/attachments'));
  assert.equal(broken.categories.find(item => item.id === 'attachments').bytes, 0);
  failPath = '';
  put('/app/workspace/deleted-chat/mini-apps/ledger/app.json', 100);
  put('/app/workspace/deleted-chat/mini-apps/ledger/data.json', 80);
  const appsScan = await StorageUsage.scan(context, data);
  assert.equal(appsScan.orphanWorkspaces, 0, 'mini apps retain a deleted chat workspace without review baselines');
  const appEntries = await StorageUsage.entries(context, data, 'workspace');
  assert.ok(appEntries.entries.filter(item => item.path.includes('/deleted-chat/')).every(item => !item.removable));
  await StorageUsage.cleanSafe(context, data);
  assert.ok(files.has('/app/workspace/deleted-chat/mini-apps/ledger/data.json'));
  console.log('PASS storage dual roots, mini-app retention, baseline-safe cleanup, partial deletion and read-error reporting');
})().catch(error => { console.error(error); process.exitCode = 1; });
