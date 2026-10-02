import { Font, Radius } from '../common/Theme';

const CELL_WIDTH: number = 104;

// Scrollable grid shared by data views, CSV files and document previews.
// Header taps sort (when onHeaderTap is set); cell taps select (when onCellTap is set).
@Component
export struct DataTable {
  @Prop header: string[] = [];
  @Prop rows: string[][] = [];
  @Prop numeric: boolean[] = [];
  @Prop sortColumn: number = -1;
  @Prop ascending: boolean = true;
  @Prop selectedRow: number = -1;
  @Prop selectedColumn: number = -1;
  maxHeight: number = 320;
  onHeaderTap?: (column: number) => void;
  onCellTap?: (row: number, column: number) => void;

  private cellAlign(column: number): TextAlign {
    return this.numeric[column] ? TextAlign.End : TextAlign.Start;
  }

  @Builder
  headerCell(label: string, column: number) {
    Row({ space: 2 }) {
      Text(label).fontSize(Font.caption).fontWeight(FontWeight.Medium).maxLines(2).layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(this.cellAlign(column))
        .fontColor($r('app.color.text_secondary'))
      if (this.sortColumn === column) {
        SymbolGlyph(this.ascending ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(11).fontColor([$r('app.color.accent')])
      }
    }.width(CELL_WIDTH).padding({ left: 10, right: 10, top: 9, bottom: 9 })
    .onClick(() => { if (this.onHeaderTap) { this.onHeaderTap(column); } })
  }

  @Builder
  cell(value: string, row: number, column: number) {
    Text(value).width(CELL_WIDTH).fontSize(13).lineHeight(18).maxLines(3)
      .textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(this.cellAlign(column))
      .padding({ left: 10, right: 10, top: 8, bottom: 8 }).fontColor($r('app.color.text_primary'))
      .backgroundColor(row === this.selectedRow && column === this.selectedColumn ? $r('app.color.accent_container') : Color.Transparent)
      .copyOption(this.onCellTap ? CopyOptions.None : CopyOptions.LocalDevice)
      .onClick(() => { if (this.onCellTap) { this.onCellTap(row, column); } })
  }

  build() {
    Scroll() {
      Column() {
        if (this.header.length > 0) {
          Row() {
            ForEach(this.header, (label: string, column: number) => { this.headerCell(label, column) },
              (label: string, column: number) => column + label)
          }.backgroundColor($r('app.color.surface_variant'))
        }
        ForEach(this.rows, (row: string[], index: number) => {
          Row() {
            ForEach(row, (value: string, column: number) => { this.cell(value, index, column) },
              (value: string, column: number) => column + ':' + value)
          }.border({ width: { top: index > 0 || this.header.length > 0 ? 0.5 : 0 }, color: $r('app.color.divider') })
        }, (row: string[], index: number) => index + ':' + row.join('\u0001'))
      }.alignItems(HorizontalAlign.Start)
    }
    .scrollable(ScrollDirection.FREE).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    .constraintSize({ maxHeight: this.maxHeight }).width('100%').align(Alignment.TopStart)
    .borderRadius(Radius.sm).clip(true).border({ width: 0.5, color: $r('app.color.divider') })
  }
}
