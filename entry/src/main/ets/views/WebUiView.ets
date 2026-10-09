import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { t } from '../model/I18n';
import { UiValues } from '../model/InteractiveUi';
import { WebUiSpec, parseWebUi, parseWebUiMessage, webUiHost, WEB_UI_ORIGIN } from '../model/WebUi';
import { webUiAssets } from '../services/WebUiAssets';
import { Btn } from '../common/Theme';

@Component
export struct WebUiView {
  @Prop @Watch('restart') content: string = '';
  @Prop @Watch('sync') values: UiValues = {};
  @Prop @Watch('sync') interactive: boolean = false;
  @Prop preflight: boolean = false;
  onValidation: (error: string) => void = () => {};
  onSave: (values: UiValues) => Promise<UiValues> = async () => { throw new Error('Web UI save handler missing'); };
  @State private error: string = '';
  @State private ready: boolean = false;
  @State private heightValue: number = 360;
  private controller: webview.WebviewController = new webview.WebviewController();
  private ports: webview.WebMessagePort[] = [];
  private spec?: WebUiSpec;
  private mounted: boolean = false;
  private attached: boolean = false;
  private initialPageLoaded: boolean = false;
  private visible: boolean = true;
  private generation: number = 0;
  private timer: number = -1;
  private saving: boolean = false;
  private hostNavigationPending: boolean = false;
  aboutToAppear(): void { this.mounted = true; hilog.info(0x0000, 'TinybotWebUI', 'mount contentChars=%{public}d', this.content.length); }
  aboutToDisappear(): void { this.mounted = false; this.attached = false; this.initialPageLoaded = false; this.generation++; this.closePorts(); }
  private closePorts(): void {
    clearTimeout(this.timer);
    for (const port of this.ports) { port.close(); }
    this.ports = [];
  }
  private report(error: Error): void {
    this.error = error.message; this.ready = false; clearTimeout(this.timer);
    hilog.error(0x0000, 'TinybotWebUI', 'generation=%{public}d error=%{public}s', this.generation, error.message);
    if (this.preflight) { this.onValidation(error.message); }
  }
  private async restart(): Promise<void> {
    if (!this.mounted || !this.attached || !this.initialPageLoaded) { return; }
    const generation = ++this.generation;
    this.closePorts(); this.ready = false; this.error = '';
    try {
      this.spec = parseWebUi(this.content); this.heightValue = this.spec.height;
      const assets = await webUiAssets(this.getUIContext().getHostContext() as common.UIAbilityContext, this.spec.library === 'three');
      if (!this.mounted || generation !== this.generation) { return; }
      const host = webUiHost(assets[0], assets[1]);
      hilog.info(0x0000, 'TinybotWebUI', 'loadData start chars=%{public}d', host.length);
      this.hostNavigationPending = true;
      this.controller.loadData(host, 'text/html', 'UTF-8', WEB_UI_ORIGIN, WEB_UI_ORIGIN);
      hilog.info(0x0000, 'TinybotWebUI', 'loadData returned');
      this.timer = setTimeout(() => { if (this.mounted && generation === this.generation && !this.ready) { this.report(new Error(t('交互内容启动超时，请重试。'))); } }, 20000);
    } catch (error) { if (this.mounted && generation === this.generation) { this.report(error as Error); } }
  }
  private async pageReady(): Promise<void> {
    const generation = this.generation;
    try {
      const ready = await this.controller.runJavaScript('globalThis.__tinybotHostReady === true');
      hilog.info(0x0000, 'TinybotWebUI', 'host ready=%{public}s', ready);
      if (this.mounted && generation === this.generation && ready === 'true') { this.connect(); }
    } catch (error) { if (this.mounted && generation === this.generation) { this.report(error as Error); } }
  }
  private connect(): void {
    if (!this.mounted || !this.spec || this.ports.length) { return; }
    try {
      const generation = this.generation;
      this.ports = this.controller.createWebMessagePorts();
      this.ports[0].onMessageEvent((data: webview.WebMessage) => { this.receive(data, generation); });
      hilog.info(0x0000, 'TinybotWebUI', 'connect message port');
      // loadData may use an opaque data: origin; transfer only to the verified top-level host.
      this.controller.postMessage('tinybot-web-port', [this.ports[1]], '*');
      this.ports[0].postMessageEvent(JSON.stringify({ type: 'init', spec: this.spec, values: this.values, active: this.preflight || (this.interactive && this.visible), preflight: this.preflight }));
    } catch (error) { this.report(error as Error); }
  }
  private sync(): void {
    if (!this.mounted || !this.ports.length) { return; }
    try { this.ports[0].postMessageEvent(JSON.stringify({ type: 'state', values: this.values, active: this.preflight || (this.interactive && this.visible) })); }
    catch (error) { this.report(error as Error); }
  }
  private async receive(data: webview.WebMessage, generation: number): Promise<void> {
    if (!this.mounted || generation !== this.generation) { return; }
    let id: number = 0;
    try {
      if (typeof data !== 'string') { throw new Error('Web UI: expected a text message'); }
      const message = parseWebUiMessage(data); id = message.id || 0;
      if (message.type === 'error') { throw new Error(message.message); }
      if (message.type === 'ready') {
        if (this.error) { return; } // A late ready must not erase a startup failure.
        clearTimeout(this.timer); this.ready = true;
        hilog.info(0x0000, 'TinybotWebUI', 'ready library=%{public}s preflight=%{public}s', this.spec?.library || 'none', String(this.preflight));
        if (this.preflight) { this.onValidation(''); } return;
      }
      if (!this.interactive || !this.visible || this.saving) { throw new Error(t('当前无法保存，请等待任务结束后重试。')); }
      this.saving = true;
      try {
        const saved = await this.onSave(message.values as UiValues);
        hilog.info(0x0000, 'TinybotWebUI', 'state saved id=%{public}d keys=%{public}d', id, Object.keys(saved).length);
        if (this.mounted && generation === this.generation) { this.ports[0].postMessageEvent(JSON.stringify({ type: 'ack', id: id, values: saved })); }
      } finally { this.saving = false; }
    } catch (error) {
      if (!this.mounted || generation !== this.generation) { return; }
      this.report(error as Error);
      if (id && this.ports.length) { this.ports[0].postMessageEvent(JSON.stringify({ type: 'ack', id: id, error: (error as Error).message })); }
    }
  }
  build() {
    Column({ space: 8 }) {
      if (this.error) {
        Text(this.error).fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice)
        Button(t('重新加载')).attributeModifier(Btn.textSmall).onClick(() => { this.restart(); })
      } else if (!this.ready) { Text(t('正在加载交互内容…')).fontSize(13).fontColor($r('app.color.text_secondary')) }
      Web({ src: 'about:blank', controller: this.controller })
        .width('100%').height(this.heightValue).javaScriptAccess(true).domStorageAccess(false).databaseAccess(false)
        .fileAccess(false).onlineImageAccess(false).blockNetwork(true)
        .onControllerAttached(() => { hilog.info(0x0000, 'TinybotWebUI', 'controller attached'); this.attached = true; })
        .onPageEnd((event) => {
          hilog.info(0x0000, 'TinybotWebUI', 'pageEnd scheme=%{public}s', event.url.split(':')[0]);
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
          if (blocked) { hilog.warn(0x0000, 'TinybotWebUI', 'blocked navigation scheme=%{public}s', url.split(':')[0]); }
          return blocked;
        })
        .onConsole((event) => { if (event.message.getMessageLevel() === MessageLevel.Error) { this.report(new Error(event.message.getMessage().slice(0, 2000))); } return false; })
        .onErrorReceive((event) => { if (event.request.isMainFrame()) { this.report(new Error(event.error.getErrorInfo())); } else { hilog.error(0x0000, 'TinybotWebUI', 'resource error=%{public}s', event.error.getErrorInfo()); } })
        .onPermissionRequest((event) => { event.request.deny(); })
        .onRenderExited(() => { this.report(new Error(t('交互内容渲染进程已退出，请重试。'))); })
        .onVisibleAreaChange([0], (visible: boolean) => { this.visible = visible; this.sync(); })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
