import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { MarkdownBlock, MarkdownSpan, markdownBlocks, markdownSpans } from '../model/Markdown';
import { Radius, Space } from '../common/Theme';

// Long code blocks start collapsed so one answer does not push the conversation off screen.
const CODE_PREVIEW_LINES: number = 18;
// Non-breaking padding keeps the code highlight attached to its text when a line wraps.
const NBSP: string = String.fromCharCode(0xA0);

@Component
export struct MarkdownView {
  @Prop @Watch('refresh') content: string = '';
  @Prop fontSize: number = 16;
  @State private blocks: MarkdownBlock[] = [];
  @State private copied: number = -1;
  @State private expanded: number[] = [];
  private copyTimer: number = -1;
  aboutToAppear(): void { this.refresh(); }
  aboutToDisappear(): void { clearTimeout(this.copyTimer); }
  private refresh(): void { this.blocks = markdownBlocks(this.content); }
  private async open(url: string): Promise<void> {
    if (!/^https?:\/\//.test(url)) { return; }
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: url }); }
    catch (_) { this.getUIContext().getPromptAction().showToast({ message: t("无法打开链接，可复制后在浏览器中打开。") }); }
  }
  private async copy(text: string, index: number): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.copied = index; clearTimeout(this.copyTimer);
      this.copyTimer = setTimeout(() => { this.copied = -1; this.copyTimer = -1; }, 1600);
    } catch (_) { this.getUIContext().getPromptAction().showToast({ message: t("复制失败，请长按文本复制。") }); }
  }
  private codeLines(block: MarkdownBlock): number { return block.text.split('\n').length; }
  private codeShown(block: MarkdownBlock, index: number): string {
    if (this.expanded.includes(index) || this.codeLines(block) <= CODE_PREVIEW_LINES) { return block.text; }
    return block.text.split('\n').slice(0, CODE_PREVIEW_LINES).join('\n');
  }
  // Cells share one width per column so rows line up; sized from the longest cell (CJK glyphs count double).
  private columnWidths(block: MarkdownBlock): number[] {
    const widths: number[] = [];
    for (const row of block.rows) {
      row.forEach((cell: string, column: number) => {
        let units = 0;
        for (const char of cell) { units += char.charCodeAt(0) >= 0x2E80 ? 14 : 8; }
        widths[column] = Math.max(widths[column] || 0, Math.min(220, Math.max(88, units + 22)));
      });
    }
    return widths;
  }
  private headingSize(level: number): number { return level <= 1 ? this.fontSize + 5 : level === 2 ? this.fontSize + 3 : this.fontSize + 1; }

  @Builder
  prose(text: string, size: number, bold: boolean, color: ResourceColor) {
    Text() {
      ForEach(markdownSpans(text), (span: MarkdownSpan) => {
        if (span.kind === 'code') {
          Span(NBSP + span.text + NBSP).fontFamily('monospace').fontSize(size - 2).fontColor($r('app.color.on_accent_container'))
            .textBackgroundStyle({ color: $r('app.color.surface_variant'), radius: 4 })
        } else {
          Span(span.text).fontWeight(bold || span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(span.kind === 'link' ? $r('app.color.accent') : color)
            .decoration({ type: span.kind === 'link' ? TextDecorationType.Underline :
              span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None, color: span.kind === 'link' ? $r('app.color.accent') : color })
            .onClick(() => { if (span.url) { this.open(span.url); } })
        }
      })
    }.fontSize(size).lineHeight(Math.round(size * 1.62)).fontColor(color).copyOption(CopyOptions.LocalDevice).width('100%')
  }

  @Builder
  codeBlock(block: MarkdownBlock, index: number) {
    Column() {
      Row({ space: Space.xs }) {
        Text(block.rows[0][0] || 'code').fontSize(12).fontFamily('monospace').layoutWeight(1).maxLines(1)
          .fontColor($r('app.color.text_secondary'))
        Row({ space: 4 }) {
          SymbolGlyph(this.copied === index ? $r('sys.symbol.checkmark') : $r('sys.symbol.rectangle_on_rectangle')).fontSize(14)
            .fontColor([this.copied === index ? $r('app.color.accent') : $r('app.color.text_secondary')])
          Text(this.copied === index ? t("已复制") : t("复制")).fontSize(12)
            .fontColor(this.copied === index ? $r('app.color.accent') : $r('app.color.text_secondary'))
        }.height(32).padding({ left: 10, right: 10 }).borderRadius(16)
        .stateStyles({ pressed: { .backgroundColor($r('app.color.divider')) }, normal: { .backgroundColor(Color.Transparent) } })
        .accessibilityText(t("复制代码")).onClick(() => this.copy(block.text, index))
      }.width('100%').padding({ left: Space.md, right: 4 }).height(38)
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Scroll() {
        Text(this.codeShown(block, index)).fontSize(13).lineHeight(20).fontFamily('monospace')
          .copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.text_primary'))
          .padding({ left: Space.md, right: Space.md, top: 10, bottom: 12 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      if (this.codeLines(block) > CODE_PREVIEW_LINES) {
        Row({ space: 4 }) {
          Text(this.expanded.includes(index) ? t("收起") : t("展开全部 {0} 行", [this.codeLines(block)])).fontSize(13)
            .fontColor($r('app.color.accent'))
          SymbolGlyph(this.expanded.includes(index) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(13).fontColor([$r('app.color.accent')])
        }.width('100%').height(40).justifyContent(FlexAlign.Center)
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
        .onClick(() => {
          this.expanded = this.expanded.includes(index) ? this.expanded.filter((item) => item !== index) : this.expanded.concat([index]);
        })
      }
    }.borderRadius(Radius.md).clip(true).backgroundColor($r('app.color.surface_variant')).width('100%')
    .border({ width: 0.5, color: $r('app.color.divider') }).margin({ top: 2, bottom: 2 })
  }

  @Builder
  table(block: MarkdownBlock) {
    Scroll() {
      Column() {
        ForEach(block.rows, (row: string[], index: number) => {
          Row() {
            ForEach(row, (cell: string, column: number) => {
              Column() { this.prose(cell, 14, index === 0, $r('app.color.text_primary')) }
                .width(this.columnWidths(block)[column] || 88).padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .border({ width: { left: column > 0 ? 0.5 : 0 }, color: $r('app.color.divider') })
            })
          }.alignItems(VerticalAlign.Top)
          .backgroundColor(index === 0 ? $r('app.color.surface_variant') : Color.Transparent)
          .border({ width: { top: index > 0 ? 0.5 : 0 }, color: $r('app.color.divider') })
        })
      }.borderRadius(Radius.sm).clip(true).border({ width: 0.5, color: $r('app.color.divider') })
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Column({ space: 10 }) {
      ForEach(this.blocks, (block: MarkdownBlock, index: number) => {
        if (block.kind === 'code') {
          this.codeBlock(block, index)
        } else if (block.kind === 'table') {
          this.table(block)
        } else if (block.kind === 'rule') {
          Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ top: 4, bottom: 4 })
        } else if (block.kind === 'quote') {
          Column() { this.prose(block.text, this.fontSize - 1, false, $r('app.color.text_secondary')) }
            .width('100%').padding({ left: Space.md, top: 2, bottom: 2 })
            .border({ width: { left: 3 }, color: $r('app.color.accent') })
        } else if (block.kind === 'list') {
          Row() {
            Text(block.rows[0][0]).fontSize(block.rows[0][0] === '•' ? this.fontSize + 2 : this.fontSize)
              .lineHeight(Math.round(this.fontSize * 1.62)).constraintSize({ minWidth: 22 })
              .fontColor(block.rows[0][0] === '☑' ? $r('app.color.accent') : $r('app.color.text_secondary'))
            Column() { this.prose(block.text, this.fontSize, false, $r('app.color.text_primary')) }.layoutWeight(1)
          }.width('100%').alignItems(VerticalAlign.Top).padding({ left: block.level * 18 }).margin({ top: -4 })
        } else if (block.kind === 'heading') {
          Column() { this.prose(block.text, this.headingSize(block.level), true, $r('app.color.text_primary')) }
            .margin({ top: index > 0 ? 6 : 0 })
        } else {
          this.prose(block.text, this.fontSize, false, $r('app.color.text_primary'))
        }
      })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
