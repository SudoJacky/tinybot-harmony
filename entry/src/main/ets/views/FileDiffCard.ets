import { AppearanceStyle } from '../common/AppearanceStyle';
import { pasteboard } from '@kit.BasicServicesKit';
import { FileDiff, FileDiffRow, fileDiffText } from '../model/FileDiff';
import { t } from '../model/I18n';

@Component
export struct FileDiffCard {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop diff: FileDiff;
  @Prop compact: boolean = false;
  @Prop page: number = 0;
  onExpand: () => void = () => {};

  private visibleRows(): FileDiffRow[] {
    return this.compact ? this.diff.rows.slice(0, 10) : this.diff.rows.slice(this.page * 40, (this.page + 1) * 40);
  }
  private rowColor(row: FileDiffRow): ResourceColor {
    return row.kind === 'added' ? $r('app.color.diff_added_background') : row.kind === 'removed' ?
      $r('app.color.diff_removed_background') : $r('app.color.surface');
  }
  private markColor(row: FileDiffRow): ResourceColor {
    return row.kind === 'added' ? this.appearance.accent : row.kind === 'removed' ?
      $r('app.color.danger') : $r('app.color.text_tertiary');
  }
  private async copy(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, fileDiffText(this.diff)));
      this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('已复制') });
    } catch (_) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t('复制失败，请长按文本选择复制。') }); }
  }
  build() {
    Column() {
      Row({ space: 6 }) {
        Text(this.diff.path).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_secondary')).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('+' + this.diff.added).fontSize(12).fontFamily('monospace').fontColor(this.appearance.accent)
        Text('−' + this.diff.removed).fontSize(12).fontFamily('monospace').fontColor($r('app.color.danger'))
        Button({ type: ButtonType.Normal }) {
          SymbolGlyph($r('sys.symbol.rectangle_on_rectangle')).fontSize(14).fontColor([$r('app.color.text_secondary')])
        }.fontFamily(this.appearance.fontFamily).width(40).height(40).padding(0).backgroundColor(Color.Transparent)
          .accessibilityText(t('复制差异')).onClick(() => this.copy())
      }.width('100%').padding({ left: 10, right: 2 }).backgroundColor($r('app.color.surface_variant'))
      ForEach(this.visibleRows().map((_row: FileDiffRow, index: number) => index), (index: number) => {
        Column() {
          Row({ space: 0 }) {
            Text(this.visibleRows()[index].oldLine ? this.visibleRows()[index].oldLine.toString() : '')
              .width(29).textAlign(TextAlign.End).fontSize(10).fontFamily('monospace').fontColor(this.markColor(this.visibleRows()[index]))
            Text(this.visibleRows()[index].newLine ? this.visibleRows()[index].newLine.toString() : '')
              .width(29).textAlign(TextAlign.End).fontSize(10).fontFamily('monospace').fontColor(this.markColor(this.visibleRows()[index]))
            Text(this.visibleRows()[index].kind === 'added' ? '+' : this.visibleRows()[index].kind === 'removed' ? '−' : '')
              .width(18).fontSize(12).fontFamily('monospace').textAlign(TextAlign.Center).fontColor(this.markColor(this.visibleRows()[index]))
            Text(this.visibleRows()[index].text || ' ').fontSize(12).lineHeight(19).fontFamily('monospace')
              .fontColor($r('app.color.text_primary')).layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
              .maxLines(this.compact ? 3 : 10000).textOverflow({ overflow: TextOverflow.Ellipsis })
              .copyOption(CopyOptions.LocalDevice)
          }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 2, bottom: 2, right: 6 })
          if (this.visibleRows()[index].noNewline) {
            Text(t('文件末尾无换行')).fontFamily(this.appearance.fontFamily).fontSize(10).fontColor($r('app.color.text_tertiary')).width('100%').padding({ left: 76, bottom: 2 })
          }
        }.width('100%').backgroundColor(this.rowColor(this.visibleRows()[index]))
      }, (index: number) => this.page + '-' + index)
      if (this.diff.rows.length === 0) {
        Text(this.diff.created ? t('空文本') : t('内容未变化')).fontFamily(this.appearance.fontFamily).fontSize(12).fontColor($r('app.color.text_tertiary')).padding(12)
      }
      if (this.compact) {
        Button(t('查看完整差异')).fontFamily(this.appearance.fontFamily).type(ButtonType.Normal).fontSize(12).height(40).width('100%')
          .fontColor(this.appearance.accent).backgroundColor($r('app.color.surface_variant')).onClick(this.onExpand)
      }
    }.width('100%').borderRadius(10).clip(true).border({ width: 1, color: $r('app.color.divider') })
  }
}
