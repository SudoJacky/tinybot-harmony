import { PageStyles } from '../common/PageStyles';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { getLocale, t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { Diagnostics } from '../model/Diagnostics';
import { CloudBackup, cloudBackupError, latestCloudBackup } from '../services/CloudBackup';
import { AutoCloudBackup, autoCloudBackup } from '../services/AutoCloudBackup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Btn, Space, Radius } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';
import { BackupLoginRequired } from '../services/HuaweiAccount';

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
  private visible: boolean = false;
  private reading?: Promise<void>;
  private statusError: boolean = false;

  aboutToAppear(): void { this.visible = true; this.refreshStatus(); }
  aboutToDisappear(): void { this.visible = false; }
  private async foregroundChanged(): Promise<void> {
    if (!this.foreground || !this.visible || this.busy) { return; }
    await this.reading;
    if (this.foreground && this.visible && !this.busy) { await this.refreshStatus(); }
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.busy || this.busy; }
  private refreshStatus(): Promise<void> {
    if (!this.reading) { this.reading = this.readStatus().finally(() => { this.reading = undefined; }); }
    return this.reading;
  }
  private async readStatus(): Promise<void> {
    try {
      const items = await CloudBackup.list(this.context());
      if (!this.visible) { return; }
      this.automatic.confirmUploaded(items);
      if (this.statusError) { this.error = ''; this.statusError = false; }
      const latest = latestCloudBackup(items);
      this.backupDate = latest ? new Date(latest.createdAt).toLocaleString(getLocale()) : '';
    } catch (error) {
      Diagnostics.log('warn', 'backup', 'cloud_list_failed', undefined, error as Error);
      if (this.visible && (!this.error || this.statusError)) { this.error = cloudBackupError(error as Error); this.statusError = true; }
    }
  }
  private async cloud(restore: boolean): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = ''; this.statusError = false; this.needsLogin = false;
    this.status = restore ? t('正在从云端下载并恢复备份…') : t('正在备份到云端…');
    try {
      await this.reading;
      this.error = ''; this.statusError = false;
      const context = this.context();
      if (restore) {
        const data = await CloudBackup.restoreLatest(context, this.app.exportSnapshot());
        if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); }
        if (this.visible) { this.status = t('备份已恢复，已保留本机已有数据。'); }
      } else {
        const completed = await CloudBackup.create(context, this.app.exportSnapshot());
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
        Text(t('云端只维护一份备份，自动备份和手动备份更新同一份内容。恢复时自动下载云端备份并合并导入，保留本机已有数据和密钥。'))
          .fontSize(13).lineHeight(20).fontColor($r('app.color.text_secondary')).width('100%')
        GroupCard() {
          Column() {
            NavRow({ title: t('备份'), subtitle: t('将当前数据保存到云端，替换上一份备份'),
              compId: 'create-cloud-backup', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.cloud(false) })
            RowDivider()
            NavRow({ title: t('恢复备份'), subtitle: t('自动从云端获取最新备份并合并恢复'),
              compId: 'restore-cloud-backup', icon: $r('sys.symbol.arrow_clockwise'), disabled: this.locked(), onTap: () => this.cloud(true) })
          }
        }
        if (this.backupDate) {
          Text(t('云端备份 · {0}', [this.backupDate])).id('cloud-backup-date').fontSize(13)
            .fontColor($r('app.color.text_secondary')).width('100%')
        }
        Text(this.automatic.status).id('auto-cloud-backup-status').fontSize(13)
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
        Text(t('包含对话、文件、生活看板、小程序、Skills、设置和用量记录。API Key 等连接凭据使用当前华为账号加密；对话和文件不加密。隐私授权、系统权限和华为账号登录需在新设备重新完成。'))
          .fontSize(13).lineHeight(19).fontColor($r('app.color.text_secondary')).width('100%')
          .padding(Space.md).borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xl }).attributeModifier(PageStyles.form)
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }
  build() { this.backupTab() }
}
