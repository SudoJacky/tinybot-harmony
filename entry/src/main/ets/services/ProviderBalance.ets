import { t } from '../model/I18n';
import { contextualError, DetailedError, parseServiceJson } from '../model/DetailedError';
import { Diagnostics } from '../model/Diagnostics';
import { protocolUrl } from '../model/ProviderEndpoint';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ProviderDraft } from './ProfileSettings';
import { providerDraftKey } from './ProviderAccess';
import { CompatHttp, CompatRequest } from './CompatHttp';
import { httpProviderError } from './providers/ProviderErrors';

export interface BalanceAmount { currency: string; total: string; granted: string; toppedUp: string; }
export interface ProviderBalance { available: boolean; amounts: BalanceAmount[]; checkedAt: number; }
interface BalanceInfo { currency?: string; total_balance?: string; granted_balance?: string; topped_up_balance?: string; }
interface BalanceResponse { is_available?: boolean; balance_infos?: BalanceInfo[]; }

// Capability follows the exact endpoint, never a preset name or a compatible wire protocol.
export function supportsProviderBalance(protocol: string, baseUrl: string): boolean {
  try {
    const root = protocolUrl(protocol, baseUrl, false).replace(/\/(chat\/completions|responses|messages)$/, '');
    return root === 'https://api.deepseek.com' || root === 'https://api.deepseek.com/v1';
  } catch (_) { return false; }
}

function money(value: string | undefined): boolean {
  return typeof value === 'string' && value.length <= 64 && /^-?\d+(\.\d+)?$/.test(value);
}

// https://api-docs.deepseek.com/api/get-user-balance/
export async function queryProviderBalance(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<ProviderBalance> {
  try {
    if (!supportsProviderBalance(draft.protocol, draft.baseUrl)) {
      throw new DetailedError(t('当前服务尚未接入余额查询，请到服务商控制台查看。'), { code: 'UNSUPPORTED_PROTOCOL' });
    }
    if (draft.noApiKey) { throw new Error(t('查询余额需要 API Key。')); }
    const key = await providerDraftKey(draft, profiles);
    const headers: Record<string, string> = {};
    headers['Authorization'] = 'Bearer ' + key;
    headers['Accept'] = 'application/json';
    const request: CompatRequest = { url: 'https://api.deepseek.com/user/balance', method: 'GET',
      headers: headers, connectTimeout: 15000, readTimeout: 30000,
      maxBytes: 64 * 1024, dataType: 'string', redirect: 'refuse' };
    const response = await CompatHttp.request(request);
    if (response.status !== 200) { throw httpProviderError(response.status, response.text); }
    const value = parseServiceJson(response.text) as BalanceResponse;
    if (!value || typeof value.is_available !== 'boolean' || !Array.isArray(value.balance_infos) ||
      value.balance_infos.length > 2 || value.balance_infos.some((item) => !item || !['CNY', 'USD'].includes(item.currency || '') ||
        !money(item.total_balance) || !money(item.granted_balance) || !money(item.topped_up_balance)) ||
      new Set(value.balance_infos.map((item) => item.currency)).size !== value.balance_infos.length) {
      throw new DetailedError(t('服务返回的余额数据格式无效。'), { code: 'INVALID_RESPONSE', stage: 'parse' });
    }
    return { available: value.is_available, checkedAt: Date.now(), amounts: value.balance_infos.map((item): BalanceAmount => ({
      currency: item.currency!, total: item.total_balance!, granted: item.granted_balance!, toppedUp: item.topped_up_balance! })) };
  } catch (error) {
    const failure = contextualError(t('查询账户余额失败'), 'balance', error as Error);
    Diagnostics.log('error', 'provider', 'balance_failed', { protocol: draft.protocol }, failure);
    throw failure;
  }
}
