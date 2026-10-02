import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { DataView, DataColumn, DataRow, parseDataView, dataCsv } from '../model/RichArtifacts';
import { writeBytes } from '../services/Attachments';
import { exportFile } from '../services/NativeActions';
import { Btn, Font, Radius, Space, compactNumber } from '../common/Theme';
import { Tag } from '../common/Widgets';
import { DataTable } from './DataTable';

// Categorical series in fixed order (blue, orange, aqua, yellow), stepped separately for light and dark surfaces.
const SERIES_LIGHT: string[] = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100'];
const SERIES_DARK: string[] = ['#3987e5', '#d95926', '#199e70', '#c98500'];
function KIND_NAMES(): Record<string, string> { return { 'bar': t("柱状图"), 'line': t("折线图"), 'waterfall': t("瀑布图"), 'table': t("表格"), 'metrics': t("指标") }; }
const CHART_HEIGHT: number = 200;
const PLOT_LEFT: number = 40;
const PLOT_TOP: number = 10;
const PLOT_BOTTOM: number = 26;

class LegendItem {
  label: string;
  color: string;

  constructor(label: string, color: string) {
    this.label = label;
    this.color = color;
  }
}

function tick(value: number): string {
  const magnitude = Math.abs(value);
  if (magnitude >= 1000) { return (value < 0 ? '-' : '') + compactNumber(magnitude); }
  return Number(value.toPrecision(3)).toString();
}

@Component
export struct DataViewCard {
  @Prop content: string;
  @State private view: DataView | undefined = undefined;
  @State private error: string = '';
  @State private table: boolean = false;
  @State private rows: DataRow[] = [];
  @State private sortColumn: number = -1;
  @State private ascending: boolean = true;
  @State private series: string[] = SERIES_LIGHT;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private chartWidth: number = 300;
  private ink: string = '#8F9B97';
  private grid: string = '#E1E5E0';
  private surface: string = '#FFFFFF';

  aboutToAppear(): void {
    try { this.view = parseDataView(this.content); this.rows = this.view.rows; this.table = this.view.kind === 'table'; }
    catch (error) { this.error = (error as Error).message; }
    try {
      const resources = this.getUIContext().getHostContext()!.resourceManager;
      this.series = resources.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK ? SERIES_DARK : SERIES_LIGHT;
      this.ink = this.rgba(resources.getColorSync($r('app.color.text_tertiary').id));
      this.grid = this.rgba(resources.getColorSync($r('app.color.divider').id));
      this.surface = this.rgba(resources.getColorSync($r('app.color.surface').id));
    } catch (_) { /* Keep light defaults. */ }
  }

  private rgba(argb: number): string {
    const value = argb >>> 0;
    return 'rgba(' + ((value >> 16) & 255) + ',' + ((value >> 8) & 255) + ',' + (value & 255) + ',' + (((value >>> 24) & 255) / 255).toFixed(2) + ')';
  }

  private sort(index: number): void {
    this.ascending = this.sortColumn === index ? !this.ascending : true;
    this.sortColumn = index;
    this.rows = this.rows.slice().sort((a, b) => {
      const left = a.values[index]; const right = b.values[index];
      return (typeof left === 'number' && typeof right === 'number' ? left - right : String(left).localeCompare(String(right))) * (this.ascending ? 1 : -1);
    });
  }

