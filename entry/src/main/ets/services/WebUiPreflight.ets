import { UiCompiler, UiValues, uiParts } from '../model/InteractiveUi';
import { Cancellation, RunCancelledError } from './Cancellation';

export interface WebUiProbe { id: number; content: string; values: UiValues; }
interface PendingProbe { probe: WebUiProbe; start: () => void; finish: (error?: Error) => void; }

// One rendered probe at a time, shared by chat and team runtimes. Never persists probe state.
export class WebUiPreflight {
  private static sequence: number = 0;
  private static queue: PendingProbe[] = [];
  private static listener?: (probes: WebUiProbe[]) => void;

  static subscribe(listener: (probes: WebUiProbe[]) => void): () => void {
    if (WebUiPreflight.listener) { throw new Error('Web UI preflight host already attached'); }
    WebUiPreflight.listener = listener; WebUiPreflight.publish();
    return () => {
      WebUiPreflight.listener = undefined;
      for (const item of WebUiPreflight.queue.slice()) { item.finish(new Error('Web UI preflight host detached')); }
    };
  }
  private static publish(): void {
    WebUiPreflight.queue[0]?.start();
    WebUiPreflight.listener?.(WebUiPreflight.queue.slice(0, 1).map((item) => item.probe));
  }
  static complete(id: number, error: string = ''): void {
    WebUiPreflight.queue.find((item) => item.probe.id === id)?.finish(error ? new Error(error) : undefined);
  }
  private static check(content: string, values: UiValues, cancellation: Cancellation): Promise<void> {
    cancellation.check();
    if (!WebUiPreflight.listener) { return Promise.reject(new Error('Web UI preflight host is unavailable')); }
    return new Promise<void>((resolve, reject) => {
      const id = ++WebUiPreflight.sequence;
      let settled = false;
      let unsubscribe = (): void => {};
      let timer: number = -1;
      const start = (): void => {
        if (timer < 0) { timer = setTimeout(() => WebUiPreflight.complete(id, 'Web UI preflight timed out before startup completed'), 30000); }
      };
      const finish = (error?: Error): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer); unsubscribe();
        WebUiPreflight.queue = WebUiPreflight.queue.filter((item) => item.probe.id !== id); WebUiPreflight.publish();
        if (error) { reject(error); } else { resolve(); }
      };
      WebUiPreflight.queue.push({ probe: { id: id, content: content, values: values }, start: start, finish: finish });
      unsubscribe = cancellation.onCancel(() => finish(new RunCancelledError() as Error));
      WebUiPreflight.publish();
    });
  }
  static async validate(content: string, cancellation: Cancellation): Promise<void> {
    for (const part of uiParts(content, false).filter((item) => item.kind === 'ui')) {
      const document = new UiCompiler().update(part.content, true);
      for (const node of document.nodes.filter((item) => item.kind === 'web')) {
        try { await WebUiPreflight.check(node.data || '', document.initial, cancellation); }
        catch (error) {
          cancellation.check();
          throw new Error('surface=' + part.key + ' node=' + node.id + '\n' + (error as Error).message);
        }
      }
    }
  }
}
