import { Diagnostics } from '../model/Diagnostics';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cloudSync, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData } from '../model/Conversation';
import { t } from '../model/I18n';
import { BackupConflictMode, backupBusy, createConfigurationFile, readBackupFile, verifyConfigurationBackup, withBackupOperation } from './Backup';
import { copyFileBytes } from './FileBytes';
import { Cancellation } from './Cancellation';
import { huaweiAccount } from './HuaweiAccount';
import { backupSnapshot } from '../model/BackupSnapshots';
import { backupDeviceId, newBackupSnapshot } from './BackupSnapshotNames';

export interface CloudBackupItem {
  name: string;
  createdAt: number;
  size: number;
  location: number;
  deviceId?: string;
}

const SNAPSHOT_NAME = /^tinybot-(\d{13})-[0-9a-f-]{36}\.(?:json|tinybot)$/;
export const CLOUD_BACKUP_NAME: string = 'tinybot-latest.tinybot';
const LATEST_BACKUP = CLOUD_BACKUP_NAME;
const AUTO_BACKUP = /^tinybot-auto-[0-9a-f-]{36}\.tinybot$/;
function validBackupName(name: string): boolean { return !!backupSnapshot(name) || name === LATEST_BACKUP || SNAPSHOT_NAME.test(name) || AUTO_BACKUP.test(name); }
function isConflictBackup(name: string): boolean {
  const original = name.replace(/\([1-9]\d*\)(\.(?:tinybot|json))$/, '$1');
  return original !== name && validBackupName(original);
}
interface CloudBackupOptions { openID?: string; cancellation?: Cancellation; }
interface CloudBackupCreateOptions extends CloudBackupOptions { onStaged?: (name: string) => void; }
interface CloudBackupRetryOptions extends CloudBackupOptions { name?: string; }
export type CloudBackupCreateResult = 'uploaded' | 'pending' | 'blocked';
function uploaded(item: CloudBackupItem): boolean { return item.location === 2 || item.location === 3; }
function configName(name: string): boolean { return name.startsWith('tinybot-config-') && backupSnapshot(name) !== undefined; }
function compareSnapshots(a: CloudBackupItem, b: CloudBackupItem): number {
  return b.createdAt - a.createdAt || (a.name < b.name ? 1 : a.name === b.name ? 0 : -1);
}
export function latestCloudConfiguration(items: CloudBackupItem[]): CloudBackupItem | undefined {
  return items.filter((item) => uploaded(item) && configName(item.name)).sort(compareSnapshots)[0];
}
export function latestCloudBackup(items: CloudBackupItem[]): CloudBackupItem | undefined {
  return items.filter(uploaded)
    .sort((a, b) => b.createdAt - a.createdAt || (a.name === LATEST_BACKUP ? -1 : b.name === LATEST_BACKUP ? 1 : 0))[0];
}
const CLOUD_READY_DELAYS: number[] = [500, 1000, 2000];
const FILE_NOT_FOUND = 13900002;

class CloudNotReadyError extends Error {
  code: number = 22400001;
  constructor() { super(t('华为云空间暂未就绪，请稍后重试；如持续失败，请检查系统云空间登录状态及 Tinybot 同步开关。')); }
}

// Retry readiness only, before any file mutation or accepted synchronization.
async function whenCloudReady<T>(operation: string, action: () => Promise<T>): Promise<T> {
  const started = Date.now();
  for (let attempt = 0; ; attempt++) {
    try {
      const result = await action();
      if (attempt > 0) { Diagnostics.log('warn', 'backup', 'cloud_retry_finished', { operation: operation, round: attempt + 1, elapsedMs: Date.now() - started }); }
      return result;
    } catch (error) {
      if ((error as BusinessError).code !== 22400001 || attempt >= CLOUD_READY_DELAYS.length) {
        Diagnostics.log('error', 'backup', 'cloud_failed', { operation: operation, round: attempt + 1, elapsedMs: Date.now() - started }, error as Error);
        throw error as Error;
      }
      const delay = CLOUD_READY_DELAYS[attempt];
      Diagnostics.log('warn', 'backup', 'cloud_retry', { operation: operation, round: attempt + 1, delayMs: delay, elapsedMs: Date.now() - started }, error as Error);
      await new Promise<void>((resolve) => { setTimeout(() => resolve(), delay); });
    }
  }
}

