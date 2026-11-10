import { webview } from '@kit.ArkWeb';
import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { FileAnnotation, FileAnnotationTarget } from '../model/FileAnnotation';
import { Banner } from '../common/Widgets';

const HOST = 'resource://rawfile/office/preview.html';
const CHUNK_SIZE = 192 * 1024;

export interface OfficePreviewSource {
  path: string;
  threadId: string;
  format: string;
  encoded: string;
  version: string;
}

interface OfficePreviewEvent {
  type: string;
  message?: string;
}

interface OfficePreviewAnnotation {
  target: FileAnnotationTarget;
  comment: string;
}

interface OfficeAnnotationMark {
  number: number;
  location: string;
  comment: string;
}

interface OfficePreviewLabels {
  annotate: string;
  placeholder: string;
  add: string;
  cancel: string;
}

@Component
export struct OfficePreview {
  source: OfficePreviewSource = { path: '', threadId: '', format: '', encoded: '', version: '' };
  @Prop @Watch('updateMarks') annotations: FileAnnotation[] = [];
  onAnnotation: (target: FileAnnotationTarget, comment: string) => Promise<void> = async () => {};
  @State private error: string = '';
  @State private ready: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private mounted: boolean = false;
  private loading: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.mounted = true;
    this.timer = setTimeout(() => this.fail('startup_timeout', new Error(t('Office 预览加载超时。'))), 30000);
  }

  aboutToDisappear(): void {
    this.mounted = false;
    clearTimeout(this.timer);
  }

  private fail(event: string, error: Error): void {
    if (!this.mounted) { return; }
    clearTimeout(this.timer);
    this.error = error.message;
    Diagnostics.log('error', 'office_preview', event, { format: this.source.format }, error);
  }

  private async load(): Promise<void> {
    if (!this.mounted || this.loading) { return; }
    this.loading = true;
    try {
      for (let offset = 0; offset < this.source.encoded.length && this.mounted; offset += CHUNK_SIZE) {
        const chunk = this.source.encoded.slice(offset, offset + CHUNK_SIZE);
        await this.controller.runJavaScript('window.appendOfficeBytes(' + JSON.stringify(chunk) + ')');
      }
      if (!this.mounted) { return; }
      const labels: OfficePreviewLabels = { annotate: t('批注'), placeholder: t('描述修改或提出问题…'),
        add: t('添加批注'), cancel: t('取消') };
      await this.controller.runJavaScript('window.renderOffice(' + JSON.stringify(this.source.format) + ',' + JSON.stringify(labels) + ')');
    } catch (error) { this.fail('load_failed', error as Error); }
  }

  private async updateMarks(): Promise<void> {
    if (!this.mounted || !this.ready) { return; }
    const marks: OfficeAnnotationMark[] = [];
    this.annotations.forEach((item, index) => {
      if (item.path === this.source.path && item.version === this.source.version) {
        marks.push({ number: index + 1, location: item.location, comment: item.comment });
      }
    });
    try { await this.controller.runJavaScript('window.updateOfficeAnnotations(' + JSON.stringify(marks) + ')'); }
    catch (error) { this.fail('update_annotations_failed', error as Error); }
  }

  private async receive(title: string): Promise<void> {
    if (!this.mounted || !title.startsWith('office:')) { return; }
    try {
      const event = JSON.parse(title.slice(7)) as OfficePreviewEvent;
      if (event.type === 'ready') {
        clearTimeout(this.timer);
        this.ready = true;
        await this.updateMarks();
      } else if (event.type === 'error') {
        this.fail('render_failed', new Error(event.message || t('无法渲染 Office 文件。')));
      } else if (event.type === 'annotation' && this.ready) {
        let saved = false;
        try {
          const result = await this.controller.runJavaScriptExt('window.getOfficeAnnotation()');
          if (!this.mounted) { return; }
          if (result.getType() !== webview.JsMessageType.STRING) { throw new Error(t('当前无法保存批注。')); }
          const encoded = JSON.parse(result.getString()) as string;
          const annotation = JSON.parse(encoded) as OfficePreviewAnnotation;
          await this.onAnnotation(annotation.target, annotation.comment);
          saved = true;
        }
        catch (error) {
          if (!this.mounted) { return; }
          this.getUIContext().getPromptAction().showToast({ message: (error as Error).message });
          Diagnostics.log('warn', 'office_preview', 'annotation_failed', { format: this.source.format }, error as Error);
        }
        if (this.mounted) { await this.controller.runJavaScript('window.ackOfficeAnnotation(' + saved + ')'); }
      }
    } catch (error) { this.fail('invalid_view_event', error as Error); }
  }

  build() {
    Column() {
      if (this.error) { Banner({ text: this.error }).width('100%') }
      else {
        Stack() {
          Web({ src: HOST, controller: this.controller }).width('100%').height('100%')
            .javaScriptAccess(true).domStorageAccess(false).databaseAccess(false).fileAccess(false)
            .onlineImageAccess(false).blockNetwork(true).multiWindowAccess(false)
            .onLoadIntercept((event) => event.data.isMainFrame() && (this.loading || event.data.getRequestUrl() !== HOST))
            .onPageEnd(() => { this.load(); })
            .onTitleReceive((event) => { this.receive(event.title); })
            .onPermissionRequest((event) => event.request.deny())
            .onErrorReceive((event) => {
              if (event.request.isMainFrame()) { this.fail('page_failed', new Error(event.error.getErrorInfo())); }
            })
            .onRenderExited(() => this.fail('process_exited', new Error(t('无法渲染 Office 文件。'))))
          if (!this.ready) { LoadingProgress().width(28).height(28).hitTestBehavior(HitTestMode.None) }
        }.width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%')
  }
}
