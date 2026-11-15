import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { AnnotationPage, BrowserElementMark } from '../model/BrowserAnnotation';
import { t } from '../model/I18n';
import { ToolFailure } from '../model/ToolFailure';
import { browserActionScript, browserElementScript, browserSnapshotScript } from '../model/BrowserScripts';
import { bingSearchScript, BingSearchPage } from '../model/BingSearch';
import { BrowserAction, BrowserDriver, BrowserPage, BrowserSession } from './BrowserSession';
import { BrowserPreview } from '../model/BrowserPreview';
import { BrowserFrame } from '../model/Agent';
import { Attachment } from '../model/Productivity';
import { parseUiSurface } from '../model/InteractiveUi';
import { PreviewBrowserRuntime } from './PreviewBrowserRuntime';
import { Cancellation } from './Cancellation';

interface BrowserTarget { x: number; y: number; }
interface BrowserScriptResult { ok?: boolean; code?: string; message?: string; target?: BrowserTarget; }
export interface NativeBrowserCapture extends AnnotationPage { pixel: image.PixelMap; width: number; height: number; }

export class NativeBrowserDriver implements BrowserDriver {
  previewRuntime: PreviewBrowserRuntime = new PreviewBrowserRuntime();
  private webController?: webview.WebviewController;
  get controller(): webview.WebviewController {
    // The retained browser host exists even before a tab is opened. Constructing
    // its native controller there loads ArkWeb into otherwise native chat sessions.
    if (!this.webController) { this.webController = new webview.WebviewController(); }
    return this.webController;
  }
  private browser: BrowserSession;
  private initialized: boolean = false;
  private loading: boolean = false;
  private clearInitialHistory: boolean = false;
  private error: string = '';
  private requestedUrl: string = '';
  private waiters: Set<() => void> = new Set<() => void>();
  private touchStart?: TouchObject;
  private touchMoved: boolean = false;
  private feedbackVisible: boolean = false;
  private saveFrame?: (pixel: image.PixelMap) => Promise<Attachment>;
  private viewportWidth: () => number;
  constructor(browser: BrowserSession, saveFrame?: (pixel: image.PixelMap) => Promise<Attachment>, viewportWidth: () => number = () => 1) {
    this.browser = browser; this.saveFrame = saveFrame; this.viewportWidth = viewportWidth;
    this.previewRuntime = new PreviewBrowserRuntime(() => this.browser.documentChanged());
  }
  private startLoading(url: string = ''): void {
    this.requestedUrl = url;
    this.loading = true; this.error = '';
    this.browser.loading = true; this.browser.progress = 0; this.browser.loadFailed = false; this.browser.error = '';
  }
  pageBegin(url: string): void {
    this.browser.documentChanged(); this.browser.clearActionFeedback();
    // The placeholder Web is also mounted when an agent has requested its first real URL.
    if (url === 'about:blank') { return; }
    // ArkWeb may report a main-document error before its page-begin callback.
    if (url === this.requestedUrl && (this.loading || this.browser.loadFailed)) { return; }
    this.startLoading(url);
  }
  progress(value: number): void {
    if (this.browser.loading) { this.browser.progress = Math.min(99, Math.max(0, value)); }
  }
  setFeedbackVisible(visible: boolean): void {
    this.feedbackVisible = visible;
    if (!visible) { this.browser.clearActionFeedback(); }
  }
  pageEnd(url: string): void {
    if (url === 'about:blank' && this.requestedUrl && this.loading) { return; }
    this.initialized = true; this.loading = false;
    this.browser.loading = false;
    if (this.browser.loadFailed) { this.wake(); return; }
    if (this.clearInitialHistory && url !== 'about:blank') { this.controller.clearHistory(); this.clearInitialHistory = false; }
    this.browser.pageChanged(url, this.controller.getTitle()); this.historyChanged(); this.wake();
  }
  historyChanged(): void {
    if (this.browser.preview) { return; }
    this.browser.canGoBack = this.controller.accessBackward();
    this.browser.canGoForward = this.controller.accessForward();
  }
  userTouch(event: TouchEvent): void {
    if (this.browser.preview && event.type === TouchType.Down) { this.browser.takeOver(); }
    if (event.type === TouchType.Down) { this.browser.clearActionFeedback(); }
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down && !this.touchStart && point) {
      this.touchStart = point; this.touchMoved = false;
    }
    if (this.touchStart && point) {
      // Remember the whole gesture: a drag back to its origin is still a drag.
      if (event.touches.length > 1 || point.id !== this.touchStart.id ||
        Math.hypot(point.screenX - this.touchStart.screenX, point.screenY - this.touchStart.screenY) > 8) {
        this.touchMoved = true;
      }
    }
    if (event.type === TouchType.Up) {
      if (this.touchStart && !this.touchMoved) { this.browser.takeOver(); }
      if (event.touches.length <= 1) { this.touchStart = undefined; }
    } else if (event.type === TouchType.Cancel) { this.touchStart = undefined; }
  }
  failed(error: Error | string, url: string = ''): void {
    if (url && url !== 'about:blank') { this.requestedUrl = url; }
    this.browser.clearActionFeedback();
    this.error = typeof error === 'string' ? error : error.message;
    this.loading = false; this.browser.loading = false; this.browser.loadFailed = true;
    this.browser.report(error); this.wake();
  }
  private wake(): void { for (const finish of Array.from(this.waiters)) { finish(); } }
  private async ready(): Promise<void> {
    if (!this.browser.open) { throw new ToolFailure('BROWSER_CLOSED', 'Browser is closed.', 'respect_user_decision'); }
    if (!this.initialized || this.loading) {
      await new Promise<void>((resolve, reject) => {
        const finish = (): void => {
          if (this.browser.open && (!this.initialized || this.loading) && !this.error) { return; }
          clearTimeout(timer); this.waiters.delete(finish); resolve();
        };
        const timer = setTimeout(() => {
          this.waiters.delete(finish);
          const failure = new ToolFailure('TIMEOUT', 'Browser page loading exceeded 30 seconds.', 'inspect_browser');
          this.browser.report(failure); reject(failure);
        }, 30000);
        this.waiters.add(finish); finish();
      });
    }
    if (!this.browser.open) { throw new ToolFailure('BROWSER_CLOSED', 'Browser is closed.', 'respect_user_decision'); }
    if (this.error) { throw new ToolFailure('BROWSER_LOAD_FAILED', this.error, 'inspect_browser'); }
  }
  async open(url: string): Promise<void> {
    if (this.browser.preview) {
      this.previewRuntime.detach(); this.browser.preview = undefined; this.browser.previewSpec = '';
      this.webController = new webview.WebviewController(); this.initialized = false; this.loading = false;
      this.browser.invalidateObservation();
    }
    if (!this.initialized) { await this.ready(); }
    this.navigate(url);
    await this.ready();
  }
  async openPreview(preview: BrowserPreview, cancellation?: Cancellation): Promise<void> {
    const document = parseUiSurface(preview.content, '0');
    const nodes = document.nodes.filter((item) => item.kind === 'web');
    if (nodes.length !== 1) { throw new ToolFailure('PREVIEW_INVALID', 'Preview browser requires one web surface.', 'publish_preview'); }
    this.loading = false; this.browser.loading = false; this.browser.loadFailed = false;
    this.error = ''; this.browser.error = '';
    this.previewRuntime.detach(); this.previewRuntime.errors = [];
    this.browser.invalidateObservation(); this.browser.previewSpec = nodes[0].data || '';
    this.browser.preview = preview; this.browser.previewInstance++;
    this.browser.canGoBack = false; this.browser.canGoForward = false;
    this.browser.requestPresentation();
    const generation = this.browser.previewInstance, start = Date.now();
    while (!this.previewRuntime.isReady) {
      cancellation?.check();
      if (!this.browser.open || generation !== this.browser.previewInstance) { throw new Error('Preview opening was interrupted'); }
      if (this.previewRuntime.errors.length) { throw new Error(this.previewRuntime.errors.join('\n')); }
      if (Date.now() - start > 20000) { throw new Error('Preview browser startup timed out'); }
      await new Promise<void>((resolve) => { setTimeout(resolve, 25); });
    }
    this.browser.error = '';
    this.browser.pageChanged('Preview: ' + preview.title, preview.title);
  }
  async captureFrame(): Promise<BrowserFrame> {
    if (!this.saveFrame) { throw new Error('Browser screenshot storage is unavailable'); }
    const pixel = this.browser.preview ? await this.previewRuntime.capture() : await this.captureBrowserSurface();
    const capturedAt = Date.now();
    try {
      const attachment = await this.saveFrame(pixel);
      const info = await pixel.getImageInfo();
      return { image: attachment, width: info.size.width, height: info.size.height,
        viewportWidth: this.viewportWidth(), elapsedMs: 0, capturedAt: capturedAt };
    } finally { await pixel.release(); }
  }
  private async captureBrowserSurface(): Promise<image.PixelMap> {
    await this.ready(); return image.createPixelMapFromSurface(this.controller.getSurfaceId());
  }
  private navigate(url: string): void {
    this.clearInitialHistory = this.clearInitialHistory || this.controller.getUrl() === 'about:blank';
    this.startLoading(url); this.controller.loadUrl(url);
  }
  async capture(): Promise<NativeBrowserCapture> {
    if (this.browser.preview) {
      if (this.browser.owner !== 'user') { throw new ToolFailure('BROWSER_NOT_OWNED', 'Take control before annotating a preview.', 'inspect_browser'); }
      const generation = this.browser.previewInstance, title = this.browser.preview.title;
      const pixel = await this.previewRuntime.capture();
      try {
        if (!this.browser.open || this.browser.owner !== 'user' || generation !== this.browser.previewInstance) {
          throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Preview changed during annotation capture.', 'inspect_browser');
        }
        const info = await pixel.getImageInfo();
        return { pixel: pixel, url: 'Preview: ' + title, title: title, width: info.size.width, height: info.size.height };
      } catch (error) { await pixel.release(); throw error as Error; }
    }
    await this.ready();
    const url = this.controller.getUrl();
    if (!/^https?:\/\//i.test(url) || this.browser.owner !== 'user') {
      throw new ToolFailure('BROWSER_NOT_OWNED', 'Open a web page and take control before annotating it.', 'inspect_browser');
    }
    const title = this.controller.getTitle();
    const pixel = await image.createPixelMapFromSurface(this.controller.getSurfaceId());
    try {
      if (!this.browser.open || this.browser.owner !== 'user' || url !== this.controller.getUrl() || this.loading) {
        throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Page changed during annotation capture. Try again after loading finishes.', 'inspect_browser');
      }
      const info = await pixel.getImageInfo();
      return { pixel: pixel, url: url, title: title, width: info.size.width, height: info.size.height };
    } catch (error) { await pixel.release(); throw error as Error; }
  }
  async captureElement(x: number, y: number): Promise<NativeBrowserCapture> {
    if (!this.browser.open || this.browser.owner !== 'user' || ![x, y].every((value) => Number.isFinite(value) && value >= 0 && value <= 1)) {
      throw new Error(t('未选中可批注的网页元素。'));
    }
    if (!this.browser.preview) { await this.ready(); }
    const instance = this.browser.createObservation().instanceId;
    const locate = (): Promise<string> => this.browser.preview ? this.previewRuntime.pick(x, y) : this.script(browserElementScript(x, y));
    const first = await locate();
    const element = JSON.parse(first) as BrowserElementMark | null;
    if (!element || typeof element.location !== 'string' || !element.location || element.location.length > 1000 ||
      typeof element.label !== 'string' || element.label.length > 160 ||
      ![element.x, element.y, element.width, element.height].every((value) => Number.isFinite(value) && value >= 0 && value <= 1) ||
      element.width <= 0 || element.height <= 0 || element.x + element.width > 1.00001 || element.y + element.height > 1.00001) {
      throw new Error(t('未选中可批注的网页元素。'));
    }
    const capture = await this.capture();
    try {
      const second = await locate();
      if (instance !== this.browser.createObservation().instanceId || this.browser.owner !== 'user' || first !== second) {
        throw new Error(t('页面已变化，请重新选择元素。'));
      }
      capture.element = element;
      return capture;
    } catch (error) { await capture.pixel.release(); throw error as Error; }
  }
  async snapshot(id: string): Promise<BrowserPage> {
    if (this.browser.preview) {
      const page = await this.previewRuntime.snapshot(id);
      page.url = 'Preview: ' + this.browser.preview.title; page.title = this.browser.preview.title;
      page.previewId = this.browser.preview.previewId; page.version = this.browser.preview.version;
      page.errors = this.previewRuntime.errors.slice(); return page;
    }
    await this.ready();
    const page = JSON.parse(await this.script(browserSnapshotScript(id))) as BrowserPage;
    if (!page || page.snapshotId !== id || typeof page.text !== 'string' || !Array.isArray(page.elements)) {
      throw new ToolFailure('INVALID_RESPONSE', 'Browser snapshot is malformed (jsonType=' + typeof page +
        ', idType=' + typeof page?.snapshotId + ', textType=' + typeof page?.text +
        ', elementsArray=' + String(Array.isArray(page?.elements)) + ').', 'inspect_browser');
    }
    return page;
  }
  private async script(source: string): Promise<string> {
    const result = await this.controller.runJavaScriptExt(source);
    if (result.getType() !== webview.JsMessageType.STRING) {
      throw new ToolFailure('INVALID_RESPONSE', 'Browser script did not return a JSON string.', 'inspect_browser');
    }
    // ArkWeb returns the JSON-encoded JS string, including its outer quotes.
    const value = JSON.parse(result.getString()) as string;
    if (typeof value !== 'string') {
      throw new ToolFailure('INVALID_RESPONSE', 'ArkWeb script result is not an encoded string.', 'inspect_browser');
    }
    return value;
  }
  async readBingSearch(query: string, maximum: number): Promise<BingSearchPage> {
    await this.ready();
    const page = JSON.parse(await this.script(bingSearchScript(query, maximum))) as BingSearchPage;
    if (!page || !['results', 'empty', 'verification', 'pending', 'unexpected_page', 'invalid_results'].includes(page.state) ||
      !Array.isArray(page.sources) || page.sources.length > maximum || !Number.isInteger(page.candidates) || !Number.isInteger(page.invalid) ||
      page.candidates < 0 || page.invalid < 0 || (page.state === 'results' && !page.sources.length) ||
      (page.state === 'empty' && page.sources.length > 0)) {
      throw new ToolFailure('INVALID_RESPONSE', 'Malformed Bing extraction result (extractor=1).', 'inspect_browser');
    }
    for (const source of page.sources) {
      if (typeof source.url !== 'string' || !/^https?:\/\/[^\s/?#@\\]+(?:[/?#][^\s\\]*)?$/.test(source.url) ||
        typeof source.title !== 'string' || !source.title || typeof source.snippet !== 'string') {
        throw new ToolFailure('INVALID_RESPONSE', 'Malformed Bing source (extractor=1).', 'inspect_browser');
      }
    }
    return page;
  }
  async act(action: BrowserAction): Promise<void> {
    if (this.browser.preview) {
      if (action.action === 'reload') { await this.openPreview(this.browser.preview); return; }
      if (['back', 'forward'].includes(action.action)) { throw new ToolFailure('BROWSER_HISTORY_EMPTY', 'Local preview has no browsing history.', 'inspect_browser'); }
      await this.previewRuntime.act(action); return;
    }
    this.browser.clearActionFeedback();
    await this.ready();
    if (action.action === 'back' || action.action === 'forward' || action.action === 'reload') {
      if (action.action === 'back' && !this.controller.accessBackward() || action.action === 'forward' && !this.controller.accessForward()) {
        throw new ToolFailure('BROWSER_HISTORY_EMPTY', 'No page in this history direction.', 'inspect_browser');
      }
      this.startLoading(this.browser.url);
      if (action.action === 'back') { this.controller.backward(); }
      else if (action.action === 'forward') { this.controller.forward(); }
      else { this.controller.refresh(); }
      await this.ready(); return;
    }
    if (this.feedbackVisible && ['click', 'type', 'select'].includes(action.action)) {
      this.requireCurrentAction(action);
      const preview = await this.runAction(action, true);
      this.requireCurrentAction(action);
      if (!preview.target || !Number.isFinite(preview.target.x) || !Number.isFinite(preview.target.y) ||
        preview.target.x < 0 || preview.target.x > 1 || preview.target.y < 0 || preview.target.y > 1) {
        throw new ToolFailure('INVALID_RESPONSE', 'Browser action preview returned an invalid target.', 'inspect_browser');
      }
      this.browser.showActionFeedback(preview.target.x, preview.target.y);
      // Allow the native cue to paint before a click can navigate away. Revalidate before issuing the effect.
      await new Promise<void>((resolve) => { setTimeout(resolve, 120); });
      this.requireCurrentAction(action);
    }
    try { await this.runAction(action); }
    catch (error) { this.browser.clearActionFeedback(); throw error as Error; }
  }
  private requireCurrentAction(action: BrowserAction): void {
    if (!this.browser.isCurrentSnapshot(action.snapshotId)) {
      this.browser.clearActionFeedback();
      throw new ToolFailure('STALE_BROWSER_SNAPSHOT', 'Browser control changed before the action was issued. Read a new snapshot.', 'read_browser_snapshot');
    }
  }
  private async runAction(action: BrowserAction, preview: boolean = false): Promise<BrowserScriptResult> {
    const result = JSON.parse(await this.script(browserActionScript(action, preview))) as BrowserScriptResult;
    if (result.ok !== true) { throw new ToolFailure(result.code || 'BROWSER_ACTION_FAILED', result.message || 'Browser action failed.', 'inspect_browser_before_retry'); }
    return result;
  }
  close(): void {
    this.previewRuntime.detach(); this.browser.preview = undefined; this.browser.previewSpec = '';
    this.browser.clearActionFeedback();
    this.initialized = false; this.loading = false; this.clearInitialHistory = false; this.error = ''; this.wake();
    this.requestedUrl = ''; this.browser.loading = false; this.browser.progress = 0; this.browser.loadFailed = false;
    this.touchStart = undefined;
    this.browser.canGoBack = false; this.browser.canGoForward = false;
    // Removing the mounted Web closes the renderer. Never run another page action here.
  }
  userNavigate(url: string): void {
    this.browser.takeOver();
    if (!this.browser.preview) { this.navigate(url); return; }
    this.open(url).catch((error: Error) => this.failed(error));
  }
  userBack(): boolean {
    if (this.browser.preview) { return false; }
    if (!this.controller.accessBackward()) { return false; }
    this.browser.takeOver(); this.startLoading(this.browser.url); this.controller.backward(); return true;
  }
  userForward(): boolean {
    if (this.browser.preview) { return false; }
    if (!this.controller.accessForward()) { return false; }
    this.browser.takeOver(); this.startLoading(this.browser.url); this.controller.forward(); return true;
  }
  userReload(): void {
    this.browser.takeOver();
    if (this.browser.preview) { this.openPreview(this.browser.preview).catch((error: Error) => this.failed(error)); return; }
    if (this.browser.loadFailed && this.requestedUrl) { this.navigate(this.requestedUrl); return; }
    if (!this.browser.url) { return; }
    this.startLoading(this.browser.url); this.controller.refresh();
  }
  userStop(): void {
    if (!this.loading || this.browser.preview) { return; }
    this.browser.takeOver(); this.browser.documentChanged();
    this.controller.stop();
    this.loading = false; this.browser.loading = false;
    this.browser.pageChanged(this.controller.getUrl(), this.controller.getTitle());
    this.historyChanged(); this.wake();
  }
}
