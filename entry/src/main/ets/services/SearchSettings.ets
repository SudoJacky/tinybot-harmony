import { AppData } from '../model/Conversation';
import { defaultProductivity } from '../model/Productivity';
import { defaultAssistantOptions } from '../model/AssistantOptions';
import { SearchConfig, SearchDraft, validateSearchConfig, deepSeekSearchProfile, searchCredentialAlias } from '../model/WebSearch';
import { t } from '../model/I18n';
import { CredentialVault } from './ProfileSettings';

export async function saveSearchSettings(data: AppData, draft: SearchDraft, credentials: CredentialVault,
  createId: () => string, commit: (data: AppData) => Promise<void>): Promise<string> {
  const productivity = data.productivity || defaultProductivity(); const options = productivity.options || defaultAssistantOptions();
  const previous = options.search; const key = draft.apiKey.trim();
  const config: SearchConfig = previous?.provider === draft.provider ? JSON.parse(JSON.stringify(previous)) as SearchConfig :
    { provider: draft.provider, enabled: draft.enabled };
  config.enabled = draft.enabled;
  if (draft.provider === 'bing-browser') {
    if (key || draft.baseUrl.trim() || draft.modelProviderId) { throw new Error('Built-in Bing search does not use API credentials or a custom endpoint.'); }
  } else if (draft.provider === 'deepseek') {
    if (key) { throw new Error(t('DeepSeek 搜索复用模型服务密钥，无需填写独立密钥。')); }
    config.modelProviderId = draft.enabled ? deepSeekSearchProfile(data.providerProfiles || [], draft.modelProviderId).id : draft.modelProviderId;
  } else {
    config.baseUrl = draft.baseUrl.trim().replace(/\/+$/, '');
    const sameEndpoint = previous?.provider === 'tavily' && previous.baseUrl === config.baseUrl;
    config.credentialAlias = key ? 'pending-key' : sameEndpoint ? previous.credentialAlias : '';
  }
  if (draft.enabled && draft.provider === 'tavily' && !config.credentialAlias) { throw new Error('请填写搜索 API Key；更换搜索地址后需要重新填写。'); }
  validateSearchConfig(config);
  if (draft.enabled && draft.provider !== 'bing-browser' && !key) {
    const savedKey = await credentials.read(searchCredentialAlias(config, data.providerProfiles || []));
    if (!savedKey.trim()) { throw new Error(t('API Key 为空，请在对应服务中重新配置。')); }
  }
  let created = '';
  try {
    if (key) { created = 'tinybot-search-' + createId(); await credentials.write(created, key); config.credentialAlias = created; }
    options.search = config; productivity.options = options; data.productivity = productivity; await commit(data);
  } catch (error) {
    if (created) { await credentials.remove(created); }
    throw error as Error;
  }
  if (previous?.provider === 'tavily' && previous.credentialAlias && previous.credentialAlias !== config.credentialAlias) {
    try { await credentials.remove(previous.credentialAlias); }
    catch (_) { return '搜索设置已保存，但旧密钥清理失败。'; }
  }
  return '';
}
