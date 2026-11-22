import { common } from '@kit.AbilityKit';
import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { MarkdownSpan, markdownSpans } from '../model/Markdown';
import { acquireMath, forgetMissingMath, MathImage, MathLease } from '../services/MathResources';

interface MathSpan extends MarkdownSpan {
  image?: MathImage;
  failed: boolean;
}

interface MathRow {
  spans: MathSpan[];
  block: boolean;
}

@Component
export struct MathView {
  @StorageProp('tinybot.appearance.style') @Watch('refresh') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.dark') @Watch('refresh') private dark: boolean = false;
  @Prop @Watch('refresh') content: string = '';
  @Prop @Watch('refresh') display: boolean = false;
  @Prop @Watch('rebuild') fontSize: number = 16;
  @Prop bold: boolean = false;
  @Prop @Watch('refresh') color: ResourceColor = $r('app.color.text_primary');
  @Prop selectable: boolean = true;
  @State private rows: MathRow[] = [];
  @State private availableWidth: number = 0;
  private source: MarkdownSpan[] = [];
  private leases: Map<string, MathLease> = new Map();
  private images: Map<string, MathImage> = new Map();
  private failed: Set<string> = new Set();
  private palette: string = '';
  private mounted: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void {
    this.generation++;
    this.mounted = true;
    this.refresh();
  }

  aboutToDisappear(): void {
    this.generation++;
    this.mounted = false;
    this.visible = false;
    this.clear();
  }

  private clear(): void {
    this.leases.forEach((lease: MathLease) => lease.release());
    this.leases.clear();
    this.images.clear();
    this.failed.clear();
  }

  private rgb(): string {
    const color = ColorMetrics.resourceColor(this.color);
    return '#' + color.red.toString(16).padStart(2, '0') +
      color.green.toString(16).padStart(2, '0') + color.blue.toString(16).padStart(2, '0');
  }

  private refresh(): void {
    if (!this.mounted) { return; }
    const palette = this.rgb() + (this.display ? ':display' : '');
    if (this.palette !== palette) { this.clear(); this.palette = palette; }
    this.source = this.display ? [{ text: this.content, kind: 'math', url: '' }] : markdownSpans(this.content);
    const wanted = new Set<string>();
    this.source.forEach((span: MarkdownSpan) => { if (span.kind === 'math') { wanted.add(span.text); } });
    this.leases.forEach((lease: MathLease, tex: string) => {
      if (wanted.has(tex)) { return; }
      this.leases.delete(tex);
      this.images.delete(tex);
      this.failed.delete(tex);
      lease.release();
    });
    this.rebuild();
    this.request();
  }

  private request(): void {
    if (!this.visible || !this.mounted) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const color = this.palette.slice(0, 7);
    this.source.forEach((span: MarkdownSpan) => {
      if (span.kind !== 'math' || this.leases.has(span.text)) { return; }
      const tex = span.text;
      const lease = acquireMath(context.cacheDir, tex, this.display, color);
      this.leases.set(tex, lease);
      lease.result.then((image: MathImage) => {
        if (this.leases.get(tex) !== lease) { return; }
        this.images.set(tex, image);
        this.rebuild();
      }, () => {
        if (this.leases.get(tex) !== lease) { return; }
        this.failed.add(tex);
        this.rebuild();
      });
    });
  }

  private setVisibility(visible: boolean): void {
    this.visible = visible;
    if (visible) { this.request(); return; }
    this.leases.forEach((lease: MathLease, tex: string) => {
      if (this.images.has(tex) || this.failed.has(tex)) { return; }
      this.leases.delete(tex);
      lease.release();
    });
  }

  private em(): number {
    const ui = this.getUIContext();
    return ui.px2vp(ui.fp2px(this.fontSize)) * (this.display ? 1.18 : 1);
  }

  private imageWidth(image: MathImage): number { return Math.max(1, image.width * this.em()); }
  private imageHeight(image: MathImage): number { return Math.max(1, image.height * this.em()); }

  private rebuild(): void {
    if (!this.mounted) { return; }
    const rows: MathRow[] = [];
    let inline: MathSpan[] = [];
    this.source.forEach((span: MarkdownSpan) => {
      const image = span.kind === 'math' && !this.failed.has(span.text) ? this.images.get(span.text) : undefined;
      const item: MathSpan = { kind: span.kind, text: span.text, url: span.url, image: image, failed: this.failed.has(span.text) };
      if (this.display || (image && this.availableWidth > 0 && this.imageWidth(image) > this.availableWidth)) {
        if (inline.length) { rows.push({ spans: inline, block: false }); inline = []; }
        rows.push({ spans: [item], block: true });
      } else {
        inline.push(item);
      }
    });
    if (inline.length) { rows.push({ spans: inline, block: false }); }
    this.rows = rows;
  }

