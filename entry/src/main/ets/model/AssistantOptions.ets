import { t } from './I18n';
import { SearchConfig, defaultSearchConfig, validateSearchConfig } from './WebSearch';
import { ModelReference, validateReference } from './ProviderProfiles';
import { isConfigurationName } from './ConfigurationValue';
export interface ModelCapability extends ModelReference { images: boolean; reasoning: string; contextWindow?: number; requestUsage: boolean; }
export interface AssistantOptions {
  search?: SearchConfig;
  autoMemory: boolean; saveSummary: boolean; readOnly: boolean;
  memory?: ModelReference;
  title?: ModelReference;
  teamWorker?: ModelReference;
  capabilities: ModelCapability[];
}
export function defaultAssistantOptions(): AssistantOptions {
  return { search: defaultSearchConfig(), autoMemory: true, saveSummary: false, readOnly: false, capabilities: [] };
}
export function validateAssistantOptions(value: AssistantOptions): void {
  if (value?.search !== undefined) { validateSearchConfig(value.search, true); }
  if (!value || [value.autoMemory, value.saveSummary, value.readOnly].some((item) => typeof item !== 'boolean') ||
    !Array.isArray(value.capabilities) || value.capabilities.length > 200) { throw new Error(t("助手选项无效。")); }
  if (value.memory) { validateReference(value.memory); }
  for (const reference of [value.title, value.teamWorker]) {
    if (reference !== undefined) { validateReference(reference); }
  }
  for (const item of value.capabilities) {
    validateReference(item);
    if (typeof item.images !== 'boolean' || typeof item.requestUsage !== 'boolean' || !isConfigurationName(item.reasoning) ||
      (item.contextWindow !== undefined && (!Number.isInteger(item.contextWindow) || item.contextWindow < 8192 || item.contextWindow > 2000000))) { throw new Error(t("模型能力配置无效。")); }
  }
}
