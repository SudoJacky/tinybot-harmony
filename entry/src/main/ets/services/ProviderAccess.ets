import { t } from '../model/I18n';
import { contextualError } from '../model/DetailedError';
import { ProviderProfile } from '../model/ProviderProfiles';
import { sameCredentialScope } from '../model/ProviderEndpoint';
import { ProviderDraft } from './ProfileSettings';
import { CredentialStore } from './CredentialStore';
import { canKeepBalanceCredential, usesBalanceCredential } from '../model/BalanceSettings';

export async function balanceDraftKey(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<string> {
  if (!usesBalanceCredential(draft.balance)) {
    if (draft.noApiKey) { throw new Error(t('查询余额需要 API Key。')); }
    return providerDraftKey(draft, profiles);
  }
  if (draft.balanceApiKey?.trim()) { return draft.balanceApiKey.trim(); }
  const existing = profiles.find((item) => item.id === draft.id);
  if (!existing || !canKeepBalanceCredential(existing, draft.protocol, draft.baseUrl, draft.balance)) { throw new Error(t('请填写余额查询专用凭据。')); }
  try { return await new CredentialStore().read(existing.balanceCredentialAlias!); }
  catch (error) { throw contextualError(t('读取余额查询凭据失败'), 'credential_read', error as Error); }
}

export async function providerDraftKey(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<string> {
  if (draft.noApiKey) { return ''; }
  if (draft.apiKey.trim()) { return draft.apiKey.trim(); }
  const existing = profiles.find((item) => item.id === draft.id);
  if (!existing || !existing.credentialAlias || !sameCredentialScope(existing.protocol, existing.baseUrl, draft.protocol, draft.baseUrl)) {
    throw new Error(t('请先填写此服务的 API Key。'));
  }
  try { return await new CredentialStore().read(existing.credentialAlias); }
  catch (error) { throw contextualError(t('读取已保存的 API Key 失败'), 'credential_read', error as Error); }
}
