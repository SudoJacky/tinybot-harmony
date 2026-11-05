import { PanelExpression, PanelJavaScriptTransform, PanelSourceTransform, transformPanelData, validatePanelSourceTransform } from '../model/PanelTransform';
import { Diagnostics } from '../model/Diagnostics';
import { CodeExecutor } from './CodeExecutionTools';
import { Cancellation } from './Cancellation';
interface ScriptResult { status: string; result?: Object | null; error?: string; resultTruncated?: boolean; durationMs?: number; }

export class PanelDataTransform {
  private executor: CodeExecutor;
  constructor(executor: CodeExecutor) { this.executor = executor; }
  async run(response: Object | null, transform: PanelSourceTransform | undefined, cancellation: Cancellation, panelId: string): Promise<Object> {
    cancellation.check();
    if (transform) { validatePanelSourceTransform(transform); }
    if (!transform || (transform as PanelJavaScriptTransform).type !== 'javascript') { return transformPanelData(response, transform as PanelExpression | undefined); }
    const started = Date.now();
    Diagnostics.log('info', 'life-panel', 'transform_started', { previewId: panelId });
    try {
      // Only the selected response crosses into a fresh QuickJS runtime. No source config,
      // request headers, user state, credentials or host capabilities are exposed to the script.
      const output = await this.executor.execute((transform as PanelJavaScriptTransform).code, JSON.stringify(response), cancellation);
      cancellation.check();
      // Bound host-side parsing as well as the final data. Leave room for the native
      // envelope and escaped console logs above the 256 KiB card data budget.
      if (output.length > 512 * 1024) { throw new Error('JavaScript transform execution result exceeds 512 KiB'); }
      let result: ScriptResult;
      try { result = JSON.parse(output) as ScriptResult; } catch (_) { throw new Error('JavaScript transform returned an invalid execution result'); }
      if (!result || result.status !== 'ok') {
        throw new Error('JavaScript transform failed (' + (result?.status || 'invalid_result') + '): ' + (result?.error || 'No execution result'));
      }
      if (result.resultTruncated || result.result === undefined) { throw new Error('JavaScript transform must return a complete JSON object or array'); }
      const data = transformPanelData(result.result);
      Diagnostics.log('info', 'life-panel', 'transform_complete', { previewId: panelId, elapsedMs: Date.now() - started }); return data;
    } catch (error) {
      // Script errors/logs can contain API data. Record metadata only; the card exposes the error.
      Diagnostics.log(cancellation.cancelled ? 'info' : 'error', 'life-panel', 'transform_failed',
        { previewId: panelId, cancelled: cancellation.cancelled, elapsedMs: Date.now() - started }); throw error as Error;
    }
  }
}
