import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { exportBackup, readBackup } from '../services/Backup';
import { ChatViewModel } from '../viewmodel/ChatViewModel';
import { Space, Radius } from '../common/Theme';
import { Banner, GroupCard, NavRow, RowDivider, SectionHeader } from '../common/Widgets';

@Component
export struct BackupPanel {
  @ObjectLink app: ChatViewModel;
  @State private busy: boolean = false;
  @State private error: string = '';
  private async backup(restore: boolean): Promise<void> {
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
        SectionHeader({ title: t("备份与恢复"), caption: t("包含对话、附件、工作区文件、Skills、模板与记忆，最多 20 MB。") })
        GroupCard() {
          Column() {
            NavRow({ title: t("导出备份"), subtitle: t("存到本机，或分享到其他设备"), compId: 'export-backup',
              icon: $r('sys.symbol.square_and_arrow_down'), disabled: this.app.busy || this.busy, onTap: () => this.backup(false) })
            RowDivider()
            NavRow({ title: t("从备份导入"), subtitle: t("作为独立副本恢复，不会覆盖现有对话"), compId: 'import-backup',
              icon: $r('sys.symbol.folder_badge_plus'), disabled: this.app.busy || this.busy, onTap: () => this.backup(true) })
          }
        }
        if (this.busy) {
          Row({ space: Space.sm }) {
            LoadingProgress().width(20).height(20).color($r('app.color.accent'))
            Text(t("正在处理备份…")).fontSize(13).fontColor($r('app.color.text_secondary'))
          }.margin({ top: Space.md })
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
