import { t } from '../model/I18n';
import { ProviderDraft } from './ProfileSettings';
import { ProviderProfile } from '../model/ProviderProfiles';
import { CredentialStore } from './CredentialStore';
import { protocolUrl, protocolHeaders, sameCredentialScope } from './providers/WireProtocols';
import { CompatHttp } from './CompatHttp';
interface ListedModel { id: string; }
interface ModelList { data: ListedModel[]; }
interface GeminiListedModel { name: string; supportedGenerationMethods: string[]; }
interface GeminiModelList { models?: GeminiListedModel[]; nextPageToken?: string; }

// Discovery sends the provider API key, so a redirect is refused on every supported system.
async function discoverPage(url: string, headers: Record<string, string>): Promise<string> {
  const response = await CompatHttp.request({
    url: url, method: 'GET', headers: headers, connectTimeout: 15000, readTimeout: 30000,
    maxBytes: 1024 * 1024, dataType: 'string', redirect: 'refuse'
  });
  if (response.status !== 200) { throw new Error(t('模型发现 HTTP ') + response.status + t('；可继续手动添加模型 ID。')); }
  return response.text;
}

export async function discoverModels(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<string[]> {
  const root = protocolUrl(draft.protocol, draft.baseUrl, true);
  const endpoint = draft.protocol === 'gemini' ? root + '/models?pageSize=1000' : root.replace(/\/(chat\/completions|responses|messages)$/, '/models');
  let key = draft.apiKey.trim();
  if (!draft.noApiKey && !key) {
    const existing = profiles.find((item) => item.id === draft.id);
    if (!existing || !existing.credentialAlias || !sameCredentialScope(existing.protocol, existing.baseUrl, draft.protocol, draft.baseUrl)) {
      throw new Error(t("请先填写此服务的 API Key。"));
    }
    key = await new CredentialStore().read(existing.credentialAlias);
  }
  const headers = protocolHeaders(draft.protocol, draft.noApiKey ? '' : key); headers['Accept'] = 'application/json';
  if (draft.protocol === 'gemini') {
    const ids: Set<string> = new Set<string>(); const pages: Set<string> = new Set<string>();
    let pageToken = '';
    do {
      const url = endpoint + (pageToken ? '&pageToken=' + encodeURIComponent(pageToken) : '');
      const parsed = JSON.parse(await discoverPage(url, headers)) as GeminiModelList;
      if (!parsed || (parsed.models !== undefined && !Array.isArray(parsed.models)) ||
        (parsed.nextPageToken !== undefined && typeof parsed.nextPageToken !== 'string')) { throw new Error(t('服务未返回兼容的模型列表。')); }
      for (const item of parsed.models || []) {
        if (item && typeof item.name === 'string' && /^models\/[A-Za-z0-9][A-Za-z0-9._-]{0,199}$/.test(item.name) &&
          Array.isArray(item.supportedGenerationMethods) && item.supportedGenerationMethods.includes('generateContent')) {
          ids.add(item.name.slice(7));
        }
      }
      pageToken = parsed.nextPageToken || '';
      if (pageToken && pages.has(pageToken)) { throw new Error(t('服务未返回兼容的模型列表。')); }
      pages.add(pageToken);
    } while (pageToken && ids.size < 200);
    if (!ids.size) { throw new Error(t('服务返回了空模型列表。')); }
    return Array.from(ids).slice(0, 200);
  }
  const parsed = JSON.parse(await discoverPage(endpoint, headers)) as ModelList;
  if (!parsed || !Array.isArray(parsed.data)) { throw new Error(t("服务未返回兼容的模型列表。")); }
  const ids = Array.from(new Set(parsed.data.filter((item) => item && typeof item.id === 'string' && item.id.trim() && item.id.length <= 200).map((item) => item.id.trim()))).slice(0, 200);
  if (!ids.length) { throw new Error(t("服务返回了空模型列表。")); }
  return ids;
}
