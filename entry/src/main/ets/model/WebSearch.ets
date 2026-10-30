import { ProviderProfile } from './ProviderProfiles';
import { t } from './I18n';
import { isConfigurationName } from './ConfigurationValue';
// Official Search API; the account key is reused from a DeepSeek model provider.
export const DEEPSEEK_SEARCH_BASE_URL: string = 'https://api.deepseek.com/v1';
export const DEEPSEEK_SEARCH_ENDPOINT: string = DEEPSEEK_SEARCH_BASE_URL + '/tools/search';
export const SEARCH_REQUEST_MODEL: string = 'search';
export type SearchProviderId = 'deepseek' | 'tavily' | 'searxng' | 'bing-browser';
export interface TavilySettings { baseUrl: string; credentialAlias: string; }
export interface SearXngSettings { baseUrl: string; }
export interface DeepSeekSearchSettings { modelProviderId?: string; }
export interface SearchConfig {
  provider: string; enabled: boolean; baseUrl?: string; credentialAlias?: string; modelProviderId?: string;
  // Keep inactive providers configured; the fields above describe the active provider for older versions.
  tavily?: TavilySettings; deepseek?: DeepSeekSearchSettings; searxng?: SearXngSettings;
}
export interface TavilyDraft { baseUrl: string; apiKey: string; clearKey?: boolean; }
export interface SearchDraft {
  provider: SearchProviderId; enabled: boolean; baseUrl: string; apiKey: string; modelProviderId?: string;
  clearKey?: boolean; tavily?: TavilyDraft; deepseek?: DeepSeekSearchSettings; searxng?: SearXngSettings;
}
export interface SearchSource { url: string; title: string; snippet: string; publishedAt?: string; }
export interface SearchResult { sources: SearchSource[]; warnings?: string[]; }

// Bing is usable immediately; other providers need credentials or an instance URL first.
export function defaultSearchConfig(provider: SearchProviderId = 'bing-browser'): SearchConfig {
  if (provider === 'searxng') { return { provider: provider, enabled: false, baseUrl: '' }; }
  return provider !== 'tavily' ? { provider: provider, enabled: provider === 'bing-browser' } :
    { provider: provider, enabled: false, baseUrl: 'https://api.tavily.com', credentialAlias: '' };
}
export function isSupportedSearchProvider(provider: string): boolean { return ['deepseek', 'tavily', 'searxng', 'bing-browser'].includes(provider); }
export function isSearXngBaseUrl(value: string): boolean {
  return value.length <= 2048 && /^https?:\/\/[^\s/?#@\\]+(?:\/[^\s?#\\]*)?$/.test(value);
}
export function validateSearchConfig(config: SearchConfig, stored: boolean = false): void {
  if (!config || !isConfigurationName(config.provider) || typeof config.enabled !== 'boolean' ||
    (!stored && !isSupportedSearchProvider(config.provider)) ||
    (config.baseUrl !== undefined && (typeof config.baseUrl !== 'string' || config.baseUrl.length > 2048)) ||
    (config.credentialAlias !== undefined && (typeof config.credentialAlias !== 'string' || config.credentialAlias.length > 200)) ||
    (config.modelProviderId !== undefined && (typeof config.modelProviderId !== 'string' || !config.modelProviderId || config.modelProviderId.length > 64))) {
    throw new Error('Invalid search settings.');
  }
  if (config.tavily !== undefined) {
    validateSearchConfig({ provider: 'tavily', enabled: false, baseUrl: config.tavily?.baseUrl, credentialAlias: config.tavily?.credentialAlias });
  }
  if (config.searxng !== undefined && (!config.searxng || typeof config.searxng !== 'object' || Array.isArray(config.searxng) ||
    typeof config.searxng.baseUrl !== 'string' || (config.searxng.baseUrl !== '' && !isSearXngBaseUrl(config.searxng.baseUrl)))) {
    throw new Error('Invalid SearXNG search settings.');
  }
  if (config.deepseek !== undefined && (!config.deepseek || typeof config.deepseek !== 'object' || Array.isArray(config.deepseek) || (config.deepseek.modelProviderId !== undefined &&
    (typeof config.deepseek.modelProviderId !== 'string' || !config.deepseek.modelProviderId || config.deepseek.modelProviderId.length > 64)))) {
    throw new Error('Invalid DeepSeek search settings.');
  }
  if (!isSupportedSearchProvider(config.provider)) { return; }
  if (config.provider === 'bing-browser') {
    if (config.baseUrl !== undefined || config.credentialAlias !== undefined || config.modelProviderId !== undefined) {
      throw new Error('Built-in Bing search does not use API credentials or a custom endpoint.');
    }
  } else if (config.provider === 'searxng') {
    if (config.credentialAlias !== undefined || config.modelProviderId !== undefined || typeof config.baseUrl !== 'string' ||
      ((config.enabled || config.baseUrl !== '') && !isSearXngBaseUrl(config.baseUrl))) {
      throw new Error(t('请填写有效的 SearXNG 实例地址（HTTP 或 HTTPS，不含查询参数）。'));
    }
  } else if (config.provider === 'deepseek') {
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
  validateSearchConfig(config);
  if (config.provider === 'bing-browser') { throw new Error('Built-in Bing search does not use API credentials.'); }
  if (config.provider === 'searxng') { throw new Error('SearXNG search does not use API credentials.'); }
  return config.provider === 'deepseek' ? deepSeekSearchProfile(profiles, config.modelProviderId).credentialAlias : config.credentialAlias!;
}