async function backupDirectory(context: common.UIAbilityContext): Promise<string> {
  return whenCloudReady('cloud_directory', async () => {
    const root = context.cloudFileDir;
    if (!root || !await fs.access(root)) { throw new CloudNotReadyError(); }
    return root + '/tinybot-backups';
  });
}

export function cloudBackupError(error: Error): string {
  const code = (error as BusinessError).code;
  if (code === 22400001) { return t('华为云空间暂未就绪，请稍后重试；如持续失败，请检查系统云空间登录状态及 Tinybot 同步开关。'); }
  if (code === 801) { return t('当前系统不支持华为云空间文件同步。'); }
  if (code === 22400002) { return t('网络不可用，请联网后刷新备份。'); }
  if (code === 22400003) { return t('电量过低，请充电后刷新备份。'); }
  if (code === 13900025) { return t('本机存储空间不足，请清理后重试。'); }
  return code ? t('云备份操作失败（{0}）：{1}', [code, error.message]) : error.message;
}

function syncError(code: cloudSync.ErrorType): string {
  switch (code) {
    case cloudSync.ErrorType.NETWORK_UNAVAILABLE: return t('网络不可用，请联网后刷新备份。');
    case cloudSync.ErrorType.WIFI_UNAVAILABLE: return t('请连接 WLAN 后刷新备份。');
    case cloudSync.ErrorType.BATTERY_LEVEL_LOW:
    case cloudSync.ErrorType.BATTERY_LEVEL_WARNING: return t('电量过低，请充电后刷新备份。');
    case cloudSync.ErrorType.CLOUD_STORAGE_FULL: return t('华为云空间已满，请释放空间后刷新备份。');
    case cloudSync.ErrorType.LOCAL_STORAGE_FULL: return t('本机存储空间不足，请清理后重试。');
    case cloudSync.ErrorType.DEVICE_TEMPERATURE_TOO_HIGH: return t('设备温度过高，请稍后刷新备份。');
    default: return t('云端同步失败（{0}），请稍后刷新备份。', [code]);
  }
}

function logCleanup(error: Error): void {
  Diagnostics.log('warn', 'backup', 'cleanup_failed', undefined, error);
}

// start() only acknowledges the request; completion is delivered through progress.
// A bounded wait leaves upload to the OS and never claims that a local file is backed up.
async function requestSync(cancellation?: Cancellation): Promise<boolean> {
  return whenCloudReady('cloud_sync', () => requestSyncAttempt(cancellation));
}

