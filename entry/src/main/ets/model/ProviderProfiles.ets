import { ModelConfig } from './Conversation';
import { builtinProviderInfos } from './Provider';
import { contextSettings } from './ConversationContext';
import { protocolUrl } from '../services/providers/WireProtocols';

export interface ModelReference {
  providerId: string;
  modelId: string;
}

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
  contextWindow: number;
}

export interface ModelChoice extends ModelReference {
  providerName: string;
}

export function modelIds(value: string): string[] {
  const ids = value.split(/[\n,，]/).map((id: string) => id.trim()).filter((id: string) => id.length > 0);
  if (ids.length === 0 || ids.some((id: string) => id.length > 200) || new Set(ids).size !== ids.length) {
    throw new Error('请填写至少一个模型 ID，每行一个或用逗号分隔，不能重复。');
  }
  return ids;
}

export function validateProfile(profile: ProviderProfile): void {
  if (!profile || typeof profile.id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(profile.id) ||
    typeof profile.name !== 'string' || profile.name.trim().length === 0 || profile.name.length > 80 ||
    !['chat-completions', 'responses', 'anthropic-messages'].includes(profile.protocol) || typeof profile.baseUrl !== 'string' ||
    typeof profile.credentialAlias !== 'string' || typeof profile.noApiKey !== 'boolean' ||
    typeof profile.enabled !== 'boolean' || !Array.isArray(profile.models) ||
    profile.models.some((id: string) => typeof id !== 'string' || id.trim() !== id || id.length === 0) ||
    (profile.noApiKey ? profile.credentialAlias.length > 0 : profile.credentialAlias.length === 0) ||
    (profile.presetId !== undefined && !builtinProviderInfos().some((info) => info.id === profile.presetId))) {
    throw new Error('模型服务配置无效，名称、协议、凭据或模型列表需要检查。');
  }
  protocolUrl(profile.protocol, profile.baseUrl, true);
  modelIds(profile.models.join('\n'));
  contextSettings({ configured: false, providerId: profile.id, baseUrl: '', model: '', systemPrompt: '',
    credentialAlias: '', contextWindow: profile.contextWindow });
}

export function validateReference(reference: ModelReference): void {
  if (!reference || typeof reference.providerId !== 'string' ||
    !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(reference.providerId) || typeof reference.modelId !== 'string' ||
    reference.modelId.trim().length === 0 || reference.modelId.length > 200) {
    throw new Error('会话的模型选择数据损坏。');
  }
}

export function migrateProfiles(config: ModelConfig): ProviderProfile[] {
  if (!config.configured) { return []; }
  const preset = builtinProviderInfos().find((info) => info.id === config.providerId);
  const models = [config.model].concat((preset?.models || []).filter((id: string) => id !== config.model));
  const profile: ProviderProfile = { id: config.providerId, name: preset?.name || config.providerId,
    presetId: preset?.id, protocol: preset?.protocol || 'chat-completions', baseUrl: config.baseUrl,
    credentialAlias: config.credentialAlias, noApiKey: config.credentialAlias.length === 0,
    enabled: true, models: models, contextWindow: contextSettings(config).window };
  validateProfile(profile);
  return [profile];
}

export function availableModels(profiles: ProviderProfile[]): ModelChoice[] {
  const result: ModelChoice[] = [];
  for (const profile of profiles) {
    if (profile.enabled) {
      for (const id of profile.models) { result.push({ providerId: profile.id, modelId: id, providerName: profile.name }); }
    }
  }
  return result;
}

export function modelConfig(profiles: ProviderProfile[], reference: ModelReference, preferences: ModelConfig): ModelConfig {
  validateReference(reference);
  const profile = profiles.find((item: ProviderProfile) => item.id === reference.providerId);
  if (!profile || !profile.enabled || !profile.models.includes(reference.modelId)) {
    throw new Error('这段对话选择的模型服务已停用、删除或移除该模型，请重新选择。');
  }
  return { configured: true, providerId: profile.id, baseUrl: profile.baseUrl, model: reference.modelId,
    credentialAlias: profile.credentialAlias, contextWindow: profile.contextWindow,
    systemPrompt: preferences.systemPrompt, autoCompact: preferences.autoCompact };
}
