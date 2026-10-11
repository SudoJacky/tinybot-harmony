import { ProviderProfile } from './ProviderProfiles';
export type SearchProviderId = 'deepseek' | 'tavily';
export interface SearchConfig { provider: SearchProviderId; enabled: boolean; baseUrl: string; model: string; credentialAlias: string; modelProviderId?: string; }
export interface SearchDraft { provider: SearchProviderId; enabled: boolean; baseUrl: string; model: string; apiKey: string; credentialSource: string; }
export interface SearchSource { url: string; title: string; snippet: string; publishedAt?: string; }
export interface SearchResult { sources: SearchSource[]; truncated: boolean; }

export function defaultSearchConfig(provider: SearchProviderId = 'deepseek'): SearchConfig {
  return { provider: provider, enabled: false, baseUrl: provider === 'deepseek' ? 'https://api.deepseek.com/anthropic/v1' : 'https://api.tavily.com',
    model: provider === 'deepseek' ? 'deepseek-v4-flash' : '', credentialAlias: '' };
}
export function validateSearchConfig(config: SearchConfig): void {
  if (!config || !['deepseek', 'tavily'].includes(config.provider) || typeof config.enabled !== 'boolean' || typeof config.baseUrl !== 'string' || config.baseUrl.length > 2048 ||
    !/^https:\/\/[^\s/?#@\\]+(?:\/[^\s?#\\]*)?$/.test(config.baseUrl) || typeof config.model !== 'string' ||
    (config.provider === 'deepseek' && !config.model.trim()) || config.model.length > 200 || typeof config.credentialAlias !== 'string' ||
    config.credentialAlias.length > 200 || (config.modelProviderId !== undefined && (config.provider !== 'deepseek' || typeof config.modelProviderId !== 'string' || !config.modelProviderId || config.modelProviderId.length > 64 || !!config.credentialAlias)) ||
    (config.enabled && !config.credentialAlias && !config.modelProviderId)) { throw new Error('Invalid search settings.'); }
}
function origin(address: string): string {
  return /^https:\/\/([^\s/?#@\\]+)/i.exec(address)?.[1].toLowerCase().replace(/:443$/, '') || '';
}
export function reusableSearchProfiles(config: SearchConfig, profiles: ProviderProfile[]): ProviderProfile[] {
  const host = origin(config.baseUrl);
  return config.provider === 'deepseek' && host ? profiles.filter((profile) => profile.enabled && !profile.noApiKey &&
    (profile.presetId === 'deepseek' || host === 'api.deepseek.com') && !!profile.credentialAlias && origin(profile.baseUrl) === host) : [];
}
// Resolve the live alias at dispatch, so rotation/removal cannot leave a stale copied key.
export function searchCredentialAlias(config: SearchConfig, profiles: ProviderProfile[]): string {
  if (!config.modelProviderId) { return config.credentialAlias; }
  const profile = reusableSearchProfiles(config, profiles).find((item) => item.id === config.modelProviderId);
  if (!profile) { throw new Error('复用的模型服务已停用、删除或地址不匹配，请检查联网搜索设置。'); }
  return profile.credentialAlias;
}
