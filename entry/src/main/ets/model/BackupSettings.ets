import { AppData, ModelConfig, defaultConfig } from './Conversation';
import { AssistantOptions, defaultAssistantOptions } from './AssistantOptions';
import { builtinSkillInfo } from './BuiltinSkills';
import { defaultExtensions } from './Skills';

// An existing non-default setting wins; factory defaults can be filled on a new installation.
export function mergeBackupConfig(local: ModelConfig, incoming: ModelConfig): ModelConfig {
  const base = defaultConfig(), merged = JSON.parse(JSON.stringify(local)) as ModelConfig;
  if (local.contextWindow === undefined) { merged.contextWindow = incoming.contextWindow; }
  if (local.autoCompact === undefined || local.autoCompact === base.autoCompact) { merged.autoCompact = incoming.autoCompact ?? base.autoCompact; }
  if (local.reasoning === undefined) { merged.reasoning = incoming.reasoning; }
  if (local.images === undefined) { merged.images = incoming.images; }
  if (local.requestUsage === undefined) { merged.requestUsage = incoming.requestUsage; }
  return merged;
}
export function mergeBackupOptions(local: AssistantOptions | undefined, incoming: AssistantOptions | undefined): AssistantOptions | undefined {
  if (!incoming) { return local; }
  if (!local) { return JSON.parse(JSON.stringify(incoming)) as AssistantOptions; }
  const merged = JSON.parse(JSON.stringify(local)) as AssistantOptions, base = defaultAssistantOptions();
  if (local.autoMemory === base.autoMemory) { merged.autoMemory = incoming.autoMemory; }
  if (local.saveSummary === base.saveSummary) { merged.saveSummary = incoming.saveSummary; }
  if (local.readOnly === base.readOnly) { merged.readOnly = incoming.readOnly; }
  if (!local.memory) { merged.memory = incoming.memory; }
  if (!local.title) { merged.title = incoming.title; }
  if (!local.teamWorker) { merged.teamWorker = incoming.teamWorker; }
  for (const capability of incoming.capabilities) {
    if (!merged.capabilities.some((item) => item.providerId === capability.providerId && item.modelId === capability.modelId)) { merged.capabilities.push(capability); }
  }
  if (!local.search || JSON.stringify(local.search) === JSON.stringify(base.search)) { merged.search = incoming.search; }
  return merged;
}
export function mergeBackupSkills(local: AppData, restored: AppData): void {
  if (!local.extensions) { return; }
  const defaults = defaultExtensions(), incoming = restored.extensions;
  if (incoming && local.extensions.webEnabled === defaults.webEnabled) { local.extensions.webEnabled = incoming.webEnabled; }
  if (incoming && (!local.extensions.browserPolicy || local.extensions.browserPolicy === defaults.browserPolicy)) { local.extensions.browserPolicy = incoming.browserPolicy; }
  for (const skill of restored.extensions?.skills || []) {
    const index = local.extensions.skills.findIndex((item) => item.name === skill.name);
    if (index < 0) { local.extensions.skills.push(skill); }
    else {
      const existing = local.extensions.skills[index];
      if (existing.enabled && builtinSkillInfo(existing)) { local.extensions.skills[index] = skill; }
    }
  }
  local.extensions.seededBuiltinSkills = Array.from(new Set((local.extensions.seededBuiltinSkills || []).concat(restored.extensions?.seededBuiltinSkills || [])));
}
