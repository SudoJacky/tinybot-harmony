import { t } from '../model/I18n';
import { DetailedError } from '../model/DetailedError';
import { BalanceSettings } from '../model/BalanceSettings';

export interface BalanceAmount {
  currency: string;
  total?: string; // Remaining amount; absent for an unlimited or undisclosed allowance.
  granted?: string;
  toppedUp?: string;
  label: string;
  kind: string;
  used?: string;
  limit?: string;
  unlimited?: boolean;
  resetAt?: string;
}
export interface ProviderBalance {
  available?: boolean; // Only set when the upstream explicitly reports availability.
  amounts: BalanceAmount[];
  checkedAt: number;
  notice?: string;
}

export function invalidBalance(field: string): DetailedError {
  return new DetailedError(t('服务返回的余额数据格式无效。') + ' [' + field + ']', { code: 'INVALID_RESPONSE', stage: 'parse' });
}

function record(value: Object | undefined, field: string): Record<string, Object> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw invalidBalance(field); }
  return value as Record<string, Object>;
}

function numeric(value: Object | undefined, field: string): number {
  if ((typeof value !== 'number' && (typeof value !== 'string' || value.length > 64 ||
    !/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(value))) || !Number.isFinite(Number(value))) {
    throw invalidBalance(field);
  }
  return Number(value);
}

function amount(value: Object | undefined, field: string, divisor: number = 1): string {
  const result = numeric(value, field) / divisor;
  if (!Number.isFinite(result)) { throw invalidBalance(field); }
  return divisor === 1 && typeof value === 'string' ? value : String(result);
}

function nonnegative(value: Object | undefined, field: string): number {
  const number = numeric(value, field);
  if (number < 0) { throw invalidBalance(field); }
  return number;
}

function result(rows: BalanceAmount[], notice?: string): ProviderBalance {
  return { checkedAt: Date.now(), amounts: rows, notice: notice };
}

function requireSuccess(value: Object | undefined): void {
  if (value === false) {
    throw new DetailedError(t('服务拒绝了余额查询，请检查凭据、权限或套餐状态。'), { code: 'REMOTE_ERROR', stage: 'parse' });
  }
  if (value !== true) { throw invalidBalance('success'); }
}

export function parseDeepSeekBalance(body: Object): ProviderBalance {
  const response = record(body, 'response');
  if (typeof response.is_available !== 'boolean' || !Array.isArray(response.balance_infos) || response.balance_infos.length > 2) {
    throw invalidBalance('balance_infos');
  }
  const rows: BalanceAmount[] = [];
  for (const value of response.balance_infos as Object[]) {
    const item = record(value, 'balance_infos');
    if (!['CNY', 'USD'].includes(item.currency as string) || rows.some((row) => row.currency === item.currency)) {
      throw invalidBalance('currency');
    }
    rows.push({ currency: item.currency as string, total: amount(item.total_balance, 'total_balance'),
      granted: amount(item.granted_balance, 'granted_balance'), toppedUp: amount(item.topped_up_balance, 'topped_up_balance'),
      label: t('账户余额'), kind: 'account' });
  }
  return { available: response.is_available as boolean, checkedAt: Date.now(), amounts: rows };
}

function optionalDate(value: Object | undefined, field: string): string | undefined {
  if (value === undefined || value === null) { return undefined; }
  if (typeof value !== 'string' || !Number.isFinite(Date.parse(value))) { throw invalidBalance(field); }
  return value;
}

