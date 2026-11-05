import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { getLocale, t } from '../model/I18n';
import { isOnboardingCandidate } from '../model/Onboarding';
import { CloudBackup, CloudBackupItem, cloudBackupError } from './CloudBackup';
import { Cancellation } from './Cancellation';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { hostedPrivacy } from './HostedPrivacy';
import { huaweiAccount } from './HuaweiAccount';

interface BackupTask { requestId: number; generation: number; cancellation: Cancellation; running: boolean; }

// Request a finite suspension delay inside UIAbility.onBackground, before any await.
// It protects a background save from suspension, not from user/system termination.
@Observed
export class AutoCloudBackup {
  enabled: boolean = true;
  state: string = 'waiting';
  error: string = '';
  lastUploadedAt: number = 0;
  private context?: common.UIAbilityContext;
  private store?: preferences.Preferences;
  private snapshot: () => AppData = () => { throw new Error('Backup source unavailable'); };
  private ready: () => boolean = () => false;
  private generation: number = 0;
  private revision: number = 0;
  private savedRevision: number = -1;
  private savedFiles: number = -1;
  private name: string = '';
  private task?: BackupTask;

  initialize(context: common.UIAbilityContext, snapshot: () => AppData, ready: () => boolean): void {
    if (this.context === context) { return; }
    this.dispose();
    const store = preferences.getPreferencesSync(context, { name: 'tinybot-ui' });
    this.enabled = store.getSync('autoCloudBackupEnabled', true) === true;
    this.context = context; this.store = store; this.snapshot = snapshot; this.ready = ready;
    this.revision = 0; this.savedRevision = -1; this.savedFiles = -1; this.name = ''; this.error = ''; this.lastUploadedAt = 0;
    this.state = this.enabled ? 'waiting' : 'disabled';
  }

  setEnabled(value: boolean): void {
    if (!this.store) { return; }
    const previous = this.enabled;
    try { this.store.putSync('autoCloudBackupEnabled', value); this.store.flushSync(); }
    catch (error) {
      this.store.putSync('autoCloudBackupEnabled', previous);
      Diagnostics.log('warn', 'backup', 'auto_settings_failed', undefined, error as Error);
      throw error as Error;
    }
    this.enabled = value; this.state = value ? 'waiting' : 'disabled'; this.error = '';
    if (value) { this.changed(); }
    else if (this.task) { this.task.cancellation.cancel(); this.release(this.task); }
  }

  changed(): void { this.revision++; }

  confirmUploaded(items: CloudBackupItem[]): void {
    if (!this.context || !this.enabled || this.state !== 'pending' || !this.name) { return; }
    const item = items.find((entry) => entry.name === this.name && (entry.location === 2 || entry.location === 3));
    if (item) { this.state = 'uploaded'; this.lastUploadedAt = item.createdAt; }
  }

  setForeground(value: boolean): void {
    // Retry a failed native release; entering foreground never starts another backup.
    if (value && this.task && !this.task.running && this.release(this.task)) { this.task = undefined; }
  }

  onBackground(): void {
    const context = this.context;
    if (!context || !this.enabled || !hostedPrivacy.allowed || !huaweiAccount.signedIn) { return; }
    if (this.task) {
      if (this.task.running || !this.release(this.task)) { return; }
      this.task = undefined;
    }
    try {
      const startupComplete = this.store?.getSync('startupBackupState', '') === 'done' ||
        this.store?.getSync('onboardingComplete', false) === true;
      if (!this.ready() || !startupComplete || CloudBackup.busy) { return; }
      if (this.revision === this.savedRevision && NativeWorkspaceFiles.contentRevision === this.savedFiles && this.state === 'uploaded') { return; }
      const task: BackupTask = { requestId: -1, generation: this.generation, cancellation: new Cancellation(), running: true };
      // Must remain synchronous: a page watcher can run too late to request this lease.
      const info = backgroundTaskManager.requestSuspendDelay(t('自动云备份'), () => this.expire(task));
      task.requestId = info.requestId; this.task = task;
      this.run(context, task);
    } catch (error) {
      this.state = 'failed'; this.error = cloudBackupError(error as Error);
      Diagnostics.log('warn', 'backup', 'auto_task_failed', undefined, error as Error);
    }
  }