  private async exportCsv(): Promise<void> {
    if (!this.view) { return; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path = context.cacheDir + '/chart-' + util.generateRandomUUID() + '.csv';
      await writeBytes(path, new util.TextEncoder().encodeInto('\ufeff' + dataCsv(this.view)).buffer as ArrayBuffer);
      await exportFile(context, path, (this.view.title.replace(/[\\/:*?"<>|\s]+/g, '_').slice(0, 40) || t("图表数据")) + '.csv');
    } catch (error) { this.error = (error as Error).message; }
  }

  private isChart(): boolean {
    return !!this.view && this.view.kind !== 'table' && this.view.kind !== 'metrics';
  }

  private columnLabel(column: DataColumn): string {
    return column.label + (column.unit ? '（' + column.unit + '）' : '');
  }

  private legend(): LegendItem[] {
    const view = this.view;
    if (!view) { return []; }
    if (view.kind === 'waterfall') { return [new LegendItem(t("增加"), this.series[2]), new LegendItem(t("减少"), this.series[1])]; }
    return view.columns.slice(1).map((column: DataColumn, index: number) =>
      new LegendItem(this.columnLabel(column), this.series[index % this.series.length]));
  }

  private tableHeader(): string[] {
    return this.view ? this.view.columns.map((column: DataColumn) => this.columnLabel(column)) : [];
  }

  private tableRows(): string[][] {
    return this.rows.map((row: DataRow) => row.values.map((value: string | number | boolean) => String(value)));
  }

  private numericColumns(): boolean[] {
    return this.view ? this.view.columns.map((column: DataColumn) => column.type === 'number') : [];
  }

  // Rounded top on the value end, square on the baseline.
  private bar(x: number, top: number, width: number, height: number, upward: boolean): void {
    const ctx = this.canvas; const r = Math.min(3, width / 2, height);
    ctx.beginPath();
    if (upward) {
      ctx.moveTo(x, top + height); ctx.lineTo(x, top + r); ctx.arcTo(x, top, x + r, top, r);
      ctx.lineTo(x + width - r, top); ctx.arcTo(x + width, top, x + width, top + r, r); ctx.lineTo(x + width, top + height);
    } else {
      ctx.moveTo(x, top); ctx.lineTo(x, top + height - r); ctx.arcTo(x, top + height, x + r, top + height, r);
      ctx.lineTo(x + width - r, top + height); ctx.arcTo(x + width, top + height, x + width, top + height - r, r); ctx.lineTo(x + width, top);
    }
    ctx.closePath(); ctx.fill();
  }

  private draw(): void {
    const view = this.view;
    if (!view || !this.isChart()) { return; }
    const ctx = this.canvas; const width = this.chartWidth; const plotWidth = Math.max(1, width - PLOT_LEFT - 4);
    const plotHeight = CHART_HEIGHT - PLOT_TOP - PLOT_BOTTOM;
    ctx.clearRect(0, 0, width, CHART_HEIGHT);
    const values: number[] = [0]; let running = 0;
    for (const row of view.rows) {
      if (view.kind === 'waterfall') { running += row.values[1] as number; values.push(running); }
      else { for (const value of row.values.slice(1)) { values.push(value as number); } }
    }
    const min = Math.min(...values); const max = Math.max(...values); const range = max - min || 1;
    const y = (value: number): number => PLOT_TOP + plotHeight - (value - min) / range * plotHeight;

    // Recessive grid with four labelled steps; the zero line is slightly stronger.
    ctx.font = Math.round(this.getUIContext().vp2px(11)) + 'px sans-serif'; ctx.textBaseline = 'middle'; ctx.textAlign = 'right';
    for (let step = 0; step <= 3; step++) {
      const value = min + range * step / 3; const lineY = y(value);
      ctx.strokeStyle = this.grid; ctx.lineWidth = 1; ctx.beginPath();
      ctx.moveTo(PLOT_LEFT, lineY); ctx.lineTo(width - 4, lineY); ctx.stroke();
      ctx.fillStyle = this.ink; ctx.fillText(tick(value), PLOT_LEFT - 6, lineY);
    }
    ctx.strokeStyle = this.ink; ctx.beginPath(); ctx.moveTo(PLOT_LEFT, y(0)); ctx.lineTo(width - 4, y(0)); ctx.stroke();

    const slot = plotWidth / view.rows.length; const series = view.columns.length - 1;
    running = 0;
    for (let column = 1; column <= series; column++) {
      const color = this.series[(column - 1) % this.series.length];
      ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
      if (view.kind === 'line') { ctx.beginPath(); }
      for (let i = 0; i < view.rows.length; i++) {
        const value = view.rows[i].values[column] as number; const x = PLOT_LEFT + i * slot;
        if (view.kind === 'line') {
          if (i === 0) { ctx.moveTo(x + slot / 2, y(value)); } else { ctx.lineTo(x + slot / 2, y(value)); }
        } else if (view.kind === 'waterfall') {
          const next = running + value; const inset = Math.min(8, slot * 0.2);
          ctx.fillStyle = value >= 0 ? this.series[2] : this.series[1];
          this.bar(x + inset, Math.min(y(running), y(next)), Math.max(1, slot - inset * 2), Math.max(1, Math.abs(y(next) - y(running))), value >= 0);
          running = next;
        } else {
          const group = Math.min(slot * 0.72, series * 28); const start = x + (slot - group) / 2; const barWidth = group / series;
          this.bar(start + (column - 1) * barWidth + 1, Math.min(y(0), y(value)), Math.max(1, barWidth - 2),
            Math.max(1, Math.abs(y(value) - y(0))), value >= 0);
        }
      }
      if (view.kind === 'line') {
        ctx.stroke();
        if (view.rows.length <= 24) {
          for (let i = 0; i < view.rows.length; i++) {
            const value = view.rows[i].values[column] as number;
            ctx.beginPath(); ctx.arc(PLOT_LEFT + i * slot + slot / 2, y(value), 3.5, 0, Math.PI * 2);
            ctx.fillStyle = color; ctx.fill(); ctx.strokeStyle = this.surface; ctx.lineWidth = 2; ctx.stroke();
          }
        }
      }
    }

    ctx.fillStyle = this.ink; ctx.textAlign = 'center'; ctx.textBaseline = 'top';
    const stride = Math.max(1, Math.ceil(view.rows.length / Math.max(1, Math.floor(plotWidth / 44))));
    for (let i = 0; i < view.rows.length; i += stride) {
      ctx.fillText(String(view.rows[i].values[0]).slice(0, 6), PLOT_LEFT + i * slot + slot / 2, CHART_HEIGHT - PLOT_BOTTOM + 8);
    }
  }

  @Builder
  metricTiles() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
      ForEach(this.rows, (row: DataRow) => {
        Column({ space: 4 }) {
          Text(String(row.values[0])).fontSize(Font.caption).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('app.color.text_secondary'))
          ForEach(this.view?.columns.slice(1) || [], (column: DataColumn, index: number) => {
            Row({ space: 4 }) {
              Text(String(row.values[index + 1])).fontSize(22).fontWeight(FontWeight.Bold).maxLines(1)
                .fontColor($r('app.color.text_primary'))
              if (column.unit) {
                Text(column.unit).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              }
            }.alignItems(VerticalAlign.Bottom)
            if ((this.view?.columns.length || 0) > 2) {
              Text(column.label).fontSize(11).fontColor($r('app.color.text_tertiary'))
            }
          })
        }.width('48.5%').alignItems(HorizontalAlign.Start).padding(12).margin({ bottom: Space.sm })
        .borderRadius(Radius.sm).backgroundColor($r('app.color.surface_variant'))
      })
    }.width('100%')
  }

  build() {
    Column({ space: 10 }) {
      if (this.view) {
        Row({ space: Space.sm }) {
          Text(this.view.title).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1).fontColor($r('app.color.text_primary'))
          Tag({ text: KIND_NAMES()[this.view.kind] || this.view.kind })
        }.width('100%').alignItems(VerticalAlign.Top)
        if (this.view.insight) {
          Text(this.view.insight).fontSize(13).lineHeight(20).width('100%').fontColor($r('app.color.text_secondary'))
        }
        if (this.isChart() && !this.table) {
          Canvas(this.canvas).width('100%').height(CHART_HEIGHT).onReady(() => this.draw())
            .accessibilityText(this.view.title + '，' + (KIND_NAMES()[this.view.kind] || '') + t("，可切换为数据表查看"))
            .onAreaChange((_old, area) => { this.chartWidth = Number(area.width); this.draw(); })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.legend(), (item: LegendItem) => {
              Row({ space: 6 }) {
                Column().width(10).height(10).borderRadius(3).backgroundColor(item.color)
                Text(item.label).fontSize(Font.caption).fontColor($r('app.color.text_secondary'))
              }.margin({ right: Space.md, bottom: 2 })
            }, (item: LegendItem) => item.label)
          }.width('100%')
        } else if (this.view.kind === 'metrics') {
          this.metricTiles()
        } else {
          DataTable({ header: this.tableHeader(), rows: this.tableRows(), numeric: this.numericColumns(),
            sortColumn: this.sortColumn, ascending: this.ascending, onHeaderTap: (column: number) => this.sort(column) })
        }
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.link')).fontSize(13).fontColor([$r('app.color.text_tertiary')])
          Text(this.view.source).fontSize(11).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            .fontColor($r('app.color.text_tertiary')).copyOption(CopyOptions.LocalDevice)
          if (this.isChart()) {
            Button(this.table ? t("看图表") : t("看数据")).attributeModifier(Btn.textSmall).padding({ left: 8, right: 8 })
              .onClick(() => { this.table = !this.table; })
          }
          Button(t("导出 CSV")).attributeModifier(Btn.textSmall).padding({ left: 8, right: 8 }).onClick(() => this.exportCsv())
        }.width('100%').margin({ bottom: -6 })
      }
      if (this.error) {
        Row({ space: Space.sm }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(16).fontColor([$r('app.color.danger')])
          Text(this.error).fontSize(13).layoutWeight(1).fontColor($r('app.color.danger'))
        }.width('100%')
      }
    }.width('100%').padding({ left: 14, right: 14, top: 14, bottom: 10 }).borderRadius(Radius.lg)
    .backgroundColor($r('app.color.surface')).border({ width: 0.5, color: $r('app.color.divider') })
  }
}
