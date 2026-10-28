import { UiCompiler, UiValues, uiParts } from '../model/InteractiveUi';
import { Cancellation, RunCancelledError } from './Cancellation';
import { UiDiagnosticError } from '../model/UiRepair';
import { MiniAppStorage } from '../model/MiniApp';

export interface WebUiProbe { id: number; content: string; values: UiValues; storage?: MiniAppStorage; }
interface PendingProbe { probe: WebUiProbe; start: () => void; pause: () => void; finish: (error?: Error) => void; }

// One rendered probe at a time, shared by chat and team runtimes. Never persists probe state.
export class WebUiPreflight {
  private static sequence: number = 0;
  private static queue: PendingProbe[] = [];
  private static listener?: (probes: WebUiProbe[]) => void;
  private static foreground: boolean = true;

  static setForeground(foreground: boolean): void {
    if (WebUiPreflight.foreground === foreground) { return; }
    WebUiPreflight.foreground = foreground;
    if (!foreground) { WebUiPreflight.queue[0]?.pause(); }
    WebUiPreflight.publish();
  }

  static subscribe(listener: (probes: WebUiProbe[]) => void): () => void {
    if (WebUiPreflight.listener) { throw new Error('Web UI preflight host already attached'); }
    WebUiPreflight.listener = listener; WebUiPreflight.publish();
    return () => {
      WebUiPreflight.listener = undefined;
      for (const item of WebUiPreflight.queue.slice()) { item.finish(new Error('Web UI preflight host detached')); }
    };
  }
  private static publish(): void {
    if (!WebUiPreflight.foreground) { WebUiPreflight.listener?.([]); return; }
    WebUiPreflight.queue[0]?.start();
    WebUiPreflight.listener?.(WebUiPreflight.queue.slice(0, 1).map((item) => item.probe));
  }
  static complete(id: number, error: string = ''): void {
    if (!WebUiPreflight.foreground) { return; }
    WebUiPreflight.queue.find((item) => item.probe.id === id)?.finish(error ? new Error(error) : undefined);
  }
  private static check(content: string, values: UiValues, cancellation: Cancellation, storage?: MiniAppStorage): Promise<void> {
    cancellation.check();
    if (!WebUiPreflight.listener) { return Promise.reject(new Error('Web UI preflight host is unavailable')); }
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      let unsubscribe = (): void => {};
      let timer: number = -1;
      const start = (): void => {
        const id = pending.probe.id;
        if (timer < 0) { timer = setTimeout(() => WebUiPreflight.complete(id, 'Web UI preflight timed out before startup completed'), 30000); }
      };
      const finish = (error?: Error): void => {
        if (settled) { return; }
        settled = true; clearTimeout(timer); unsubscribe();
        WebUiPreflight.queue = WebUiPreflight.queue.filter((item) => item !== pending); WebUiPreflight.publish();
        if (error) { reject(error); } else { resolve(); }
      };
      const pending: PendingProbe = {
        probe: { id: ++WebUiPreflight.sequence, content: content, values: values, storage: storage }, start: start, finish: finish,
        pause: (): void => {
          clearTimeout(timer); timer = -1;
          // A foreground host mounts a fresh validation attempt for the same immutable source.
          // Keep the old object/id detached so delayed Web callbacks cannot settle the new attempt.
          pending.probe = { id: ++WebUiPreflight.sequence, content: content, values: values, storage: storage };
        }
      };
      WebUiPreflight.queue.push(pending);
      unsubscribe = cancellation.onCancel(() => finish(new RunCancelledError() as Error));
      WebUiPreflight.publish();
    });
  }
  static validateMiniApp(content: string, storage: MiniAppStorage, cancellation: Cancellation): Promise<void> {
    return WebUiPreflight.check(content, {}, cancellation, storage);
  }
  static async validate(content: string, cancellation: Cancellation): Promise<void> {
    for (const part of uiParts(content, false).filter((item) => item.kind === 'ui')) {
      const document = new UiCompiler().update(part.content, true);
      for (const node of document.nodes.filter((item) => item.kind === 'web')) {
        try { await WebUiPreflight.check(node.data || '', document.initial, cancellation); }
        catch (error) {
          cancellation.check();
          throw new UiDiagnosticError('WEB_STARTUP_FAILED', 'surface=' + part.key + ' node=' + node.id + '\n' + (error as Error).message,
            { surface: part.key, node: node.id, field: 'node.data' });
        }
      }
    }
  }
}
