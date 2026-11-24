import { common } from '@kit.AbilityKit';
import { ColorMetrics, FrameCallback, LengthMetrics } from '@kit.ArkUI';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { MarkdownSpan } from '../model/Markdown';
import { acquireCachedMath, acquireMath, MathImage, MathLease } from '../services/MathResources';

interface MathSpan extends MarkdownSpan {
  image?: MathImage;
  failed: boolean;
}

interface MathRow {
  spans: MathSpan[];
  block: boolean;
}

class MathLayoutFrame extends FrameCallback {
  private readonly apply: () => void;
  constructor(apply: () => void) { super(); this.apply = apply; }
  onFrame(_time: number): void { this.apply(); }
  onIdle(_time: number): void {}
}

@Component
export struct MathView {
  @StorageProp('tinybot.appearance.style') @Watch('refresh') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.dark') @Watch('refresh') private dark: boolean = false;
  @Prop @Watch('refresh') content: string = '';
  @Prop @Watch('refresh') display: boolean = false;
  @Prop @Watch('refresh') fontSize: number = 16;
  @Prop bold: boolean = false;
  @Prop @Watch('refresh') color: ResourceColor = $r('app.color.text_primary');
  @Prop selectable: boolean = true;
  inlineSpans: (source: string) => MarkdownSpan[] = () => [];
  @State private rows: MathRow[] = [];
  @State private availableWidth: number = 0;
  private source: MarkdownSpan[] = [];
  private leases: Map<string, MathLease> = new Map();
  private images: Map<string, MathImage> = new Map();
  private failed: Set<string> = new Set();
  private palette: string = '';
  private emPixels: number = 0;
  private emVp: number = 0;
  private mounted: boolean = false;
  private visible: boolean = false;
  private layoutScheduled: boolean = false;
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
    this.layoutScheduled = false;
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
    const ui = this.getUIContext();
    const pixels = ui.fp2px(this.fontSize) * (this.display ? 1.18 : 1);
    const emPixels = Math.ceil(pixels);
    this.emVp = ui.px2vp(pixels);
    if (this.palette !== palette || this.emPixels !== emPixels) {
      this.clear(); this.palette = palette; this.emPixels = emPixels;
    }
    this.source = this.display ? [{ text: this.content, kind: 'math', url: '' }] : this.inlineSpans(this.content);
    if (this.leases.size) {
      const wanted = new Set<string>();
      this.source.forEach((span: MarkdownSpan) => { if (span.kind === 'math') { wanted.add(span.text); } });
      this.leases.forEach((lease: MathLease, tex: string) => {
        if (wanted.has(tex)) { return; }
        this.leases.delete(tex);
        this.images.delete(tex);
        this.failed.delete(tex);
        lease.release();
      });
    }
    const color = this.palette.slice(0, 7);
    // A warm formula can take part in the first layout. Misses still wait for visibility.
    this.source.forEach((span: MarkdownSpan) => {
      if (span.kind !== 'math' || this.leases.has(span.text)) { return; }
      const hit = acquireCachedMath(span.text, this.display, color, this.emPixels);
      if (!hit) { return; }
      this.leases.set(span.text, hit);
      this.images.set(span.text, hit.image!);
    });
    this.rebuild();
    this.request();
  }

  private request(): void {
    if (!this.visible || !this.mounted) { return; }
    const color = this.palette.slice(0, 7);
    this.source.forEach((span: MarkdownSpan) => {
      if (span.kind !== 'math' || this.leases.has(span.text)) { return; }
      const tex = span.text;
      const lease = acquireMath(tex, this.display, color, this.emPixels);
      this.leases.set(tex, lease);
      lease.result.then((image: MathImage) => {
        if (this.leases.get(tex) !== lease) { return; }
        this.images.set(tex, image);
        this.scheduleLayout();
      }, () => {
        if (this.leases.get(tex) !== lease) { return; }
        this.failed.add(tex);
        this.scheduleLayout();
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

  private imageWidth(image: MathImage): number { return Math.max(1, image.width * this.emVp); }
  private imageHeight(image: MathImage): number { return Math.max(1, image.height * this.emVp); }

  private scheduleLayout(): void {
    if (this.layoutScheduled || !this.mounted) { return; }
    this.layoutScheduled = true;
    const generation = this.generation;
    this.getUIContext().postFrameCallback(new MathLayoutFrame(() => {
      if (this.generation !== generation) { return; }
      this.layoutScheduled = false;
      this.rebuild();
    }));
  }

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

  private onImageError(tex: string, id: number): () => void {
    return () => {
      if (this.images.get(tex)?.id !== id || this.failed.has(tex)) { return; }
      this.failed.add(tex);
      Diagnostics.log('warn', 'math', 'bitmap_display_failed');
      this.scheduleLayout();
    };
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
    Image(this.rows[index].spans[0].image!.pixelMap)
      .width(this.imageWidth(this.rows[index].spans[0].image!))
      .height(this.imageHeight(this.rows[index].spans[0].image!))
      .objectFit(ImageFit.Fill)
      .accessibilityText(this.rows[index].spans[0].text)
      .onError(this.onImageError(this.rows[index].spans[0].text, this.rows[index].spans[0].image!.id))
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
          ImageSpan(span.image.pixelMap)
            .width(this.imageWidth(span.image)).height(this.imageHeight(span.image))
            .objectFit(ImageFit.Fill).verticalAlign(ImageSpanAlignment.BASELINE)
            .baselineOffset(LengthMetrics.vp(-span.image.descent * this.emVp))
            .accessibilityText(span.text)
            .onError(this.onImageError(span.text, span.image.id))
        } else if (span.kind === 'code') {
          Span(span.text).fontFamily('monospace').fontSize(this.fontSize - 2)
            .textBackgroundStyle({ color: $r('app.color.surface_variant'), radius: 4 })
        } else {
          Span(span.text).fontWeight(this.bold || span.kind === 'bold' ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(span.kind === 'italic' ? FontStyle.Italic : FontStyle.Normal)
            .fontColor(span.failed ? $r('app.color.danger') : span.kind === 'link' ? this.appearance.accent : this.color)
            .decoration({ type: span.kind === 'link' ? TextDecorationType.Underline :
              span.kind === 'strike' ? TextDecorationType.LineThrough : TextDecorationType.None })
            .onClick(() => { if (span.url) { this.open(span.url); } })
        }
      }, (span: MathSpan, offset: number) => JSON.stringify([offset, span.kind, span.text, span.url, span.image?.id, span.failed]))
    }.fontFamily(this.appearance.fontFamily).fontSize(this.fontSize).fontColor(this.color)
      .lineSpacing(LengthMetrics.vp(7), { onlyBetweenLines: true })
      .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None).width('100%')
  }

  build() {
    Column({ space: 8 }) {
      if (this.display && this.rows.length) {
        this.block(0)
      } else {
        ForEach(this.rows, (_row: MathRow, index: number) => {
          if (this.rows[index].block) { this.block(index) } else { this.prose(index) }
        }, (_row: MathRow, index: number) => `${index}`)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
      .padding({ top: this.display ? 6 : 3, bottom: this.display ? 6 : 3 })
      .onAreaChange((previous: Area, area: Area) => {
        const width = Number(area.width);
        if (previous.width === area.width && width === this.availableWidth) { return; }
        const generation = this.generation;
        Promise.resolve().then(() => {
          if (this.mounted && generation === this.generation && width !== this.availableWidth) {
            this.availableWidth = width;
            if (!this.display && this.images.size) { this.scheduleLayout(); }
          }
        });
      })
      .onVisibleAreaChange([0], (visible: boolean) => {
        const generation = this.generation;
        Promise.resolve().then(() => { if (this.mounted && generation === this.generation) { this.setVisibility(visible); } });
      })
  }
}
