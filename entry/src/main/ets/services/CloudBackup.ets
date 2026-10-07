import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cloudSync, fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppData } from '../model/Conversation';
import { t } from '../model/I18n';
import { createBackupFile, readBackupFile } from './Backup';

export interface CloudBackupItem {
  name: string;
  createdAt: number;
  size: number;
  location: number;
}

const SNAPSHOT_NAME = /^tinybot-(\d{13})-[0-9a-f-]{36}\.json$/;
const MAX_BACKUP = 20 * 1024 * 1024;
let operating: boolean = false;

// Native sync APIs have limited concurrency. This lock also covers a reopened page.
async function exclusive<T>(action: () => Promise<T>): Promise<T> {
  if (operating) { throw new Error(t('另一项云备份操作正在进行，请稍后再试。')); }
  operating = true;
  try { return await action(); } finally { operating = false; }
}

async function backupDirectory(context: common.UIAbilityContext): Promise<string> {
  const root = context.cloudFileDir;
  if (!root || !await fs.access(root)) { throw new Error(t('华为云空间尚不可用，请登录华为账号，并在系统云空间中开启 Tinybot。')); }
  return root + '/tinybot-backups';
}

export function cloudBackupError(error: Error): string {
  const code = (error as BusinessError).code;
  if (code === 22400001 || code === 801) { return t('华为云空间尚不可用，请登录华为账号，并在系统云空间中开启 Tinybot。'); }
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
  hilog.warn(0x0000, 'CloudBackup', 'Native cleanup failed: %{public}s', String((error as BusinessError).code));
}

// start() only acknowledges the request; completion is delivered through progress.
// A bounded wait leaves upload to the OS and never claims that a local file is backed up.
async function requestSync(): Promise<boolean> {
  const sync = new cloudSync.FileSync();
  let subscribed = false;
  let timer: number = -1;
  let callback: (progress: cloudSync.SyncProgress) => void = () => {};
  try {
    return await new Promise<boolean>((resolve, reject) => {
      callback = (progress: cloudSync.SyncProgress): void => {
        if (progress.error !== cloudSync.ErrorType.NO_ERROR) { reject(new Error(syncError(progress.error))); }
        else if (progress.state === cloudSync.SyncState.COMPLETED) { resolve(true); }
        else if (progress.state === cloudSync.SyncState.STOPPED) { resolve(false); }
        else if (progress.state === cloudSync.SyncState.UPLOAD_FAILED || progress.state === cloudSync.SyncState.DOWNLOAD_FAILED) {
          reject(new Error(syncError(progress.error)));
        }
      };
      sync.on('progress', callback); subscribed = true;
      timer = setTimeout(() => resolve(false), 30000);
      sync.start().catch((error: Error) => reject(error));
    });
  } finally {
    clearTimeout(timer);
    if (subscribed) { try { sync.off('progress', callback); } catch (error) { logCleanup(error as Error); } }
  }
}

async function download(path: string): Promise<void> {
  const cache = new cloudSync.CloudFileCache();
  const uri = fileUri.getUriFromPath(path);
  let subscribed = false; let started = false; let complete = false; let timer: number = -1;
  let callback: (progress: cloudSync.DownloadProgress) => void = () => {};
  try {
    await new Promise<void>((resolve, reject) => {
      callback = (progress: cloudSync.DownloadProgress): void => {
        if (progress.uri !== uri) { return; }
        if (progress.state === cloudSync.State.COMPLETED && progress.error === cloudSync.DownloadErrorType.NO_ERROR) {
          complete = true; resolve();
        } else if (progress.state === cloudSync.State.FAILED || progress.state === cloudSync.State.STOPPED || progress.error !== cloudSync.DownloadErrorType.NO_ERROR) {
          reject(new Error(t('备份下载失败（{0}），请检查网络与本机空间后重试。', [progress.error])));
        }
      };
      cache.on('progress', callback); subscribed = true;
      timer = setTimeout(() => reject(new Error(t('备份下载超时，请检查网络后重试。'))), 60000);
      started = true; cache.start(uri).catch((error: Error) => reject(error));
    });
  } finally {
    clearTimeout(timer);
    if (started && !complete) { try { await cache.stop(uri); } catch (error) { logCleanup(error as Error); } }
    if (subscribed) { try { cache.off('progress', callback); } catch (error) { logCleanup(error as Error); } }
  }
}

export class CloudBackup {
  // Listing cached metadata does not create or upload any snapshot.
  static async list(context: common.UIAbilityContext): Promise<CloudBackupItem[]> {
    const directory = await backupDirectory(context);
    if (!await fs.access(directory)) { return []; }
    const result: CloudBackupItem[] = [];
    for (const name of await fs.listFile(directory)) {
      const match = name.match(SNAPSHOT_NAME);
      if (!match) { continue; }
      const stat = await fs.lstat(directory + '/' + name);
      if (stat.isFile() && !stat.isSymbolicLink()) {
        // lstat lacks native FileInfo; reading its location can crash libfs.
        const location = (await fs.stat(directory + '/' + name)).location;
        result.push({ name: name, createdAt: Number(match[1]), size: stat.size, location: location });
      }
    }
    return result.sort((a: CloudBackupItem, b: CloudBackupItem) => b.createdAt - a.createdAt);
  }

  static sync(): Promise<boolean> { return exclusive(() => requestSync()); }

  static remove(context: common.UIAbilityContext, name: string): Promise<boolean> {
    return exclusive(async () => {
      if (!SNAPSHOT_NAME.test(name)) { throw new Error(t('备份文件无效。')); }
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

  static create(context: common.UIAbilityContext, data: AppData): Promise<boolean> {
    return exclusive(async () => {
      const directory = await backupDirectory(context);
      const source = await createBackupFile(context, data);
      const name = 'tinybot-' + Date.now() + '-' + util.generateRandomUUID() + '.json';
      const temporary = directory + '/' + name + '.partial';
      try {
        if (!await fs.access(directory)) { await fs.mkdir(directory); }
        await fs.copyFile(source, temporary);
        // Only complete snapshots are discoverable; never overwrite an older backup.
        await fs.rename(temporary, directory + '/' + name);
      } catch (error) {
        if ((error as BusinessError).code === 13900012) {
          throw new Error(t('无法写入华为云空间（13900012）。请在系统云空间中开启 Tinybot 后重试。'));
        }
        throw error as Error;
      } finally {
        await fs.unlink(source);
        if (await fs.access(temporary)) { await fs.unlink(temporary); }
      }
      return requestSync();
    });
  }

  static restore(context: common.UIAbilityContext, name: string): Promise<AppData> {
    return exclusive(async () => {
      if (!SNAPSHOT_NAME.test(name)) { throw new Error(t('备份文件无效。')); }
      const path = await backupDirectory(context) + '/' + name;
      const stat = await fs.lstat(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_BACKUP) { throw new Error(t('备份文件无效。')); }
      if ((await fs.stat(path)).location === 2) { await download(path); }
      return readBackupFile(context, path);
    });
  }
}