async function requestSyncAttempt(cancellation?: Cancellation): Promise<boolean> {
  cancellation?.check();
  const sync = new cloudSync.FileSync();
  const startedAt = Date.now();
  let subscribed = false;
  let timer: number = -1;
  let callback: (progress: cloudSync.SyncProgress) => void = () => {};
  let unsubscribe: () => void = () => {};
  try {
    return await new Promise<boolean>((resolve, reject) => {
      let initial = true;
      let accepted = false;
      let terminal: boolean | undefined = undefined;
      let settled = false;
      const finish = (completed: boolean): void => {
        if (settled) { return; }
        settled = true;
        Diagnostics.log(completed ? 'info' : 'warn', 'backup', 'cloud_sync_finished', {
          ready: accepted, enabled: completed, elapsedMs: Date.now() - startedAt
        });
        resolve(completed);
      };
      const fail = (error: Error): void => { if (!settled) { settled = true; reject(error); } };
      callback = (progress: cloudSync.SyncProgress): void => {
        if (settled) { return; }
        Diagnostics.log(!initial && progress.error !== cloudSync.ErrorType.NO_ERROR ? 'warn' : 'info', 'backup', 'cloud_sync_progress', {
          phase: initial ? 'initial' : 'active', eventCode: progress.state, code: progress.error, ready: accepted,
          elapsedMs: Date.now() - startedAt
        });
        if (initial) {
          // Registration sends the previous state, including COMPLETED. Consume it BEFORE
          // starting this run, so a delayed snapshot cannot masquerade as its completion.
          initial = false;
          try {
            sync.start().then(() => {
              accepted = true;
              if (terminal !== undefined) { finish(terminal); }
            }).catch((error: Error) => fail(error));
          } catch (error) { fail(error as Error); }
          return;
        }
        if (progress.error !== cloudSync.ErrorType.NO_ERROR) { fail(new Error(syncError(progress.error))); }
        else if (progress.state === cloudSync.SyncState.COMPLETED) { terminal = true; if (accepted) { finish(true); } }
        else if (progress.state === cloudSync.SyncState.STOPPED) { terminal = false; if (accepted) { finish(false); } }
        else if (progress.state === cloudSync.SyncState.UPLOAD_FAILED || progress.state === cloudSync.SyncState.DOWNLOAD_FAILED) {
          fail(new Error(syncError(progress.error)));
        }
      };
      timer = setTimeout(() => finish(false), 30000);
      sync.on('progress', callback); subscribed = true;
      if (cancellation) { unsubscribe = cancellation.onCancel(() => fail(new Error(t('后台备份时间已结束，请稍后重试。')))); }
    });
  } finally {
    clearTimeout(timer);
    unsubscribe();
    if (subscribed) { try { sync.off('progress', callback); } catch (error) { logCleanup(error as Error); } }
  }
}

async function download(path: string): Promise<void> {
  const cache = new cloudSync.CloudFileCache();
  const uri = fileUri.getUriFromPath(path);
  let subscribed = false; let started = false; let complete = false; let timer: number = -1;
  let processed = 0;
  let callback: (progress: cloudSync.DownloadProgress) => void = () => {};
  try {
    await new Promise<void>((resolve, reject) => {
      const resetTimeout = (): void => {
        clearTimeout(timer);
        timer = setTimeout(() => reject(new Error(t('备份下载超时，请检查网络后重试。'))), 60000);
      };
      callback = (progress: cloudSync.DownloadProgress): void => {
        if (progress.uri !== uri) { return; }
        if (progress.processed > processed) { processed = progress.processed; resetTimeout(); }
        if (progress.state === cloudSync.State.COMPLETED && progress.error === cloudSync.DownloadErrorType.NO_ERROR) {
          complete = true; resolve();
        } else if (progress.state === cloudSync.State.FAILED || progress.state === cloudSync.State.STOPPED || progress.error !== cloudSync.DownloadErrorType.NO_ERROR) {
          reject(new Error(t('备份下载失败（{0}），请检查网络与本机空间后重试。', [progress.error])));
        }
      };
      cache.on('progress', callback); subscribed = true;
      resetTimeout();
      started = true; cache.start(uri).catch((error: Error) => reject(error));
    });
  } finally {
    clearTimeout(timer);
    if (started && !complete) { try { await cache.stop(uri); } catch (error) { logCleanup(error as Error); } }
    if (subscribed) { try { cache.off('progress', callback); } catch (error) { logCleanup(error as Error); } }
  }
}

async function restoreCloudFile(context: common.UIAbilityContext, name: string, local: AppData, openID: string, conflicts: BackupConflictMode = 'skip'): Promise<AppData> {
  if (!validBackupName(name)) { throw new Error(t('备份文件无效。')); }
  const path = await backupDirectory(context) + '/' + name;
  const stat = await fs.lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t('备份文件无效。')); }
  try {
    if ((await fs.stat(path)).location === 2) { await download(path); }
    return await readBackupFile(context, path, local, openID, conflicts);
  } finally { await releaseUploadedCache(path); }
}

