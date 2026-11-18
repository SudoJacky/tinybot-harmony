import { common } from '@kit.AbilityKit';
import { AppData, ThreadData } from '../model/Conversation';
import { deviceData, mergeDeviceData } from '../model/DeviceMerge';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { RequestUsage } from '../model/Usage';
import { Diagnostics } from '../model/Diagnostics';
import { UsageLedger } from './UsageLedger';
import { validateBackupDeviceState } from './BackupDeviceState';
import { backupDeviceId } from './BackupSnapshotNames';
import { DeviceAssets, DeviceAsset } from './DeviceAssets';
import { DeviceSyncStore, localTransferDevice } from './DeviceSyncStore';
import { NativeData } from './NativeData';

interface Publication { version: number; origin: string; recipient: string; threadIds: string[]; data: AppData; }
export interface ReceivedDeviceData { data: AppData; files: number; branches: number; threads: number; }

export async function sendDeviceData(context: common.UIAbilityContext, store: DeviceSyncStore, device: string, source: AppData): Promise<void> {
  const data = deviceData(source), origin = backupDeviceId(context);
  const db = await NativeData.forFilesDir(context.filesDir)?.open();
  if (!db) { throw new Error('Local ArkData store is unavailable'); }
  const files = new DeviceAssets(context), assets = await files.capture(data, origin, db);
  const records = new Map<string, string>();
  for (const thread of data.threads) { records.set('thread/' + thread.id, JSON.stringify(thread)); }
  for (const usage of await UsageLedger.backup(context.filesDir)) { records.set('usage/' + usage.id, JSON.stringify(usage)); }
  for (const asset of assets) {
    const id = JSON.stringify([asset.workspace, asset.path]);
    asset.base = await db.read('device-files:' + device, id);
    records.set('file/' + id, JSON.stringify(asset));
  }
  const publication: Publication = { version: 1, origin: origin, recipient: device,
    threadIds: data.threads.map(thread => thread.id), data: data };
  data.threads = [];
  records.set('publication', JSON.stringify(publication));
  await store.publish(records);
  await store.send(device);
  await files.prune(origin, assets);
  Diagnostics.log('info', 'sync', 'device_published', { count: records.size });
}

export async function receiveDeviceData(context: common.UIAbilityContext, store: DeviceSyncStore, device: string,
  local: AppData): Promise<ReceivedDeviceData> {
  const records = await store.receive(device), header = records.get('publication');
  if (!header) { throw new Error('Incomplete device publication'); }
  const pub = JSON.parse(header) as Publication;
  if (pub.recipient !== localTransferDevice(context)) { throw new Error('The sender must select this device before receiving'); }
  if (pub.version !== 1 || !/^[0-9a-f-]{36}$/.test(pub.origin) || !Array.isArray(pub.data?.threads) || pub.data.threads.length) {
    throw new Error('Unsupported device publication');
  }
  const assets: DeviceAsset[] = [], usage: RequestUsage[] = [], threads = new Map<string, ThreadData>();
  for (const key of records.keys()) {
    const text = records.get(key)!;
    if (key === 'publication') { continue; }
    if (key.startsWith('thread/')) {
      const thread = JSON.parse(text) as ThreadData;
      if (key !== 'thread/' + thread.id) { throw new Error('Invalid device thread identity'); }
      threads.set(thread.id, thread);
    } else if (key.startsWith('usage/')) {
      const record = JSON.parse(text) as RequestUsage;
      if (key !== 'usage/' + record.id) { throw new Error('Invalid device usage identity'); }
      usage.push(record);
    } else if (key.startsWith('file/')) {
      const asset = JSON.parse(text) as DeviceAsset;
      if (key !== 'file/' + JSON.stringify([asset.workspace, asset.path])) { throw new Error('Invalid device file identity'); }
      assets.push(asset);
    }
    else { throw new Error('Unknown device transfer record'); }
  }
  if (!Array.isArray(pub.threadIds) || pub.threadIds.length !== threads.size || new Set(pub.threadIds).size !== threads.size) {
    throw new Error('Invalid device conversation index');
  }
  for (const id of pub.threadIds) {
    const thread = threads.get(id);
    if (!thread) { throw new Error('Missing device conversation'); }
    pub.data.threads.push(thread);
  }
  validateBackupDeviceState({ usage: usage });
  const db = await NativeData.forFilesDir(context.filesDir)?.open();
  if (!db) { throw new Error('Local ArkData store is unavailable'); }
  const files = new DeviceAssets(context);
  const merge = await mergeDeviceData(local, pub.data);
  files.verify(assets, pub.data);
  const changed = await files.apply(assets, merge.roots, device, pub.origin, db);
  const workspaces = new WorkspaceStore(context.getApplicationContext().filesDir);
  for (const project of merge.data.projects || []) { await workspaces.ensureThread(project.workspaceId); }
  for (const thread of merge.data.threads) {
    if (!thread.projectId) { await workspaces.ensureThread(thread.id); }
  }
  await UsageLedger.restoreBackup(context.filesDir, usage);
  return { data: merge.data, files: changed, threads: merge.threads, branches: merge.branches };
}
