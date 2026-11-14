import { AnimatorResult, ColorMetrics } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Radius } from '../common/Theme';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';

const REVEAL_MS = 500;
const PREVIEW_EDGE = 1024;
const MOSAIC_EDGE = 26;

@Component
export struct GeneratedImageCard {
  @StorageProp('tinybot.appearance.style') @Watch('syncMotion')
  private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncMotion') private foreground: boolean = true;
  @Prop @Watch('pathChanged') path: string = '';
  @Prop ratio: number = 1;
  @Prop cardId: string = '';
  onOpen: () => void = () => {};

  @State private showResult: boolean = false;
  @State private imageLoaded: boolean = false;
  @State private loadFailed: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animator?: AnimatorResult;
  private ready: boolean = false;
  private visible: boolean = false;
  private mounted: boolean = false;
  private sawPlaceholder: boolean = false;
  private loading: boolean = false;
  private phase: number = 0;
  private aspect: number = 1;
  private clear?: image.PixelMap;
  private mosaic?: image.PixelMap;

  aboutToAppear(): void {
    this.mounted = true;
    this.showResult = this.path.length > 0;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.visible = false;
    this.ready = false;
    this.stop();
    this.releaseFrames();
  }

  private stop(): void {
    const animation = this.animator;
    this.animator = undefined;
    animation?.cancel();
  }

  private releaseFrames(): void {
    this.clear?.release();
    this.mosaic?.release();
    this.clear = undefined;
    this.mosaic = undefined;
  }

  private displayResult(): void {
    this.stop();
    this.showResult = true;
    this.releaseFrames();
  }

  private canAnimate(): boolean {
    return this.mounted && this.foreground && this.visible && this.appearance.effectStrength > 0;
  }

  private syncMotion(): void {
    if (this.showResult || !this.ready) { return; }
    if (!this.path) {
      if (this.canAnimate()) {
        if (!this.animator) {
          this.phase = 0;
          this.drawWaiting();
          this.play(2100, -1, (phase: number) => { this.phase = phase; this.drawWaiting(); });
        }
      } else {
        this.stop();
        this.canvas.clearRect(0, 0, this.canvas.width, this.canvas.height);
      }
    } else if (!this.canAnimate()) {
      this.displayResult();
    }
  }

  private visibilityChanged(visible: boolean): void {
    this.visible = visible;
    if (visible && !this.path && this.foreground) { this.sawPlaceholder = true; }
    this.syncMotion();
  }

  private pathChanged(): void {
    if (!this.mounted || !this.path || this.loading || this.showResult) { return; }
    this.stop();
    if (!this.sawPlaceholder || !this.canAnimate() || !this.ready) {
      this.displayResult();
      return;
    }
    this.prepareReveal(this.path);
  }

  private play(duration: number, iterations: number, frame: (phase: number) => void): void {
    const animation = this.getUIContext().createAnimator({ duration: duration, iterations: iterations,
      easing: iterations === 1 ? 'cubic-bezier(0.25, 0.15, 0.45, 1)' : 'linear',
      begin: 0, end: 1, delay: 0, fill: 'none', direction: 'normal' });
    this.animator = animation;
    animation.onFrame = (phase: number) => { if (this.animator === animation) { frame(phase); } };
    animation.onFinish = () => {
      if (this.animator === animation) {
        frame(1);
        this.displayResult();
      }
    };
    animation.play();
  }

