import { t } from '../model/I18n';
import { contextualError } from '../model/DetailedError';
import { ProviderProfile } from '../model/ProviderProfiles';
import { sameCredentialScope } from '../model/ProviderEndpoint';
import { ProviderDraft } from './ProfileSettings';
import { CredentialStore } from './CredentialStore';

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