  private async imageFailed(tex: string, uri: string): Promise<void> {
    const lease = this.leases.get(tex);
    if (!lease || this.images.get(tex)?.uri !== uri || this.failed.has(tex)) { return; }
    this.failed.add(tex);
    try {
      // The storage cleanup page can remove a previously rendered SVG.
      if (await forgetMissingMath(tex, this.display, this.palette.slice(0, 7), uri)) {
        if (this.leases.get(tex) === lease) {
          lease.release();
          this.leases.delete(tex); this.images.delete(tex); this.failed.delete(tex);
          this.rebuild(); this.request();
        }
        return;
      }
    } catch (error) {
      Diagnostics.log('warn', 'math', 'cache_read_failed', undefined, error as Error);
    }
    if (this.leases.get(tex) !== lease) { return; }
    Diagnostics.log('warn', 'math', 'image_decode_failed');
    this.rebuild();
  }

  private onImageError(tex: string, uri: string): () => void {
    return () => { this.imageFailed(tex, uri); };
  }

  private async open(url: string): Promise<void> {
    if (!/^https?:\/\//.test(url)) { return; }
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: url }); }
    catch (_) {
      if (this.mounted) { this.getUIContext().getPromptAction().showToast({ message: t('无法打开链接，可复制后在浏览器中打开。') }); }
    }
  }

  @Builder
  blockImage(index: number) {
    Image(this.rows[index].spans[0].image!.uri)
      .width(this.imageWidth(this.rows[index].spans[0].image!))
      .height(this.imageHeight(this.rows[index].spans[0].image!))
      .objectFit(ImageFit.Fill)
      .accessibilityText(this.rows[index].spans[0].text)
      .onError(this.onImageError(this.rows[index].spans[0].text, this.rows[index].spans[0].image!.uri))
  }

  @Builder
  block(index: number) {
    if (this.rows[index].spans[0].image) {
      if (this.availableWidth > 0 && this.imageWidth(this.rows[index].spans[0].image!) > this.availableWidth) {
        Scroll() { this.blockImage(index) }
          .width('100%').scrollable(ScrollDirection.Horizontal)
      } else {
        Row() { this.blockImage(index) }.width('100%').justifyContent(FlexAlign.Center)
      }
    } else if (this.rows[index].spans[0].failed) {
      Text(t('公式渲染失败')).fontSize(12).fontColor($r('app.color.danger'))
      Text(this.rows[index].spans[0].text).fontSize(this.fontSize).fontColor($r('app.color.danger'))
        .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
    } else {
      Text(this.rows[index].spans[0].text).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(this.fontSize).fontColor(this.color)
    }
  }

  @Builder
  prose(index: number) {
    Text() {
      ForEach(this.rows[index].spans, (span: MathSpan) => {
        if (span.image) {
          ImageSpan(span.image.uri)
            .width(this.imageWidth(span.image)).height(this.imageHeight(span.image))
            .objectFit(ImageFit.Fill).verticalAlign(ImageSpanAlignment.BASELINE)
            .baselineOffset(LengthMetrics.vp(-span.image.descent * this.em()))
            .accessibilityText(span.text)
            .onError(this.onImageError(span.text, span.image.uri))
        } else if (span.kind === 'code') {
          Span('\u00a0' + span.text + '\u00a0').fontFamily('monospace').fontSize(this.fontSize - 2)
            .textBackgroundStyle({ color: $r('app.color.surface_variant'), radius: 4 })
        } else {
          Span(span.text).fontWeight(this.bold || span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(span.failed ? $r('app.color.danger') : span.kind === 'link' ? this.appearance.accent : this.color)
            .decoration({ type: span.kind === 'link' ? TextDecorationType.Underline :
              span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None })
            .onClick(() => { if (span.url) { this.open(span.url); } })
        }
      }, (span: MathSpan, offset: number) => JSON.stringify([offset, span.kind, span.text, span.url, span.image?.uri, span.failed]))
    }.fontFamily(this.appearance.fontFamily).fontSize(this.fontSize).fontColor(this.color)
      .lineSpacing(LengthMetrics.vp(3), { onlyBetweenLines: true })
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None).width('100%')
  }

  build() {
    Column({ space: 4 }) {
      ForEach(this.rows, (_row: MathRow, index: number) => {
        if (this.rows[index].block) { this.block(index) } else { this.prose(index) }
      }, (_row: MathRow, index: number) => `${index}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onAreaChange((_previous: Area, area: Area) => {
        const generation = this.generation;
        Promise.resolve().then(() => {
          if (this.mounted && generation === this.generation && Number(area.width) !== this.availableWidth) {
            this.availableWidth = Number(area.width);
            this.rebuild();
          }
        });
      })
      .onVisibleAreaChange([0], (visible: boolean) => {
        const generation = this.generation;
        Promise.resolve().then(() => { if (this.mounted && generation === this.generation) { this.setVisibility(visible); } });
      })
  }
}
