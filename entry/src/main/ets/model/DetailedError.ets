import { t } from './I18n';

export interface ErrorEvidence {
  code?: number | string;
  nativeCode?: number;
  httpStatus?: number;
  providerCode?: string;
  stage?: string;
}

// Keep machine-readable evidence when adding operation context. Never copy response bodies.
export class DetailedError extends Error implements ErrorEvidence {
  reason: string;
  code?: number | string;
  nativeCode?: number;
  httpStatus?: number;
  providerCode?: string;
  stage?: string;
  originalError?: Error;
  constructor(reason: string, evidence: ErrorEvidence = {}) {
    const details: string[] = [];
    if (evidence.httpStatus !== undefined) { details.push('HTTP ' + evidence.httpStatus); }
    if (evidence.code !== undefined) { details.push(t('错误码 {0}', [evidence.code])); }
    if (evidence.nativeCode !== undefined) { details.push(t('系统错误码 {0}', [evidence.nativeCode])); }
    if (evidence.providerCode) { details.push(t('服务错误码 {0}', [evidence.providerCode])); }
    super(reason + (details.length ? ' [' + details.join(' · ') + ']' : ''));
    this.name = 'DetailedError'; this.reason = reason;
    this.code = evidence.code; this.httpStatus = evidence.httpStatus;
    this.nativeCode = evidence.nativeCode;
    this.providerCode = evidence.providerCode; this.stage = evidence.stage;
  }
}

export function contextualError(operation: string, stage: string, error: Error): DetailedError {
  const source = error as DetailedError;
  const reason = error instanceof DetailedError ? error.reason : error.message || t('系统未提供具体原因。');
  const result = new DetailedError(operation + '：' + reason, { code: source.code, httpStatus: source.httpStatus,
    nativeCode: source.nativeCode, providerCode: source.providerCode, stage: source.stage || stage });
  result.originalError = error;
  return result;
}

// Provider identifiers are useful; arbitrary messages may echo prompts or credentials.
export function providerErrorCode(value: string | number | undefined): string | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) { return String(value); }
  return typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,80}$/.test(value) && !/^sk-/i.test(value) ? value : undefined;
}

export function parseServiceJson(text: string): Object {
  try { return JSON.parse(text) as Object; }
  catch (_) { throw new DetailedError(t('服务响应不是有效的 JSON，请检查服务地址或网关配置。'), { code: 'INVALID_RESPONSE', stage: 'parse' }); }
}
