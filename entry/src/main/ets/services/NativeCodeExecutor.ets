import { util } from '@kit.ArkTS';
import sandbox from 'libtinybot_sandbox.so';
import { Cancellation, RunCancelledError } from './Cancellation';
import { CodeExecutor } from './CodeExecutionTools';
import { Diagnostics } from '../model/Diagnostics';

export class NativeCodeExecutor implements CodeExecutor {
  private static tail: Promise<void> = Promise.resolve();
  async execute(source: string, inputJson: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    // The native engine admits one execution globally, including cleanup. Foreground
    // card transforms and agent execute_code calls share this lane across instances.
    const previous = NativeCodeExecutor.tail;
    let release: () => void = () => {};
    NativeCodeExecutor.tail = new Promise<void>((resolve) => { release = resolve; });
    await previous;
    try { return await this.run(source, inputJson, cancellation); } finally { release(); }
  }
  private async run(source: string, inputJson: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const id = util.generateRandomUUID();
    // Native registration is synchronous. Subscribe after admission so immediate cancellation
    // always finds the job, including work waiting for a native worker thread.
    let unsubscribe = (): void => {};
    try {
      const pending: Promise<string> = sandbox.execute(id, source, inputJson);
      unsubscribe = cancellation.onCancel(() => { sandbox.cancel(id); });
      const result: string = await pending;
      cancellation.check();
      return result;
    } catch (error) {
      if (!(error instanceof RunCancelledError)) {
        Diagnostics.log('error', 'sandbox', 'execution_failed', { sessionId: id }, error as Error);
      }
      throw error as Error;
    } finally { unsubscribe(); }
  }
}