  private expire(task: BackupTask): void {
    if (task.requestId < 0) { return; }
    task.cancellation.cancel();
    if (task.generation === this.generation && this.enabled) {
      this.state = 'failed'; this.error = t('后台备份时间已结束，请稍后重试。');
      Diagnostics.log('warn', 'backup', 'auto_expired');
    }
    this.release(task);
  }

  private release(task: BackupTask): boolean {
    if (task.requestId < 0) { return true; }
    try { backgroundTaskManager.cancelSuspendDelay(task.requestId); task.requestId = -1; return true; }
    catch (error) {
      Diagnostics.log('warn', 'backup', 'auto_release_failed', undefined, error as Error);
      return false;
    }
  }

  private async run(context: common.UIAbilityContext, task: BackupTask): Promise<void> {
    try {
      if (!await CloudBackup.available(context)) { if (task.generation === this.generation) { this.state = 'waiting'; } return; }
      task.cancellation.check();
      if (task.generation !== this.generation || !this.enabled || !hostedPrivacy.allowed || !this.ready()) { return; }
      if (this.revision !== this.savedRevision || NativeWorkspaceFiles.contentRevision !== this.savedFiles) {
        const data = this.snapshot();
        if (isOnboardingCandidate(data) && !(data.config.userDocument || '').trim() &&
          !(data.productivity?.memories || []).length) { this.state = 'waiting'; return; }
        if (!this.name) {
          let id = this.store?.getSync('autoCloudBackupId', '') as string;
          if (!/^[0-9a-f-]{36}$/.test(id)) {
            id = util.generateRandomUUID(); this.store?.putSync('autoCloudBackupId', id); this.store?.flushSync();
          }
          this.name = 'tinybot-auto-' + id + '.tinybot';
        }
        const revision = this.revision;
        const files = NativeWorkspaceFiles.contentRevision;
        this.state = 'creating'; this.error = '';
        await CloudBackup.create(context, data, { name: this.name, interactive: false, cancellation: task.cancellation });
        if (task.generation !== this.generation) { return; }
        this.savedRevision = revision; this.savedFiles = files;
      } else { await CloudBackup.sync(task.cancellation); }
      task.cancellation.check();
      const items = await CloudBackup.list(context);
      if (task.generation !== this.generation || !this.enabled || !hostedPrivacy.allowed) { return; }
      const item = items.find((entry) => entry.name === this.name);
      const uploaded = item !== undefined && (item.location === 2 || item.location === 3);
      this.state = uploaded ? 'uploaded' : 'pending';
      if (uploaded && item) { this.lastUploadedAt = item.createdAt; }
    } catch (error) {
      if (task.generation === this.generation && this.enabled) {
        this.state = 'failed';
        this.error = task.cancellation.cancelled ? t('后台备份时间已结束，请稍后重试。') : cloudBackupError(error as Error);
        Diagnostics.log('warn', 'backup', 'auto_failed', undefined, error as Error);
      }
    } finally {
      task.running = false;
      if (this.release(task) && this.task === task) { this.task = undefined; }
    }
  }

  get status(): string {
    if (!this.enabled) { return t('自动云备份已关闭'); }
    if (this.state === 'creating') { return t('正在自动备份…'); }
    if (this.state === 'failed') { return this.error; }
    if (this.state === 'uploaded') { return t('自动备份已上传 · {0}', [new Date(this.lastUploadedAt).toLocaleString(getLocale())]); }
    if (this.state === 'pending') { return t('自动备份等待上传，卸载前请确认云端状态。'); }
    return t('离开应用时，有变更才自动备份；需登录并开启云空间。');
  }

  dispose(): void {
    this.generation++;
    if (this.task) { this.task.cancellation.cancel(); if (this.release(this.task) && !this.task.running) { this.task = undefined; } }
    this.context = undefined; this.store = undefined;
  }
}

export const autoCloudBackup: AutoCloudBackup = new AutoCloudBackup();
