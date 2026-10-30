import { AppData } from '../model/Conversation';
import { Diagnostics } from '../model/Diagnostics';
import { ProductivityData, defaultProductivity } from '../model/Productivity';
import { defaultAssistantOptions } from '../model/AssistantOptions';
import { SearchConfig, SearchDraft, TavilySettings, validateSearchConfig, deepSeekSearchProfile, searchCredentialAlias } from '../model/WebSearch';
import { t } from '../model/I18n';
import { CredentialVault } from './ProfileSettings';

export async function saveSearchSettings(data: AppData, draft: SearchDraft, credentials: CredentialVault,
  createId: () => string, commit: (data: AppData) => Promise<void>): Promise<string> {
  const productivity = JSON.parse(JSON.stringify(data.productivity || defaultProductivity())) as ProductivityData;
  const options = productivity.options || defaultAssistantOptions();
  const previous = options.search;
  let retained: TavilySettings | undefined = previous?.tavily;
  if (previous?.provider === 'tavily') {
    retained = retained ? JSON.parse(JSON.stringify(retained)) as TavilySettings : { baseUrl: '', credentialAlias: '' };
    retained.baseUrl = previous.baseUrl!; retained.credentialAlias = previous.credentialAlias!;
  }
  const tavilyDraft = draft.tavily || (draft.provider === 'tavily' ?
    { baseUrl: draft.baseUrl, apiKey: draft.apiKey, clearKey: draft.clearKey } : undefined);
  const key = (tavilyDraft?.apiKey || '').trim();
  if (key && tavilyDraft?.clearKey) { throw new Error(t('不能同时替换和清除搜索密钥。')); }
  // Clone to retain unknown fields; clear only the known active-provider bindings.
  const config: SearchConfig = previous ? JSON.parse(JSON.stringify(previous)) as SearchConfig : { provider: draft.provider, enabled: draft.enabled };
  config.provider = draft.provider; config.enabled = draft.enabled;
  config.baseUrl = undefined; config.credentialAlias = undefined; config.modelProviderId = undefined;
  config.tavily = retained;
  if (previous?.provider === 'deepseek' || draft.deepseek) {
    config.deepseek = config.deepseek || {};
    config.deepseek.modelProviderId = draft.deepseek ? draft.deepseek.modelProviderId : previous?.modelProviderId;
  }
  if (tavilyDraft) {
    const baseUrl = tavilyDraft.baseUrl.trim().replace(/\/+$/, '');
    const tavily: TavilySettings = config.tavily ? JSON.parse(JSON.stringify(config.tavily)) as TavilySettings : { baseUrl: baseUrl, credentialAlias: '' };
    tavily.baseUrl = baseUrl;
    tavily.credentialAlias = key ? 'pending-key' : !tavilyDraft.clearKey && retained?.baseUrl === baseUrl ? retained.credentialAlias : '';
    config.tavily = tavily;
  }
  if (draft.provider === 'bing-browser') {
    if (draft.apiKey.trim() || draft.baseUrl.trim() || draft.modelProviderId) { throw new Error('Built-in Bing search does not use API credentials or a custom endpoint.'); }
  } else if (draft.provider === 'deepseek') {
    if (draft.apiKey.trim()) { throw new Error(t('DeepSeek 搜索复用模型服务密钥，无需填写独立密钥。')); }
    const source = draft.deepseek?.modelProviderId || draft.modelProviderId;
    config.modelProviderId = draft.enabled ? deepSeekSearchProfile(data.providerProfiles || [], source).id : source;
    config.deepseek = config.deepseek || {}; config.deepseek.modelProviderId = config.modelProviderId;
  } else if (draft.provider === 'tavily') {
    config.baseUrl = config.tavily?.baseUrl; config.credentialAlias = config.tavily?.credentialAlias;
  }
  if (draft.enabled && draft.provider === 'tavily' && !config.credentialAlias) { throw new Error(t('请填写搜索 API Key；更换搜索地址后需要重新填写。')); }
  validateSearchConfig(config);
  if (draft.enabled && draft.provider !== 'bing-browser' && !(draft.provider === 'tavily' && key)) {
    const savedKey = await credentials.read(searchCredentialAlias(config, data.providerProfiles || []));
    if (!savedKey.trim()) { throw new Error(t('API Key 为空，请在对应服务中重新配置。')); }
  }
  let created = '';
  const previousProductivity = data.productivity;
  try {
    if (key) {
      created = 'tinybot-search-' + createId(); await credentials.write(created, key);
      config.tavily!.credentialAlias = created;
      if (config.provider === 'tavily') { config.credentialAlias = created; }
    }
    options.search = config; productivity.options = options; data.productivity = productivity; await commit(data);
  } catch (error) {
    Diagnostics.log('error', 'configuration', 'save_failed', { credentialScope: 'search' }, error as Error);
    data.productivity = previousProductivity;
    if (created) {
      try { await credentials.remove(created); }
      catch (cleanupError) {
        Diagnostics.log('error', 'resources', 'credential_rollback_failed', { credentialScope: 'search' }, cleanupError as Error);
      }
    }
    throw error as Error;
  }
  if (retained?.credentialAlias && retained.credentialAlias !== config.tavily?.credentialAlias) {
    try { await credentials.remove(retained.credentialAlias); }
    catch (error) {
      Diagnostics.log('warn', 'resources', 'credential_cleanup_failed', { credentialScope: 'search' }, error as Error);
      return '搜索设置已保存，但旧密钥清理失败。';
    }
  }
  return '';
}
