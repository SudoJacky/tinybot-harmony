import { Cancellation, RunCancelledError } from './Cancellation';

export interface OfficeReviewRequest { id: number; encoded: string; }

// Workspace code is already serialized across sessions. Mount only for the active layout check.
export class OfficeLayoutReview {
  private static listener?: (requests: OfficeReviewRequest[]) => void;
  private static nextId: number = 0;
  private static finish?: (id: number, result: string, error?: Error) => void;

  static subscribe(listener: (requests: OfficeReviewRequest[]) => void): () => void {
    OfficeLayoutReview.listener = listener;
    return () => {
      OfficeLayoutReview.listener = undefined;
      OfficeLayoutReview.complete(OfficeLayoutReview.nextId, '', new Error('The document review view closed.'));
    };
  }

  static complete(id: number, result: string, error?: Error): void {
    OfficeLayoutReview.finish?.(id, result, error);
  }

  static check(encoded: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const listener = OfficeLayoutReview.listener;
    if (!listener || OfficeLayoutReview.finish) {
      return Promise.reject(new Error('PowerPoint layout review requires the open Tinybot chat view.'));
    }
    return new Promise<string>((resolve, reject) => {
      const id = ++OfficeLayoutReview.nextId;
      const timeout = setTimeout(() => OfficeLayoutReview.complete(id, '', new Error('PowerPoint layout review timed out.')), 30000);
      let unsubscribe = (): void => {};
      OfficeLayoutReview.finish = (requestId, result, error): void => {
        if (requestId !== id) { return; }
        OfficeLayoutReview.finish = undefined;
        clearTimeout(timeout);
        unsubscribe();
        OfficeLayoutReview.listener?.([]);
        if (error) { reject(error); } else { resolve(result); }
      };
      unsubscribe = cancellation.onCancel(() => OfficeLayoutReview.complete(id, '', new RunCancelledError() as Error));
      listener([{ id: id, encoded: encoded }]);
    });
  }
}
