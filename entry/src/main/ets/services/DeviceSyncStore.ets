import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { contentVersion } from './TextDigest';
import { t } from '../model/I18n';

const TABLE = 'transfer_parts';
const PERMISSION = 'ohos.permission.DISTRIBUTED_DATASYNC';
const PART = 32 * 1024;
export interface SyncDevice { id: string; name: string; }

export function localTransferDevice(context: common.UIAbilityContext): string {
  const manager = distributedDeviceManager.createDeviceManager(context.applicationInfo.name);
  try { return manager.getLocalDeviceNetworkId(); } finally { distributedDeviceManager.releaseDeviceManager(manager); }
}

export async function trustedDevices(context: common.UIAbilityContext): Promise<SyncDevice[]> {
  const access = abilityAccessCtrl.createAtManager();
  const app = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).appInfo;
  if (access.checkAccessTokenSync(app.accessTokenId, PERMISSION) !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
    const result = await access.requestPermissionsFromUser(context, [PERMISSION]);
    if (result.authResults[0] !== 0) { throw new Error(t('请允许连接附近设备后再开启同步。')); }
  }
  const manager = distributedDeviceManager.createDeviceManager(context.applicationInfo.name);
  try {
    return manager.getAvailableDeviceListSync().filter(item => !!item.networkId)
      .map((item): SyncDevice => ({ id: item.networkId!, name: item.deviceName }));
  } finally { distributedDeviceManager.releaseDeviceManager(manager); }
}

// Cooperative distributed tables isolate each source device. Rebuilding a local publication
// changes only differing parts. A single transaction publishes the complete new generation.
export class DeviceSyncStore {
  private db: relationalStore.RdbStore;
  private constructor(db: relationalStore.RdbStore) { this.db = db; }

  static async open(context: common.UIAbilityContext): Promise<DeviceSyncStore> {
    const db = await relationalStore.getRdbStore(context, {
      name: 'TinybotDeviceTransfer.db', securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    try {
      await db.executeSql('CREATE TABLE IF NOT EXISTS transfer_parts (id TEXT PRIMARY KEY NOT NULL, entity TEXT NOT NULL, part INTEGER NOT NULL, body TEXT NOT NULL)');
      await db.setDistributedTables([TABLE], relationalStore.DistributedType.DISTRIBUTED_DEVICE);
      return new DeviceSyncStore(db);
    } catch (error) { await db.close(); throw error as Error; }
  }

  async publish(records: Map<string, string>): Promise<void> {
    records.set('seal', await this.seal(records));
    const tx = await this.db.createTransaction();
    try {
      const old = new Set<string>();
      const rows = await tx.querySql('SELECT id FROM transfer_parts');
      try { while (rows.goToNextRow()) { old.add(rows.getString(0)); } } finally { rows.close(); }
      for (const entity of records.keys()) {
        const text = records.get(entity)!;
        let offset = 0, part = 0;
        do {
          let end = Math.min(offset + PART, text.length);
          if (end < text.length && /[\uD800-\uDBFF]/.test(text.charAt(end - 1))) { end--; }
          const id = JSON.stringify([entity, part]), body = text.slice(offset, end);
          // Avoid dirtying unchanged rows in the distributed change log.
          if (old.delete(id)) {
            await tx.execute('UPDATE transfer_parts SET body=? WHERE id=? AND body!=?', [body, id, body]);
          } else {
            await tx.execute('INSERT INTO transfer_parts (id,entity,part,body) VALUES (?,?,?,?)', [id, entity, part, body]);
          }
          part++; offset = end;
        } while (offset < text.length);
      }
      for (const id of old) { await tx.execute('DELETE FROM transfer_parts WHERE id=?', [id]); }
      await tx.commit();
    } catch (error) { await tx.rollback(); throw error as Error; }
  }

  private async seal(records: Map<string, string>): Promise<string> {
    const items: string[] = [];
    for (const key of Array.from(records.keys()).sort()) {
      items.push(key, await contentVersion(records.get(key)!));
    }
    return contentVersion(JSON.stringify(items));
  }

  async send(device: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.inDevices([device]);
    const result = await this.db.sync(relationalStore.SyncMode.SYNC_MODE_PUSH, predicates);
    const status = result.find(item => item[0] === device);
    if (!status || status[1] !== 0) { throw new Error('ArkData device sync failed: ' + (status ? status[1] : 'missing acknowledgement')); }
  }

  async receive(device: string): Promise<Map<string, string>> {
    // A sender explicitly pushes to the chosen peer. Read its delivered replica here.
    // Pulling the sender's current table could retrieve a publication addressed to someone else.
    const table = await this.db.obtainDistributedTableName(device, TABLE);
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.orderByAsc('entity').orderByAsc('part');
    const rows = await this.db.query(predicates, ['entity', 'part', 'body']);
    const records = new Map<string, string>();
    let key = '', parts: string[] = [];
    try {
      while (rows.goToNextRow()) {
        const entity = rows.getString(0);
        if (entity !== key) { if (key) { records.set(key, parts.join('')); } key = entity; parts = []; }
        if (!entity || rows.getLong(1) !== parts.length) { throw new Error('Incomplete ArkData transfer record'); }
        parts.push(rows.getString(2));
      }
      if (key) { records.set(key, parts.join('')); }
    } finally { rows.close(); }
    const expected = records.get('seal');
    if (!expected) { throw new Error(t('请先在对方设备选择发送数据。')); }
    records.delete('seal');
    if (await this.seal(records) !== expected) { throw new Error('Incomplete ArkData device publication'); }
    return records;
  }
  close(): Promise<void> { return this.db.close(); }
}
