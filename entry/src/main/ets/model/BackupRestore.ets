import { AppData } from './Conversation';
import { ModelReference, ProviderProfile } from './ProviderProfiles';
import { McpServer } from './Productivity';
import { t } from './I18n';

// Only remap the detached import. Local settings and credential aliases remain untouched.
export function prepareBackupServices(local: AppData, restored: AppData, createId: () => string, servers: Map<string, string> = new Map<string, string>()): Map<string, string> {
  const providers = new Map<string, string>();
  const additions: ProviderProfile[] = [];
  for (const profile of restored.providerProfiles || []) {
    const matches = (local.providerProfiles || []).filter((item) => item.protocol === profile.protocol &&
      item.baseUrl.replace(/\/+$/, '') === profile.baseUrl.replace(/\/+$/, ''));
    const existing = matches.find((item) => item.id === profile.id) || (matches.length === 1 ? matches[0] : undefined);
    if (existing) { providers.set(profile.id, existing.id); }
    else {
      const id = (local.providerProfiles || []).some((item) => item.id === profile.id) ? 'provider-' + createId() : profile.id;
      providers.set(profile.id, id); profile.id = id;
      profile.credentialAlias = ''; profile.balanceCredentialAlias = undefined; profile.noApiKey = true; profile.enabled = false;
      profile.name = t('{0}（恢复后请配置密钥）', [profile.name]); additions.push(profile);
    }
  }
  restored.providerProfiles = additions;
  const serverAdditions: McpServer[] = [];
  for (const server of restored.productivity?.servers || []) {
    const matches = (local.productivity?.servers || []).filter((item) => item.url === server.url);
    const existing = matches.find((item) => item.id === server.id) || (matches.length === 1 ? matches[0] : undefined);
    if (existing) { servers.set(server.id, existing.id); }
    else {
      const id = (local.productivity?.servers || []).some((item) => item.id === server.id) ? createId() : server.id;
      servers.set(server.id, id); server.id = id;
      server.enabled = server.enabled && !server.credentialAlias && !server.authType;
      server.credentialAlias = ''; server.authType = undefined; serverAdditions.push(server);
    }
  }
  if (restored.productivity) { restored.productivity.servers = serverAdditions; }
  for (const thread of restored.threads) {
    remapModel(thread.modelRef, providers);
    for (const message of thread.messages) { remapModel(message.modelRef, providers); }
    for (const run of thread.teams || []) { remapModel(run.model, providers); }
    thread.disabledMcpIds = (thread.disabledMcpIds || []).map((id) => servers.get(id) || id);
  }
  const options = restored.productivity?.options;
  restored.config.providerId = providers.get(restored.config.providerId) || restored.config.providerId;
  if (options) {
    for (const reference of [options.fast, options.deep, options.vision, options.memory, ...options.capabilities]) { remapModel(reference, providers); }
    const search = options.search;
    if (search?.modelProviderId) { search.modelProviderId = providers.get(search.modelProviderId) || search.modelProviderId; }
    if (search?.deepseek?.modelProviderId) { search.deepseek.modelProviderId = providers.get(search.deepseek.modelProviderId) || search.deepseek.modelProviderId; }
  }
  return providers;
}

function remapModel(reference: ModelReference | undefined, providers: Map<string, string>): void {
  if (reference) { reference.providerId = providers.get(reference.providerId) || reference.providerId; }
}