export function parseSub2ApiBalance(body: Object): ProviderBalance {
  const data = record(body, 'response');
  requireSuccess(data.isValid);
  if (data.mode !== 'quota_limited' && data.mode !== 'unrestricted') { throw invalidBalance('mode'); }
  if (data.unit !== undefined && data.unit !== 'USD') { throw invalidBalance('unit'); }
  const rows: BalanceAmount[] = [];
  const notice = data.status === 'expired' ? t('此 API Key 已过期。') :
    data.status === 'quota_exhausted' ? t('此 API Key 的额度已用尽。') : undefined;
  if (data.mode === 'quota_limited') {
    if (data.quota !== undefined) {
      const quota = record(data.quota, 'quota');
      if (quota.unit !== 'USD') { throw invalidBalance('quota.unit'); }
      rows.push({ currency: 'USD', total: String(nonnegative(quota.remaining, 'quota.remaining')),
        used: String(nonnegative(quota.used, 'quota.used')), limit: String(nonnegative(quota.limit, 'quota.limit')),
        label: t('API Key 剩余额度'), kind: 'key' });
    }
    if (data.rate_limits !== undefined) {
      if (!Array.isArray(data.rate_limits) || data.rate_limits.length > 3) { throw invalidBalance('rate_limits'); }
      const windows: string[] = [];
      for (const value of data.rate_limits as Object[]) {
        const window = record(value, 'rate_limits');
        if (!['5h', '1d', '7d'].includes(window.window as string) || windows.includes(window.window as string)) {
          throw invalidBalance('rate_limits.window');
        }
        windows.push(window.window as string);
        rows.push({ currency: 'USD', total: String(nonnegative(window.remaining, 'rate_limits.remaining')),
          used: String(nonnegative(window.used, 'rate_limits.used')), limit: String(nonnegative(window.limit, 'rate_limits.limit')),
          label: window.window === '5h' ? t('5 小时额度') : window.window === '1d' ? t('每日额度') : t('每周额度'),
          kind: 'window', resetAt: optionalDate(window.reset_at, 'rate_limits.reset_at') });
      }
    }
  } else if (data.balance !== undefined) {
    rows.push({ currency: 'USD', total: amount(data.balance, 'balance'), label: t('账户余额'), kind: 'account' });
  } else {
    if (data.subscription !== undefined) {
      const subscription = record(data.subscription, 'subscription');
      const periods = ['daily', 'weekly', 'monthly'];
      for (const period of periods) {
        const limit = subscription[period + '_limit_usd'];
        if (limit === undefined || limit === null) { continue; }
        const maximum = nonnegative(limit, 'subscription.limit');
        if (maximum === 0) { continue; }
        const used = nonnegative(subscription[period + '_usage_usd'], 'subscription.used');
        rows.push({ currency: 'USD', total: String(Math.max(0, maximum - used)), used: String(used), limit: String(maximum),
          label: period === 'daily' ? t('每日额度') : period === 'weekly' ? t('每周额度') : t('每月额度'), kind: 'subscription' });
      }
    }
    if (rows.length === 0 && data.remaining !== undefined) {
      const remaining = numeric(data.remaining, 'remaining');
      if (remaining < 0 && remaining !== -1) { throw invalidBalance('remaining'); }
      rows.push({ currency: 'USD', total: remaining === -1 ? undefined : String(remaining), unlimited: remaining === -1,
        label: t('订阅剩余额度'), kind: 'subscription' });
    }
  }
  return result(rows, notice);
}

interface QuotaUnit { divisor: number; multiplier: number; unit: string; }

function newApiUnit(body: Object): QuotaUnit {
  const response = record(body, 'status');
  requireSuccess(response.success);
  const data = record(response.data, 'status.data');
  const display = data.quota_display_type;
  if (display === 'TOKENS') { return { divisor: 1, multiplier: 1, unit: t('额度单位') }; }
  const divisor = numeric(data.quota_per_unit, 'quota_per_unit');
  if (divisor <= 0) { throw invalidBalance('quota_per_unit'); }
  if (display === 'USD' || (display === undefined && data.display_in_currency === true)) {
    return { divisor: divisor, multiplier: 1, unit: 'USD' };
  }
  if (display === undefined && data.display_in_currency === false) { return { divisor: 1, multiplier: 1, unit: t('额度单位') }; }
  const multiplier = numeric(display === 'CNY' ? data.usd_exchange_rate : data.custom_currency_exchange_rate, 'exchange_rate');
  const unit = display === 'CNY' ? 'CNY' : data.custom_currency_symbol;
  if (!['CNY', 'CUSTOM'].includes(display as string) || multiplier <= 0 || typeof unit !== 'string' || !unit || unit.length > 16) {
    throw invalidBalance('quota_display_type');
  }
  return { divisor: divisor, multiplier: multiplier, unit: unit };
}

