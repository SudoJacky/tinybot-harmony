import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { Space } from '../common/Theme';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { MAX_MERMAID_SNAPSHOT_PIXELS, MermaidPreview, mermaidPreviewHasContent, mermaidPreviews, mermaidStartup } from '../services/MermaidResources';

const MERMAID_HOST: string = 'resource://rawfile/mermaid/index.html';

interface MermaidInput {
  revision: number;
  source: string;
  dark: boolean;
  selectable: boolean;
  errorLabel: string;
}

@Component
export struct MermaidView {
  @StorageProp('tinybot.appearance.dark') @Watch('diagramChanged') private dark: boolean = false;
  @StorageProp('tinybot.foreground') @Watch('activate') private foreground: boolean = true;
  @StorageProp('tinybot.chat.scrolling') @Watch('activate') private scrolling: boolean = false;
  @Prop @Watch('diagramChanged') content: string = '';
  @Prop @Watch('render') selectable: boolean = true;
  @State private diagramHeight: number = 40;
  @State private hostFailed: boolean = false;
  @State private showHost: boolean = false;
  @State private rendered: boolean = false;
  @State private preview: MermaidPreview | undefined = undefined;
  private controller?: webview.WebviewController;
  private readonly instanceId: number = Diagnostics.nextId();
  private mounted: boolean = false;
  private visibleRatio: number = 0;
  private widthPx: number = 0;
  private useLive: boolean = false;
  private previewKey: string = '';
  private captureAttempt: string = '';
  private successfulRevision: number = 0;
  private captureTimer: number = -1;
  private lifetime: number = 0;
  private ready: boolean = false;
  private revision: number = 0;
  private timeout: number = -1;

  aboutToAppear(): void {
    this.lifetime++;
    this.mounted = true;
  }

  aboutToDisappear(): void {
    this.lifetime++;
    this.mounted = false;
    this.visibleRatio = 0;
    mermaidStartup.finish(this.instanceId);
    this.releasePreview();
    this.ready = false;
    this.revision++;
    clearTimeout(this.timeout);
    clearTimeout(this.captureTimer);
    this.timeout = -1;
    this.captureTimer = -1;
    this.showHost = false;
    this.rendered = false;
    this.useLive = false;
    this.captureAttempt = '';
    this.controller = undefined;
  }

  private snapshotKey(): string { return JSON.stringify([this.content, this.dark, this.widthPx]); }
  private hostId(): string { return `mermaid-render-${this.instanceId}`; }

  private releasePreview(): void {
    this.preview?.release();
    this.preview = undefined;
    this.previewKey = '';
  }

  private diagramChanged(): void {
    this.releasePreview();
    if (this.showHost) { this.render(); }
    else { this.activate(); }
  }

  private available(): boolean { return this.mounted && this.visibleRatio > 0 && this.foreground && !this.scrolling && !this.hostFailed; }

  private activate(): void {
    if (!this.available()) { mermaidStartup.remove(this.instanceId); return; }
    if (this.showHost) { this.capturePreview(); return; }
    const key = this.snapshotKey();
    if (this.preview && this.previewKey !== key) { this.releasePreview(); }
    if (!this.preview && this.widthPx > 0) {
      const cached = mermaidPreviews.acquire(key);
      if (cached) {
        this.preview = cached; this.previewKey = key; this.diagramHeight = cached.height;
      }
    }
    if (this.preview && !this.useLive) { mermaidStartup.remove(this.instanceId); return; }
    mermaidStartup.request(this.instanceId, this.visibleRatio, () => {
      if (!this.available() || this.showHost) { mermaidStartup.finish(this.instanceId); return; }
      try {
        this.controller = new webview.WebviewController();
        this.showHost = true;
        this.timeout = setTimeout(() => this.fail('startup_timeout'), 15000);
      } catch (error) { this.fail('page_failed', error as Error); }
    });
  }

  private fail(event: string, error?: Error | string): void {
    if (!this.mounted || this.hostFailed) { return; }
    clearTimeout(this.timeout);
    mermaidStartup.finish(this.instanceId);
    this.hostFailed = true;
    Diagnostics.log('error', 'mermaid', event, { chars: this.content.length }, error);
  }

  private async render(): Promise<void> {
    if (!this.mounted || !this.ready || this.hostFailed || !this.controller) { return; }
    const input: MermaidInput = { revision: ++this.revision, source: this.content, dark: this.dark,
      selectable: this.selectable, errorLabel: t('Mermaid 图表渲染失败') };
    clearTimeout(this.timeout);
    this.timeout = setTimeout(() => this.fail('render_timeout'), 15000);
    try {
      // The packaged host receives the diagram as data.
      await this.controller.runJavaScript('window.renderMermaid(' + JSON.stringify(input) + ');');
    } catch (error) {
      if (this.revision === input.revision) { this.fail('script_failed', error as Error); }
    }
  }

  private receiveTitle(title: string): void {
    const match = title.match(/^mermaid:(\d+):(\d+):(ok|error)$/);
    if (!match || Number(match[1]) !== this.revision) { return; }
    const revision = Number(match[1]);
    const height = Number(match[2]);
    Promise.resolve().then(() => {
      if (!this.mounted || this.hostFailed || revision !== this.revision) { return; }
      if (this.timeout !== -1 && match[3] === 'error') {
        Diagnostics.log('warn', 'mermaid', 'diagram_failed', { chars: this.content.length });
      }
      clearTimeout(this.timeout);
      this.timeout = -1;
      this.diagramHeight = Math.max(1, height);
      this.rendered = true;
      mermaidStartup.finish(this.instanceId);
      if (match[3] === 'ok') {
        this.successfulRevision = revision;
        this.capturePreview();
      }
    });
  }

