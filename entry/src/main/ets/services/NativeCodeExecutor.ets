import { util } from '@kit.ArkTS';
import sandbox from 'libtinybot_sandbox.so';
import { Cancellation } from './Cancellation';
import { CodeExecutor } from './CodeExecutionTools';

export class NativeCodeExecutor implements CodeExecutor {
  async execute(source: string, inputJson: string, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    const id = util.generateRandomUUID();
    // Native registration is synchronous. Subscribe after admission so immediate cancellation
    // always finds the job, including work waiting for a native worker thread.
    const pending: Promise<string> = sandbox.execute(id, source, inputJson);
    const unsubscribe = cancellation.onCancel(() => { sandbox.cancel(id); });
    try {
      const result: string = await pending;
      cancellation.check();
      return result;
    } finally { unsubscribe(); }
  }
}
