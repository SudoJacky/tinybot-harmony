import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { deviceInfo } from '@kit.BasicServicesKit';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { Diagnostics } from '../model/Diagnostics';

const DB_NAME = 'TinybotNearby.db';
const TABLE = 'nearby_items';
const PART_SIZE = 32 * 1024;
const BUNDLE = 'com.sudojacky.tinybot';

export interface NearbyItem {
  kind: string;
  id: string;
  text?: string;
}
export interface NearbyRecord extends NearbyItem {
  origin: string;
  revision: number;
}
interface Header {
  origin: string;
  kind: string;
  id: string;
  revision: number;
  parts: number;
  removed: boolean;
}

function recordKey(origin: string, kind: string, id: string): string { return JSON.stringify([origin, kind, id]); }
function splitText(text: string): string[] {
  const parts: string[] = [];
  for (let index = 0; index < text.length;) {
    let end = Math.min(index + PART_SIZE, text.length);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) { end--; }
    parts.push(text.slice(index, end)); index = end;
  }
  return parts.length ? parts : [''];
}

export class NearbySyncStore {
  private store: relationalStore.RdbStore;
  private manager: distributedDeviceManager.DeviceManager;
  private origin: string;
  private revision: number = 0;
  private changed: (devices: string[]) => void;

