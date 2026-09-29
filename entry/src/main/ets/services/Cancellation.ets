export class RunCancelledError extends Error {
  constructor() {
    super('已停止执行。已完成的文件操作会保留。');
  }
}

// One signal per run, shared by preparation, credential resolution, requests and tools.
export class Cancellation {
  private stopped: boolean = false;
  private listeners: Set<() => void> = new Set<() => void>();

  get cancelled(): boolean {
    return this.stopped;
  }

  cancel(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    const listeners = Array.from(this.listeners);
    this.listeners.clear();
    for (const listener of listeners) {
      listener();
    }
  }

  onCancel(listener: () => void): () => void {
    if (this.stopped) {
      listener();
      return () => {};
    }
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  check(): void {
    if (this.stopped) {
      throw new RunCancelledError();
    }
  }
}
