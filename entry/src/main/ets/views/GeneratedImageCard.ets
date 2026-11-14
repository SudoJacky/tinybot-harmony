import { AnimatorResult, ColorMetrics } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Radius } from '../common/Theme';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { Cancellation } from '../services/Cancellation';

const REVEAL_MS = 500;
const PREVIEW_EDGE = 1024;
const MOSAIC_EDGES: number[] = [20, 32, 52, 86, 144, 240];
const REFERENCE_EDGE = 192;
const MAX_REFERENCE_PIXELS = 24 * 1024 * 1024;
const QUEUED_MOSAIC: string[][] = [
  ['#BDBDCC', '#BCBDCD', '#C5C3D1', '#D2CCD7', '#C9C7D4', '#C0C2D1', '#B9BECE'],
  ['#B9BBCB', '#BDBECD', '#C6C5D2', '#C8C6D3', '#C0C2D0', '#BCBFCE', '#B7BCCC'],
  ['#B8BDCB', '#BABECC', '#BCBFCD', '#BABDCC', '#B7BCCB', '#B5BAC9', '#B3B8C8'],
  ['#A6ADBA', '#A9B0BE', '#ADB3C1', '#ADB3C1', '#AAB1BF', '#A9AFBE', '#A7AEBC'],
  ['#ACB2BE', '#ACB2BF', '#AFB5C2', '#AEB4C1', '#A7AEBC', '#A8AEBC', '#A4ACBA']
];

@Component
export struct GeneratedImageCard {
  @StorageProp('tinybot.appearance.style') @Watch('syncMotion')
  private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.foreground') @Watch('syncMotion') private foreground: boolean = true;
  @Prop @Watch('pathChanged') path: string = '';
  @Prop ratio: number = 1;
  @Prop cardId: string = '';
  references: string[] = [];
  readReference?: (path: string, signal: Cancellation) => Promise<Uint8Array>;
  onOpen: () => void = () => {};

  @State private showResult: boolean = false;
  @State private imageLoaded: boolean = false;
  @State private loadFailed: boolean = false;
  @State private showingReference: boolean = false;
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private animator?: AnimatorResult;
  private ready: boolean = false;
  private visible: boolean = false;
  private mounted: boolean = false;
  private sawPlaceholder: boolean = false;
  private loading: boolean = false;
  private phase: number = 0;
  private aspect: number = 1;
  private waitingTint: string = '';
  private frames: image.PixelMap[] = [];
  private reference?: image.PixelMap;
  private referenceAspect: number = 1;
  private referenceRead?: Cancellation;
  private triedReference: boolean = false;

  aboutToAppear(): void {
    this.mounted = true;
    this.showResult = this.path.length > 0;
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.visible = false;
    this.ready = false;
    this.stop();
    this.releaseReference();
    this.releaseFrames();
  }

  private stop(): void {
    const animation = this.animator;
    this.animator = undefined;
    animation?.cancel();
  }

  private releaseFrames(): void {
    for (const frame of this.frames) { frame.release(); }
    this.frames = [];
  }

