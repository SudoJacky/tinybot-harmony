import { webview } from '@kit.ArkWeb';
import { Space } from '../common/Theme';
import { Diagnostics } from '../model/Diagnostics';
import { t } from '../model/I18n';

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
  @StorageProp('tinybot.appearance.dark') @Watch('render') private dark: boolean = false;
  @StorageProp('tinybot.foreground') @Watch('activate') private foreground: boolean = true;
  @StorageProp('tinybot.chat.scrolling') @Watch('activate') private scrolling: boolean = false;
  @Prop @Watch('render') content: string = '';
  @Prop @Watch('render') selectable: boolean = true;
  @State private diagramHeight: number = 40;
  @State private hostFailed: boolean = false;
  @State private showHost: boolean = false;
  private controller?: webview.WebviewController;
  private mounted: boolean = false;
  private visible: boolean = false;
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
    this.visible = false;
    this.ready = false;
    this.revision++;
    clearTimeout(this.timeout);
    this.timeout = -1;
    this.showHost = false;
    this.controller = undefined;
  }

  private activate(): void {
    if (!this.mounted || !this.visible || !this.foreground || this.scrolling || this.showHost || this.hostFailed) { return; }
    this.controller = new webview.WebviewController();
    this.showHost = true;
    this.timeout = setTimeout(() => this.fail('startup_timeout'), 15000);
  }

  private fail(event: string, error?: Error | string): void {
    if (!this.mounted || this.hostFailed) { return; }
    clearTimeout(this.timeout);
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
    });
  }

  build() {
    Column() {
      if (this.hostFailed) {
        Column({ space: Space.xs }) {
          Text(t('Mermaid 图表渲染失败')).fontSize(12).fontColor($r('app.color.danger'))
          Text(this.content).fontSize(13).fontFamily('monospace').fontColor($r('app.color.text_primary'))
            .copyOption(this.selectable ? CopyOptions.LocalDevice : CopyOptions.None)
      }.width('100%').padding(Space.md).alignItems(HorizontalAlign.Start)
    } else if (this.showHost) {
      Web({ src: MERMAID_HOST, controller: this.controller! })
        .width('100%').height(this.diagramHeight).backgroundColor(Color.Transparent)
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
    } else {
      Blank().width('100%').height(this.diagramHeight)
    }
    }.width('100%')
      .onVisibleAreaChange([0], (visible: boolean) => {
        const lifetime = this.lifetime;
        Promise.resolve().then(() => {
          if (!this.mounted || this.lifetime !== lifetime) { return; }
          this.visible = visible;
          this.activate();
        });
      })
  }
}
