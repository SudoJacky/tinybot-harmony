import { t } from '../model/I18n';
import { http } from '@kit.NetworkKit';
import { ProviderDraft } from './ProfileSettings';
import { ProviderProfile } from '../model/ProviderProfiles';
import { CredentialStore } from './CredentialStore';
import { protocolUrl, protocolHeaders, sameCredentialScope } from './providers/WireProtocols';
interface ListedModel { id: string; }
interface ModelList { data: ListedModel[]; }
export async function discoverModels(draft: ProviderDraft, profiles: ProviderProfile[]): Promise<string[]> {
  const endpoint = protocolUrl(draft.protocol, draft.baseUrl, true).replace(/\/(chat\/completions|responses|messages)$/, '/models');
  let key = draft.apiKey.trim();
  if (!draft.noApiKey && !key) {
    const existing = profiles.find((item) => item.id === draft.id);
    if (!existing || !existing.credentialAlias || !sameCredentialScope(existing.protocol, existing.baseUrl, draft.protocol, draft.baseUrl)) {
      throw new Error(t("请先填写此服务的 API Key。"));
    }
    key = await new CredentialStore().read(existing.credentialAlias);
  }
  const request = http.createHttp();
  try {
    const headers = protocolHeaders(draft.protocol, draft.noApiKey ? '' : key); headers['Accept'] = 'application/json';
    const result = await request.request(endpoint, { method: http.RequestMethod.GET, header: headers, usingCache: false,
      connectTimeout: 15000, readTimeout: 30000, maxRedirects: 0, maxLimit: 1024 * 1024, expectDataType: http.HttpDataType.STRING });
    if (result.responseCode !== 200) { throw new Error(t("模型发现 HTTP ") + result.responseCode + t("；可继续手动添加模型 ID。")); }
    const parsed = JSON.parse(result.result as string) as ModelList;
    if (!parsed || !Array.isArray(parsed.data)) { throw new Error(t("服务未返回兼容的模型列表。")); }
    const ids = Array.from(new Set(parsed.data.filter((item) => item && typeof item.id === 'string' && item.id.trim() && item.id.length <= 200).map((item) => item.id.trim()))).slice(0, 200);
    if (!ids.length) { throw new Error(t("服务返回了空模型列表。")); }
    return ids;
  } finally { request.destroy(); }
}
