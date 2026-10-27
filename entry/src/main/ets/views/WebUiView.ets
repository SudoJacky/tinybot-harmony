import { Diagnostics } from '../model/Diagnostics';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { t } from '../model/I18n';
import { UiValues } from '../model/InteractiveUi';
import { WebUiSpec, parseWebUi, parseWebUiMessage, webUiHost, webUiAutoHeight, WEB_UI_ORIGIN } from '../model/WebUi';
import { webUiAssets } from '../services/WebUiAssets';
import { Btn } from '../common/Theme';
import { PreviewBrowserRuntime } from '../services/PreviewBrowserRuntime';
import { browserAutomationScript } from '../model/BrowserScripts';

let activeWebViews: number = 0;
let webViewSequence: number = 0;

@Component
export struct WebUiView {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop @Watch('restart') content: string = '';
  @Prop @Watch('sync') values: UiValues = {};
  @Prop @Watch('sync') interactive: boolean = false;
  @Prop preflight: boolean = false;
  @Prop snapshotMode: boolean = false;
  @Prop retainedHeight: number = 0;
  @Prop @Watch('viewportChanged') viewportHeight: number = 0;
  browserRuntime?: PreviewBrowserRuntime;
  private browserAttachment: number = -1;
  onHeight: (height: number) => void = () => {};
  @StorageLink('tinybot.foreground') @Watch('foregroundChanged') private foreground: boolean = true;
  @StorageProp('tinybot.chat.scrolling') @Watch('visibilityChanged') private scrolling: boolean = false;
  onValidation: (error: string) => void = () => {};
  onSave: (values: UiValues) => Promise<UiValues> = async () => { throw new Error('Web UI save handler missing'); };
  @State private error: string = '';
  @State private ready: boolean = false;
  @State private heightValue: number = 360;
  @State private snapshot: image.PixelMap | undefined = undefined;
  @State private renderWeb: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private ports: webview.WebMessagePort[] = [];
  private spec?: WebUiSpec;
  private mounted: boolean = false;
  private attached: boolean = false;
  private nativeActive: boolean | undefined = undefined;
  private initialPageLoaded: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private timer: number = -1;
  private releaseTimer: number = -1;
  private saving: boolean = false;
  private hostNavigationPending: boolean = false;
  private reloadPending: boolean = false;
  private snapshotRequested: boolean = false;
  private instanceId: number = ++webViewSequence;
  private measuredHeight: number = 0;
  private viewportChanged(): void {
    if (this.viewportHeight > 0) { this.heightValue = this.viewportHeight; }
    else if (this.spec) {
      this.heightValue = webUiAutoHeight(this.spec) ? this.measuredHeight || this.retainedHeight || this.spec.height : this.spec.height;
      if (this.measuredHeight > 0 && webUiAutoHeight(this.spec)) { this.onHeight(this.heightValue); }
    }
  }
  aboutToAppear(): void {
    this.mounted = true;
    try {
      this.spec = parseWebUi(this.content);
      this.heightValue = webUiAutoHeight(this.spec) && this.retainedHeight > 0 ? this.retainedHeight : this.spec.height;
      this.viewportChanged();
    } catch (error) { this.report(error as Error); return; }
    this.visibilityChanged();
  }
  aboutToDisappear(): void { this.mounted = false; clearTimeout(this.releaseTimer); this.releaseWeb(); this.snapshot?.release(); }
  private releaseWeb(): void {
    this.browserRuntime?.detach(this.browserAttachment);
    this.attached = false; this.initialPageLoaded = false; this.hostNavigationPending = false;
    this.nativeActive = undefined;
    this.reloadPending = false;
    this.generation++; this.closePorts(); this.ready = false;
    if (this.renderWeb) {
      activeWebViews--;
      if (Diagnostics.recording) { Diagnostics.event('web.release', { active: activeWebViews, generation: this.generation }, this.instanceId); }
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'release', { instanceId: this.instanceId, generation: this.generation, active: activeWebViews }); };
    }
    this.renderWeb = false;
  }
  private visibilityChanged(): void {
    if (!this.mounted) { return; }
    if (this.preflight || (this.visible && this.foreground)) {
      clearTimeout(this.releaseTimer); this.releaseTimer = -1;
      if ((this.preflight || !this.scrolling) && !this.renderWeb && !this.error) {
        this.controller = new webview.WebviewController(); this.renderWeb = true;
        activeWebViews++;
        if (Diagnostics.recording) { Diagnostics.event('web.activate', { active: activeWebViews, generation: this.generation, preflight: this.preflight ? 1 : 0 }, this.instanceId); }
        if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'activate', { instanceId: this.instanceId, generation: this.generation, active: activeWebViews, preflight: this.preflight }); };
      }
      if ((this.preflight || !this.scrolling) && this.reloadPending) { this.restart(); }
    } else if (this.foreground && this.renderWeb && !this.saving && this.releaseTimer === -1) {
      // Reclaim offscreen views only while ArkUI can commit their removal. A background
      // false -> true update can retain the old native Web with a replacement controller.
      this.releaseTimer = setTimeout(() => { this.releaseTimer = -1; if (this.mounted && this.foreground && !this.visible) { this.releaseWeb(); } }, 5000);
    }
    this.sync();
    this.syncActivity();
  }
  private foregroundChanged(): void {
    clearTimeout(this.releaseTimer); this.releaseTimer = -1;
    this.visibilityChanged();
  }
  private syncActivity(): void {
    if (!this.renderWeb || !this.attached) { return; }
    // Scrolling delays creation/loading, never painting an already visible document.
    const active = this.preflight || (this.visible && this.foreground);
    if (this.nativeActive === active) { return; }
    try {
      if (active) { this.controller.onActive(); } else { this.controller.onInactive(); }
      this.nativeActive = active;
      if (Diagnostics.recording) { Diagnostics.event('web.activity', { active: active ? 1 : 0 }, this.instanceId); }
    } catch (error) { this.report(error as Error); }
  }
  private closePorts(): void {
    this.browserRuntime?.detach(this.browserAttachment); this.browserAttachment = -1;
    clearTimeout(this.timer);
    for (const port of this.ports) { port.close(); }
    this.ports = [];
  }
  private report(error: Error): void {
    this.browserRuntime?.recordError(error.message);
    if (this.browserRuntime?.isReady) {
      Diagnostics.log('error', 'web', 'failed', { instanceId: this.instanceId, generation: this.generation }, error); return;
    }
    this.error = error.message; this.ready = false; clearTimeout(this.timer);
    Diagnostics.log('error', 'web', 'failed', { instanceId: this.instanceId, generation: this.generation }, error);
    if (this.preflight) { this.onValidation(error.message); }
  }
  private async restart(): Promise<void> {
    if (!this.mounted || !this.attached || !this.initialPageLoaded) { return; }
    if (!this.preflight && (this.scrolling || !this.visible || !this.foreground)) { this.reloadPending = true; return; }
    this.reloadPending = false;
    const generation = ++this.generation;
    this.measuredHeight = 0;
    this.closePorts(); this.ready = false; this.error = ''; this.snapshotRequested = false;
    const oldSnapshot = this.snapshot; this.snapshot = undefined; await oldSnapshot?.release();
    try {
      this.spec = parseWebUi(this.content);
      if (!webUiAutoHeight(this.spec)) { this.heightValue = this.spec.height; }
      this.viewportChanged();
      const assets = await webUiAssets(this.getUIContext().getHostContext() as common.UIAbilityContext, this.spec.library === 'three');
      if (!this.mounted || generation !== this.generation) { return; }
      if (!this.preflight && (this.scrolling || !this.visible || !this.foreground)) { this.reloadPending = true; return; }
      const host = webUiHost(assets[0], assets[1], this.browserRuntime ? browserAutomationScript() : '');
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'load_start', { instanceId: this.instanceId, chars: host.length }); };
      this.hostNavigationPending = true;
      const mark = Diagnostics.begin(this.instanceId);
      this.controller.loadData(host, 'text/html', 'UTF-8', WEB_UI_ORIGIN, WEB_UI_ORIGIN);
      if (Diagnostics.recording) { Diagnostics.end('web.loadData', mark, { chars: host.length }); }
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'load_returned', { instanceId: this.instanceId }); };
      this.timer = setTimeout(() => { if (this.mounted && generation === this.generation && !this.ready) { this.report(new Error(t('交互内容启动超时，请重试。'))); } }, 20000);
    } catch (error) { if (this.mounted && generation === this.generation) { this.report(error as Error); } }
  }
  private async pageReady(): Promise<void> {
    const generation = this.generation;
    try {
      const ready = await this.controller.runJavaScript('globalThis.__tinybotHostReady === true');
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'host_ready', { instanceId: this.instanceId, ready: ready === 'true' }); };
      if (this.mounted && generation === this.generation && ready === 'true') { this.connect(); }
    } catch (error) { if (this.mounted && generation === this.generation) { this.report(error as Error); } }
  }
  private connect(): void {
    if (!this.mounted || !this.spec || this.ports.length) { return; }
    try {
      const generation = this.generation;
      this.ports = this.controller.createWebMessagePorts();
      this.ports[0].onMessageEvent((data: webview.WebMessage) => { this.receive(data, generation); });
      this.browserAttachment = this.browserRuntime?.attach((id, operation, argumentsJson) => {
        this.ports[0].postMessageEvent(JSON.stringify({ type: 'browserCommand', id: id, operation: operation, argumentsJson: argumentsJson }));
      }, () => image.createPixelMapFromSurface(this.controller.getSurfaceId())) ?? -1;
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'port_connected', { instanceId: this.instanceId }); };
      // loadData may use an opaque data: origin; transfer only to the verified top-level host.
      this.controller.postMessage('tinybot-web-port', [this.ports[1]], '*');
      this.ports[0].postMessageEvent(JSON.stringify({ type: 'init', spec: this.spec, autoHeight: webUiAutoHeight(this.spec), values: this.values, active: this.preflight || (this.interactive && this.visible && this.foreground), preflight: this.preflight, snapshotMode: this.snapshotMode, automation: !!this.browserRuntime }));
    } catch (error) { this.report(error as Error); }
  }
  private sync(): void {
    if (!this.mounted || !this.ports.length) { return; }
    try { this.ports[0].postMessageEvent(JSON.stringify({ type: 'state', values: this.values, active: this.preflight || (this.interactive && this.visible && this.foreground) })); }
    catch (error) { this.report(error as Error); }
  }
  private async receive(data: webview.WebMessage, generation: number): Promise<void> {
    if (!this.mounted || generation !== this.generation) { return; }
    let id: number = 0;
    try {
      if (typeof data !== 'string') { throw new Error('Web UI: expected a text message'); }
      const message = parseWebUiMessage(data); id = message.id || 0;
      if (message.type === 'browserResult' && this.browserRuntime) { this.browserRuntime.receive(id, message.message as string); return; }
      if (message.type === 'error' && this.browserRuntime?.isReady) {
        this.browserRuntime.recordError(message.message as string);
        Diagnostics.log('error', 'web', 'failed', { instanceId: this.instanceId }, message.message); return;
      }
      if (message.type === 'error') { throw new Error(message.message); }
      if (message.type === 'resize') {
        if (this.spec && webUiAutoHeight(this.spec)) { this.measuredHeight = Math.max(48, Math.min(800, Math.ceil(message.height as number))); }
        if (this.viewportHeight > 0) { return; }
        if (this.spec && webUiAutoHeight(this.spec)) { this.heightValue = this.measuredHeight; }
        this.onHeight(this.heightValue);
        return;
      }
      if (message.type === 'ready') {
        if (this.error) { return; } // A late ready must not erase a startup failure.
        clearTimeout(this.timer); this.ready = true;
        this.browserRuntime?.ready();
        if (Diagnostics.recording) { Diagnostics.event('web.ready', { generation: this.generation }, this.instanceId); }
        if (Diagnostics.acceptsLog('info')) { Diagnostics.log('info', 'web', 'ready', { instanceId: this.instanceId, library: this.spec?.library || 'none', preflight: this.preflight }); };
        if (this.snapshotMode) {
          if (this.snapshotRequested) { return; }
          this.snapshotRequested = true;
          // Hidden Web views may be inactive after startup. Activate before requesting a painted frame.
          this.controller.onActive();
          this.ports[0].postMessageEvent(JSON.stringify({ type: 'snapshot' }));
          return;
        }
        if (this.preflight) { this.onValidation(''); } return;
      }
      if (message.type === 'snapshotReady' && this.snapshotMode) {
        if (!this.snapshotRequested || this.error) { return; }
        this.snapshotRequested = false;
        // RAF completes before ArkWeb commits its independent native surface. Allow that commit to settle.
        await new Promise<void>((resolve) => { setTimeout(resolve, 1000); });
        if (!this.mounted || generation !== this.generation || this.error) { return; }
        const pixel = await image.createPixelMapFromSurface(this.controller.getSurfaceId());
        if (!this.mounted || generation !== this.generation || this.error) { await pixel.release(); return; }
        this.snapshot = pixel;
        this.onValidation(''); return;
      }
      if (!this.interactive || !this.visible || !this.foreground || this.saving) { throw new Error(t('当前无法保存，请等待任务结束后重试。')); }
      this.saving = true;
      try {
        const saved = await this.onSave(message.values as UiValues);
        if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'state_saved', { operationId: id, keys: Object.keys(saved).length }); };
        if (this.mounted && generation === this.generation) { this.ports[0].postMessageEvent(JSON.stringify({ type: 'ack', id: id, values: saved })); }
      } finally { this.saving = false; this.visibilityChanged(); }
    } catch (error) {
      if (!this.mounted || generation !== this.generation) { return; }
      this.report(error as Error);
      if (id && this.ports.length) { this.ports[0].postMessageEvent(JSON.stringify({ type: 'ack', id: id, error: (error as Error).message })); }
    }
  }
  build() {
    Column({ space: 8 }) {
      if (this.error) {
        Text(this.error).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice)
        Button(t('重新加载')).fontFamily(this.appearance.fontFamily).attributeModifier(Btn.textSmall).onClick(() => { this.error = ''; this.visibilityChanged(); this.restart(); })
      }
      Stack({ alignContent: Alignment.TopStart }) {
      if (this.renderWeb) {
      Web({ src: 'about:blank', controller: this.controller })
        .backgroundColor(Color.Transparent)
        .width('100%').height(this.heightValue).javaScriptAccess(true).domStorageAccess(false).databaseAccess(false)
        .fileAccess(false).onlineImageAccess(false).blockNetwork(true)
        .onControllerAttached(() => { if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'attached', { instanceId: this.instanceId }); }; this.attached = true; this.syncActivity(); })
        .onPageEnd((event) => {
          if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'web', 'page_end', { instanceId: this.instanceId, scheme: event.url.split(':')[0] }); };
          // Wait for Web's initial about:blank navigation before replacing it with the host.
          if (!this.initialPageLoaded) { this.initialPageLoaded = true; this.restart(); }
          else { this.pageReady(); }
        })
        .onLoadIntercept((event) => {
          const url = event.data.getRequestUrl();
          // ArkWeb implements loadData as a main-frame data: navigation. Allow only that pending load.
          if (this.hostNavigationPending && event.data.isMainFrame() && url.startsWith('data:text/html')) {
            this.hostNavigationPending = false; return false;
          }
          const blocked = url !== 'about:blank' && url !== 'about:srcdoc' && url !== WEB_UI_ORIGIN;
          if (blocked) { Diagnostics.log('warn', 'web', 'navigation_blocked', { instanceId: this.instanceId, scheme: url.split(':')[0] }); }
          return blocked;
        })
        .onConsole((event) => { if (event.message.getMessageLevel() === MessageLevel.Error) { this.report(new Error(event.message.getMessage().slice(0, 2000))); } return false; })
        .onErrorReceive((event) => { if (event.request.isMainFrame()) { this.report(new Error(event.error.getErrorInfo())); } else { Diagnostics.log('error', 'web', 'resource_failed', { instanceId: this.instanceId }, event.error.getErrorInfo()); } })
        .onPermissionRequest((event) => { event.request.deny(); })
        .onRenderExited(() => { this.browserRuntime?.detach(this.browserAttachment); this.report(new Error(t('交互内容渲染进程已退出，请重试。'))); })
      }
      if (this.snapshot) { Image(this.snapshot).width('100%').height(this.heightValue).objectFit(ImageFit.Fill) }
      if (!this.ready && !this.error) {
        Text(t('正在加载交互内容…')).fontFamily(this.appearance.fontFamily).fontSize(13).fontColor($r('app.color.text_secondary')).hitTestBehavior(HitTestMode.None)
      }
      }.width('100%').height(this.heightValue)
    }.width('100%').alignItems(HorizontalAlign.Start)
      .onVisibleAreaChange([0], (visible: boolean) => { this.visible = visible; this.visibilityChanged(); })
  }
}
