import { ProviderProfile } from './ProviderProfiles';
import { t } from './I18n';
// Official Search API; the account key is reused from a DeepSeek model provider.
export const DEEPSEEK_SEARCH_BASE_URL: string = 'https://api.deepseek.com/v1';
export const DEEPSEEK_SEARCH_ENDPOINT: string = DEEPSEEK_SEARCH_BASE_URL + '/tools/search';
export const SEARCH_REQUEST_MODEL: string = 'search';
export type SearchProviderId = 'deepseek' | 'tavily';
export interface SearchConfig { provider: SearchProviderId; enabled: boolean; baseUrl?: string; credentialAlias?: string; modelProviderId?: string; }
export interface SearchDraft { provider: SearchProviderId; enabled: boolean; baseUrl: string; apiKey: string; modelProviderId?: string; }
export interface SearchSource { url: string; title: string; snippet: string; publishedAt?: string; }
export interface SearchResult { sources: SearchSource[]; }

export function defaultSearchConfig(provider: SearchProviderId = 'deepseek'): SearchConfig {
  return provider === 'deepseek' ? { provider: provider, enabled: false } :
    { provider: provider, enabled: false, baseUrl: 'https://api.tavily.com', credentialAlias: '' };
}
export function validateSearchConfig(config: SearchConfig): void {
  if (!config || !['deepseek', 'tavily'].includes(config.provider) || typeof config.enabled !== 'boolean') {
    throw new Error('Invalid search settings.');
  }
  if (config.provider === 'deepseek') {
    if (config.baseUrl !== undefined || config.credentialAlias !== undefined ||
      (config.enabled && !config.modelProviderId) || (config.modelProviderId !== undefined &&
      (typeof config.modelProviderId !== 'string' || !config.modelProviderId || config.modelProviderId.length > 64))) {
      throw new Error('Invalid DeepSeek search settings.');
    }
  } else if (config.modelProviderId !== undefined || typeof config.baseUrl !== 'string' || config.baseUrl.length > 2048 ||
    !/^https:\/\/[^\s/?#@\\]+(?:\/[^\s?#\\]*)?$/.test(config.baseUrl) || typeof config.credentialAlias !== 'string' ||
    config.credentialAlias.length > 200 || (config.enabled && !config.credentialAlias)) {
    throw new Error('Invalid Tavily search settings.');
  }
}
function origin(address: string): string {
  return /^https:\/\/([^\s/?#@\\]+)/i.exec(address)?.[1].toLowerCase().replace(/:443$/, '') || '';
}
export function deepSeekSearchProfiles(profiles: ProviderProfile[]): ProviderProfile[] {
  return profiles.filter((profile) => profile.enabled && !profile.noApiKey && !!profile.credentialAlias &&
    origin(profile.baseUrl) === 'api.deepseek.com');
}
export function deepSeekSearchProfile(profiles: ProviderProfile[], selectedId?: string): ProviderProfile {
  const candidates = deepSeekSearchProfiles(profiles);
  if (selectedId) {
    const selected = candidates.find((item) => item.id === selectedId);
    if (!selected) { throw new Error(t('所选 DeepSeek 服务已停用、删除或不再使用官方地址，请在联网搜索中重新选择。')); }
    return selected;
  }
  if (!candidates.length) { throw new Error(t('请先在设置中添加并启用 DeepSeek 官方模型服务，配置 API Key。')); }
  if (candidates.length > 1) { throw new Error(t('请选择用于联网搜索的 DeepSeek 服务。')); }
  return candidates[0];
}
// Resolve the live alias at dispatch, so rotation/removal cannot leave a stale copied key.
export function searchCredentialAlias(config: SearchConfig, profiles: ProviderProfile[]): string {
  return config.provider === 'deepseek' ? deepSeekSearchProfile(profiles, config.modelProviderId).credentialAlias : config.credentialAlias!;
}
