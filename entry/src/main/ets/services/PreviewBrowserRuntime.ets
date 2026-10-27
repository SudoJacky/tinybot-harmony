import { BrowserPage, BrowserAction } from './BrowserSession';
import { ToolFailure } from '../model/ToolFailure';
import { image } from '@kit.ImageKit';

interface PendingBrowserRequest { id: number; finish: (output?: string, error?: Error) => void; }

// The live preview view supplies the transport and native surface. No generated code gets native access.
export class PreviewBrowserRuntime {
  private send?: (id: number, operation: string, argumentsJson: string) => void;
  private surface?: () => Promise<image.PixelMap>;
  private pending: PendingBrowserRequest[] = [];
  private sequence: number = 0;
  private started: boolean = false;
  private attachment: number = 0;
  private onDocumentChanged: () => void;
  errors: string[] = [];
  constructor(onDocumentChanged: () => void = () => {}) { this.onDocumentChanged = onDocumentChanged; }
  get isReady(): boolean { return this.started; }
  attach(send: (id: number, operation: string, argumentsJson: string) => void, surface: () => Promise<image.PixelMap>): number {
    this.detach(); this.errors = []; this.send = send; this.surface = surface;
    this.onDocumentChanged(); return this.attachment;
  }
  ready(): void { this.started = true; }
  recordError(message: string): void { this.errors = this.errors.concat([message.slice(0, 2000)]).slice(-16); }
  detach(attachment?: number): void {
    if (attachment !== undefined && attachment !== this.attachment) { return; }
    this.attachment++;
    this.started = false; this.send = undefined; this.surface = undefined;
    for (const request of this.pending.slice()) { request.finish(undefined, new Error('Preview page was released or reloaded')); }
  }
  receive(id: number, output: string): void { this.pending.find((item) => item.id === id)?.finish(output); }
  private request(operation: string, argumentsJson: string): Promise<string> {
    if (!this.started || !this.send) {
      return Promise.reject(new ToolFailure('PREVIEW_NOT_READY', 'Preview has not started. ' + this.errors.join('\n'), 'inspect_browser'));
    }
    return new Promise<string>((resolve, reject) => {
      const id = ++this.sequence;
      const finish = (output?: string, error?: Error): void => {
        clearTimeout(timer); this.pending = this.pending.filter((item) => item.id !== id);
        if (error) { reject(error); } else { resolve(output as string); }
      };
      const timer = setTimeout(() => finish(undefined, new Error('Preview browser command timed out')), 5000);
      this.pending.push({ id: id, finish: finish });
      try { this.send?.(id, operation, argumentsJson); } catch (error) { finish(undefined, error as Error); }
    });
  }
  async snapshot(id: string): Promise<BrowserPage> {
    const page = JSON.parse(await this.request('snapshot', JSON.stringify({ snapshotId: id }))) as BrowserPage;
    if (page.snapshotId !== id || typeof page.text !== 'string' || !Array.isArray(page.elements)) {
      throw new ToolFailure('INVALID_RESPONSE', 'Malformed preview observation.', 'inspect_browser');
    }
    return page;
  }
  async act(action: BrowserAction): Promise<void> {
    const result = JSON.parse(await this.request('action', JSON.stringify(action))) as Record<string, string | boolean>;
    if (result.ok !== true) { throw new ToolFailure(result.code as string || 'BROWSER_ACTION_FAILED', result.message as string, 'read_browser_snapshot'); }
  }
  async capture(): Promise<image.PixelMap> {
    if (!this.started || !this.surface) { throw new Error('Preview surface is not ready'); }
    await this.request('paint', '{}');
    if (!this.surface) { throw new Error('Preview surface was released'); }
    return this.surface();
  }
}