async function releaseUploadedCache(path: string): Promise<void> {
  try {
    // A cloud-only snapshot remains restorable, and location 1 is the only copy.
    if ((await fs.stat(path)).location === 3) {
      new cloudSync.CloudFileCache().cleanFileCache(fileUri.getUriFromPath(path));
    }
  } catch (error) { Diagnostics.log('warn', 'backup', 'cache_release_failed', undefined, error as Error); }
}

// Every writer uses the same ordering, even when devices observe different subsets of the cloud directory.
async function finishUpload(context: common.UIAbilityContext, openID: string, name?: string,
  cancellation?: Cancellation): Promise<boolean> {
  const items = await CloudBackup.list(context, true);
  const keeper = latestCloudConfiguration(items);
  if (!keeper) { return false; }
  if (name) {
    const expected = backupSnapshot(name);
    const target = items.find((item) => item.name === name);
    if (!expected || !name.startsWith('tinybot-config-') || (target && !uploaded(target))) { return false; }
    if (!target && (keeper.createdAt < expected.createdAt ||
      (keeper.createdAt === expected.createdAt && keeper.name <= name))) { return false; }
  }
  const directory = await backupDirectory(context), keeperPath = directory + '/' + keeper.name;
  const obsolete = items.filter((item) => uploaded(item) && item.name !== keeper.name);
  try {
    if (obsolete.length) {
      cancellation?.check();
      if (keeper.location === 2) { await download(keeperPath); }
      cancellation?.check();
      await verifyConfigurationBackup(context, keeperPath, openID);
      const location = (await fs.stat(keeperPath)).location;
      if (location !== 2 && location !== 3) { throw new Error(t('云端同步尚未完成，请稍后重试恢复备份。')); }
      for (const item of obsolete) {
        cancellation?.check();
        try { await fs.unlink(directory + '/' + item.name); }
        catch (error) { if ((error as BusinessError).code !== FILE_NOT_FOUND) { throw error as Error; } }
      }
      if (!await requestSync(cancellation)) { throw new Error(t('旧备份删除尚未同步。')); }
    }
    return true;
  } catch (error) {
    Diagnostics.log('error', 'backup', 'retire_failed', undefined, error as Error);
    throw new Error(t('备份已上传，但旧备份清理未完成：{0}', [cloudBackupError(error as Error)]));
  } finally {
    await releaseUploadedCache(keeperPath);
  }
}

export class CloudBackup {
  static get busy(): boolean { return backupBusy(); }
  static async available(context: common.UIAbilityContext): Promise<boolean> {
    return !!context.cloudFileDir && await fs.access(context.cloudFileDir);
  }
  // Listing cached metadata does not create or upload any snapshot.
  static async list(context: common.UIAbilityContext, includeConflicts: boolean = false): Promise<CloudBackupItem[]> {
    let operation = 'cloud_directory';
    try {
      const directory = await backupDirectory(context);
      operation = 'access';
      if (!await fs.access(directory)) { return []; }
      const result: CloudBackupItem[] = [];
      operation = 'list';
      for (const name of await fs.listFile(directory)) {
        const match = name.match(SNAPSHOT_NAME);
        if (!validBackupName(name) && !(includeConflicts && isConflictBackup(name))) { continue; }
        operation = 'stat';
        try {
          const stat = await fs.lstat(directory + '/' + name);
          if (!stat.isFile() || stat.isSymbolicLink()) { continue; }
          // lstat lacks native FileInfo; reading its location can crash libfs.
          const info = await fs.stat(directory + '/' + name);
          const snapshot = backupSnapshot(name);
          result.push({ name: name, createdAt: snapshot?.createdAt || (match ? Number(match[1]) : info.mtime * 1000),
            deviceId: snapshot?.deviceId, size: stat.size, location: info.location });
        } catch (error) {
          // Another device can remove an older snapshot while the directory is being read.
          if ((error as BusinessError).code !== FILE_NOT_FOUND) { throw error as Error; }
        }
      }
      return result.sort((a: CloudBackupItem, b: CloudBackupItem) => b.createdAt - a.createdAt);
    } catch (error) {
      Diagnostics.log('error', 'backup', 'cloud_list_failed', { operation: operation }, error as Error);
      throw error as Error;
    }
  }