  private releaseReference(): void {
    this.referenceRead?.cancel();
    this.reference?.release();
    this.reference = undefined;
    this.showingReference = false;
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
      const tint = ColorMetrics.resourceColor(this.appearance.accent);
      this.waitingTint = tint.red + ',' + tint.green + ',' + tint.blue;
      if (this.canAnimate()) {
        if (!this.triedReference && this.references.length && this.readReference) {
          this.triedReference = true;
          this.prepareReference(this.references[Math.floor(Math.random() * this.references.length)], this.readReference);
        }
        if (!this.animator) {
          this.phase = 0;
          this.drawWaiting();
          this.play(2100, -1, (phase: number) => { this.phase = phase; this.drawWaiting(); });
        }
      } else {
        this.stop();
        this.drawWaiting(false);
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
    this.releaseReference();
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
    let frames: image.PixelMap[] = [];
    try {
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const source = image.createImageSource(file.fd);
        try {
          const size = (await source.getImageInfo()).size;
          const clear = await this.decodeAtSize(source, size, PREVIEW_EDGE);
          frames.push(clear);
          const decoded = (await clear.getImageInfo()).size;
          const edge = Math.max(decoded.width, decoded.height);
          for (const level of MOSAIC_EDGES) {
            if (level >= edge || !this.canAnimate() || this.showResult) { break; }
            const scale = level / edge;
            frames.splice(frames.length - 1, 0, await clear.createScaledPixelMap(scale, scale, image.AntiAliasingLevel.MEDIUM));
          }
          this.aspect = size.width / size.height;
        } finally { await source.release(); }
      } finally { await fs.close(file); }
      if (!this.canAnimate() || this.showResult || this.path !== path) { return; }
      this.frames = frames;
      frames = [];
      this.phase = 0;
      this.drawReveal();
      this.play(REVEAL_MS, 1, (phase: number) => { this.phase = phase; this.drawReveal(); });
    } catch (error) {
      Diagnostics.log('warn', 'preview', 'thumbnail_failed', undefined, error as Error);
      if (this.mounted) { this.displayResult(); }
    } finally {
      for (const frame of frames) { await frame.release(); }
      this.loading = false;
    }
  }

  private decodeAtSize(source: image.ImageSource, size: image.Size, edge: number): Promise<image.PixelMap> {
    const scale = Math.min(1, edge / Math.max(size.width, size.height));
    return source.createPixelMap({ desiredSize: {
      width: Math.max(1, Math.round(size.width * scale)), height: Math.max(1, Math.round(size.height * scale)) } });
  }

  private async prepareReference(path: string, read: (path: string, signal: Cancellation) => Promise<Uint8Array>): Promise<void> {
    const signal = new Cancellation();
    this.referenceRead = signal;
    let preview: image.PixelMap | undefined;
    try {
      const bytes = await read(path, signal);
      signal.check();
      const data = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
      const source = image.createImageSource(data);
      try {
        const size = (await source.getImageInfo()).size;
        if (size.width * size.height > MAX_REFERENCE_PIXELS) { throw new Error('Image reference exceeds preview pixel limit.'); }
        this.referenceAspect = size.width / size.height;
        preview = await this.decodeAtSize(source, size, REFERENCE_EDGE);
      } finally { await source.release(); }
      if (!this.mounted || this.path || signal.cancelled) { return; }
      this.reference = preview;
      preview = undefined;
      this.showingReference = true;
      this.drawWaiting(this.canAnimate());
    } catch (error) {
      if (!signal.cancelled) { Diagnostics.log('warn', 'preview', 'thumbnail_failed', undefined, error as Error); }
    } finally {
      await preview?.release();
      this.referenceRead = undefined;
    }
  }

  private drawWaiting(sweep: boolean = true): void {
    const ctx = this.canvas;
    const width = ctx.width;
    const height = ctx.height;
    if (width <= 0 || height <= 0) { return; }
    ctx.clearRect(0, 0, width, height);
    if (this.reference) {
      const w = Math.min(width, height * this.referenceAspect);
      const h = w / this.referenceAspect;
      ctx.save();
      ctx.globalAlpha = 0.78;
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(this.reference, (width - w) / 2, (height - h) / 2, w, h);
      ctx.restore();
    } else {
      this.drawQueuedMosaic(width, height, sweep);
    }
    if (!sweep) { return; }
    const spread = width * 0.4;
    const center = -spread + (width + spread * 2) * this.phase;
    const beam = ctx.createLinearGradient(center - spread, height, center + spread, 0);
    const highlight = this.reference ? '255,255,255' : this.waitingTint;
    beam.addColorStop(0, 'rgba(' + highlight + ',0)');
    beam.addColorStop(0.5, 'rgba(' + highlight + ',' + ((this.reference ? 0.16 : 0.07) * this.appearance.effectStrength) + ')');
    beam.addColorStop(1, 'rgba(' + highlight + ',0)');
    ctx.fillStyle = beam;
    ctx.fillRect(0, 0, width, height);
  }

