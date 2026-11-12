import { PageStyles } from '../common/PageStyles';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { getLocale, t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { CloudBackup, CloudBackupItem, cloudBackupError, latestCloudBackup } from '../services/CloudBackup';
import { reviewBackupRestore } from './BackupRestoreReview';
import { AutoCloudBackup, autoCloudBackup } from '../services/AutoCloudBackup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Space } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';
import { BackupLoginRequired, huaweiAccount } from '../services/HuaweiAccount';
import { NativeData } from '../services/NativeData';

@Component
export struct BackupPanel {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink app: ChatViewModel;
  onWebDav: () => void = () => {};
  onLogin: () => void = () => {};
  @StorageProp('tinybot.foreground') @Watch('foregroundChanged') private foreground: boolean = true;
  @State private automatic: AutoCloudBackup = autoCloudBackup;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private status: string = '';
  @State private backupDate: string = '';
  @State private needsLogin: boolean = false;
  @State private recoveryPending: boolean = false;
  @State private versions: CloudBackupItem[] = [];
  @State private showVersions: boolean = false;
  private visible: boolean = false;
  private reading?: Promise<void>;
  private statusError: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.recoveryPending = NativeData.forFilesDir(this.context().filesDir)?.autoBackupReady() === false;
    this.refreshStatus();
  }
  aboutToDisappear(): void { this.visible = false; }
  private async foregroundChanged(): Promise<void> {
    if (!this.foreground || !this.visible || this.busy) { return; }
    await this.reading;
    if (this.foreground && this.visible && !this.busy) { await this.refreshStatus(); }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.sharedBusy || this.busy; }
  private refreshStatus(): Promise<void> {
    if (!this.reading) { this.reading = this.readStatus().finally(() => { this.reading = undefined; }); }
    return this.reading;
  }
  private async readStatus(): Promise<void> {
    try {
      const items = await CloudBackup.list(this.context());
      if (!this.visible) { return; }
      this.automatic.confirmUploaded(items);
      this.versions = items.filter((item) => item.location === 2 || item.location === 3);
      if (this.statusError) { this.error = ''; this.statusError = false; }
      const latest = latestCloudBackup(items);
      this.backupDate = latest ? new Date(latest.createdAt).toLocaleString(getLocale()) : '';
    } catch (error) {
      Diagnostics.log('warn', 'backup', 'cloud_list_failed', undefined, error as Error);
      if (this.visible && (!this.error || this.statusError)) { this.error = cloudBackupError(error as Error); this.statusError = true; }
    }
  }
  private async chooseRestore(): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.needsLogin = false; this.versions = []; this.showVersions = false;
    try {
      await huaweiAccount.backupOpenID(this.context());
      if (!await CloudBackup.sync()) { throw new Error(t('云端同步尚未完成，请稍后重试恢复备份。')); }
      await this.reading;
      this.versions = (await CloudBackup.list(this.context())).filter((item) => item.location === 2 || item.location === 3);
      this.showVersions = true;
      if (!this.versions.length) { this.error = t('云端暂无可恢复的备份，请先在原设备完成备份。'); }
    } catch (error) { this.error = cloudBackupError(error as Error); this.needsLogin = error instanceof BackupLoginRequired; }
    finally { this.busy = false; }
  }
  private async cloud(restore: boolean, name: string = ''): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.statusError = false; this.needsLogin = false;
    this.status = restore ? t('正在从云端下载并恢复备份…') : t('正在备份到云端…');
    try {
      await this.reading;
      this.error = ''; this.statusError = false;
      const context = this.context();
      if (restore) {
        const data = name ? await CloudBackup.restore(context, name, this.app.exportSnapshot(), 'copy') :
          await CloudBackup.restoreLatest(context, this.app.exportSnapshot());
        if (!await reviewBackupRestore(this.getUIContext(), data)) { this.status = ''; return; }
        if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); }
        NativeData.forFilesDir(context.filesDir)?.allowAutoBackup();
        this.recoveryPending = false;
        if (this.visible) { this.status = t('备份已恢复，已保留本机已有数据。'); }
      } else {
        const completed = await CloudBackup.create(context, this.app.exportSnapshot());
        if (completed) { NativeData.forFilesDir(context.filesDir)?.allowAutoBackup(); this.recoveryPending = false; }
        if (this.visible) { this.status = completed ? t('备份已上传到云端。') : t('备份已保存在本机，等待上传。请联网后再次备份。'); }
      }
    } catch (error) {
      if (this.visible) {
        this.needsLogin = error instanceof BackupLoginRequired;
        this.error = cloudBackupError(error as Error); this.status = '';
      }
    } finally {
      if (!this.needsLogin) { await this.refreshStatus(); }
      this.busy = false;
    }
  }

  @Builder
  backupTab() {
    Scroll() {
      Column({ space: Space.md }) {
        SectionHeader({ title: t('第三方备份位置') })
        GroupCard() {
          NavRow({ title: t('WebDAV'), subtitle: t('使用自己的 WebDAV 服务器手动备份和恢复'),
            compId: 'webdav-backup-settings', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.onWebDav() })
        }
        SectionHeader({ title: t('华为云空间') })
        GroupCard() {
          Column() {
            NavRow({ title: t('备份'), subtitle: t('每台设备独立保存最近 3 个备份版本'),
              compId: 'create-cloud-backup', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.cloud(false) })
            RowDivider()
            NavRow({ title: t('恢复备份'), subtitle: t('选择设备与版本，确认恢复内容'),
              compId: 'restore-cloud-backup', icon: $r('sys.symbol.arrow_clockwise'), disabled: this.locked(), onTap: () => this.chooseRestore() })
          }
        }
        if (this.showVersions) {
          GroupCard() {
            Column() {
              ForEach(this.versions, (item: CloudBackupItem) => {
                NavRow({ title: new Date(item.createdAt).toLocaleString(getLocale()),
                  subtitle: item.deviceId ? t('设备 {0}', [item.deviceId.slice(0, 8)]) : t('旧版备份'),
                  icon: $r('sys.symbol.clock'), disabled: this.locked(), onTap: () => this.cloud(true, item.name) })
              }, (item: CloudBackupItem) => item.name)
            }
          }
        }
        if (this.backupDate) {
          Text(t('云端备份 · {0}', [this.backupDate])).id('cloud-backup-date').fontSize(13)
            .fontColor($r('app.color.text_secondary')).width('100%')
        }
        Text(this.recoveryPending ? t('数据恢复期间已暂停自动备份。恢复云备份或手动完成新备份后，将继续自动备份。') : this.automatic.status)
          .id('auto-cloud-backup-status').fontSize(13)
          .fontColor($r('app.color.text_secondary')).width('100%')
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color(this.appearance.accent)
            Text(this.status).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.width('100%')
        } else if (this.status) {
          Banner({ text: this.status, danger: false, compId: 'cloud-backup-status' })
        }
        if (this.error) { Banner({ text: this.error, compId: 'cloud-backup-error' }) }
        if (this.needsLogin) {
          Button(t('登录华为账号')).attributeModifier(Btn.tonal).id('cloud-backup-login').onClick(() => this.onLogin())
        }
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl }).attributeModifier(PageStyles.form)
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
  build() { this.backupTab() }
}
