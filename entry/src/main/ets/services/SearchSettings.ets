import { AppData } from '../model/Conversation';
import { defaultProductivity } from '../model/Productivity';
import { defaultAssistantOptions } from '../model/AssistantOptions';
import { SearchConfig, SearchDraft, validateSearchConfig, reusableSearchProfiles, searchCredentialAlias } from '../model/WebSearch';
import { CredentialVault } from './ProfileSettings';

export async function saveSearchSettings(data: AppData, draft: SearchDraft, credentials: CredentialVault,
  createId: () => string, commit: (data: AppData) => Promise<void>): Promise<string> {
  const productivity = data.productivity || defaultProductivity(); const options = productivity.options || defaultAssistantOptions();
  const previous = options.search; const key = draft.apiKey.trim();
  const baseUrl = draft.baseUrl.trim().replace(/\/+$/, '');
  const sameEndpoint = previous?.baseUrl === baseUrl && previous.provider === draft.provider;
  const config: SearchConfig = { provider: draft.provider, enabled: draft.enabled, baseUrl: baseUrl, model: draft.model.trim(),
    credentialAlias: key ? 'pending-key' : sameEndpoint ? previous?.credentialAlias || '' : '' };
  if (draft.credentialSource !== 'custom') {
    if (key) { throw new Error('复用模型服务密钥时无需填写独立密钥。'); }
    const candidates = reusableSearchProfiles(config, data.providerProfiles || []);
    const source = draft.credentialSource === 'auto' ? (candidates.length === 1 ? candidates[0] : undefined) : candidates.find((item) => item.id === draft.credentialSource);
    if (draft.enabled && !source) { throw new Error(candidates.length > 1 ? '请选择要复用密钥的模型服务。' : '没有地址匹配的可用模型密钥，请配置独立搜索密钥。'); }
    config.modelProviderId = source?.id; config.credentialAlias = '';
  }
  if (draft.enabled && !config.credentialAlias && !config.modelProviderId) { throw new Error('请填写搜索 API Key；更换搜索地址后需要重新填写。'); }
  validateSearchConfig(config);
  if (draft.enabled && !key) { await credentials.read(searchCredentialAlias(config, data.providerProfiles || [])); }
  let created = '';
  try {
    if (key) { created = 'tinybot-search-' + createId(); await credentials.write(created, key); config.credentialAlias = created; }
    options.search = config; productivity.options = options; data.productivity = productivity; await commit(data);
  } catch (error) {
    if (created) { await credentials.remove(created); }
    throw error as Error;
  }
  if (previous?.credentialAlias && previous.credentialAlias !== config.credentialAlias) {
    try { await credentials.remove(previous.credentialAlias); }
    catch (_) { return '搜索设置已保存，但旧密钥清理失败。'; }
  }
  return '';
}
