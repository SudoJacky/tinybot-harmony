import { Diagnostics } from '../model/Diagnostics';

interface CheckpointWaiter { resolve: () => void; reject: (error: Error) => void; }

// All callers in a batch wait for the snapshot that includes their changes. A caller
// arriving during IO belongs to the next batch and cannot be acknowledged by stale IO.
export class CheckpointQueue {
  private pending: CheckpointWaiter[] = [];
  private running: boolean = false;
  private persist: () => Promise<void>;
  constructor(persist: () => Promise<void>) { this.persist = persist; }

  save(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      this.pending.push({ resolve: resolve, reject: reject });
      if (!this.running) { this.running = true; setTimeout(() => { this.flush(); }, 0); }
    });
  }

  private async flush(): Promise<void> {
    const batch = this.pending; this.pending = [];
    const mark = Diagnostics.begin();
    try {
      await this.persist();
      batch.forEach((waiter) => waiter.resolve());
    } catch (error) {
      batch.forEach((waiter) => waiter.reject(error as Error));
    } finally {
      if (Diagnostics.recording) { Diagnostics.end('storage.checkpoint', mark, { batchSize: batch.length }); }
      // Yield between snapshots, including after a failed save. Errors still reach every caller.
      if (this.pending.length) { setTimeout(() => { this.flush(); }, 0); }
      else { this.running = false; }
    }
  }
}
