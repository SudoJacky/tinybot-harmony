import { t } from '../model/I18n';
import { parseDelimited } from '../model/RichArtifacts';
import { Btn, Font, Radius, Space } from '../common/Theme';
import { BottomBar, EmptyState, IconBadge, IconButton } from '../common/Widgets';
import { DataTable } from './DataTable';

@Component
export struct DocumentPreview {
  name: string = '';
  content: string = '';
  onClose: () => void = () => {};
  onReference: (value: string) => void = () => {};
  @State private rows: string[][] = [];
  @State private selected: string = '';
  @State private location: string = '';
  @State private selectedRow: number = -1;
  @State private selectedColumn: number = -1;
  @State private error: string = '';
  aboutToAppear(): void {
    if (/\.(csv|tsv)$/i.test(this.name)) { try { this.rows = parseDelimited(this.content, /\.tsv$/i.test(this.name) ? '\t' : ','); } catch (error) { this.error = (error as Error).message; } }
  }

  private kind(): string {
    const dot = this.name.lastIndexOf('.');
    return (dot > 0 ? this.name.slice(dot + 1).toUpperCase() + ' · ' : '') + (this.rows.length ? this.rows.length + t(" 行") : this.content.length + t(" 字"));
  }

  build() {
    Column() {
      Row({ space: Space.md }) {
        IconBadge({ icon: this.rows.length ? $r('sys.symbol.text_alignleft') : $r('sys.symbol.doc_text') })
        Column({ space: 2 }) {
          Text(this.name).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(this.kind()).fontSize(Font.caption).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        IconButton({ icon: $r('sys.symbol.xmark'), label: t("关闭"), diameter: 36, iconSize: 18,
          fill: $r('app.color.surface_variant'), tint: $r('app.color.text_secondary'), onTap: () => this.onClose() })
      }.width('100%').padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.sm })
      Text(this.rows.length ? t("点选单元格后可引用到对话。") : t("长按选择文字后可引用到对话。PDF 页码、幻灯片序号与单元格地址保留在正文中。"))
        .fontSize(Font.caption).lineHeight(18).width('100%').fontColor($r('app.color.text_secondary'))
        .padding({ left: Space.page, right: Space.page, bottom: Space.md })
      Scroll() {
        Column() {
          if (this.rows.length) {
            DataTable({ header: this.rows[0], rows: this.rows.slice(1), maxHeight: 2000,
              selectedRow: this.selectedRow, selectedColumn: this.selectedColumn,
              onCellTap: (row: number, column: number) => {
                this.selectedRow = row; this.selectedColumn = column; this.selected = this.rows[row + 1][column];
                this.location = t('第 {0} 行，第 {1} 列', [row + 2, column + 1]);
              } })
          } else if (this.content.length === 0) {
            EmptyState({ icon: $r('sys.symbol.doc_text'), title: t("没有可显示的文字"), caption: t("这个附件没有提取到文本内容。") })
          } else {
            Text(this.content).fontSize(15).lineHeight(24).width('100%').fontColor($r('app.color.text_primary')).copyOption(CopyOptions.LocalDevice)
              .onTextSelectionChange((start, end) => { this.selected = this.content.slice(start, end); this.location = t('提取文本第 {0} 行', [this.content.slice(0, start).split('\n').length]); })
          }
        }.width('100%').padding(this.rows.length ? 0 : Space.lg).borderRadius(Radius.lg)
        .backgroundColor(this.rows.length ? Color.Transparent : $r('app.color.surface'))
      }.layoutWeight(1).width('100%').padding({ left: Space.page, right: Space.page }).align(Alignment.Top)
      .scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
      BottomBar() {
        Column({ space: 10 }) {
          if (this.error) {
            Text(this.error).fontColor($r('app.color.danger')).fontSize(Font.caption).width('100%')
          }
          Row({ space: Space.sm }) {
            SymbolGlyph($r('sys.symbol.quote')).fontSize(14).fontColor([$r('app.color.text_tertiary')])
            Text(this.selected ? this.location + '：' + this.selected.replace(/\s+/g, ' ').slice(0, 80) : t("尚未选择内容"))
              .fontSize(Font.caption).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              .fontColor(this.selected ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
          }.width('100%')
          Button(t("引用到对话")).id('reference-document').attributeModifier(Btn.primary).width('100%').enabled(!!this.selected).onClick(() => {
            this.onReference(t("\n\n引用附件 ") + this.name + '（' + this.location + '）：\n' + this.selected.slice(0, 4000) + t("\n修改要求：")); this.onClose();
          })
        }.width('100%')
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.page_background'))
  }
}
