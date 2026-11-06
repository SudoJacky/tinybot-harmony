import { t } from '../model/I18n';
import { contextualError, DetailedError, parseServiceJson } from '../model/DetailedError';
import { Diagnostics } from '../model/Diagnostics';
import { BalanceSettings, validateBalanceSettings } from '../model/BalanceSettings';
import { protocolUrl } from '../model/ProviderEndpoint';
import { ProviderProfile } from '../model/ProviderProfiles';
import { ProviderDraft } from './ProfileSettings';
import { balanceDraftKey } from './ProviderAccess';
import { CompatHttp, CompatRequest } from './CompatHttp';
import { httpProviderError } from './providers/ProviderErrors';
import { ProviderBalance, parseCustomBalance, parseDeepSeekBalance, parseNewApiBalance, parseNewApiAccountBalance, parseSub2ApiBalance, parseZhipuBalance } from './BalanceParsers';

export { BalanceAmount, ProviderBalance } from './BalanceParsers';

function serviceRoot(protocol: string, baseUrl: string): string {
  protocolUrl(protocol, baseUrl, false);
  // Validate the model endpoint, but do not inherit paths synthesized by its wire protocol.
  return baseUrl.trim().replace(/\/+$/, '').replace(/\/(chat\/completions|responses|messages)$/, '');
}

// A wire protocol or preset name is not evidence of a billing API.
export function balanceAdapter(protocol: string, baseUrl: string, settings?: BalanceSettings): string {
  const root = serviceRoot(protocol, baseUrl);
  const mode = settings?.mode || 'auto';
  if (mode === 'auto') { return ['https://api.deepseek.com', 'https://api.deepseek.com/v1'].includes(root) ? 'deepseek' : ''; }
  if (mode === 'zhipu') { return root === 'https://open.bigmodel.cn/api/paas/v4' ? mode : ''; }
  return ['sub2api', 'newapi', 'newapi-account', 'custom'].includes(mode) ? mode : '';
}

export function supportsProviderBalance(protocol: string, baseUrl: string, settings?: BalanceSettings): boolean {
  try { return balanceAdapter(protocol, baseUrl, settings).length > 0; }
  catch (_) { return false; } // Invalid editor input is reported when querying/saving.
}

async function getBalanceJson(url: string, key: string, auth: string, userId?: string): Promise<Object> {
  const headers: Record<string, string> = { 'Accept': 'application/json' };
  if (auth === 'bearer') { headers['Authorization'] = 'Bearer ' + key; }
  else if (auth === 'raw') { headers['Authorization'] = key; }
  else if (auth === 'api-key') { headers['x-api-key'] = key; }
  if (userId) { headers['New-Api-User'] = userId; }
  const request: CompatRequest = { url: url, method: 'GET', headers: headers, connectTimeout: 15000, readTimeout: 30000,
    maxBytes: 256 * 1024, dataType: 'string', redirect: 'refuse' };
  const response = await CompatHttp.request(request);
  if (response.status !== 200) { throw httpProviderError(response.status, response.text); }
  return parseServiceJson(response.text);
}

export async function queryProviderBalance(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<ProviderBalance> {
  let adapter = '';
  const started = Date.now();
  try {
    validateBalanceSettings(draft.balance);
    if (!supportsProviderBalance(draft.protocol, draft.baseUrl, draft.balance)) {
      throw new DetailedError(t('当前服务尚未接入余额查询，请到服务商控制台查看。'), { code: 'UNSUPPORTED_PROTOCOL' });
    }
    adapter = balanceAdapter(draft.protocol, draft.baseUrl, draft.balance);
    const auth = adapter === 'custom' ? draft.balance!.auth! : adapter === 'zhipu' ? 'raw' : 'bearer';
    const key = auth === 'none' ? '' : await balanceDraftKey(draft, profiles);
    const root = serviceRoot(draft.protocol, draft.baseUrl);
    const site = root.replace(/\/v1(?:beta)?$/, '');
    let result: ProviderBalance;
    if (adapter === 'deepseek') {
      result = parseDeepSeekBalance(await getBalanceJson('https://api.deepseek.com/user/balance', key, auth));
    } else if (adapter === 'sub2api') {
      result = parseSub2ApiBalance(await getBalanceJson(site + '/v1/usage', key, auth));
    } else if (adapter === 'newapi' || adapter === 'newapi-account') {
      const account = adapter === 'newapi-account';
      const usage = await getBalanceJson(site + (account ? '/api/user/self' : '/api/usage/token/'), key, auth,
        account ? draft.balance!.userId : undefined);
      // Public station metadata controls the unit conversion; never guess a divisor.
      const status = await getBalanceJson(site + '/api/status', '', 'none');
      result = account ? parseNewApiAccountBalance(usage, status, draft.balance!.userId!) : parseNewApiBalance(usage, status);
    } else if (adapter === 'zhipu') {
      result = parseZhipuBalance(await getBalanceJson('https://open.bigmodel.cn/api/biz/account/query-customer-account-report', key, auth));
    } else {
      const origin = root.match(/^https:\/\/[^/]+/)![0];
      result = parseCustomBalance(await getBalanceJson(origin + draft.balance!.path!, key, auth), draft.balance!);
    }
    Diagnostics.log('info', 'provider', 'balance_completed', { balanceAdapter: adapter, count: result.amounts.length, elapsedMs: Date.now() - started });
    return result;
  } catch (error) {
    const failure = contextualError(t('查询账户余额失败'), 'balance', error as Error);
    Diagnostics.log('error', 'provider', 'balance_failed', { protocol: draft.protocol, balanceAdapter: adapter, elapsedMs: Date.now() - started }, failure);
    throw failure;
  }
}