  private constructor(store: relationalStore.RdbStore, manager: distributedDeviceManager.DeviceManager, origin: string, changed: (devices: string[]) => void) {
    this.store = store; this.manager = manager; this.origin = origin; this.changed = changed;
  }
  static async open(context: common.UIAbilityContext, origin: string, changed: (devices: string[]) => void): Promise<NearbySyncStore> {
    const store = await relationalStore.getRdbStore(context, { name: DB_NAME, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
    await store.executeSql('CREATE TABLE IF NOT EXISTS nearby_items (row_id TEXT NOT NULL PRIMARY KEY, origin TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL, revision INTEGER NOT NULL, part INTEGER NOT NULL, parts INTEGER NOT NULL, removed INTEGER NOT NULL, body TEXT NOT NULL)');
    await store.setDistributedTables([TABLE], relationalStore.DistributedType.DISTRIBUTED_DEVICE, {
      autoSync: false, asyncDownloadAsset: false, enableCloud: false,
      tableType: relationalStore.DistributedTableType.SINGLE_VERSION
    });
    const manager = distributedDeviceManager.createDeviceManager(BUNDLE);
    store.on('dataChange', relationalStore.SubscribeType.SUBSCRIBE_TYPE_REMOTE, changed);
    const opened = new NearbySyncStore(store, manager, origin, changed);
    const cursor = await store.querySql('SELECT MAX(revision) FROM nearby_items WHERE origin = ?', [origin]);
    try { if (cursor.goToNextRow() && !cursor.isColumnNull(0)) { opened.revision = cursor.getLong(0); } }
    finally { cursor.close(); }
    return opened;
  }
  devices(): string[] {
    return this.availableDevices().map((item) => item.networkId!).sort();
  }
  availableDevices(): distributedDeviceManager.DeviceBasicInfo[] {
    return this.manager.getAvailableDeviceListSync().filter((item) => !!item.networkId);
  }
  localNetworkId(): string { return this.manager.getLocalDeviceNetworkId(); }
  async exchange(devices: string[], push: boolean): Promise<void> {
    if (!devices.length) { return; }
    const mode = push ? relationalStore.SyncMode.SYNC_MODE_PUSH : relationalStore.SyncMode.SYNC_MODE_PULL;
    const results = await this.exchangeResults(devices, mode);
    const failures: number[] = [];
    let missing = 0;
    for (const device of devices) {
      const code = results.get(device);
      if (code !== 0) {
        if (code === undefined) { missing++; }
        else { failures.push(code); }
        Diagnostics.log('warn', 'sync', 'nearby_device_failed', { deviceId: device, code: code, uncertain: code === undefined });
      }
    }
    if (missing || failures.length) {
      const details: string[] = [];
      if (missing) { details.push('missing device results: ' + missing); }
      if (failures.length) { details.push('failure codes: ' + failures.join(',')); }
      throw new Error('Nearby ArkData sync incomplete (' + details.join('; ') + ')');
    }
  }

  private async exchangeResults(devices: string[], mode: relationalStore.SyncMode): Promise<Map<string, number>> {
    const results = new Map<string, number>();
    if (deviceInfo.sdkApiVersion >= 26) {
      const predicates = new relationalStore.RdbPredicates(TABLE);
      predicates.inDevices(devices);
      for (const result of await this.store.syncEx(mode, predicates)) {
        if (!devices.includes(result.device) || results.has(result.device)) {
          throw new Error('Nearby ArkData returned unexpected device results');
        }
        results.set(result.device, result.code);
      }
      return results;
    }
    // Legacy sync() reports UUIDs. Scope each request to one network ID to attribute its result.
    for (const device of devices) {
      const predicates = new relationalStore.RdbPredicates(TABLE);
      predicates.inDevices([device]);
      const reply = await this.store.sync(mode, predicates);
      if (reply.length === 1 && reply[0][0]) { results.set(device, reply[0][1]); }
    }
    return results;
  }
  async write(items: NearbyItem[]): Promise<void> {
    if (!items.length) { return; }
    const transaction = await this.store.createTransaction();
    try {
      for (const item of items) {
        this.revision = Math.max(this.revision + 1, Date.now());
        const key = recordKey(this.origin, item.kind, item.id), parts = splitText(item.text || '');
        for (let part = 0; part < parts.length; part++) {
          await transaction.execute('INSERT OR REPLACE INTO nearby_items (row_id,origin,kind,entity_id,revision,part,parts,removed,body) VALUES (?,?,?,?,?,?,?,?,?)',
            [key + ':' + part, this.origin, item.kind, item.id, this.revision, part, parts.length, item.text === undefined ? 1 : 0, parts[part]]);
        }
        // Shorter updates must not leave old message chunks available for synchronization.
        await transaction.execute('DELETE FROM nearby_items WHERE origin = ? AND kind = ? AND entity_id = ? AND part >= ?',
          [this.origin, item.kind, item.id, parts.length]);
      }
      await transaction.commit();
    } catch (error) {
      try { await transaction.rollback(); }
      catch (rollback) { throw new Error((error as Error).message + ' | rollback: ' + (rollback as Error).message); }
      throw error as Error;
    }
  }
  private async headers(local: boolean): Promise<Header[]> {
    const sql = 'SELECT origin,kind,entity_id,revision,parts,removed FROM nearby_items WHERE part = 0 AND origin ' + (local ? '= ?' : '!= ?');
    const rows = await this.store.querySql(sql, [this.origin]);
    try {
      const result: Header[] = [];
      while (rows.goToNextRow()) {
        result.push({ origin: rows.getString(0), kind: rows.getString(1), id: rows.getString(2), revision: rows.getLong(3),
          parts: rows.getLong(4), removed: rows.getLong(5) === 1 });
      }
      return result;
    } finally { rows.close(); }
  }
  async localItems(): Promise<NearbyItem[]> {
    const records = await this.headers(true);
    return records.filter((item) => !item.removed).map((item): NearbyItem => ({ kind: item.kind, id: item.id }));
  }
  async remoteItems(seen: Map<string, number>): Promise<NearbyRecord[]> {
    const updates: NearbyRecord[] = [];
    for (const header of await this.headers(false)) {
      const key = recordKey(header.origin, header.kind, header.id);
      if ((seen.get(key) || 0) >= header.revision) { continue; }
      if (header.removed) {
        updates.push({ kind: header.kind, id: header.id, origin: header.origin, revision: header.revision });
        continue;
      }
      const rows = await this.store.querySql('SELECT part,body FROM nearby_items WHERE origin=? AND kind=? AND entity_id=? AND revision=? ORDER BY part',
        [header.origin, header.kind, header.id, header.revision]);
      try {
        const parts: string[] = [];
        while (rows.goToNextRow() && rows.getLong(0) === parts.length) { parts.push(rows.getString(1)); }
        if (parts.length === header.parts) {
          updates.push({ kind: header.kind, id: header.id, origin: header.origin, revision: header.revision, text: parts.join('') });
        }
      } finally { rows.close(); }
    }
    return updates;
  }
  mark(seen: Map<string, number>, record: NearbyRecord): void { seen.set(recordKey(record.origin, record.kind, record.id), record.revision); }
  async close(): Promise<void> {
    this.store.off('dataChange', relationalStore.SubscribeType.SUBSCRIBE_TYPE_REMOTE, this.changed);
    distributedDeviceManager.releaseDeviceManager(this.manager);
    await this.store.close();
  }
}
