import { AppData, ModelConfig } from './Conversation';

// Allowlist cloud fields before serializing. Skill files, personal documents, memories,
// projects and transcripts travel only through device sync or legacy full exports.
export function cloudConfiguration(source: AppData): AppData {
  const model = source.config;
  const config: ModelConfig = { configured: model.configured, providerId: model.providerId, baseUrl: model.baseUrl,
    model: model.model, systemPrompt: model.systemPrompt, credentialAlias: model.credentialAlias, userDocument: '',
    contextWindow: model.contextWindow, autoCompact: model.autoCompact, reasoning: model.reasoning,
    images: model.images, requestUsage: model.requestUsage };
  return {
    version: 2, activeThreadId: '', threads: [], config: config,
    lastToolApprovalMode: source.lastToolApprovalMode, providerProfiles: source.providerProfiles,
    extensions: source.extensions ? { webEnabled: source.extensions.webEnabled,
      browserPolicy: source.extensions.browserPolicy, skills: [] } : undefined,
    productivity: source.productivity ? { options: source.productivity.options,
      servers: source.productivity.servers, memories: [], templates: [] } : undefined
  };
}
