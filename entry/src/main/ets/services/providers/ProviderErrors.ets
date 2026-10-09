import { t } from '../../model/I18n';

export interface ProviderErrorData { code?: string; type?: string; message?: string; }
interface ErrorEnvelope { error?: ProviderErrorData; }

export class ContextOverflowError extends Error {
  constructor() {
    super(t('模型服务报告输入超过上下文窗口。'));
    this.name = 'ContextOverflowError';
  }
}

// Only explicit provider evidence enables recovery. HTTP 413, output truncation,
// quota errors and network failures alone do not establish context overflow.
export function isContextOverflow(error?: ProviderErrorData): boolean {
  if (!error) { return false; }
  if (error.code === 'context_length_exceeded' || error.code === 'context_window_exceeded') { return true; }
  return error.type === 'invalid_request_error' && typeof error.message === 'string' &&
    /^prompt is too long: \d+ tokens? > \d+ maximum\b/i.test(error.message);
}

export function httpProviderError(status: number, body: string): Error {
  let envelope: ErrorEnvelope | undefined = undefined;
  try { envelope = JSON.parse(body) as ErrorEnvelope; }
  catch (_) { /* Non-JSON HTTP errors still report the status, never an invented cause. */ }
  if ([400, 413, 422].includes(status) && isContextOverflow(envelope?.error)) { return new ContextOverflowError(); }
  // Never expose upstream message bodies: some services echo prompts or credentials.
  return new Error(t('模型服务返回 HTTP {0}，请检查地址、API Key、模型名称和额度。', [status]));
}
