import { AppearanceStyle } from '../common/AppearanceStyle';
import { Btn, Font, Space } from '../common/Theme';
import { Banner } from '../common/Widgets';
import { t } from '../model/I18n';
import { BackupLoginRequired } from '../services/HuaweiAccount';

@CustomDialog
export struct StartupBackupDialog {
  controller?: CustomDialogController;
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  date: string = '';
  onRestore: () => Promise<void> = async () => {};
  onLogin: () => Promise<void> = async () => {};
  @State private busy: boolean = false;
  @State private error: string = '';
  @State private needsLogin: boolean = false;
  private async restore(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = ''; this.needsLogin = false;
    try { await this.onRestore(); this.controller?.close(); }
    catch (error) { this.needsLogin = error instanceof BackupLoginRequired; this.error = (error as Error).message; }
    finally { this.busy = false; }
  }
  private async login(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true; this.error = '';
    try { await this.onLogin(); this.needsLogin = false; }
    catch (error) { this.error = (error as Error).message; }
    finally { this.busy = false; }
  }
  build() {
    Column({ space: Space.md }) {
      Text(t('检测到云备份')).fontFamily(this.appearance.fontFamily).fontSize(Font.title)
        .fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary')).width('100%')
      Text(t('发现 {0} 的备份。是否恢复到这台设备？', [this.date])).fontFamily(this.appearance.fontFamily)
        .fontSize(Font.body).fontColor($r('app.color.text_secondary')).width('100%')
      Text(t('恢复 API Key 时需登录创建备份时使用的华为账号。')).fontFamily(this.appearance.fontFamily)
        .fontSize(Font.body).fontColor($r('app.color.text_secondary')).width('100%')
      if (this.busy) { LoadingProgress().width(24).height(24) }
      if (this.error) { Banner({ text: this.error, compId: 'startup-backup-error' }) }
      if (this.needsLogin) {
        Button(t('登录华为账号')).id('startup-backup-login')
          .attributeModifier(Btn.primary).width('100%').enabled(!this.busy).onClick(() => this.login())
      } else {
        Button(this.busy ? t('正在处理备份…') : t('恢复备份')).id('startup-backup-restore')
          .attributeModifier(Btn.primary).width('100%').enabled(!this.busy).onClick(() => this.restore())
      }
      Button(t('暂不')).id('startup-backup-skip').attributeModifier(Btn.tonal).width('100%')
        .enabled(!this.busy).onClick(() => this.controller?.close())
    }.id('startup-backup-dialog').width('100%').padding(Space.xl)
  }
}
