import { t } from './I18n';
import { ProviderProfile } from './ProviderProfiles';
import { SearchConfig, SearchDraft, SearchProviderId, defaultSearchConfig, deepSeekSearchProfiles, isSupportedSearchProvider, isSearXngBaseUrl } from './WebSearch';

// Only this in-memory draft carries entered secrets. Details return a copy to the list.
export interface SearchEditorDraft {
  provider: string; enabled: boolean; modelProviderId: string;
  baseUrl: string; apiKey: string; savedBaseUrl: string; savedKey: boolean; clearKey: boolean;
  searxngBaseUrl: string;
}
export interface SearchProviderRoute { provider: string; draft: SearchEditorDraft; }

export function searchEditorDraft(saved: SearchConfig = defaultSearchConfig()): SearchEditorDraft {
  const tavily = saved.provider === 'tavily' ? saved : saved.tavily;
  return { provider: saved.provider, enabled: saved.enabled,
    modelProviderId: (saved.provider === 'deepseek' ? saved.modelProviderId : saved.deepseek?.modelProviderId) || '',
    baseUrl: tavily?.baseUrl || 'https://api.tavily.com', apiKey: '', savedBaseUrl: tavily?.baseUrl || '',
    savedKey: !!tavily?.credentialAlias, clearKey: false,
    searxngBaseUrl: (saved.provider === 'searxng' ? saved.baseUrl : saved.searxng?.baseUrl) || '' };
}
export function searchProviderName(provider: string): string {
  return provider === 'deepseek' ? 'DeepSeek' : provider === 'tavily' ? 'Tavily' : provider === 'searxng' ? 'SearXNG' :
    provider === 'bing-browser' ? t('必应（内置浏览器）') : t('未知提供方（当前版本不支持）');
}
export function tavilyKeyReady(draft: SearchEditorDraft): boolean {
  return !draft.clearKey && (!!draft.apiKey.trim() || (draft.savedKey && draft.savedBaseUrl === draft.baseUrl.trim().replace(/\/+$/, '')));
}
export function searchProviderStatus(provider: string, draft: SearchEditorDraft, profiles: ProviderProfile[], browserPolicy: string): string {
  if (provider === 'deepseek') {
    const candidates = deepSeekSearchProfiles(profiles);
    const ready = draft.modelProviderId ? candidates.some((item) => item.id === draft.modelProviderId) : candidates.length === 1;
    return ready ? t('复用官方服务密钥 · 已就绪') : t('复用官方服务密钥 · 未配置');
  }
  if (provider === 'tavily') {
    return tavilyKeyReady(draft) ? t('自定义地址 · 已就绪') : t('自定义地址 · 未填写密钥');
  }
  if (provider === 'bing-browser') {
    return browserPolicy === 'enabled' ? t('无需密钥 · 已就绪') : t('无需密钥 · 需要启用浏览器');
  }
  if (provider === 'searxng') {
    return isSearXngBaseUrl(draft.searxngBaseUrl.trim()) ? t('无需密钥 · 已配置实例') : t('无需密钥 · 未配置实例');
  }
  return t('配置已保留，请选择受支持的提供方或升级应用。');
}
export function searchSettingsSummary(config: SearchConfig = defaultSearchConfig()): string {
  return searchProviderName(config.provider) + ' · ' + (config.enabled ? t('已启用') : t('已停用'));
}
export function searchSaveDraft(draft: SearchEditorDraft): SearchDraft {
  if (!isSupportedSearchProvider(draft.provider)) { throw new Error(t('配置已保留，请选择受支持的提供方或升级应用。')); }
  return { provider: draft.provider as SearchProviderId, enabled: draft.enabled, baseUrl: '', apiKey: '',
    deepseek: { modelProviderId: draft.modelProviderId || undefined },
    searxng: { baseUrl: draft.searxngBaseUrl },
    tavily: { baseUrl: draft.baseUrl, apiKey: draft.apiKey, clearKey: draft.clearKey } };
}
