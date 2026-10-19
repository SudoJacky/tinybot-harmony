import { AgentStep, ModelTurn, RequestRetry } from '../model/Agent';
import { Cancellation, RunCancelledError } from './Cancellation';
import { TransientProviderError } from './providers/ProviderErrors';

export function retryDelay(milliseconds: number, cancellation: Cancellation): Promise<void> {
  cancellation.check();
  return new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => { unsubscribe(); resolve(); }, milliseconds);
    const unsubscribe = cancellation.onCancel(() => { clearTimeout(timer); reject(new RunCancelledError()); });
  });
}

// Retry the request only, never its surrounding tool batch or completed steps.
export async function requestWithRetry(step: AgentStep, request: () => Promise<ModelTurn>, cancellation: Cancellation,
  checkpoint: () => Promise<void>, changed: () => void): Promise<ModelTurn> {
  for (let attempt = 0; ; attempt++) {
    cancellation.check();
    try { return await request(); }
    catch (error) {
      cancellation.check();
      if (!(error instanceof TransientProviderError) || attempt >= 2 || step.tools.length > 0) { throw error as Error; }
      // No tools are dispatched before a complete model result. Discard only this
      // failed attempt's preview; never replay already committed steps or tools.
      step.content = ''; step.reasoningContent = '';
      const retry: RequestRetry = { attempt: attempt + 1, delayMs: 1000 * (attempt + 1), code: error.code, waiting: true };
      step.retries = (step.retries || []).concat([retry]);
      changed();
      try { await checkpoint(); cancellation.check(); await retryDelay(retry.delayMs, cancellation); }
      finally { retry.waiting = false; changed(); }
      // Persist the transition before dispatch; a failed save prevents the next request.
      await checkpoint(); cancellation.check();
    }
  }
}
