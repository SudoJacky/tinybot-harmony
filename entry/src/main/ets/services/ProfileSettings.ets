import { t } from '../model/I18n';
import { AppData, copyModelConfig } from '../model/Conversation';
import { ProviderProfile, modelConfig, modelIds, validateProfile } from '../model/ProviderProfiles';
import { CredentialReader } from './providers/Provider';
import { sameCredentialScope } from './providers/WireProtocols';

export interface CredentialVault extends CredentialReader {
  write(alias: string, secret: string): Promise<void>;
  remove(alias: string): Promise<void>;
}

export interface ProviderDraft {
  id: string;
  name: string;
  presetId?: string;
  protocol: string;
  baseUrl: string;
  apiKey: string;
  noApiKey: boolean;
  enabled: boolean;
  models: string;
  contextWindow: string;
}

// Configuration commits and key lifecycle belong together, outside the editor and runtime.
export class ProfileSettings {
  private credentials: CredentialVault;
  private createId: () => string;
  constructor(credentials: CredentialVault, createId: () => string) {
    this.credentials = credentials;
    this.createId = createId;
  }

  async save(data: AppData, draft: ProviderDraft, commit: (data: AppData) => Promise<void>): Promise<string> {
    const profiles = data.providerProfiles || [];
    const previous = profiles.find((item: ProviderProfile) => item.id === draft.id);
    if (draft.id.length > 0 && !previous) { throw new Error(t("模型服务不存在。")); }
    const key = draft.apiKey.trim();
    const sameScope = previous !== undefined && sameCredentialScope(previous.protocol, previous.baseUrl, draft.protocol, draft.baseUrl);
    if (!draft.noApiKey && key.length === 0 && (!previous?.credentialAlias || !sameScope)) {
      throw new Error(t("请填写 API Key；更换服务基础地址时需要重新填写，其他服务的密钥不会被复用。"));
    }
    const profile: ProviderProfile = { id: previous?.id || 'provider-' + this.createId(), name: draft.name.trim(),
      presetId: draft.presetId, protocol: draft.protocol, baseUrl: draft.baseUrl.trim().replace(/\/+$/, ''),
      credentialAlias: draft.noApiKey ? '' : key.length > 0 ? 'pending-key' : previous?.credentialAlias || '',
      noApiKey: draft.noApiKey, enabled: draft.enabled, models: modelIds(draft.models), contextWindow: Number(draft.contextWindow) };
    validateProfile(profile);
    // An alias can survive a restore/signing change while its secure asset is unavailable.
    // Do not report a successful save when a blank editor would retain a missing key.
    if (!profile.noApiKey && key.length === 0) {
      await this.credentials.read(profile.credentialAlias);
    }
    let createdAlias = '';
    try {
      if (!profile.noApiKey && key.length > 0) {
        createdAlias = 'tinybot-' + this.createId();
        await this.credentials.write(createdAlias, key);
        profile.credentialAlias = createdAlias;
      }
      data.providerProfiles = previous ? profiles.map((item: ProviderProfile) => item.id === profile.id ? profile : item) : profiles.concat([profile]);
      const first = profiles.length === 0;
      if ((first || data.config.providerId === profile.id) && profile.enabled) {
        const id = first ? profile.models[0] : data.config.model;
        data.config = profile.models.includes(id) ? modelConfig(data.providerProfiles, { providerId: profile.id, modelId: id }, data.config) :
          copyModelConfig(data.config, false);
      } else if (data.config.providerId === profile.id) { data.config = copyModelConfig(data.config, false); }
      const active = data.threads.find((item) => item.id === data.activeThreadId);
      if (first && profile.enabled && active && !active.modelRef) { active.modelRef = { providerId: profile.id, modelId: profile.models[0] }; }
      await commit(data);
    } catch (error) {
      let message = '保存模型服务失败：' + (error as Error).message;
      if (createdAlias.length > 0) {
        try { await this.credentials.remove(createdAlias); }
        catch (cleanupError) { message += '；未生效的密钥清理失败：' + (cleanupError as Error).message; }
      }
      throw new Error(message);
    }
    if (previous && previous.credentialAlias !== profile.credentialAlias) {
      try { await this.credentials.remove(previous.credentialAlias); }
      catch (error) { return '模型服务已保存，但旧密钥清理失败：' + (error as Error).message; }
    }
    return '';
  }

  async remove(data: AppData, id: string, commit: (data: AppData) => Promise<void>): Promise<string> {
    const profile = (data.providerProfiles || []).find((item: ProviderProfile) => item.id === id);
    if (!profile) { throw new Error(t("模型服务不存在。")); }
    data.providerProfiles = (data.providerProfiles || []).filter((item: ProviderProfile) => item.id !== id);
    if (data.config.providerId === id) { data.config = copyModelConfig(data.config, false); data.config.credentialAlias = ''; }
    await commit(data);
    try { await this.credentials.remove(profile.credentialAlias); }
    catch (error) { return '服务已删除，但密钥清理失败：' + (error as Error).message; }
    return '';
  }
}
