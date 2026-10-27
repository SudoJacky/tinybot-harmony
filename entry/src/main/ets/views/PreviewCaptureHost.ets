import { Diagnostics } from '../model/Diagnostics';
import { image } from '@kit.ImageKit';
import { PreviewCapture, PreviewCaptureRequest } from '../services/PreviewCapture';
import { Attachments } from '../services/Attachments';
import { UiCompiler, UiNode, uiNodeVisible, uiParts } from '../model/InteractiveUi';
import { Space } from '../common/Theme';
import { InteractiveAnswer } from './InteractiveAnswer';

@Component
struct PreviewCaptureView {
  request: PreviewCaptureRequest = { id: 0, content: '' };
  private waiting: Set<string> = new Set<string>();
  private mounted: boolean = false;
  private capturing: boolean = false;
  private timer: number = -1;
  private cardWidth: number = 0;
  aboutToAppear(): void {
    this.mounted = true;
    for (const part of uiParts(this.request.content, false).filter((item) => item.kind === 'ui')) {
      const document = new UiCompiler().update(part.content, true);
      for (const node of document.nodes.filter((item) => item.kind === 'web')) {
        let current: UiNode | undefined = node;
        let visible = true;
        while (current) {
          if (!uiNodeVisible(current, document.initial)) { visible = false; break; }
          current = current.parent ? document.nodes.find((item) => item.id === current?.parent) : undefined;
        }
        if (visible) { this.waiting.add('0:' + part.key + '/' + node.id); }
      }
    }
  }
  aboutToDisappear(): void { this.mounted = false; clearTimeout(this.timer); }
  private schedule(): void {
    clearTimeout(this.timer);
    if (this.mounted && PreviewCapture.isCurrent(this.request.id) && !this.capturing && !this.waiting.size && this.cardWidth > 0) {
      // Area changes reset the delay; capture the settled layout, not the loading placeholder.
      this.timer = setTimeout(() => { this.capture(); }, 200);
    }
  }
  private async capture(): Promise<void> {
    if (!this.mounted || !PreviewCapture.isCurrent(this.request.id)) { return; }
    this.capturing = true;
    let pixel: image.PixelMap | undefined;
    try {
      pixel = await this.getUIContext().getComponentSnapshot().get('preview-capture-' + this.request.id,
        { waitUntilRenderFinished: true });
      if (!this.mounted || !PreviewCapture.isCurrent(this.request.id)) { return; }
      const attachment = await Attachments.savePreview(pixel);
      const info = await pixel.getImageInfo();
      if (!this.mounted || !PreviewCapture.isCurrent(this.request.id)) { return; }
      if (Diagnostics.acceptsLog('debug')) { Diagnostics.log('debug', 'preview', 'captured', { operationId: this.request.id, width: info.size.width, height: info.size.height, widthVp: this.cardWidth }); };
      PreviewCapture.complete(this.request.id, { image: attachment, width: info.size.width, height: info.size.height, viewportWidth: this.cardWidth });
    } catch (error) {
      if (this.mounted && PreviewCapture.isCurrent(this.request.id)) { PreviewCapture.complete(this.request.id, undefined, error as Error); }
    } finally { await pixel?.release(); }
  }
  build() {
    Column() {
      InteractiveAnswer({ content: this.request.content, available: true, snapshotMode: true, allowSurface: true, frameless: true,
        onWebReady: (id: string, error: string) => {
          if (error) { PreviewCapture.complete(this.request.id, undefined, new Error(error)); return; }
          this.waiting.delete(id); this.schedule();
        } })
    }.id('preview-capture-' + this.request.id).width('100%').backgroundColor($r('app.color.page_background'))
      .onAreaChange((_old: Area, area: Area) => { this.cardWidth = Number(area.width); this.schedule(); })
  }
}

@Component
export struct PreviewCaptureHost {
  @State private requests: PreviewCaptureRequest[] = [];
  private unsubscribe?: () => void;
  aboutToAppear(): void { this.unsubscribe = PreviewCapture.subscribe((requests) => { this.requests = requests; }); }
  aboutToDisappear(): void { this.unsubscribe?.(); }
  build() {
    Column() {
      ForEach(this.requests, (request: PreviewCaptureRequest) => {
        PreviewCaptureView({ request: request })
      }, (request: PreviewCaptureRequest) => String(request.id))
    }.width('100%').padding({ left: Space.page, right: Space.page })
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no-hide-descendants')
  }
}
