import { t } from './I18n';
import { ModelConfig } from './Conversation';
import { builtinProviderInfos } from './Provider';
import { contextSettings } from './ContextSettings';
import { isImageProtocol, isProviderProtocol, isSupportedProtocol, protocolUrl, sharedImageBaseUrl } from './ProviderEndpoint';
import { isConfigurationName } from './ConfigurationValue';
import { BalanceSettings, validateBalanceSettings } from './BalanceSettings';

export interface ModelReference {
  providerId: string;
  modelId: string;
}

export interface ImageModelSettings { protocol: string; baseUrl?: string; models: string[]; }
export interface ImageServiceAccess { id: string; name: string; protocol: string; baseUrl: string; credentialAlias: string; }

// An instance is distinct from its preset and wire protocol. Keys stay in AssetStore.
export interface ProviderProfile {
  id: string;
  name: string;
  presetId?: string;
  protocol: string;
  baseUrl: string;
  credentialAlias: string;
  noApiKey: boolean;
  enabled: boolean;
  models: string[];
  imageModels?: ImageModelSettings;
  contextWindow?: number;
  balance?: BalanceSettings;
  balanceCredentialAlias?: string;
  pendingSetup?: boolean;
}

export interface ModelChoice extends ModelReference {
  providerName: string;
}

export function modelIds(value: string): string[] {
  const ids = value.split(/[\n,，]/).map((id: string) => id.trim()).filter((id: string) => id.length > 0);
  if (ids.length === 0 || ids.some((id: string) => id.length > 200) || new Set(ids).size !== ids.length) {
    throw new Error(t("请填写至少一个模型 ID，每行一个或用逗号分隔，不能重复。"));
  }
  return ids;
}

export function validateProfile(profile: ProviderProfile, stored: boolean = false): void {
  if (!profile || typeof profile.id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(profile.id) ||
    typeof profile.name !== 'string' || profile.name.trim().length === 0 || profile.name.length > 80 ||
    !isConfigurationName(profile.protocol) || (!stored && !isProviderProtocol(profile.protocol)) || typeof profile.baseUrl !== 'string' ||
    typeof profile.credentialAlias !== 'string' || typeof profile.noApiKey !== 'boolean' ||
    (profile.pendingSetup !== undefined && (profile.pendingSetup !== true || profile.enabled || !profile.noApiKey)) ||
    (profile.balanceCredentialAlias !== undefined && typeof profile.balanceCredentialAlias !== 'string') ||
    typeof profile.enabled !== 'boolean' || !Array.isArray(profile.models) ||
    profile.models.some((id: string) => typeof id !== 'string' || id.trim() !== id || id.length === 0) ||
    (profile.noApiKey ? profile.credentialAlias.length > 0 : profile.credentialAlias.length === 0) ||
    (profile.presetId !== undefined && !isConfigurationName(profile.presetId))) {
    throw new Error(t("模型服务配置无效，名称、协议、凭据或模型列表需要检查。"));
  }
  if (isProviderProtocol(profile.protocol)) { protocolUrl(profile.protocol, profile.baseUrl, true); }
  modelIds(profile.models.join('\n'));
  if (profile.imageModels !== undefined) {
    const image = profile.imageModels;
    if (!image || isImageProtocol(profile.protocol) || !isConfigurationName(image.protocol) ||
      (!stored && (!isSupportedProtocol(profile.protocol) || !isImageProtocol(image.protocol))) ||
      (image.baseUrl !== undefined && (typeof image.baseUrl !== 'string' || !image.baseUrl.trim() || image.baseUrl.length > 1024)) ||
      !Array.isArray(image.models) || image.models.some((id) => typeof id !== 'string' || !id || id.trim() !== id)) {
      throw new Error(t('图片生成服务配置无效。'));
    }
    modelIds(image.models.join('\n'));
    if (isSupportedProtocol(profile.protocol) && isImageProtocol(image.protocol)) {
      sharedImageBaseUrl(profile.protocol, profile.baseUrl, image.protocol, image.baseUrl);
    }
  }
  validateBalanceSettings(profile.balance);
  contextSettings({ configured: false, providerId: profile.id, baseUrl: '', model: '', systemPrompt: '',
    credentialAlias: '', contextWindow: profile.contextWindow });
}