function quotaAmount(value: Object | undefined, field: string, unit: QuotaUnit): string {
  const raw = numeric(value, field);
  if (!Number.isSafeInteger(raw)) { throw invalidBalance(field); }
  const converted = raw / unit.divisor * unit.multiplier;
  if (!Number.isFinite(converted)) { throw invalidBalance(field); }
  // Suppress binary floating-point tails while keeping small quota amounts visible.
  return String(Number(converted.toPrecision(12)));
}

export function parseNewApiBalance(body: Object, status: Object): ProviderBalance {
  const response = record(body, 'response');
  requireSuccess(response.code);
  const data = record(response.data, 'data');
  if (data.object !== 'token_usage' || typeof data.unlimited_quota !== 'boolean') { throw invalidBalance('token_usage'); }
  const unit = newApiUnit(status);
  const unlimited = data.unlimited_quota as boolean;
  const rows: BalanceAmount[] = [{ currency: unit.unit, label: t('API Key 剩余额度'), kind: 'key', unlimited: unlimited,
    total: unlimited ? undefined : quotaAmount(data.total_available, 'total_available', unit),
    limit: unlimited ? undefined : quotaAmount(data.total_granted, 'total_granted', unit),
    used: quotaAmount(data.total_used, 'total_used', unit) }];
  if (data.user_quota !== undefined) {
    const account = record(data.user_quota, 'user_quota');
    rows.push({ currency: unit.unit, label: t('账户余额'), kind: 'account',
      total: quotaAmount(account.total_available, 'user_quota.total_available', unit),
      used: quotaAmount(account.total_used, 'user_quota.total_used', unit) });
  }
  let notice = data.user_quota === undefined ? t('站点未开放账户余额，仅显示此 Key 的额度。') : undefined;
  if (data.expires_at !== undefined) {
    const expires = nonnegative(data.expires_at, 'expires_at');
    if (expires > 0 && expires * 1000 <= Date.now()) { notice = t('此 API Key 已过期。'); }
  }
  return result(rows, notice);
}

export function parseNewApiAccountBalance(body: Object, status: Object, userId: string): ProviderBalance {
  const response = record(body, 'response');
  requireSuccess(response.success);
  const data = record(response.data, 'data');
  if (numeric(data.id, 'id') !== Number(userId)) { throw invalidBalance('id'); }
  const unit = newApiUnit(status);
  return result([{ currency: unit.unit, label: t('账户余额'), kind: 'account',
    total: quotaAmount(data.quota, 'quota', unit), used: quotaAmount(data.used_quota, 'used_quota', unit) }]);
}

export function parseZhipuBalance(body: Object): ProviderBalance {
  const response = record(body, 'response');
  requireSuccess(response.success);
  const data = record(response.data, 'data');
  return result([{ currency: 'CNY', total: amount(data.availableBalance, 'availableBalance'), label: t('账户余额'), kind: 'account' }]);
}

function field(body: Object, path: string): Object | undefined {
  let value: Object | undefined = body;
  for (const part of path.split('.')) {
    if (!value || typeof value !== 'object' || !Object.keys(value).includes(part)) { throw invalidBalance(path); }
    value = (value as Record<string, Object>)[part];
  }
  return value;
}

export function parseCustomBalance(body: Object, settings: BalanceSettings): ProviderBalance {
  record(body, 'response');
  if (settings.successField) { requireSuccess(field(body, settings.successField)); }
  return result([{ currency: settings.unit!, total: amount(field(body, settings.remainingField!), settings.remainingField!, settings.divisor),
    used: settings.usedField ? amount(field(body, settings.usedField), settings.usedField, settings.divisor) : undefined,
    limit: settings.totalField ? amount(field(body, settings.totalField), settings.totalField, settings.divisor) : undefined,
    label: t('自定义余额 / 额度'), kind: 'custom' }]);
}
