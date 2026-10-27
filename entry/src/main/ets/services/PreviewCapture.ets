import { PreviewScreenshot } from '../model/Agent';
import { Cancellation, RunCancelledError } from './Cancellation';

export interface PreviewCaptureRequest { id: number; content: string; }
interface PendingCapture { request: PreviewCaptureRequest; start: () => void; pause: () => void; finish: (result?: PreviewScreenshot, error?: Error) => void; }

// The UI host renders one whole card at a time at the same width as the chat.
export class PreviewCapture {
  private static sequence: number = 0;
  private static queue: PendingCapture[] = [];
  private static listener?: (requests: PreviewCaptureRequest[]) => void;
  private static foreground: boolean = true;
  static setForeground(foreground: boolean): void {
    if (PreviewCapture.foreground === foreground) { return; }
    PreviewCapture.foreground = foreground;
    if (!foreground) { PreviewCapture.queue[0]?.pause(); }
    PreviewCapture.publish();
  }
  static subscribe(listener: (requests: PreviewCaptureRequest[]) => void): () => void {
    if (PreviewCapture.listener) { throw new Error('Preview capture host already attached'); }
    PreviewCapture.listener = listener; PreviewCapture.publish();
    return () => {
      PreviewCapture.listener = undefined;
      for (const item of PreviewCapture.queue.slice()) { item.finish(undefined, new Error('Preview capture host detached')); }
    };
  }
  private static publish(): void {
    if (!PreviewCapture.foreground) { PreviewCapture.listener?.([]); return; }
    PreviewCapture.queue[0]?.start();
    PreviewCapture.listener?.(PreviewCapture.queue.slice(0, 1).map((item) => item.request));
  }
  static complete(id: number, result?: PreviewScreenshot, error?: Error): void {
    if (!PreviewCapture.foreground) { return; }
    PreviewCapture.queue.find((item) => item.request.id === id)?.finish(result, error);
  }
  static isCurrent(id: number): boolean {
    return PreviewCapture.foreground && PreviewCapture.queue[0]?.request.id === id;
  }
  static capture(content: string, cancellation: Cancellation): Promise<PreviewScreenshot> {
    cancellation.check();
    if (!PreviewCapture.listener) { return Promise.reject(new Error('Preview capture host is unavailable')); }
    return new Promise<PreviewScreenshot>((resolve, reject) => {
      let settled = false, timer = -1;
      let unsubscribe = (): void => {};
      const finish = (result?: PreviewScreenshot, error?: Error): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer); unsubscribe();
        PreviewCapture.queue = PreviewCapture.queue.filter((item) => item !== pending); PreviewCapture.publish();
        if (error) { reject(error); } else if (result) { resolve(result); } else { reject(new Error('Preview capture returned no image')); }
      };
      const pending: PendingCapture = {
        request: { id: ++PreviewCapture.sequence, content: content }, finish: finish,
        start: (): void => {
          const id = pending.request.id;
          if (timer < 0) { timer = setTimeout(() => PreviewCapture.complete(id, undefined, new Error('Preview capture timed out')), 30000); }
        },
        pause: (): void => {
          clearTimeout(timer); timer = -1;
          pending.request = { id: ++PreviewCapture.sequence, content: content };
        }
      };
      PreviewCapture.queue.push(pending);
      unsubscribe = cancellation.onCancel(() => finish(undefined, new RunCancelledError() as Error));
      PreviewCapture.publish();
    });
  }
}
