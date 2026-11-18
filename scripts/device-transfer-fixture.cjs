const assert = require('node:assert/strict');
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');

// The native transport boundary is simulated. Publication, RDB transactions, integrity checks,
// file IO, branch reconciliation and the duplicate-transfer checks run the application code.
module.exports = async function deviceTransferFixture({ load, kits, fileIo, nativePath, model }) {
  const rdb = kits['@kit.ArkData'], previous = rdb.relationalStore;
  const systems = new Map(), peers = new Map(), deliveries = new Map();
  let localId = '', downloads = 0, failExchange = false, corruptRead = false, changedRows = 0;
  const makeContext = id => {
    const root = '/sandbox/device-transfer/' + id;
    fs.mkdirSync(nativePath(root), { recursive: true });
    return { id, filesDir: root, applicationInfo: { name: 'com.sudojacky.tinybot' },
      distributedFilesDir: '/sandbox/device-transfer/dfs', getApplicationContext: () => ({ filesDir: root }) };
  };
  function query(sql, statement, args = []) {
    const prepared = sql.prepare(statement); prepared.setReturnArrays(true);
    const rows = prepared.all(...args); let at = -1;
    return { goToNextRow: () => ++at < rows.length, getLong: i => rows[at][i], getString: i => rows[at][i], close() {} };
  }
  class Predicates {
    constructor(table) { this.table = table; }
    inDevices(ids) { [this.device] = ids; }
    orderByAsc() { return this; }
  }
  const kit = { SecurityLevel: { S3: 3 }, DistributedType: { DISTRIBUTED_DEVICE: 0 },
    SyncMode: { SYNC_MODE_PUSH: 0, SYNC_MODE_PULL: 1 }, RdbPredicates: Predicates,
    async getRdbStore(context, config) {
      assert.equal(config.encrypt, true);
      const key = context.id + '/' + config.name;
      if (!systems.has(key)) systems.set(key, new DatabaseSync(':memory:'));
      const sql = systems.get(key), querySql = (statement, args) => query(sql, statement, args);
      return {
        executeSql: async text => sql.exec(text), querySql, close: async () => {},
        setDistributedTables: async () => peers.set(context.id, sql),
        obtainDistributedTableName: async id => id,
        query: async predicates => {
          const rows = deliveries.get(context.id + '/' + predicates.table) || [];
          let at = -1;
          const result = { goToNextRow: () => ++at < rows.length, getString: i => rows[at][i], getLong: i => rows[at][i], close() {} };
          if (corruptRead) {
            const get = result.getString;
            result.getString = i => i === 2 && get(0) === 'publication' ? get(i) + ' ' : get(i);
          }
          return result;
        },
        sync: async (direction, p) => {
          assert.equal(direction, kit.SyncMode.SYNC_MODE_PUSH);
          if (!failExchange && peers.has(p.device)) {
            const select = sql.prepare('SELECT entity,part,body FROM transfer_parts ORDER BY entity,part');
            select.setReturnArrays(true);
            deliveries.set(p.device + '/' + context.id, select.all());
          }
          return [[p.device, failExchange ? 1 : 0]];
        },
        createTransaction: async () => {
          sql.exec('BEGIN');
          return { querySql, execute: async (statement, args) => {
            const result = sql.prepare(statement).run(...args);
            if (statement.includes('transfer_parts')) changedRows += Number(result.changes);
          }, commit: async () => sql.exec('COMMIT'), rollback: async () => sql.exec('ROLLBACK') };
        }
      };
    }
  };
  rdb.relationalStore = kit;
  kits['@kit.DistributedServiceKit'] = { distributedDeviceManager: {
    createDeviceManager: () => ({ getLocalDeviceNetworkId: () => localId }), releaseDeviceManager() {}
  } };
  fileIo.connectDfs = async () => { downloads++; };
  fileIo.disconnectDfs = async () => {};
  const A = makeContext('A'), B = makeContext('B');
  fs.mkdirSync(nativePath(A.distributedFilesDir), { recursive: true });
  const { DeviceSyncStore } = load('services/DeviceSyncStore');
  const { sendDeviceData, receiveDeviceData } = load('services/DeviceTransfer');
  const { NativeData } = load('services/NativeData');
  const { mergeDeviceData, deviceData } = load('model/DeviceMerge');
  const a = await DeviceSyncStore.open(A), b = await DeviceSyncStore.open(B);
  const detached = x => JSON.parse(JSON.stringify(x));
  const turn = (id, text) => ['user','assistant'].map(role => ({ role, status:'complete', error:'', id:id+role, content:text+role }));
  try {
    await new NativeData(A, A.filesDir).open(); await new NativeData(B, B.filesDir).open();
    const app = model.emptyData();
    const thread = { id:'topic', title:'Chat', updatedAt:1, messages:turn('root','a'.repeat(40000)) };
    app.threads.push(thread); app.activeThreadId = 'topic';
    const rel = '/workspace/topic/attachments/pdf/report.pdf';
    fs.mkdirSync(nativePath(A.filesDir + rel.slice(0,rel.lastIndexOf('/'))), { recursive:true });
    fs.writeFileSync(nativePath(A.filesDir + rel), '%PDF-sample');
    thread.messages[0].attachments = [{ id:'pdf', name:'report.pdf', path:'attachments/pdf/report.pdf', workspaceId:'topic',
      size:11, original:true, mime:'application/pdf' }];
    await sendDeviceData(A, a, 'B', app);
    const initialWrites = changedRows;
    await sendDeviceData(A, a, 'B', app);
    assert.equal(changedRows, initialWrites, 'unchanged rows never enter the native change log');
    localId = 'B'; failExchange = true;
    await assert.rejects(sendDeviceData(A, a, 'B', app), /sync failed/);
    failExchange = false; corruptRead = true;
    await assert.rejects(receiveDeviceData(B, b, 'A', model.emptyData()), /Incomplete ArkData/);
    corruptRead = false;
    const initial = await receiveDeviceData(B, b, 'A', model.emptyData());
    assert.equal(initial.threads, 1); assert.equal(initial.files, 1); assert.equal(downloads, 1);
    assert.equal(fs.readFileSync(nativePath(B.filesDir + rel),'utf8'), '%PDF-sample');
    thread.messages.push(...turn('phone','phone')); thread.updatedAt++;
    await sendDeviceData(A, a, 'B', app);
    const next = await receiveDeviceData(B, b, 'A', detached(initial.data));
    assert.equal(next.data.threads.length, 1); assert.equal(next.data.threads[0].messages.length, 4);
    assert.equal(downloads, 1, 'fast-forward never opens the already stored remote PDF');
    const tablet = detached(initial.data);
    tablet.threads[0].messages.push(...turn('tablet','tablet')); tablet.threads[0].updatedAt++;
    const split = await receiveDeviceData(B, b, 'A', tablet);
    assert.equal(downloads, 1, 'forks reuse the original local attachment');
    assert.equal(split.branches, 1); assert.equal(split.data.threads.length, 2);
    assert.equal(split.data.threads[0].messages[2].content, 'tabletuser');
    const repeat = await receiveDeviceData(B, b, 'A', detached(split.data));
    assert.equal(repeat.data.threads.length, 2); assert.equal(repeat.files, 0);
    const reverse = await mergeDeviceData(detached(app), deviceData(split.data));
    assert.equal(reverse.data.threads.length, 2, 'sending a branch back cannot duplicate its original');
    const note = '/workspace/topic/note.txt';
    fs.writeFileSync(nativePath(A.filesDir + note),'first');
    await sendDeviceData(A, a, 'B', app);
    await receiveDeviceData(B, b, 'A', detached(next.data));
    fs.writeFileSync(nativePath(B.filesDir + note),'tablet edit');
    await sendDeviceData(B, b, 'A', next.data);
    localId = 'A';
    await receiveDeviceData(A, a, 'B', detached(app));
    assert.equal(fs.readFileSync(nativePath(A.filesDir + note),'utf8'),'tablet edit','unilateral edit propagates on reverse transfer');
    fs.writeFileSync(nativePath(B.filesDir + note),'new tablet edit');
    fs.writeFileSync(nativePath(A.filesDir + note),'local phone edit');
    await sendDeviceData(B, b, 'A', next.data);
    await receiveDeviceData(A, a, 'B', detached(app));
    assert.equal(fs.readFileSync(nativePath(A.filesDir + note),'utf8'),'local phone edit');
    const conflict = fs.readdirSync(nativePath(A.filesDir + '/workspace/topic')).find(name => name.startsWith('sync-') && name.endsWith('note.txt'));
    assert.equal(fs.readFileSync(nativePath(A.filesDir + '/workspace/topic/' + conflict),'utf8'),'new tablet edit');
    localId = 'C';
    await assert.rejects(receiveDeviceData(B, b, 'A', model.emptyData()), /must select/);
  } finally {
    await a.close(); await b.close();
    for (const sql of systems.values()) sql.close();
    rdb.relationalStore = previous; delete fileIo.connectDfs; delete fileIo.disconnectDfs;
  }
};
