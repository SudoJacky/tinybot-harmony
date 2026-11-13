import { t } from '../model/I18n';
import { Diagnostics } from '../model/Diagnostics';
import { contextualError } from '../model/DetailedError';
import { AppData, copyModelConfig } from '../model/Conversation';
import { ImageModelSettings, ProviderProfile, modelConfig, modelIds, validateProfile } from '../model/ProviderProfiles';
import { CredentialReader } from './providers/Provider';
import { isSupportedProtocol, sameCredentialScope } from '../model/ProviderEndpoint';
import { mergeSavedConfiguration } from '../model/SavedConfiguration';
import { BalanceSettings, canKeepBalanceCredential, usesBalanceCredential } from '../model/BalanceSettings';

export interface CredentialVault extends CredentialReader {
  readOptional(alias: string): Promise<string | undefined>;
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
  imageModels?: ImageModelDraft | null;
  balance?: BalanceSettings;
  balanceApiKey?: string;
}

export interface ImageModelDraft { protocol: string; baseUrl: string; models: string; }

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
    const balanceKey = draft.balanceApiKey?.trim() || '';
    const separateBalance = usesBalanceCredential(draft.balance);
    if (separateBalance && !balanceKey && (!previous || !canKeepBalanceCredential(previous, draft.protocol, draft.baseUrl, draft.balance))) {
      throw new Error(t('请填写余额查询专用凭据。'));
    }
    const sameScope = previous !== undefined && sameCredentialScope(previous.protocol, previous.baseUrl, draft.protocol, draft.baseUrl);
    if (!draft.noApiKey && key.length === 0 && (!previous?.credentialAlias || !sameScope)) {
      throw new Error(t("请填写 API Key；更换服务基础地址时需要重新填写，其他服务的密钥不会被复用。"));
    }
    const image = draft.imageModels;
    const imageModels = image ? mergeSavedConfiguration<ImageModelSettings>(previous?.imageModels,
      { protocol: image.protocol, baseUrl: image.baseUrl.trim() || undefined, models: modelIds(image.models) }) :
      image === null ? undefined : previous?.imageModels;
    const edited: ProviderProfile = { id: previous?.id || 'provider-' + this.createId(), name: draft.name.trim(),
      presetId: draft.presetId, protocol: draft.protocol, baseUrl: draft.baseUrl.trim().replace(/\/+$/, ''),
      credentialAlias: draft.noApiKey ? '' : key.length > 0 ? 'pending-key' : previous?.credentialAlias || '',
      noApiKey: draft.noApiKey, enabled: draft.enabled, models: modelIds(draft.models), pendingSetup: undefined,
      contextWindow: draft.contextWindow.trim() ? Number(draft.contextWindow) : undefined,
      imageModels: imageModels,
      balance: draft.balance,
      balanceCredentialAlias: separateBalance ? (balanceKey ? 'pending-balance-key' : previous?.balanceCredentialAlias) : undefined };
    const profile = mergeSavedConfiguration(previous, edited);
    validateProfile(profile);
    // An alias can survive a restore/signing change while its secure asset is unavailable.
    // Do not report a successful save when a blank editor would retain a missing key.
    if (!profile.noApiKey && key.length === 0) {
      try { await this.credentials.read(profile.credentialAlias); }
      catch (error) {
        const failure = contextualError(t('读取已保存的 API Key 失败'), 'credential_read', error as Error);
        Diagnostics.log('error', 'configuration', 'save_failed', { credentialScope: 'provider' }, failure);
        throw failure;
      }
    }
    if (separateBalance && !balanceKey) {
      try { await this.credentials.read(profile.balanceCredentialAlias!); }
      catch (error) {
        const failure = contextualError(t('读取余额查询凭据失败'), 'credential_read', error as Error);
        Diagnostics.log('error', 'configuration', 'save_failed', { credentialScope: 'provider' }, failure);
        throw failure;
      }
    }
    const createdAliases: string[] = [];
    let stage = 'save_config';
    try {
      if (!profile.noApiKey && key.length > 0) {
        const createdAlias = 'tinybot-' + this.createId();
        createdAliases.push(createdAlias);
        stage = 'credential_write';
        await this.credentials.write(createdAlias, key);
        stage = 'save_config';
        profile.credentialAlias = createdAlias;
      }
      if (separateBalance && balanceKey) {
        const alias = 'tinybot-balance-' + this.createId();
        createdAliases.push(alias);
        stage = 'credential_write';
        await this.credentials.write(alias, balanceKey);
        profile.balanceCredentialAlias = alias;
        stage = 'save_config';
      }
      data.providerProfiles = previous ? profiles.map((item: ProviderProfile) => item.id === profile.id ? profile : item) : profiles.concat([profile]);
      const chat = isSupportedProtocol(profile.protocol);
      const first = chat && !profiles.some((item) => isSupportedProtocol(item.protocol));
      if ((first || data.config.providerId === profile.id) && profile.enabled && chat) {
        const id = first ? profile.models[0] : data.config.model;
        const reasoning = first ? undefined : data.config.reasoning;
        data.config = profile.models.includes(id) ? modelConfig(data.providerProfiles, { providerId: profile.id, modelId: id }, data.config) :
          copyModelConfig(data.config, false);
        data.config.reasoning = reasoning;
      } else if (data.config.providerId === profile.id) { data.config = copyModelConfig(data.config, false); }
      const active = data.threads.find((item) => item.id === data.activeThreadId);
      if (first && profile.enabled && active && !active.modelRef) { active.modelRef = { providerId: profile.id, modelId: profile.models[0] }; }
      await commit(data);
    } catch (error) {
      const failure = contextualError(stage === 'credential_write' ? t('写入 API Key 失败') : t('保存模型配置失败'), stage, error as Error);
      Diagnostics.log('error', 'configuration', 'save_failed', { credentialScope: 'provider' }, failure);
      for (const createdAlias of createdAliases) {
        try { await this.credentials.remove(createdAlias); }
        catch (cleanupError) {
          const cleanup = contextualError(t('未生效的密钥清理失败'), 'credential_remove', cleanupError as Error);
          Diagnostics.log('error', 'resources', 'credential_rollback_failed', { credentialScope: 'provider' }, cleanup);
          failure.message += '\n' + cleanup.message;
          failure.reason += '\n' + cleanup.message;
        }
      }
      throw failure;
    }
    const obsolete = previous ? [previous.credentialAlias, previous.balanceCredentialAlias || ''].filter((alias) =>
      !!alias && alias !== profile.credentialAlias && alias !== profile.balanceCredentialAlias) : [];
    const warnings: string[] = [];
    for (const alias of obsolete) {
      try { await this.credentials.remove(alias); }
      catch (error) {
        const failure = contextualError(t('模型服务已保存，但旧密钥清理失败'), 'credential_remove', error as Error);
        Diagnostics.log('warn', 'resources', 'credential_cleanup_failed', { credentialScope: 'provider' }, failure);
        warnings.push(failure.message);
      }
    }
    return warnings.join('\n');
  }

  async remove(data: AppData, id: string, commit: (data: AppData) => Promise<void>): Promise<string> {
    const profile = (data.providerProfiles || []).find((item: ProviderProfile) => item.id === id);
    if (!profile) { throw new Error(t("模型服务不存在。")); }
    data.providerProfiles = (data.providerProfiles || []).filter((item: ProviderProfile) => item.id !== id);
    if (data.config.providerId === id) { data.config = copyModelConfig(data.config, false); data.config.credentialAlias = ''; }
    await commit(data);
    const warnings: string[] = [];
    for (const alias of [profile.credentialAlias, profile.balanceCredentialAlias || ''].filter((value) => !!value)) {
      try { await this.credentials.remove(alias); }
      catch (error) {
        const failure = contextualError(t('服务已删除，但密钥清理失败'), 'credential_remove', error as Error);
        Diagnostics.log('warn', 'resources', 'credential_cleanup_failed', { credentialScope: 'provider' }, failure);
        warnings.push(failure.message);
      }
    }
    return warnings.join('\n');
  }
}
