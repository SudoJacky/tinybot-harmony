import { AppData } from './Conversation';
import { MemoryEntry, McpServer, validateProductivity } from './Productivity';
import { SkillData, validateExtensions } from './Skills';
import { ProviderProfile, validateProviderProfiles } from './ProviderProfiles';

export interface PeerSettings {
  userDocument: string;
  autoCompact?: boolean;
  autoMemory?: boolean;
  saveSummary?: boolean;
  memories: MemoryEntry[];
  skills: SkillData[];
  profiles: ProviderProfile[];
  servers: McpServer[];
}
export interface PeerSettingsDelta { current: PeerSettings; previous?: PeerSettings; origin?: string; force?: string[]; }
export interface PeerSettingsConflict { origin: string; keys: string[]; current: PeerSettings; }

// A service URL may itself carry authentication in user info or query parameters.
function shareableEndpoint(value: string): boolean {
  return /^https?:\/\/[^/?#@\\\s]+(?:\/[^?#\\\s]*)?$/i.test(value);
}

export function peerProfile(profile: ProviderProfile): ProviderProfile {
  return { id: profile.id, name: profile.name, presetId: profile.presetId, protocol: profile.protocol, baseUrl: profile.baseUrl,
    models: profile.models, contextWindow: profile.contextWindow, credentialAlias: '', enabled: false, noApiKey: true };
}
export function peerServer(server: McpServer): McpServer {
  return { id: server.id, name: server.name, url: server.url, enabled: false, credentialAlias: '' };
}

export function peerSettingsText(data: AppData): string {
  const settings: PeerSettings = {
    userDocument: data.config.userDocument || '',
    autoCompact: data.config.autoCompact,
    autoMemory: data.productivity?.options?.autoMemory,
    saveSummary: data.productivity?.options?.saveSummary,
    memories: data.productivity?.memories || [],
    skills: data.extensions?.skills || [],
    profiles: (data.providerProfiles || []).filter((profile) => shareableEndpoint(profile.baseUrl)).map(peerProfile),
    servers: (data.productivity?.servers || []).filter((server) => shareableEndpoint(server.url)).map(peerServer)
  };
  return JSON.stringify(settings);
}

export function parsePeerSettings(text: string): PeerSettings {
  const settings = JSON.parse(text) as PeerSettings;
  validatePeerSettings(settings);
  return settings;
}

export function validatePeerSettings(settings: PeerSettings): void {
  if (!settings || typeof settings.userDocument !== 'string' || !Array.isArray(settings.memories) ||
    !Array.isArray(settings.skills) || !Array.isArray(settings.profiles) || !Array.isArray(settings.servers) ||
    [settings.autoCompact, settings.autoMemory, settings.saveSummary].some((value) => value !== undefined && typeof value !== 'boolean') ||
    settings.profiles.some((profile) => !profile || profile.credentialAlias !== '' || profile.balanceCredentialAlias !== undefined ||
      profile.enabled || !profile.noApiKey || !shareableEndpoint(profile.baseUrl)) ||
    settings.servers.some((server) => !server || server.credentialAlias !== '' || server.authType !== undefined || server.enabled ||
      !shareableEndpoint(server.url))) {
    throw new Error('Invalid synchronized settings');
  }
  validateProductivity({ memories: settings.memories, servers: settings.servers, templates: [] });
  validateExtensions({ webEnabled: false, skills: settings.skills });
  validateProviderProfiles(settings.profiles);
}
