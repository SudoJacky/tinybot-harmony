import { util } from '@kit.ArkTS';
import sandbox from 'libtinybot_sandbox.so';
import { Cancellation, RunCancelledError } from './Cancellation';
import { OrchestrationExecutor } from './OrchestrationTools';
import { Diagnostics } from '../model/Diagnostics';
import { toolError } from '../model/Agent';

export class NativeOrchestrationExecutor implements OrchestrationExecutor {
  async execute(source: string, catalog: string, invoke: (name: string, argumentsJson: string) => Promise<string>,
    cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const id = util.generateRandomUUID();
    const pending: Promise<void>[] = [];
    let accepting = true;
    let bridgeError: Error | undefined = undefined;
    const settle = (callId: number, output: string, error: boolean): void => {
      try { sandbox.settle(id, callId, output, error); }
      catch (failure) { bridgeError = failure as Error; sandbox.cancelOrchestration(id); }
    };
    const result = sandbox.orchestrate(id, source, catalog, (callId, name, argumentsJson) => {
      if (!accepting || cancellation.cancelled) { return; }
      const work = async (): Promise<void> => {
        try {
          const output = await invoke(name, argumentsJson);
          settle(callId, output, false);
        } catch (error) { settle(callId, toolError(error as Error), true); }
      };
      pending.push(work());
    });
    const unsubscribe = cancellation.onCancel(() => sandbox.cancelOrchestration(id));
    try {
      const output = await result;
      if (bridgeError) { throw bridgeError as Error; }
      cancellation.check();
      return output;
    } catch (error) {
      if (!(error instanceof RunCancelledError)) {
        Diagnostics.log('error', 'sandbox', 'orchestration_failed', { sessionId: id }, error as Error);
      }
      throw error as Error;
    } finally {
      accepting = false;
      // Stop and drain admitted work even when JS fails or leaves a tool unawaited.
      cancellation.cancel();
      await Promise.all(pending);
      unsubscribe();
    }
  }
}