  private canCapture(): boolean {
    return this.available() && this.showHost && this.successfulRevision === this.revision && this.successfulRevision > 0 && this.widthPx > 0;
  }

  private capturePreview(): void {
    if (!this.canCapture() || this.captureTimer !== -1) { return; }
    const key = this.snapshotKey();
    if (key === this.captureAttempt || mermaidPreviews.has(key)) { return; }
    // The successful title comes before ArkWeb presents its independently rendered surface.
    this.captureTimer = setTimeout(() => { this.captureTimer = -1; this.captureSurface(); }, 160);
  }

  private async captureSurface(): Promise<void> {
    const controller = this.controller;
    if (!controller || !this.canCapture()) { return; }
    const height = this.diagramHeight;
    const ui = this.getUIContext();
    if (this.widthPx * ui.vp2px(height) > MAX_MERMAID_SNAPSHOT_PIXELS) { return; }
    const key = this.snapshotKey();
    if (key === this.captureAttempt || mermaidPreviews.has(key)) { return; }
    this.captureAttempt = key;
    const revision = this.revision;
    let pixel: image.PixelMap | undefined;
    try {
      pixel = await image.createPixelMapFromSurface(controller.getSurfaceId());
      const info = await pixel.getImageInfo();
      if (Math.abs(info.size.width - this.widthPx) > 2 || Math.abs(info.size.height - ui.vp2px(height)) > 2 ||
        !await mermaidPreviewHasContent(pixel, info.size.width, info.size.height)) {
        throw new Error('Diagram surface snapshot is empty or its size has not settled');
      }
      if (!this.mounted || this.revision !== revision || this.snapshotKey() !== key || this.hostFailed) { return; }
      mermaidPreviews.store(key, pixel, height);
      pixel = undefined;
    } catch (error) {
      if (this.mounted && this.revision === revision) { Diagnostics.log('warn', 'mermaid', 'snapshot_failed', undefined, error as Error); }
    } finally {
      if (pixel) {
        await pixel.release().catch((error: Error) => Diagnostics.log('warn', 'mermaid', 'snapshot_release_failed', undefined, error));
      }
    }
  }

  private updateSize(area: Area): void {
    const width = Math.round(this.getUIContext().vp2px(Number(area.width)));
    if (width === this.widthPx) { return; }
    const lifetime = this.lifetime;
    Promise.resolve().then(() => {
      if (!this.mounted || this.lifetime !== lifetime) { return; }
      this.widthPx = width;
      this.activate();
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.hostFailed) {
        Column({ space: Space.xs }) {
          Text(t('Mermaid 图表渲染失败')).fontSize(12).fontColor($r('app.color.danger'))
          Text(this.content).fontSize(13).fontFamily('monospace').fontColor($r('app.color.text_primary'))
            .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      }.width('100%').padding(Space.md).alignItems(HorizontalAlign.Start)
      } else {
        if (this.showHost) {
          Web({ src: MERMAID_HOST, controller: this.controller!, renderMode: RenderMode.ASYNC_RENDER })
            .id(this.hostId()).width('100%').height(this.diagramHeight).backgroundColor(Color.Transparent)
            .opacity(this.preview && !this.rendered ? 0 : 1)
            .javaScriptAccess(true).domStorageAccess(false).databaseAccess(false).fileAccess(false)
            .onlineImageAccess(false).blockNetwork(true).multiWindowAccess(false).zoomAccess(false)
            .nestedScroll({ scrollUp: NestedScrollMode.PARENT_FIRST, scrollDown: NestedScrollMode.PARENT_FIRST })
            .onLoadIntercept((event) => {
              return event.data.isMainFrame() && (this.ready || event.data.getRequestUrl() !== MERMAID_HOST);
            })
            .onPageEnd(() => {
              if (!this.mounted || this.ready || this.hostFailed) { return; }
              this.ready = true;
              this.render();
            })
            .onTitleReceive((event) => this.receiveTitle(event.title))
            .onPermissionRequest((event) => event.request.deny())
            .onErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.fail('page_failed', event.error.getErrorInfo()); }
            })
            .onRenderExited(() => this.fail('process_exited'))
        }
        if (this.preview && !this.rendered) {
          Image(this.preview.pixel).width('100%').height(this.preview.height).objectFit(ImageFit.Fill)
            .accessibilityText('Mermaid')
            .onClick(() => { if (this.selectable) { this.useLive = true; this.activate(); } })
        } else if (!this.showHost) {
          Blank().width('100%').height(this.diagramHeight)
        }
      }
    }.width('100%')
      .onAreaChange((_old: Area, area: Area) => this.updateSize(area))
      .onVisibleAreaChange([0, 0.5, 1], (_visible: boolean, ratio: number) => {
        const lifetime = this.lifetime;
        Promise.resolve().then(() => {
          if (!this.mounted || this.lifetime !== lifetime) { return; }
          this.visibleRatio = ratio;
          this.activate();
        });
      })
  }
}