export function validateReference(reference: ModelReference): void {
  if (!reference || typeof reference.providerId !== 'string' ||
    !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(reference.providerId) || typeof reference.modelId !== 'string' ||
    reference.modelId.trim().length === 0 || reference.modelId.length > 200) {
    throw new Error(t("会话的模型选择数据损坏。"));
  }
}

export function validateProviderProfiles(profiles: ProviderProfile[]): void {
  if (!Array.isArray(profiles)) { throw new Error(t("模型服务列表损坏。")); }
  const ids = new Set<string>();
  const aliases = new Set<string>();
  for (const profile of profiles) {
    validateProfile(profile, true);
    if (ids.has(profile.id) || (profile.credentialAlias.length > 0 && aliases.has(profile.credentialAlias))) {
      throw new Error(t("模型服务 ID 或密钥别名重复。"));
    }
    ids.add(profile.id);
    if (profile.credentialAlias.length > 0) { aliases.add(profile.credentialAlias); }
  }
}

export function migrateProfiles(config: ModelConfig): ProviderProfile[] {
  if (!config.configured) { return []; }
  const preset = builtinProviderInfos().find((info) => info.id === config.providerId);
  const models = [config.model].concat((preset?.models || []).filter((id: string) => id !== config.model));
  const profile: ProviderProfile = { id: config.providerId, name: preset?.name || config.providerId,
    presetId: preset?.id, protocol: preset?.protocol || 'chat-completions', baseUrl: config.baseUrl,
    credentialAlias: config.credentialAlias, noApiKey: config.credentialAlias.length === 0,
    enabled: true, models: models, contextWindow: config.contextWindow };
  validateProfile(profile);
  return [profile];
}

export function availableModels(profiles: ProviderProfile[]): ModelChoice[] {
  return modelChoices(profiles, false);
}

export function availableImageModels(profiles: ProviderProfile[]): ModelChoice[] {
  return modelChoices(profiles, true);
}

function imageModelIds(profile: ProviderProfile): string[] {
  if (isImageProtocol(profile.protocol)) { return profile.models; }
  const image = profile.imageModels;
  return image && isSupportedProtocol(profile.protocol) && isImageProtocol(image.protocol) ? image.models : [];
}

export function imageService(profiles: ProviderProfile[], reference?: ModelReference): ImageServiceAccess | undefined {
  if (!reference) { return undefined; }
  const profile = profiles.find((item) => item.id === reference.providerId && item.enabled && imageModelIds(item).includes(reference.modelId));
  if (!profile) { return undefined; }
  const image = profile.imageModels;
  return { id: profile.id, name: profile.name, credentialAlias: profile.credentialAlias,
    protocol: image?.protocol || profile.protocol,
    baseUrl: image ? sharedImageBaseUrl(profile.protocol, profile.baseUrl, image.protocol, image.baseUrl) : profile.baseUrl };
}

function modelChoices(profiles: ProviderProfile[], images: boolean): ModelChoice[] {
  const result: ModelChoice[] = [];
  for (const profile of profiles) {
    if (!profile.enabled) { continue; }
    const ids = images ? imageModelIds(profile) : isSupportedProtocol(profile.protocol) ? profile.models : [];
    for (const id of ids) { result.push({ providerId: profile.id, modelId: id, providerName: profile.name }); }
  }
  return result;
}

export function modelConfig(profiles: ProviderProfile[], reference: ModelReference, preferences: ModelConfig): ModelConfig {
  validateReference(reference);
  const profile = profiles.find((item: ProviderProfile) => item.id === reference.providerId);
  if (!profile || !profile.enabled || !isSupportedProtocol(profile.protocol) || !profile.models.includes(reference.modelId)) {
    throw new Error(t("这段对话选择的模型服务已停用、删除或移除该模型，请重新选择。"));
  }
  const config = JSON.parse(JSON.stringify(preferences)) as ModelConfig;
  config.configured = true; config.providerId = profile.id; config.baseUrl = profile.baseUrl; config.model = reference.modelId;
  config.credentialAlias = profile.credentialAlias; config.contextWindow = profile.contextWindow;
  // Model-specific options are resolved by SessionService, rather than copied from another model.
  config.reasoning = undefined; config.images = undefined; config.requestUsage = undefined;
  return config;
}