  private async prepareReveal(path: string): Promise<void> {
    this.loading = true;
    let clear: image.PixelMap | undefined;
    let mosaic: image.PixelMap | undefined;
    try {
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const source = image.createImageSource(file.fd);
        try {
          const size = (await source.getImageInfo()).size;
          const longest = Math.max(size.width, size.height);
          const scale = Math.min(1, PREVIEW_EDGE / longest);
          clear = await source.createPixelMap({ desiredSize: {
            width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)) } });
          const pixelScale = Math.min(1, MOSAIC_EDGE / longest);
          mosaic = await source.createPixelMap({ desiredSize: {
            width: Math.max(1, Math.round(size.width * pixelScale)), height: Math.max(1, Math.round(size.height * pixelScale)) } });
          this.aspect = size.width / size.height;
        } finally { await source.release(); }
      } finally { await fs.close(file); }
      if (!this.canAnimate() || this.showResult || this.path !== path) { return; }
      this.clear = clear; this.mosaic = mosaic;
      clear = undefined; mosaic = undefined;
      this.phase = 0;
      this.drawReveal();
      this.play(REVEAL_MS, 1, (phase: number) => { this.phase = phase; this.drawReveal(); });
    } catch (error) {
      Diagnostics.log('warn', 'preview', 'thumbnail_failed', undefined, error as Error);
      if (this.mounted) { this.displayResult(); }
    } finally {
      await clear?.release();
      await mosaic?.release();
      this.loading = false;
    }
  }

  private drawWaiting(): void {
    const ctx = this.canvas;
    const width = ctx.width;
    const height = ctx.height;
    if (width <= 0 || height <= 0) { return; }
    ctx.clearRect(0, 0, width, height);
    const tint = ColorMetrics.resourceColor(this.appearance.accent);
    const rgb = tint.red + ',' + tint.green + ',' + tint.blue;
    const spread = width * 0.4;
    const center = -spread + (width + spread * 2) * this.phase;
    const beam = ctx.createLinearGradient(center - spread, height, center + spread, 0);
    beam.addColorStop(0, 'rgba(' + rgb + ',0)');
    beam.addColorStop(0.5, 'rgba(' + rgb + ',' + (0.13 * this.appearance.effectStrength) + ')');
    beam.addColorStop(1, 'rgba(' + rgb + ',0)');
    ctx.fillStyle = beam;
    ctx.fillRect(0, 0, width, height);
  }

  private drawReveal(): void {
    if (!this.clear || !this.mosaic) { return; }
    const ctx = this.canvas;
    const width = ctx.width;
    const height = ctx.height;
    ctx.clearRect(0, 0, width, height);
    const w = Math.min(width, height * this.aspect);
    const h = w / this.aspect;
    const x = (width - w) / 2;
    const y = (height - h) / 2;
    const edge = Math.round(h * this.phase);
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y + edge, w, h - edge); ctx.clip();
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(this.mosaic, x, y, w, h);
    ctx.restore();
    ctx.save();
    ctx.beginPath(); ctx.rect(x, y, w, edge); ctx.clip();
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(this.clear, x, y, w, h);
    ctx.restore();
    if (edge <= 0 || edge >= h) { return; }
    const scanY = y + edge;
    const glow = ctx.createLinearGradient(0, scanY - 4, 0, scanY + 4);
    glow.addColorStop(0, '#00FFFFFF');
    glow.addColorStop(0.5, 'rgba(255,255,255,' + (0.72 * this.appearance.effectStrength) + ')');
    glow.addColorStop(1, '#00FFFFFF');
    ctx.fillStyle = glow;
    ctx.fillRect(x, scanY - 4, w, 8);
  }

  build() {
    Stack() {
      if (this.path) {
        Image('file://' + this.path).width('100%').height('100%').objectFit(ImageFit.Contain)
          .opacity(this.showResult ? 1 : 0).accessibilityLevel('no')
          .onComplete((event) => { if (event?.loadingStatus === 1) { this.imageLoaded = true; } })
          .onError(() => { this.loadFailed = true; })
      }
      if (!this.showResult || (this.ready && !this.imageLoaded && !this.loadFailed)) {
        Canvas(this.canvas).width('100%').height('100%').hitTestBehavior(HitTestMode.None).accessibilityLevel('no')
          .onReady(() => { this.ready = true; this.syncMotion(); })
      }
      if (this.loadFailed && this.showResult) {
        Text(t('图片加载失败')).fontSize(13).fontFamily(this.appearance.fontFamily)
          .fontColor($r('app.color.text_secondary'))
      } else if (!this.path) {
        Row({ space: 7 }) {
          SymbolGlyph($r('sys.symbol.picture')).fontSize(17).fontColor([this.appearance.accent]).accessibilityLevel('no')
          Text(t('正在生成图片…')).fontSize(13).fontFamily(this.appearance.fontFamily)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      if (this.path) {
        Button({ type: ButtonType.Normal, stateEffect: false }) {}
          .id(this.cardId + '-open').width('100%').height('100%').backgroundColor(Color.Transparent)
          .accessibilityText(t('生成图片') + ' · ' + t('打开文件 · 分享与导出'))
          .onClick(() => this.onOpen())
      }
    }.id(this.cardId).width('100%').constraintSize({ maxWidth: 340 * this.ratio }).aspectRatio(this.ratio)
      .borderRadius(Radius.md).clip(true).backgroundColor($r('app.color.surface_variant'))
      .onVisibleAreaChange([0.1], (_visible: boolean, ratio: number) => this.visibilityChanged(ratio >= 0.1))
  }
}
