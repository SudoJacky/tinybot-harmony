import { PanelFailureInfo } from '../model/LifePanel';
interface AgentPanelOutcome { status: string; data?: Object; code?: string; }
const REASONS: Record<string, string> = {
  'NOT_FOUND': 'The required data or file was not found', 'FILE_NOT_FOUND': 'The required workspace file was not found',
  'AUTH_REQUIRED': 'The data source requires authentication', 'PERMISSION_DENIED': 'The data source denied access',
  'NETWORK_ERROR': 'The data source connection failed', 'HTTP_ERROR': 'The data source returned an HTTP error',
  'TIMEOUT': 'The update exceeded its time limit', 'RATE_LIMITED': 'The data source rate limit was reached',
  'UNSUPPORTED_CONTENT': 'The data source content is unsupported', 'INVALID_RESPONSE': 'The data source returned an invalid response',
  'LIMIT_EXCEEDED': 'The update exceeded a resource limit', 'TOOL_UNAVAILABLE': 'A required tool is unavailable',
  'DATA_UNAVAILABLE': 'The requested data could not be obtained', 'EXECUTION_FAILED': 'A required tool failed',
  'OUTPUT_INVALID': 'Agent did not return the required success/error JSON envelope', 'MODEL_FAILED': 'The model request did not complete',
  'DATA_INVALID': 'Agent data does not match the card bindings'
};
export class PanelTaskFailure extends Error {
  info: PanelFailureInfo;
  code: string;
  constructor(stage: string, code: string, tool?: string, nativeCode?: number) {
    const safeCode = Object.keys(REASONS).includes(code) ? code : 'EXECUTION_FAILED';
    const message = (tool ? tool + ': ' : '') + REASONS[safeCode]; super(message);
    this.code = safeCode; this.info = { stage: stage, code: safeCode, message: message, tool: tool, nativeCode: nativeCode };
  }
}
// Persist classified evidence only, never arbitrary model prose, tool bodies or headers.
export function panelAgentOutcome(text: string, toolFailure?: PanelFailureInfo): Object {
  let result: AgentPanelOutcome;
  try { result = JSON.parse(text) as AgentPanelOutcome; }
  catch (_) { throw new PanelTaskFailure(toolFailure?.stage || 'output', toolFailure?.code || 'OUTPUT_INVALID', toolFailure?.tool, toolFailure?.nativeCode); }
  if (!result || typeof result !== 'object' || Array.isArray(result) || Object.keys(result).some((key: string) => !['status', 'data', 'code'].includes(key))) { throw new PanelTaskFailure('output', 'OUTPUT_INVALID'); }
  if (result.status === 'error' && result.data === undefined && typeof result.code === 'string' && Object.keys(REASONS).includes(result.code)) {
    const code = toolFailure && toolFailure.code !== 'EXECUTION_FAILED' ? toolFailure.code : result.code;
    throw new PanelTaskFailure(toolFailure?.stage || 'acquisition', code, toolFailure?.tool, toolFailure?.nativeCode);
  }
  if (result.status !== 'success' || result.code !== undefined || !result.data || typeof result.data !== 'object') { throw new PanelTaskFailure('output', 'OUTPUT_INVALID'); }
  return result.data;
}
