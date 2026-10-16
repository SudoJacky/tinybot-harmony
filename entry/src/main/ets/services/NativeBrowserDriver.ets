import { webview } from '@kit.ArkWeb';
import { image } from '@kit.ImageKit';
import { AnnotationPage } from '../model/BrowserAnnotation';
import { ToolFailure } from '../model/ToolFailure';
import { browserActionScript, browserSnapshotScript } from '../model/BrowserScripts';
import { BrowserAction, BrowserDriver, BrowserPage, BrowserSession } from './BrowserSession';

interface BrowserScriptResult { ok?: boolean; code?: string; message?: string; }
export interface NativeBrowserCapture extends AnnotationPage { pixel: image.PixelMap; width: number; height: number; }

export class NativeBrowserDriver implements BrowserDriver {
  controller: webview.WebviewController = new webview.WebviewController();
  private browser: BrowserSession;
  private initialized: boolean = false;
  private loading: boolean = false;
  private clearInitialHistory: boolean = false;
  private error: string = '';
  private waiters: Set<() => void> = new Set<() => void>();
  private touchStart?: TouchObject;
  private touchMoved: boolean = false;
  constructor(browser: BrowserSession) { this.browser = browser; }
  pageBegin(): void { this.loading = true; this.error = ''; this.browser.error = ''; }
  pageEnd(url: string): void {
    this.initialized = true; this.loading = false;
    if (this.clearInitialHistory && url !== 'about:blank') { this.controller.clearHistory(); this.clearInitialHistory = false; }
    this.browser.pageChanged(url, this.controller.getTitle()); this.historyChanged(); this.wake();
  }
  historyChanged(): void {
    this.browser.canGoBack = this.controller.accessBackward();
    this.browser.canGoForward = this.controller.accessForward();
  }
  userTouch(event: TouchEvent): void {
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
  failed(message: string): void {
    this.error = message; this.loading = false; this.browser.report(message); this.wake();
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
          this.browser.report(failure.message); reject(failure);
        }, 30000);
        this.waiters.add(finish); finish();
      });
    }
    if (!this.browser.open) { throw new ToolFailure('BROWSER_CLOSED', 'Browser is closed.', 'respect_user_decision'); }
    if (this.error) { throw new ToolFailure('BROWSER_LOAD_FAILED', this.error, 'inspect_browser'); }
  }
  async open(url: string): Promise<void> {
    await this.ready();
    this.navigate(url);
    await this.ready();
  }
  private navigate(url: string): void {
    this.clearInitialHistory = this.clearInitialHistory || this.controller.getUrl() === 'about:blank';
    this.loading = true; this.error = ''; this.controller.loadUrl(url);
  }
  async capture(): Promise<NativeBrowserCapture> {
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
  async snapshot(id: string): Promise<BrowserPage> {
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
  async act(action: BrowserAction): Promise<void> {
    await this.ready();
    if (action.action === 'back' || action.action === 'forward' || action.action === 'reload') {
      if (action.action === 'back' && !this.controller.accessBackward() || action.action === 'forward' && !this.controller.accessForward()) {
        throw new ToolFailure('BROWSER_HISTORY_EMPTY', 'No page in this history direction.', 'inspect_browser');
      }
      this.loading = true;
      if (action.action === 'back') { this.controller.backward(); }
      else if (action.action === 'forward') { this.controller.forward(); }
      else { this.controller.refresh(); }
      await this.ready(); return;
    }
    const result = JSON.parse(await this.script(browserActionScript(action))) as BrowserScriptResult;
    if (result.ok !== true) { throw new ToolFailure(result.code || 'BROWSER_ACTION_FAILED', result.message || 'Browser action failed.', 'inspect_browser_before_retry'); }
  }
  close(): void {
    this.initialized = false; this.loading = false; this.clearInitialHistory = false; this.error = ''; this.wake();
    this.touchStart = undefined;
    this.browser.canGoBack = false; this.browser.canGoForward = false;
    // Removing the mounted Web closes the renderer. Never run another page action here.
  }
  userNavigate(url: string): void { this.browser.takeOver(); this.navigate(url); }
  userBack(): boolean {
    if (!this.controller.accessBackward()) { return false; }
    this.browser.takeOver(); this.loading = true; this.error = ''; this.controller.backward(); return true;
  }
  userForward(): boolean {
    if (!this.controller.accessForward()) { return false; }
    this.browser.takeOver(); this.loading = true; this.error = ''; this.controller.forward(); return true;
  }
  userReload(): void { this.browser.takeOver(); this.loading = true; this.error = ''; this.controller.refresh(); }
}