  private drawQueuedMosaic(width: number, height: number, animated: boolean): void {
    const ctx = this.canvas;
    const cellWidth = width / QUEUED_MOSAIC[0].length;
    const cellHeight = height / QUEUED_MOSAIC.length;
    const pulse = animated ? (1 - Math.cos(this.phase * Math.PI * 2)) * 0.04 * this.appearance.effectStrength : 0;
    ctx.globalAlpha = 1 - pulse;
    for (let row = 0; row < QUEUED_MOSAIC.length; row++) {
      const top = Math.round(row * cellHeight);
      const bottom = row === QUEUED_MOSAIC.length - 1 ? height : Math.round((row + 1) * cellHeight);
      const colors = QUEUED_MOSAIC[row];
      for (let column = 0; column < colors.length; column++) {
        const left = Math.round(column * cellWidth);
        const right = column === colors.length - 1 ? width : Math.round((column + 1) * cellWidth);
        ctx.fillStyle = colors[column];
        ctx.fillRect(left, top, right - left, bottom - top);
      }
    }
    ctx.globalAlpha = 1;
  }

  private drawReveal(): void {
    if (!this.frames.length) { return; }
    const ctx = this.canvas;
    const width = ctx.width;
    const height = ctx.height;
    ctx.clearRect(0, 0, width, height);
    const w = Math.min(width, height * this.aspect);
    const h = w / this.aspect;
    const x = (width - w) / 2;
    const y = (height - h) / 2;
    const last = this.frames.length - 1;
    const level = Math.max(0, Math.min(1, this.phase)) * last;
    const lower = Math.min(last, Math.floor(level));
    const higher = Math.min(last, lower + 1);
    const edge = Math.round(h * this.phase);
    // Each pass replaces coarse pixels with the next smaller blocks. The last frame uses the clear preview.
    this.drawRegion(this.frames[lower], x, y, w, h, y + edge, h - edge, lower === last);
    this.drawRegion(this.frames[higher], x, y, w, h, y, edge, higher === last);
    this.drawScan(x, y, w, h, edge);
  }

  private drawRegion(pixel: image.PixelMap, x: number, y: number, width: number, height: number,
    clipTop: number, clipHeight: number, smooth: boolean): void {
    if (clipHeight <= 0) { return; }
    const ctx = this.canvas;
    ctx.save();
    ctx.beginPath(); ctx.rect(x, clipTop, width, clipHeight); ctx.clip();
    ctx.imageSmoothingEnabled = smooth;
    ctx.drawImage(pixel, x, y, width, height);
    ctx.restore();
  }

  private drawScan(x: number, y: number, width: number, height: number, edge: number): void {
    const ctx = this.canvas;
    if (edge <= 0 || edge >= height) { return; }
    const scanY = y + edge;
    const glow = ctx.createLinearGradient(0, scanY - 4, 0, scanY + 4);
    glow.addColorStop(0, '#00FFFFFF');
    glow.addColorStop(0.5, 'rgba(255,255,255,' + (0.72 * this.appearance.effectStrength) + ')');
    glow.addColorStop(1, '#00FFFFFF');
    ctx.fillStyle = glow;
    ctx.fillRect(x, scanY - 4, width, 8);
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
        if (this.showingReference) {
          Row({ space: 7 }) {
            SymbolGlyph($r('sys.symbol.picture')).fontSize(17).fontColor([this.appearance.accent]).accessibilityLevel('no')
            Text(t('参考图 · 正在生成图片…')).fontSize(13).fontFamily(this.appearance.fontFamily)
              .fontColor($r('app.color.text_secondary'))
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(Radius.md).backgroundColor($r('app.color.surface_variant'))
        } else {
          Row({ space: 6 }) {
            LoadingProgress().width(14).height(14).color('#5D606A')
              .enableLoading(this.foreground && this.appearance.effectStrength > 0).accessibilityLevel('no')
            Text(t('等待中')).fontSize(13).fontWeight(FontWeight.Medium).fontFamily(this.appearance.fontFamily)
              .fontColor('#202127')
          }.id(this.cardId + '-queued').height(28).padding({ left: 9, right: 11 })
            .borderRadius(14).backgroundColor('#E6F7F7FA')
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