  static sync(cancellation?: Cancellation): Promise<boolean> { return withBackupOperation(() => requestSync(cancellation)); }
  static retryUpload(context: common.UIAbilityContext, options?: CloudBackupRetryOptions): Promise<boolean> {
    return withBackupOperation(async () => {
      const openID = options?.openID ?? await huaweiAccount.backupOpenID(context);
      if (!await requestSync(options?.cancellation)) { return false; }
      return finishUpload(context, openID, options?.name, options?.cancellation);
    });
  }

  static remove(context: common.UIAbilityContext, name: string): Promise<boolean> {
    return withBackupOperation(async () => {
      if (!validBackupName(name)) { throw new Error(t('备份文件无效。')); }
      const path = await backupDirectory(context) + '/' + name;
      const stat = await fs.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t('备份文件无效。')); }
      await fs.unlink(path);
      try { return await requestSync(); }
      catch (error) {
        throw new Error(t('备份已从本机列表移除，云端删除尚待同步：{0}', [cloudBackupError(error as Error)]));
      }
    });
  }

  static create(context: common.UIAbilityContext, data: AppData, options?: CloudBackupCreateOptions): Promise<CloudBackupCreateResult> {
    return withBackupOperation(async () => {
      const cancellation = options?.cancellation;
      cancellation?.check();
      const openID = options?.openID ?? await huaweiAccount.backupOpenID(context);
      cancellation?.check();
      const deviceId = backupDeviceId(context);
      const pending = (item: CloudBackupItem): boolean =>
        item.deviceId === deviceId && configName(item.name) && item.location === 1;
      let items = await CloudBackup.list(context);
      if (items.some(pending)) {
        await requestSync(cancellation);
        items = await CloudBackup.list(context);
        if (items.some(pending)) { return 'blocked'; }
      }
      cancellation?.check();
      const name = newBackupSnapshot(context, items.find((item) => configName(item.name))?.createdAt);
      const directory = await backupDirectory(context);
      const source = await createConfigurationFile(context, data, openID, cancellation);
      const target = directory + '/' + name;
      const temporary = directory + '/tinybot-' + util.generateRandomUUID() + '.partial';
      try {
        cancellation?.check();
        if (!await fs.access(directory)) { await fs.mkdir(directory); }
        if (await fs.access(target)) {
          throw new Error(t('备份版本已存在，请创建新的备份。'));
        }
        await copyFileBytes(source, temporary);
        cancellation?.check();
        await fs.rename(temporary, target);
        options?.onStaged?.(name);
      } catch (error) {
        if ((error as BusinessError).code === 13900012) {
          throw new Error(t('无法写入华为云空间（13900012）。请在系统云空间中开启 Tinybot 后重试。'));
        }
        throw error as Error;
      } finally {
        await fs.unlink(source);
        if (await fs.access(temporary)) { await fs.unlink(temporary); }
      }
      if (!await requestSync(cancellation)) { return 'pending'; }
      return await finishUpload(context, openID, name, cancellation) ? 'uploaded' : 'pending';
    });
  }

  static restore(context: common.UIAbilityContext, name: string, local: AppData, conflicts: BackupConflictMode = 'skip'): Promise<AppData> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      return restoreCloudFile(context, name, local, openID, conflicts);
    });
  }
  static restoreLatest(context: common.UIAbilityContext, local: AppData): Promise<AppData> {
    return withBackupOperation(async () => {
      const openID = await huaweiAccount.backupOpenID(context);
      if (!await requestSync()) { throw new Error(t('云端同步尚未完成，请稍后重试恢复备份。')); }
      const latest = latestCloudBackup(await CloudBackup.list(context));
      if (!latest) { throw new Error(t('云端暂无可恢复的备份，请先在原设备完成备份。')); }
      return restoreCloudFile(context, latest.name, local, openID);
    });
  }
}
