import { t } from '../../model/I18n';
import { DetailedError, ErrorEvidence, providerErrorCode } from '../../model/DetailedError';

export interface ProviderErrorData { code?: string; type?: string; message?: string; }
interface ErrorEnvelope { error?: ProviderErrorData; }

export class TransientProviderError extends DetailedError {
  code: string;
  constructor(message: string, code: string, evidence: ErrorEvidence = {}) {
    super(message, { code: code, nativeCode: evidence.nativeCode, httpStatus: evidence.httpStatus, providerCode: evidence.providerCode, stage: evidence.stage });
    this.name = 'TransientProviderError';
    this.code = code;
  }
}

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
  const quota = ['insufficient_quota', 'quota_exceeded', 'billing_hard_limit_reached'].includes(envelope?.error?.code || '');
  const message = providerFailureReason(status, quota);
  const evidence: ErrorEvidence = { httpStatus: status,
    providerCode: providerErrorCode(envelope?.error?.code) || providerErrorCode(envelope?.error?.type), stage: 'response' };
  return !quota && [408, 429, 500, 502, 503, 504].includes(status)
    ? new TransientProviderError(message, 'http_' + status, evidence) : new DetailedError(message, evidence);
}

function providerFailureReason(status: number, quota: boolean): string {
  if (quota || status === 402) { return t('账户余额不足或额度已用尽，请到服务商控制台检查余额和计费额度。'); }
  if (status === 401) { return t('API Key 验证失败，请检查密钥是否正确、有效。'); }
  if (status === 403) { return t('服务拒绝访问，请检查账户、密钥或模型的访问权限。'); }
  if (status === 404) { return t('服务接口或模型不存在，请检查服务地址、协议和模型名称。'); }
  if (status === 429) { return t('请求频率或并发数超过限制，请稍后重试。'); }
  if (status === 408 || status === 504) { return t('服务响应超时，请稍后重试。'); }
  if (status >= 500) { return t('模型服务端发生故障，请稍后重试；持续失败时请联系服务商。'); }
  if (status >= 300 && status < 400) { return t('服务要求重定向，请填写最终 API 地址后重试。'); }
  if (status === 400 || status === 422) { return t('服务拒绝了请求参数，请检查协议、模型和请求配置。'); }
  return t('模型服务返回错误，请结合 HTTP 状态和服务错误码检查服务配置。');
}

export function streamProviderError(error?: ProviderErrorData): Error {
  if (isContextOverflow(error)) { return new ContextOverflowError(); }
  const code = providerErrorCode(error?.code) || providerErrorCode(error?.type);
  const quota = ['insufficient_quota', 'quota_exceeded', 'billing_hard_limit_reached'].includes(code || '');
  const status = quota ? 402 : ['rate_limit_exceeded', 'rate_limit_error'].includes(code || '') ? 429 :
    ['authentication_error', 'invalid_api_key'].includes(code || '') ? 401 : ['permission_denied', 'permission_error'].includes(code || '') ? 403 : 0;
  return new DetailedError(status ? providerFailureReason(status, quota) : t('模型服务在生成过程中返回错误。'),
    { providerCode: code, stage: 'streaming' });
}
