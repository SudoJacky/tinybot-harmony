import { common } from '@kit.AbilityKit';
import { ColorMetrics } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { AppearanceStyle } from '../common/AppearanceStyle';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';
import { MathContent } from '../model/MathContent';
import { markdownSpans } from '../model/Markdown';
import { loadMathHost } from '../services/MathResources';

@Component
export struct MathView {
  @StorageProp('tinybot.appearance.style') @Watch('schedule') private appearance: AppearanceStyle = new AppearanceStyle();
  @StorageProp('tinybot.appearance.dark') @Watch('schedule') private dark: boolean = false;
  @Prop @Watch('schedule') content: string = '';
  @Prop @Watch('schedule') display: boolean = false;
  @Prop @Watch('schedule') fontSize: number = 16;
  @Prop @Watch('schedule') bold: boolean = false;
  @Prop @Watch('schedule') color: ResourceColor = $r('app.color.text_primary');
  @Prop @Watch('schedule') selectable: boolean = true;
  @State private heightValue: number = 32;
  @State private failed: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private mounted: boolean = false;
  private ready: boolean = false;
  private navigationPending: boolean = false;
  private revision: number = 0;
  private timer: number = -1;
  private startupTimer: number = -1;
  aboutToAppear(): void { this.mounted = true; }
  aboutToDisappear(): void {
    this.mounted = false; this.ready = false; this.revision++;
    clearTimeout(this.timer); clearTimeout(this.startupTimer); this.timer = -1;
  }
  private report(event: string, error?: Error): void {
    if (!this.mounted) { return; }
    this.failed = true;
    clearTimeout(this.startupTimer);
    Diagnostics.log('error', 'math', event, undefined, error);
  }
  private async attach(): Promise<void> {
    try {
      this.startupTimer = setTimeout(() => this.report('startup_timeout'), 10000);
      const host = await loadMathHost(this.getUIContext().getHostContext() as common.UIAbilityContext);
      if (!this.mounted) { return; }
      this.navigationPending = true;
      this.controller.loadData(host, 'text/html', 'UTF-8', 'https://tinybot-math.invalid/', 'https://tinybot-math.invalid/');
    } catch (error) { this.report('load_failed', error as Error); }
  }
  private schedule(): void {
    if (!this.mounted || !this.ready || this.failed || this.timer !== -1) { return; }
    this.timer = setTimeout(() => { this.timer = -1; this.render(); }, 32);
  }
  private cssColor(value: ResourceColor): string {
    const color = ColorMetrics.resourceColor(value);
    return `rgba(${color.red},${color.green},${color.blue},${color.alpha / 255})`;
  }
  private async render(): Promise<void> {
    if (!this.mounted || !this.ready || this.failed) { return; }
    try {
      const data: MathContent = { revision: ++this.revision, spans: this.display ? [{ kind: 'math', text: this.content, url: '' }] : markdownSpans(this.content),
        display: this.display, size: this.fontSize, bold: this.bold, color: this.cssColor(this.color),
        accent: this.cssColor(this.appearance.accent), selectable: this.selectable };
      // JSON is passed to the packaged function; reply text never becomes HTML or executable code.
      await this.controller.runJavaScript('window.renderMath(' + JSON.stringify(data) + ')');
    } catch (error) { this.report('render_failed', error as Error); }
  }
  private async open(url: string): Promise<void> {
    if (!/^https?:\/\//.test(url)) { return; }
    try { await (this.getUIContext().getHostContext() as common.UIAbilityContext).startAbility({ action: 'ohos.want.action.viewData', uri: url }); }
    catch (_) {
      if (this.mounted) { this.getUIContext().getPromptAction().showToast({ message: t('无法打开链接，可复制后在浏览器中打开。') }); }
    }
  }
  build() {
    Column() {
      if (this.failed) {
        Text(t('公式渲染失败')).fontSize(12).fontColor($r('app.color.danger'))
        Text(this.content).fontSize(this.fontSize).fontColor(this.color)
          .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      } else {
        Web({ src: '', controller: this.controller })
          .width('100%').height(this.heightValue).backgroundColor(Color.Transparent)
          .javaScriptAccess(true).domStorageAccess(false).databaseAccess(false).fileAccess(false)
          .onlineImageAccess(false).blockNetwork(true).zoomAccess(false)
          .nestedScroll({ scrollUp: NestedScrollMode.PARENT_FIRST, scrollDown: NestedScrollMode.PARENT_FIRST })
          .onControllerAttached(() => { this.attach(); })
          .onPageEnd(() => {
            if (!this.mounted || this.ready || this.failed) { return; }
            this.ready = true; clearTimeout(this.startupTimer); this.render();
          })
          .onTitleReceive((event) => {
            const match = event.title.match(/^math:(\d+):(\d+)$/);
            if (!match || Number(match[1]) !== this.revision) { return; }
            const height = Number(match[2]);
            Promise.resolve().then(() => {
              if (this.mounted && Number(match[1]) === this.revision) { this.heightValue = Math.max(1, height); }
            });
          })
          .onLoadIntercept((event) => {
            const url = event.data.getRequestUrl();
            if (this.navigationPending && event.data.isMainFrame() && url.startsWith('data:text/html')) {
              this.navigationPending = false; return false;
            }
            if (event.data.isMainFrame() && /^https?:\/\//.test(url)) { this.open(url); }
            return url !== 'about:blank';
          })
          .onPermissionRequest((event) => event.request.deny())
          .onErrorReceive((event) => { if (event.request.isMainFrame()) { this.report('page_failed'); } })
          .onRenderExited(() => this.report('process_exited'))
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
