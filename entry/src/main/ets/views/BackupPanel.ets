import { getLocale, t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { exportBackup, readBackup } from '../services/Backup';
import { CloudBackup, CloudBackupItem, cloudBackupError } from '../services/CloudBackup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Space, Radius } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';

@Component
export struct BackupPanel {
  @ObjectLink app: ChatViewModel;
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private cloudError: string = '';
  @State private cloudStatus: string = '';
  @State private cloudItems: CloudBackupItem[] = [];
  @State private cloudLoaded: boolean = false;
  private visible: boolean = false;

  aboutToAppear(): void { this.visible = true; this.loadCloudList(); }
  aboutToDisappear(): void { this.visible = false; }

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private locked(): boolean { return this.app.busy || this.busy; }

  private async loadCloudList(): Promise<void> {
    try {
      const items = await CloudBackup.list(this.context());
      if (this.visible) { this.cloudItems = items; this.cloudLoaded = true; }
    } catch (error) {
      if (this.visible) { this.cloudItems = []; this.cloudLoaded = false; this.cloudError = cloudBackupError(error as Error); }
    }
  }

  private async openCloudSettings(): Promise<void> {
    try { await this.context().startAbility({ action: 'ohos.want.action.viewData', uri: 'hicloud://cloudDrive/getInfo?path=MainActivity' }); }
    catch (_) { this.cloudError = t('无法打开云空间，请前往系统「设置 → 云空间」，登录华为账号并开启 Tinybot。'); }
  }

  private date(item: CloudBackupItem): string { return new Date(item.createdAt).toLocaleString(getLocale()); }
  private detail(item: CloudBackupItem): string {
    const size = (item.size / (1024 * 1024)).toFixed(2) + ' MB';
    if (item.location === 2 || item.location === 3) { return t('已上传云端 · {0} · 点按恢复', [size]); }
    if (item.location === 1) { return t('仅保存在本机，等待上传 · {0}', [size]); }
    return t('云端状态未知，请刷新确认 · {0}', [size]);
  }

  private confirmRestore(item: CloudBackupItem): void {
    if (this.locked()) { return; }
    this.getUIContext().showAlertDialog({ title: t('恢复这份备份？'),
      message: t('将 {0} 的备份恢复为独立副本，现有对话会保留。恢复后需要重新配置密钥。', [this.date(item)]),
      primaryButton: { value: t('取消'), action: () => {} },
      secondaryButton: { value: t('恢复'), action: () => this.cloud('restore', item.name) } });
  }

  private async cloud(action: string, name: string = ''): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.cloudError = ''; this.cloudStatus = ''; this.error = '';
    try {
      const context = this.context();
      if (action === 'restore') {
        const data = await CloudBackup.restore(context, name);
        if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); }
        if (this.visible) { this.cloudStatus = t('备份已恢复为独立副本'); }
      } else {
        const completed = action === 'create' ? await CloudBackup.create(context, this.app.exportSnapshot()) : await CloudBackup.sync();
        if (this.visible) { this.cloudStatus = completed ? t('已刷新备份列表，请以每份备份的云端状态为准。') : t('同步尚未完成，请稍后刷新。未上传的备份只保存在本机。'); }
      }
    } catch (error) { if (this.visible) { this.cloudError = cloudBackupError(error as Error); } }
    finally { await this.loadCloudList(); if (this.visible) { this.busy = false; } }
  }

  private async backup(restore: boolean): Promise<void> {
    if (this.locked()) { return; }
    this.busy = true; this.error = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (restore) { const data = await readBackup(context); if (data) { if (!await this.app.importSnapshot(data)) { throw new Error(this.app.error); } this.getUIContext().getPromptAction().showToast({ message: t("备份已恢复为独立副本") }); } }
      else { await exportBackup(context, this.app.exportSnapshot()); }
    } catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; }
  }

  @Builder
  backupTab() {
    Scroll() {
      Column() {
        SectionHeader({ title: t('华为云空间') })
        GroupCard() {
          Column() {
            NavRow({ title: t('备份到华为云空间'), subtitle: t('包含对话、附件、工作区、Skills、模板与记忆，最多 20 MB'),
              compId: 'create-cloud-backup', icon: $r('sys.symbol.cloud'), disabled: this.locked(), onTap: () => this.cloud('create') })
            RowDivider()
            NavRow({ title: t('刷新备份列表'), subtitle: t('获取其他设备的备份，并重试待上传的备份'),
              compId: 'refresh-cloud-backups', icon: $r('sys.symbol.arrow_clockwise'), disabled: this.locked(), onTap: () => this.cloud('refresh') })
            RowDivider()
            NavRow({ title: t('打开华为云空间'), compId: 'open-cloud-settings', disabled: this.busy, onTap: () => this.openCloudSettings() })
          }
        }
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color($r('app.color.accent'))
            Text(t('正在处理备份…')).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.margin({ top: Space.md })
        }
        if (this.cloudError) { Banner({ text: this.cloudError, compId: 'cloud-backup-error' }).margin({ top: Space.md }) }
        if (this.cloudStatus) { Banner({ text: this.cloudStatus, danger: false, compId: 'cloud-backup-status' }).margin({ top: Space.md }) }
        if (this.cloudItems.length > 0) {
          SectionHeader({ title: t('可恢复的备份') })
          GroupCard() {
            Column() {
              ForEach(this.cloudItems, (item: CloudBackupItem, index: number) => {
                if (index > 0) { RowDivider() }
                NavRow({ title: this.date(item), subtitle: this.detail(item), compId: 'cloud-backup-' + item.name,
                  disabled: this.locked(), onTap: () => this.confirmRestore(item) })
              }, (item: CloudBackupItem) => item.name + ':' + item.location + ':' + item.size)
            }
          }
        } else if (this.cloudLoaded) {
          Text(t('暂无备份。已在其他设备备份？请开启云空间后刷新列表。')).fontSize(13).lineHeight(19)
            .fontColor($r('app.color.text_secondary')).width('100%').margin({ top: Space.md })
        }
        SectionHeader({ title: t('本地备份') })
        GroupCard() {
          Column() {
            NavRow({ title: t("导出备份"), subtitle: t("存到本机，或分享到其他设备"), compId: 'export-backup',
              icon: $r('sys.symbol.square_and_arrow_down'), disabled: this.app.busy || this.busy, onTap: () => this.backup(false) })
            RowDivider()
            NavRow({ title: t("从备份导入"), subtitle: t("作为独立副本恢复，不会覆盖现有对话"), compId: 'import-backup',
              icon: $r('sys.symbol.folder_badge_plus'), disabled: this.app.busy || this.busy, onTap: () => this.backup(true) })
          }
        }
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.lock')).fontSize(16).fontColor([$r('app.color.text_secondary')])
          Text(t("API 密钥和 Token 不会导出。恢复后，请重新填写密钥并启用对应服务。")).fontSize(13).lineHeight(19).layoutWeight(1)
            .fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(VerticalAlign.Top).padding(Space.md).margin({ top: Space.md })
        .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
        if (this.error) { Banner({ text: this.error }).margin({ top: Space.md }) }
      }.width('100%').padding({ left: Space.page, right: Space.page, bottom: Space.xl })
    }.width('100%').height('100%').scrollBar(BarState.Off).align(Alignment.Top)
  }


  build() { this.backupTab() }
}
