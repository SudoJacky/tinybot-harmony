// Source-level sync regressions with real SQLite transactions and isolated device module state.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const studio = process.env.DEVECO_STUDIO_HOME || path.join(process.env.ProgramFiles, 'Huawei/DevEco Studio');
const ts = require(path.join(studio, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const root = path.resolve(__dirname, '../entry/src/main/ets');
const A = '11111111-1111-1111-1111-111111111111', B = '22222222-2222-2222-2222-222222222222';
const boardPath = 'life-boards/dashboard/board.json';
const board = (updatedAt, title = 'board') => JSON.stringify({ version: 2, id: 'dashboard', title, description: '',
  archived: false, createdAt: 1, updatedAt, items: [] });
const copy = value => JSON.parse(JSON.stringify(value));
function device() {
  const cache = new Map(), logs = [], appStorage = new Map(), sql = new DatabaseSync(':memory:');
  const context = { filesDir: '/ability', getApplicationContext: () => ({ filesDir: '/app' }) };
  const transport = { localItems: async () => [], remoteItems: async () => [], mark() {},
    availableDevices: () => [], localNetworkId: () => '', devices: () => [], close: async () => {} };
  let failCommit = false;
  const querySql = async (text, args = []) => {
    const statement = sql.prepare(text); statement.setReturnArrays(true);
    const rows = statement.all(...args); let i = -1;
    return { goToNextRow: () => ++i < rows.length, getLong: c => rows[i][c], getString: c => rows[i][c],
      isColumnNull: c => rows[i][c] === null, close() {} };
  };
  const store = { querySql, executeSql: async text => sql.exec(text), createTransaction: async () => {
    sql.exec('BEGIN');
    return { querySql, execute: async (text, args) => sql.prepare(text).run(...args),
      commit: async () => { if (failCommit) throw Error('injected commit failure'); sql.exec('COMMIT'); },
      rollback: async () => sql.exec('ROLLBACK') };
  } };
  const kits = {
    '@kit.ArkData': { relationalStore: { getRdbStore: async () => store, SecurityLevel: { S3: 3 },
      RdbPredicates: class { inDevices() {} }, SyncMode: { SYNC_MODE_PUSH: 1, SYNC_MODE_PULL: 2 } } },
    '@kit.CoreFileKit': { fileShare: { OperationMode: { READ_MODE: 1, WRITE_MODE: 2 } },
      fileIo: { access: async () => true, listFile: async p => p === '/app/workspace' ? ['w'] : [],
      mkdir: async () => {}, lstat: async () => ({ isDirectory: () => true, isSymbolicLink: () => false }) } },
    '@kit.ArkTS': { url: { URL: { parseURL: (value, base) => new URL(value, base) } }, util: { generateRandomUUID: () => crypto.randomUUID(),
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } },
      Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256');
      return { update: async blob => hash.update(blob.data), digest: async () => ({ data: hash.digest() }) };
    } } },
    '@kit.BasicServicesKit': { deviceInfo: { sdkApiVersion: 26 } }
  };
  function load(name) {
    const file = path.resolve(root, name.endsWith('.ets') ? name : name + '.ets');
    if (cache.has(file)) return cache.get(file);
    const exports = {}; cache.set(file, exports);
    vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: {
      module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021, experimentalDecorators: true
    } }).outputText, { exports, console, setTimeout, clearTimeout, setInterval: () => 1, clearInterval() {},
      Uint8Array, ArrayBuffer, Observed: x => x,
      AppStorage: { setOrCreate: (k, v) => appStorage.set(k, v), get: k => appStorage.get(k) },
      require: id => {
        if (id.endsWith('/Diagnostics')) return { Diagnostics: { log: (...args) => logs.push(args), acceptsLog: () => false } };
        if (file.endsWith('NearbySync.ets') && id === './NearbySyncStore') return { NearbySyncStore: { open: async () => transport } };
        if (file.endsWith('NearbySync.ets') && id === './NearbyFiles') return { NearbyFiles: class { async open() {} async close() {} tick() {} } };
        if (file.endsWith('NearbySync.ets') && id === './NearbyConversations') return { nearbyConversations: { start() {}, stop() {} } };
        return id.startsWith('.') ? load(path.resolve(path.dirname(file), id)) : kits[id] || {};
      }
    }, { filename: file });
    return exports;
  }
  const opened = load('services/ArkDataRecords').ArkDataRecords.open(context);
  load('services/ArkDataWorkspace').registerWorkspaceDatabase('/app/workspace', () => opened);
  const workspace = load('services/ArkDataWorkspace').ArkDataWorkspace.forRoot('/app/workspace/w');
  const sync = load('services/NearbySync').nearbySync;
  sync.context = context; sync.database = () => opened;
  sync.config = { getSync: () => A, putSync() {}, flushSync() {} };
  sync.session = { snapshot: () => ({ threads: [], projects: [], config: {} }), clearPeerProgress() {} };
  sync.tick = () => {};
  return { load, logs, appStorage, transport, workspace, sync, context, opened,
    failCommit: value => { failCommit = value; }, close: () => sql.close() };
}
let failures = 0;
async function test(name, run) {
  try { await run(); console.log('PASS ' + name); }
  catch (error) { failures++; console.error('FAIL ' + name + ': ' + error.stack); }
}
async function main() {
  await test('partial device failure rejects the exchange and reaches retry scheduling', async () => {
    const d = device(); await d.opened;
    try {
      const { NearbySyncStore } = d.load('services/NearbySyncStore');
      const transport = new NearbySyncStore({ sync: async () => [['B', 0], ['C', 14800014]] }, {}, A, () => {});
      await assert.rejects(transport.exchange(['B', 'C'], true), /14800014/);
      assert.ok(d.logs.some(log => log[2] === 'nearby_device_failed' && log[3].deviceId === 'C' && log[3].code === 14800014));
      d.sync.ready = true; d.sync.nextPull = Infinity;
      d.sync.scheduleExchange(transport, ['B', 'C'], Date.now()); await d.sync.exchange;
      assert.equal(d.sync.needsPush, true); assert.equal(d.sync.exchangeFailed, true);
      assert.ok(d.logs.some(log => log[2] === 'nearby_failed'));
    } finally { d.close(); }
  });
  await test('deletion survives disabled sync and restart without reviving stale content', async () => {
    const d = device(); const db = await d.opened;
    try {
      const text = board(10); await d.workspace.write(boardPath, text);
      d.failCommit(true);
      await assert.rejects(d.workspace.write(boardPath), /injected/);
      d.failCommit(false);
      assert.equal(await d.workspace.read(boardPath), text, 'failed deletion must retain the object');
      await d.workspace.write(boardPath);
      const Ledger = d.load('services/UsageLedger').UsageLedger; await Ledger.configure('/ability', () => d.opened);
      await d.sync.start();
      const outgoing = [...d.sync.outgoing.values()].find(item => item.kind === 'workspace');
      assert.ok(outgoing?.text, 'startup must publish a durable versioned deletion');
      const { ArkDataWorkspace } = d.load('services/ArkDataWorkspace');
      const restarted = ArkDataWorkspace.forRoot('/app/workspace/w');
      await d.sync.receiveWorkspace({ kind: 'workspace', id: 'w/' + boardPath, origin: B, revision: 30, text });
      assert.equal(await restarted.read(boardPath), undefined, 'old snapshot must not undo deletion');
      d.failCommit(true);
      await assert.rejects(restarted.write(boardPath, board(40)), /injected/);
      d.failCommit(false);
      await d.sync.receiveWorkspace({ kind: 'workspace', id: 'w/' + boardPath, origin: B, revision: 50, text });
      assert.equal(await restarted.read(boardPath), undefined, 'failed recreation must retain deletion');
      const recreated = await restarted.write(boardPath, text);
      assert.ok(JSON.parse(recreated).updatedAt > 10, 'explicit recreation must have a new revision');
      await d.sync.receiveWorkspace({ ...outgoing, origin: B, revision: 60 });
      assert.equal(await restarted.read(boardPath), recreated, 'an old deletion must not remove a recreated object');
    } finally { d.close(); }
  });
  await test('legacy unversioned deletion reports an unapplied change without blocking other records', async () => {
    const d = device(); const db = await d.opened;
    try {
      d.sync.localStore = db; await d.workspace.write(boardPath, board(10));
      const Ledger = d.load('services/UsageLedger').UsageLedger; await Ledger.configure('/ability', () => d.opened);
      const usage = { id: 'legacy-neighbor', provider: 'p', model: 'm', startedAt: 1, durationMs: 2, status: 'complete' };
      d.transport.remoteItems = async () => [
        { kind: 'workspace', id: 'w/' + boardPath, origin: B, revision: 1 },
        { kind: 'usage', id: usage.id, text: JSON.stringify(usage), origin: B, revision: 2 }
      ];
      let marked = 0; d.transport.mark = () => { marked++; };
      await d.sync.receive(d.transport);
      assert.equal(await d.workspace.read(boardPath), board(10));
      assert.equal(marked, 2); assert.equal(Ledger.list()[0].id, usage.id);
      assert.ok(d.logs.some(log => log[2] === 'workspace_delete_unversioned'));
      assert.ok(d.appStorage.get('tinybot.nearby.status').length > 0);
    } finally { d.close(); }
  });
  await test('offline edits beat concurrent deletion in either delivery order', async () => {
    const a = device(), b = device(); await Promise.all([a.opened, b.opened]);
    try {
      for (const d of [a, b]) { await d.workspace.write(boardPath, board(10));
        await d.load('services/UsageLedger').UsageLedger.configure('/ability', () => d.opened); }
      await a.workspace.write(boardPath); await a.sync.start();
      const deletion = [...a.sync.outgoing.values()].find(item => item.kind === 'workspace');
      assert.ok(deletion?.text, 'deletion needs its base revision');
      await b.workspace.write(boardPath, board(20, 'offline edit')); await b.sync.start();
      await b.sync.receiveWorkspace({ ...deletion, origin: A, revision: 30 });
      assert.equal(await b.workspace.read(boardPath), board(20, 'offline edit'));
      await a.sync.receiveWorkspace({ kind: 'workspace', id: 'w/' + boardPath, origin: B, revision: 40, text: board(20, 'offline edit') });
      assert.equal(await a.workspace.read(boardPath), board(20, 'offline edit'));
      assert.ok(b.logs.some(log => log[2] === 'workspace_delete_conflict'));
      // Replaying the deletion after resolution must still preserve the edit.
      await a.sync.receiveWorkspace({ ...deletion, origin: A, revision: 30 });
      assert.equal(await a.workspace.read(boardPath), board(20, 'offline edit'));
      // The unchanged base on a third device is removed normally.
      const c = device(); await c.opened;
      try {
        await c.workspace.write(boardPath, board(10)); c.sync.localStore = await c.opened;
        await c.sync.receiveWorkspace({ ...deletion, origin: A, revision: 30 });
        assert.equal(await c.workspace.read(boardPath), undefined);
        await c.sync.receiveWorkspace({ kind: 'workspace', id: 'w/' + boardPath, origin: B, revision: 20, text: board(9, 'older') });
        assert.equal(await c.workspace.read(boardPath), undefined);
      } finally { c.close(); }
      const diverged = device(); await diverged.opened;
      try {
        diverged.sync.localStore = await diverged.opened;
        await diverged.workspace.write(boardPath, board(9, 'independent edit'));
        await diverged.sync.receiveWorkspace({ ...deletion, origin: A, revision: 30 });
        assert.equal(await diverged.workspace.read(boardPath), board(9, 'independent edit'),
          'timestamp order alone cannot prove that a different local revision is safe to delete');
      } finally { diverged.close(); }
    } finally { a.close(); b.close(); }
  });
  await test('remote deletion waits for a local guarded write and preserves its committed result', async () => {
    const a = device(), b = device(); await Promise.all([a.opened, b.opened]);
    try {
      for (const d of [a, b]) { await d.workspace.write(boardPath, board(10));
        await d.load('services/UsageLedger').UsageLedger.configure('/ability', () => d.opened); }
      await a.workspace.write(boardPath); await a.sync.start(); await b.sync.start();
      const deletion = [...a.sync.outgoing.values()].find(item => item.kind === 'workspace');
      const db = await b.opened, commit = db.commit.bind(db);
      let release, entered;
      const blocked = new Promise(resolve => { release = resolve; });
      const writing = new Promise(resolve => { entered = resolve; });
      db.commit = async (records, source) => { entered(); await blocked; return commit(records, source); };
      const files = new (b.load('services/NativeWorkspaceFiles').NativeWorkspaceFiles)('/app/workspace/w');
      const { Cancellation } = b.load('services/Cancellation');
      const before = await files.read(boardPath, new Cancellation());
      const saving = files.writeLifeBoard(boardPath, board(20, 'in-flight edit'), new Cancellation(), { version: before.version });
      await writing;
      const receiving = b.sync.receiveWorkspace({ ...deletion, origin: A, revision: 30 });
      release(); await saving; await receiving;
      assert.equal(await b.workspace.read(boardPath), board(20, 'in-flight edit'));
      assert.equal([...b.sync.outgoing.values()].find(item => item.kind === 'workspace').text, board(20, 'in-flight edit'),
        'waiting for a remote update must not suppress publication of the local write');
    } finally { a.close(); b.close(); }
  });
  await test('synchronized provider placeholders recover credentials; manual edits still win', async () => {
    const d = device(); await d.opened;
    try {
      const { emptyData } = d.load('model/Conversation');
      const { peerSettingsText, parsePeerSettings } = d.load('model/PeerSettings');
      const { SessionService } = d.load('services/SessionService');
      const { importedSessionCandidate } = d.load('services/SessionCandidates');
      const { attachBackupKeys, commitBackupKeys } = d.load('services/BackupKeyRestore');
      const { ProfileSettings } = d.load('services/ProfileSettings');
      const source = emptyData(); source.providerProfiles = [{ id: 'provider', name: 'Service', protocol: 'chat-completions',
        baseUrl: 'https://example.com/v1', noApiKey: false, enabled: true, credentialAlias: 'source-key', models: ['model'] }];
      const local = emptyData();
      SessionService.prototype.mergePeerSettings.call({}, local, [{ current: parsePeerSettings(peerSettingsText(source)) }]);
      const imported = copy(source), writes = new Map();
      const vault = { readOptional: async alias => writes.get(alias), write: async (alias, key) => writes.set(alias, key), remove: async alias => writes.delete(alias) };
      const restore = async () => {
        attachBackupKeys(imported, { providers: [{ profile: source.providerProfiles[0], apiKey: 'secret' }] });
        const candidate = importedSessionCandidate(local, imported, () => 'fresh');
        await commitBackupKeys(local, imported, candidate, vault, () => 'fresh', async () => {});
        return candidate.data.providerProfiles[0];
      };
      const restored = await restore();
      assert.equal(writes.get(restored.credentialAlias), 'secret');
      assert.equal(restored.noApiKey, false); assert.equal(restored.enabled, true);
      attachBackupKeys(imported, { providers: [{ profile: source.providerProfiles[0], apiKey: 'secret' }] });
      const failed = importedSessionCandidate(local, imported, () => 'rollback');
      await assert.rejects(commitBackupKeys(local, imported, failed, vault, () => 'rollback', async () => { throw Error('save failed'); }), /save failed/);
      assert.equal(writes.has('tinybot-rollback'), false);
      writes.clear();
      await new ProfileSettings(vault, () => 'edited').save(local, { id: 'provider', name: 'My choice', protocol: 'chat-completions',
        baseUrl: 'https://example.com/v1', noApiKey: true, enabled: false, apiKey: '', models: 'model', contextWindow: '' }, async () => {});
      assert.equal((await restore()).name, 'My choice'); assert.equal(writes.size, 0);
    } finally { d.close(); }
  });
  await test('usage updates retain owner and revision across reload without echoing or changing backup precedence', async () => {
    const d = device(); const db = await d.opened;
    try {
      const Ledger = d.load('services/UsageLedger').UsageLedger;
      await Ledger.configure('/ability', () => d.opened); d.sync.localStore = db;
      const usage = { id: 'request', provider: 'p', model: 'm', startedAt: 1, durationMs: 10, status: 'complete',
        tools: [{ id: 'tool', name: 'read_file', status: 'running', startedAt: 1, durationMs: 0 }] };
      const receive = async (origin, revision, item) => {
        d.transport.remoteItems = async () => [{ kind: 'usage', id: item.id, origin, revision, text: JSON.stringify(item) }];
        await d.sync.receive(d.transport);
      };
      await receive(A, 1, usage);
      const finished = copy(usage); finished.tools[0].status = 'complete'; finished.tools[0].durationMs = 5000;
      await receive(A, 2, finished);
      assert.equal(Ledger.list()[0].tools[0].durationMs, 5000);
      Ledger.records = []; Ledger.positions = new Map();
      await Ledger.configure('/ability', () => d.opened);
      await receive(A, 1, usage); await receive(B, 100, usage);
      assert.equal(Ledger.list()[0].tools[0].status, 'complete');
      let marked = 0; d.transport.mark = () => { marked++; };
      d.failCommit(true);
      const later = copy(finished); later.durationMs = 99;
      await assert.rejects(receive(A, 3, later), /injected/);
      assert.equal(marked, 0, 'failed durable update must not acknowledge the remote revision');
      d.failCommit(false); await receive(A, 3, later);
      assert.equal(marked, 1); assert.equal(Ledger.list()[0].durationMs, 99);
      await Ledger.restoreBackup('/ability', [usage]);
      assert.equal(Ledger.list()[0].tools[0].status, 'complete');
      await d.sync.start();
      assert.ok(![...d.sync.outgoing.values()].some(item => item.kind === 'usage'), 'mirrored usage must not be republished');
    } finally { d.close(); }
  });
  await test('reload preserves remote execution state but interrupts local execution', async () => {
    const d = device(); await d.opened;
    try {
      const { emptyData, parseAppData } = d.load('model/Conversation');
      const { SessionService } = d.load('services/SessionService');
      const data = emptyData(); const messages = [{ id: 'u', role: 'user', content: 'question', status: 'complete', error: '' },
        { id: 'answer', role: 'assistant', content: 'partial', status: 'generating', error: '' }];
      data.threads = [{ id: 'local', title: '', updatedAt: 1, messages: copy(messages) },
        { id: 'remote', title: '', updatedAt: 1, messages: copy(messages), peerOwner: A, peerThreadId: 'source' }];
      data.activeThreadId = 'remote';
      const loaded = parseAppData(JSON.stringify(data));
      assert.equal(loaded.threads[0].messages[1].status, 'stopped');
      assert.equal(loaded.threads[1].messages[1].status, 'generating');
      const session = new SessionService({ load: async () => loaded, save: async () => {} }, {}, {}, {});
      session.data = loaded; session.application.ready = true; session.publish = () => {}; session.emit = () => {};
      assert.equal(session.receivePeerAnswer(A, 'source', { ...messages[1], content: 'next token' }), true);
      assert.equal(session.peerMessages.get('remote').content, 'next token');
      const completed = copy(loaded.threads[1]); completed.messages[1].status = 'complete';
      assert.equal(session.isOlderPeerThread(completed, loaded.threads[1], true), true, 'late progress must not replace a final answer');
    } finally { d.close(); }
  });
  if (failures) process.exitCode = 1;
}
main().catch(error => { console.error(error); process.exitCode = 1; });
