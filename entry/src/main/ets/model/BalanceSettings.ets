import { t } from './I18n';
import { sameCredentialScope } from './ProviderEndpoint';
import { ProviderProfile } from './ProviderProfiles';

// Secrets live in AssetStore; this configuration only selects their source.
export interface BalanceSettings {
  mode: string;
  path?: string;
  remainingField?: string;
  totalField?: string;
  usedField?: string;
  successField?: string;
  unit?: string;
  divisor?: number;
  auth?: string;
  credential?: string;
  userId?: string;
}

export const BALANCE_MODES: string[] = ['auto', 'off', 'sub2api', 'newapi', 'newapi-account', 'zhipu', 'custom'];
export const BALANCE_AUTH: string[] = ['bearer', 'api-key', 'raw', 'none'];

export function usesBalanceCredential(value?: BalanceSettings): boolean {
  return value?.mode !== 'off' && !(value?.mode === 'custom' && value.auth === 'none') &&
    (value?.credential === 'separate' || value?.mode === 'newapi-account');
}

export function balanceCredentialScope(value?: BalanceSettings): string {
  return JSON.stringify([value?.mode || 'auto', value?.auth || 'bearer', value?.userId || '', value?.path || '']);
}

export function canKeepBalanceCredential(profile: ProviderProfile, protocol: string, baseUrl: string, balance?: BalanceSettings): boolean {
  return !!profile.balanceCredentialAlias && usesBalanceCredential(profile.balance) && usesBalanceCredential(balance) &&
    sameCredentialScope(profile.protocol, profile.baseUrl, protocol, baseUrl) &&
    balanceCredentialScope(profile.balance) === balanceCredentialScope(balance);
}

export function validateBalanceSettings(value: BalanceSettings | undefined): void {
  if (value === undefined) { return; }
  if (!value || !BALANCE_MODES.includes(value.mode)) { throw new Error(t('余额查询方式无效。')); }
  if (value.credential !== undefined && !['provider', 'separate'].includes(value.credential)) {
    throw new Error(t('余额查询凭据来源无效。'));
  }
  if (value.mode === 'newapi-account' && (typeof value.userId !== 'string' || !/^[1-9]\d{0,15}$/.test(value.userId) ||
    !Number.isSafeInteger(Number(value.userId)))) { throw new Error(t('请填写 New API 的数字用户 ID。')); }
  if (value.mode !== 'custom') { return; }
  // Origin-relative paths only: no alternate host, URL credentials, queries or encoded traversal.
  if (typeof value.path !== 'string' || value.path.length > 512 ||
    !/^\/(?:[a-zA-Z0-9_-]+\/?)+$/.test(value.path)) {
    throw new Error(t('查询路径需以 / 开头，仅包含字母、数字、下划线、短横线和斜杠。'));
  }
  const fields = [value.remainingField, value.totalField, value.usedField, value.successField];
  if (!value.remainingField || fields.some((field) => field !== undefined &&
    (typeof field !== 'string' || field.length > 160 || !/^[a-zA-Z_][a-zA-Z0-9_]*(\.(?:[a-zA-Z_][a-zA-Z0-9_]*|\d+))*$/.test(field) ||
      field.split('.').some((part) => ['__proto__', 'prototype', 'constructor'].includes(part))))) {
    throw new Error(t('余额字段路径无效，请使用 data.balance 或 data.0.balance 这样的格式。'));
  }
  if (typeof value.unit !== 'string' || !value.unit.trim() || value.unit.length > 16 || /[\x00-\x1f\x7f]/.test(value.unit) ||
    typeof value.divisor !== 'number' || !Number.isFinite(value.divisor) || value.divisor <= 0 ||
    !BALANCE_AUTH.includes(value.auth || '')) {
    throw new Error(t('请填写余额单位、正数换算除数和认证方式。'));
  }
}
