import { t } from './I18n';
import { ModelReference, validateReference } from './ProviderProfiles';
export interface ModelCapability extends ModelReference { images: boolean; reasoning: string; contextWindow: number; requestUsage: boolean; }
export interface AssistantOptions {
  autoMemory: boolean; saveSummary: boolean; readOnly: boolean; autoRoute: boolean;
  fast?: ModelReference; deep?: ModelReference; vision?: ModelReference; memory?: ModelReference; image?: ModelReference;
  capabilities: ModelCapability[];
}
export function defaultAssistantOptions(): AssistantOptions {
  return { autoMemory: false, saveSummary: false, readOnly: false, autoRoute: false, capabilities: [] };
}
export function validateAssistantOptions(value: AssistantOptions): void {
  if (!value || [value.autoMemory, value.saveSummary, value.readOnly, value.autoRoute].some((item) => typeof item !== 'boolean') ||
    !Array.isArray(value.capabilities) || value.capabilities.length > 200) { throw new Error(t("助手选项无效。")); }
  for (const reference of [value.fast, value.deep, value.vision, value.memory, value.image]) { if (reference) { validateReference(reference); } }
  for (const item of value.capabilities) {
    validateReference(item);
    if (typeof item.images !== 'boolean' || typeof item.requestUsage !== 'boolean' || !['default', 'low', 'medium', 'high'].includes(item.reasoning) ||
      !Number.isInteger(item.contextWindow) || item.contextWindow < 8192 || item.contextWindow > 2000000) { throw new Error(t("模型能力配置无效。")); }
  }
}
export function routeModel(options: AssistantOptions, text: string, hasImages: boolean, current: ModelReference): ModelReference {
  if (!options.autoRoute) { return current; }
  if (hasImages) { return options.vision || current; }
  return text.length > 1000 || /深入|详细|推理|分析|比较|方案|证明|debug|analy[sz]e/i.test(text) ? options.deep || current : options.fast || current;
}
