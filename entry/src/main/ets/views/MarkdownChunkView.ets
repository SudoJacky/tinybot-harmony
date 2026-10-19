import { Diagnostics } from '../model/Diagnostics';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { t } from '../model/I18n';
import { common } from '@kit.AbilityKit';
import { ColorMetrics } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { MarkdownBlock, MarkdownSpan, markdownSpans } from '../model/Markdown';
import { highlightCode } from '../model/CodeHighlight';
import { Radius, Space } from '../common/Theme';
import { RevealSpan, StreamReveal } from '../model/StreamReveal';
import { MarkdownChunkModel } from '../viewmodel/MarkdownChunkModel';
import { ImageViewer } from './ImageViewer';

// Long code blocks start collapsed so one answer does not push the conversation off screen.
const CODE_PREVIEW_LINES: number = 18;
// Non-breaking padding keeps the code highlight attached to its text when a line wraps.
const NBSP: string = String.fromCharCode(0xA0);
// A fixed height keeps a streaming answer from reflowing while a remote image loads.
const IMAGE_HEIGHT: number = 220;

@Component
export struct MarkdownChunkView {
  @StorageProp('tinybot.appearance.style') @Watch('invalidateMeasure') private appearance: AppearanceStyle = new AppearanceStyle();
  @ObjectLink @Watch('refresh') model: MarkdownChunkModel;
  @Prop @Watch('refresh') streaming: boolean = false;
  @Prop @Watch('invalidateMeasure') fontSize: number = 16;
  @Prop selectable: boolean = true;
  blockOffset: number = 0;
  @State private visible: boolean = true;
  @State private measuredHeight: number = 0;
  private measuredWidth: number = 0;
  private perfId: number = Diagnostics.nextId();
  private previousBlocks?: MarkdownBlock[];
  private inlineCache: Map<string, MarkdownSpan[]> = new Map<string, MarkdownSpan[]>();
  @State private codeTokens: MarkdownSpan[][] = [];
  @State private tableWidths: number[][] = [];
  private highlighted: Map<number, string> = new Map<number, string>();
  @State private copied: number = -1;
  @State private expanded: number[] = [];
  // Failed image sources are remembered per block so a broken URL shows a tap-through card.
  @State private imageFailed: number[] = [];
  @State private previewing: boolean = false;
  @State private previewSource: string = '';
  private copyTimer: number = -1;
  @State private revealTime: number = 0;
  private reveal: StreamReveal = new StreamReveal();
  private revealTimer: number = -1;
  private mounted: boolean = false;
  aboutToAppear(): void { Diagnostics.adjust('render.chunks', 1); this.refresh(); this.mounted = true; }
  aboutToDisappear(): void {
    Diagnostics.adjust('render.chunks', -1);
    this.mounted = false; clearTimeout(this.copyTimer); clearTimeout(this.revealTimer); this.revealTimer = -1;
  }
  private refresh(): void {
    const mark = Diagnostics.begin(this.perfId);
    const now = Date.now();
    const blocks = this.model.blocks;
    if (blocks !== this.previousBlocks) {
      this.measuredHeight = 0; this.previousBlocks = blocks;
      const failed = this.imageFailed.filter((index: number) => index < blocks.length && blocks[index].kind === 'image');
      if (failed.length !== this.imageFailed.length) { this.imageFailed = failed; }
    }
    this.inlineCache.clear();
    const keys: string[] = [];
    // A completed response still finishes its pending fade; history mounts stay static.
    const animate = (this.mounted || this.model.animate) && this.visible && (this.streaming || this.reveal.active(now));
    blocks.forEach((block: MarkdownBlock, index: number) => {
      if (block.kind === 'table') {
        block.rows.forEach((row: string[], r: number) => {
          row.forEach((cell: string, c: number) => {
            const key = `${index}:${r}:${c}`; keys.push(key);
            this.reveal.update(key, this.inlineSpans(cell).map((span: MarkdownSpan) => span.text).join(''), now, animate);
          });
        });
      } else if (block.kind !== 'image') {
        const key = `${index}`; keys.push(key);
        const text = block.kind === 'code' ? block.text : this.inlineSpans(block.text).map((span: MarkdownSpan) => span.text).join('');
        this.reveal.update(key, text, now, animate);
      }
    });
    this.reveal.retain(keys);
    this.refreshCode();
    this.tableWidths = blocks.map((block: MarkdownBlock): number[] => block.kind === 'table' ? this.columnWidths(block) : []);
    this.revealTime = now;
    clearTimeout(this.revealTimer); this.revealTimer = -1;
    this.scheduleReveal();
    if (Diagnostics.recording) { Diagnostics.end('render.chunkRefresh', mark, { blocks: blocks.length, visible: this.visible ? 1 : 0, blockOffset: this.blockOffset }); }
  }
  private invalidateMeasure(): void { this.measuredHeight = 0; }
  private refreshCode(): void {
    this.highlighted.forEach((_value: string, index: number) => {
      if (index >= this.model.blocks.length) { this.highlighted.delete(index); }
    });
    this.codeTokens = this.model.blocks.map((block: MarkdownBlock, index: number): MarkdownSpan[] => {
      if (block.kind !== 'code') { this.highlighted.delete(index); return []; }
      const text = this.codeShown(block, index); const key = block.rows[0][0] + ':' + text;
      if (this.highlighted.get(index) === key) { return this.codeTokens[index]; }
      this.highlighted.set(index, key);
      const mark = Diagnostics.begin(this.perfId); const tokens = highlightCode(text, block.rows[0][0]);
      if (Diagnostics.recording) { Diagnostics.end('markdown.highlight', mark, { chars: text.length, tokens: tokens.length, expanded: this.expanded.includes(index) ? 1 : 0 }); }
      return tokens;
    });
  }
  private proseText(key: string): string {
    const cell = key.split(':'); const block = this.model.blocks[Number(cell[0])];
    return cell.length === 3 ? block.rows[Number(cell[1])][Number(cell[2])] : block.text;
  }
  private scheduleReveal(): void {
    if (!this.visible || !this.reveal.active(this.revealTime)) { return; }
    this.revealTimer = setTimeout(() => {
      this.revealTimer = -1;
      if (!this.mounted) { return; }
      if (Diagnostics.recording) { Diagnostics.measure('render.revealTick', 1, 'count'); }
      this.revealTime = Date.now(); this.scheduleReveal();
    }, 16);
  }
  private revealColor(color: ResourceColor, opacity: number): ResourceColor {
    if (opacity >= 1) { return color; }
    try {
      const value = ColorMetrics.resourceColor(color);
      return ColorMetrics.rgba(value.red, value.green, value.blue, value.alpha / 255 * opacity).color;
    } catch (_) { return color; }
  }
  private inlineSpans(text: string): MarkdownSpan[] {
    const cached = this.inlineCache.get(text);
    if (cached) { if (Diagnostics.recording) { Diagnostics.measure('markdown.inlineCacheHit', 1, 'count'); } return cached; }
    const mark = Diagnostics.begin(this.perfId);
    const spans = markdownSpans(text).map((span: MarkdownSpan): MarkdownSpan => {
      return { text: span.kind === 'code' ? NBSP + span.text + NBSP : span.text, kind: span.kind, url: span.url };
    });
    this.inlineCache.set(text, spans);
    if (Diagnostics.recording) { Diagnostics.end('markdown.inline', mark, { chars: text.length, spans: spans.length }); }
    return spans;
  }
  private async open(url: string): Promise<void> {
    if (!/^https?:\/\//.test(url)) { return; }
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: url }); }
    catch (_) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("无法打开链接，可复制后在浏览器中打开。") }); }
  }
  private async copy(text: string, index: number): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.copied = index; clearTimeout(this.copyTimer);
      this.copyTimer = setTimeout(() => { this.copied = -1; this.copyTimer = -1; }, 1600);
    } catch (_) { this.getUIContext().getPromptAction().showToast({ systemMaterial: this.appearance.surface, message: t("复制失败，请长按文本复制。") }); }
  }
  private codeLines(block: MarkdownBlock): number { return block.text.split('\n').length; }
  private codeShown(block: MarkdownBlock, index: number): string {
    if (this.expanded.includes(index)) { return block.text; }
    let end = -1;
    for (let line = 0; line < CODE_PREVIEW_LINES; line++) {
      end = block.text.indexOf('\n', end + 1);
      if (end < 0) { return block.text; }
    }
    return block.text.slice(0, end);
  }
  private codeColor(kind: string): ResourceColor {
    switch (kind) {
      case 'syntax-keyword': return $r('app.color.code_keyword');
      case 'syntax-string': return $r('app.color.code_string');
      case 'syntax-number': return $r('app.color.code_number');
      case 'syntax-comment': return $r('app.color.code_comment');
      case 'syntax-function': return $r('app.color.code_function');
      case 'syntax-property': return $r('app.color.code_property');
      case 'syntax-punctuation': return $r('app.color.code_punctuation');
      default: return $r('app.color.text_primary');
    }
  }
  // Cells share one width per column so rows line up; sized from the longest cell (CJK glyphs count double).
  private columnWidths(block: MarkdownBlock): number[] {
    const mark = Diagnostics.begin(this.perfId);
    const widths: number[] = [];
    for (const row of block.rows) {
      row.forEach((cell: string, column: number) => {
        let units = 0;
        for (const char of cell) { units += char.charCodeAt(0) >= 0x2E80 ? 14 : 8; }
        widths[column] = Math.max(widths[column] || 0, Math.min(220, Math.max(88, units + 22)));
      });
    }
    if (Diagnostics.recording) { Diagnostics.end('markdown.tableWidths', mark, { rows: block.rows.length, columns: widths.length }); }
    return widths;
  }
  private headingSize(level: number): number { return level <= 1 ? this.fontSize + 5 : level === 2 ? this.fontSize + 3 : this.fontSize + 1; }
  // Image blocks keep [alt, url] in rows; read it from the model because keyed builders keep their arguments.
  private imageAlt(index: number): string {
    const rows = this.model.blocks[index].rows;
    return rows.length > 0 && rows[0].length > 0 ? rows[0][0] : '';
  }
  private imageUrl(index: number): string {
    const rows = this.model.blocks[index].rows;
    return rows.length > 0 && rows[0].length > 1 ? rows[0][1] : '';
  }

  // Keyed builders retain their original arguments; read changing text from the model.
  @Builder
  prose(text: string, size: number, bold: boolean, color: ResourceColor, key: string) {
    Text() {
      ForEach(this.reveal.spans(key, this.inlineSpans(this.proseText(key)), this.revealTime), (span: RevealSpan) => {
        if (span.kind === 'code') {
          Span(span.text).fontFamily('monospace').fontSize(size - 2)
            .fontColor(this.revealColor(this.appearance.onAccentContainer, span.opacity))
            .textBackgroundStyle({ color: $r('app.color.surface_variant'), radius: 4 })
        } else {
          Span(span.text).fontWeight(bold || span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(this.revealColor(span.kind === 'link' ? this.appearance.accent : color, span.opacity))
            .decoration({ type: span.kind === 'link' ? TextDecorationType.Underline :
              span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None, color: this.revealColor(span.kind === 'link' ? this.appearance.accent : color, span.opacity) })
            .onClick(() => { if (span.url) { this.open(span.url); } })
        }
      })
    }.fontFamily(this.appearance.fontFamily).fontSize(size).lineHeight(Math.round(size * 1.62)).fontColor(color).copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None).width('100%')
  }

  @Builder
  codeBlock(block: MarkdownBlock, index: number) {
    Column() {
      Row({ space: Space.xs }) {
        Text(this.model.blocks[index].rows[0][0] || 'code').fontSize(12).fontFamily('monospace').layoutWeight(1).maxLines(1)
          .fontColor($r('app.color.text_secondary'))
        Row({ space: 4 }) {
          SymbolGlyph(this.copied === index ? $r('sys.symbol.checkmark') : $r('sys.symbol.rectangle_on_rectangle')).fontSize(14)
            .fontColor([this.copied === index ? this.appearance.accent : $r('app.color.text_secondary')])
          Text(this.copied === index ? t("已复制") : t("复制")).fontFamily(this.appearance.fontFamily).fontSize(12)
            .fontColor(this.copied === index ? this.appearance.accent : $r('app.color.text_secondary'))
        }.height(32).padding({ left: 10, right: 10 }).borderRadius(16)
        .stateStyles({ pressed: { .backgroundColor($r('app.color.divider')) }, normal: { .backgroundColor(Color.Transparent) } })
        .accessibilityText(t("复制代码")).onClick(() => this.copy(this.model.blocks[index].text, index))
      }.width('100%').padding({ left: Space.md, right: 4 }).height(38)
      Divider().strokeWidth(0.5).color($r('app.color.divider'))
      Scroll() {
        Text() {
          ForEach(this.reveal.spans(`${index}`, this.codeTokens[index], this.revealTime), (span: RevealSpan) => {
            Span(span.text).fontColor(this.revealColor(this.codeColor(span.kind), span.opacity))
          })
        }.fontSize(13).lineHeight(20).fontFamily('monospace')
          .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None).fontColor($r('app.color.text_primary'))
          .padding({ left: Space.md, right: Space.md, top: 10, bottom: 12 })
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%').align(Alignment.Start)
      if (this.codeLines(this.model.blocks[index]) > CODE_PREVIEW_LINES) {
        Row({ space: 4 }) {
          Text(this.expanded.includes(index) ? t("收起") : t("展开全部 {0} 行", [this.codeLines(this.model.blocks[index])])).fontFamily(this.appearance.fontFamily).fontSize(13)
            .fontColor(this.appearance.accent)
          SymbolGlyph(this.expanded.includes(index) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
            .fontSize(13).fontColor([this.appearance.accent])
        }.width('100%').height(40).justifyContent(FlexAlign.Center)
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
        .onClick(() => {
          this.expanded = this.expanded.includes(index) ? this.expanded.filter((item) => item !== index) : this.expanded.concat([index]);
          this.refreshCode();
        })
      }
    }.borderRadius(Radius.md).clip(true).backgroundColor($r('app.color.surface_variant')).width('100%')
    .border({ width: 0.5, color: $r('app.color.divider') }).margin({ top: 2, bottom: 2 })
  }

  @Builder
  table(block: MarkdownBlock, blockIndex: number) {
    Scroll() {
      Column() {
        ForEach(this.model.blocks[blockIndex].rows, (row: string[], index: number) => {
          Row() {
            ForEach(row, (cell: string, column: number) => {
              Column() { this.prose(cell, 14, index === 0, $r('app.color.text_primary'), `${blockIndex}:${index}:${column}`) }
                .width(this.tableWidths[blockIndex][column] || 88).padding({ left: 10, right: 10, top: 8, bottom: 8 })
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

  @Builder
  imagePreview() {
    ImageViewer({ source: this.previewSource, onClose: () => { this.previewing = false; } })
  }

  // A standalone image line becomes its own block. Parsing only accepts HTTPS, so a reply cannot
  // point the app at cleartext or local sources; a broken URL falls back to a tap-through card.
  @Builder
  image(index: number) {
    if (this.imageFailed.includes(index)) {
      Row({ space: Space.sm }) {
        SymbolGlyph($r('sys.symbol.picture')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        Column({ space: 1 }) {
          Text(this.imageAlt(index) || t('图片')).fontFamily(this.appearance.fontFamily).fontSize(13).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.text_primary'))
          Text(t('图片加载失败，轻点用浏览器打开')).fontFamily(this.appearance.fontFamily).fontSize(11)
            .fontColor($r('app.color.text_secondary'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%').padding({ left: Space.md, right: Space.md, top: 10, bottom: 10 })
      .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
      .border({ width: 0.5, color: $r('app.color.divider') })
      .accessibilityText(this.imageAlt(index) || t('图片'))
      .onClick(() => this.open(this.imageUrl(index)))
    } else {
      Image(this.imageUrl(index))
        .width('100%').height(IMAGE_HEIGHT).objectFit(ImageFit.Contain)
        .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
        .accessibilityText(this.imageAlt(index) || t('图片'))
        .onError(() => {
          if (this.imageFailed.includes(index)) { return; }
          this.imageFailed = this.imageFailed.concat([index]); this.invalidateMeasure();
        })
        .onClick(() => { this.previewSource = this.imageUrl(index); this.previewing = true; })
    }
  }

  build() {
    Column() {
      if (this.visible || this.measuredHeight === 0) {
        Column({ space: 10 }) {
          ForEach(this.model.blocks, (block: MarkdownBlock, index: number) => {
            if (this.model.blocks[index].kind === 'code') {
              this.codeBlock(this.model.blocks[index], index)
            } else if (this.model.blocks[index].kind === 'table') {
              this.table(this.model.blocks[index], index)
            } else if (this.model.blocks[index].kind === 'image') {
              this.image(index)
            } else if (this.model.blocks[index].kind === 'rule') {
              Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ top: 4, bottom: 4 })
            } else if (this.model.blocks[index].kind === 'quote') {
              Column() { this.prose(this.model.blocks[index].text, this.fontSize - 1, false, $r('app.color.text_secondary'), `${index}`) }
                .width('100%').padding({ left: Space.md, top: 2, bottom: 2 })
                .border({ width: { left: 3 }, color: this.appearance.accent })
            } else if (this.model.blocks[index].kind === 'list') {
              Row() {
                Text(this.model.blocks[index].rows[0][0]).fontFamily(this.appearance.fontFamily).fontSize(this.model.blocks[index].rows[0][0] === '•' ? this.fontSize + 2 : this.fontSize)
                  .lineHeight(Math.round(this.fontSize * 1.62)).constraintSize({ minWidth: 22 })
                  .fontColor(this.model.blocks[index].rows[0][0] === '☑' ? this.appearance.accent : $r('app.color.text_secondary'))
                Column() { this.prose(this.model.blocks[index].text, this.fontSize, false, $r('app.color.text_primary'), `${index}`) }.layoutWeight(1)
              }.width('100%').alignItems(VerticalAlign.Top).padding({ left: this.model.blocks[index].level * 18 }).margin({ top: -4 })
            } else if (this.model.blocks[index].kind === 'heading') {
              Column() { this.prose(this.model.blocks[index].text, this.headingSize(this.model.blocks[index].level), true, $r('app.color.text_primary'), `${index}`) }
                .margin({ top: this.blockOffset + index > 0 ? 6 : 0 })
            } else {
              this.prose(this.model.blocks[index].text, this.fontSize, false, $r('app.color.text_primary'), `${index}`)
            }
          }, (_block: MarkdownBlock, index: number) => `${index}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
        .onAreaChange((previous: Area, area: Area) => { this.measuredHeight = Number(area.height);
          if (Diagnostics.recording) {
            Diagnostics.measure('layout.chunkCallback', 1, 'count');
            if (previous.height !== area.height || previous.width !== area.width) {
              Diagnostics.event('layout.chunk', { heightVp: this.measuredHeight, widthVp: Number(area.width), offset: this.blockOffset }, this.perfId);
            }
          } })
      } else {
        // Preserve the exact measured extent while releasing offscreen Text/Span nodes.
        Blank().width('100%').height(this.measuredHeight)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
    .bindContentCover($$this.previewing, this.imagePreview(), { modalTransition: ModalTransition.ALPHA })
    .onAreaChange((_previous: Area, area: Area) => {
      const width = Number(area.width);
      if (this.measuredWidth > 0 && width !== this.measuredWidth) { this.invalidateMeasure(); }
      this.measuredWidth = width;
    })
    .onVisibleAreaChange([0], (visible: boolean) => {
      if (Diagnostics.recording) { Diagnostics.event('render.visibility', { visible: visible ? 1 : 0, heightVp: this.measuredHeight }, this.perfId); }
      this.visible = visible; clearTimeout(this.revealTimer); this.revealTimer = -1;
      if (visible) { this.revealTime = Date.now(); this.scheduleReveal(); }
    })
  }
}
