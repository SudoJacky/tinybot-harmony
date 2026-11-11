import { AppData, MessageData, ThreadData, emptyData, parseAppData } from './Conversation';
import { ProjectData, validateProjects } from './Project';
import { threadWorkspacePath } from './Workspace';
import { MemoryEntry, McpServer } from './Productivity';
import { SkillData } from './Skills';
import { ProviderProfile } from './ProviderProfiles';

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
export interface PeerSettingsDelta { current: PeerSettings; previous?: PeerSettings; }
export interface PeerThreadUpdate {
  origin: string;
  id: string;
  collisionId: string;
  thread?: ThreadData;
}

// A service URL may itself carry authentication in user info or query parameters.
function shareableEndpoint(value: string): boolean {
  return /^https?:\/\/[^/?#@\\\s]+(?:\/[^?#\\\s]*)?$/i.test(value);
}

export function peerThreadText(thread: ThreadData): string {
  const copy = JSON.parse(JSON.stringify(thread)) as ThreadData;
  copy.peerOwner = undefined; copy.peerThreadId = undefined;
  // Queue admission and tool approval are specific to the executing device.
  copy.pendingInputs = undefined; copy.queuePaused = undefined; copy.toolApprovalMode = undefined;
  return JSON.stringify(copy);
}

export function parsePeerThread(text: string, id: string): ThreadData {
  const raw = JSON.parse(text) as ThreadData;
  if (!raw || raw.id !== id || raw.peerOwner !== undefined || raw.peerThreadId !== undefined) {
    throw new Error('Invalid synchronized conversation');
  }
  threadWorkspacePath('', id);
  const projectId = raw.projectId;
  raw.projectId = undefined;
  const data = emptyData(); data.threads = [raw];
  const checked = parseAppData(JSON.stringify(data)).threads[0];
  checked.projectId = projectId;
  const last = raw.messages[raw.messages.length - 1];
  if (last?.status === 'generating') { checked.messages[checked.messages.length - 1].status = 'generating'; }
  checked.pendingInputs = undefined; checked.queuePaused = undefined; checked.toolApprovalMode = undefined;
  return checked;
}

export function peerProjectText(project: ProjectData): string {
  const copy: ProjectData = { id: project.id, name: project.name, workspaceId: project.workspaceId,
    instructions: project.instructions, createdAt: project.createdAt, updatedAt: project.updatedAt };
  return JSON.stringify(copy);
}

export function parsePeerProject(text: string, id: string): ProjectData {
  const item = JSON.parse(text) as ProjectData;
  if (!item || item.id !== id || item.sharedFolders !== undefined) { throw new Error('Invalid synchronized project'); }
  const data: AppData = emptyData(); data.projects = [item]; validateProjects(data);
  return item;
}

export function peerSettingsText(data: AppData): string {
  const settings: PeerSettings = {
    userDocument: data.config.userDocument || '',
    autoCompact: data.config.autoCompact,
    autoMemory: data.productivity?.options?.autoMemory,
    saveSummary: data.productivity?.options?.saveSummary,
    memories: data.productivity?.memories || [],
    skills: data.extensions?.skills || [],
    profiles: (data.providerProfiles || []).filter((profile) => shareableEndpoint(profile.baseUrl)).map((profile): ProviderProfile => ({
      id: profile.id, name: profile.name, presetId: profile.presetId, protocol: profile.protocol, baseUrl: profile.baseUrl,
      models: profile.models, contextWindow: profile.contextWindow, credentialAlias: '', enabled: false, noApiKey: true
    })),
    servers: (data.productivity?.servers || []).filter((server) => shareableEndpoint(server.url)).map((server): McpServer => ({
      id: server.id, name: server.name, url: server.url, enabled: false, credentialAlias: ''
    }))
  };
  return JSON.stringify(settings);
}

export function parsePeerSettings(text: string): PeerSettings {
  const settings = JSON.parse(text) as PeerSettings;
  if (!settings || typeof settings.userDocument !== 'string' || !Array.isArray(settings.memories) ||
    !Array.isArray(settings.skills) || !Array.isArray(settings.profiles) || !Array.isArray(settings.servers) ||
    [settings.autoCompact, settings.autoMemory, settings.saveSummary].some((value) => value !== undefined && typeof value !== 'boolean') ||
    settings.profiles.some((profile) => !profile || profile.credentialAlias !== '' || profile.balanceCredentialAlias !== undefined ||
      profile.enabled || !profile.noApiKey || !shareableEndpoint(profile.baseUrl)) ||
    settings.servers.some((server) => !server || server.credentialAlias !== '' || server.authType !== undefined || server.enabled ||
      !shareableEndpoint(server.url))) {
    throw new Error('Invalid synchronized settings');
  }
  const data = emptyData();
  data.config.userDocument = settings.userDocument;
  data.productivity = { memories: settings.memories, servers: settings.servers, templates: [] };
  data.extensions = { webEnabled: false, skills: settings.skills };
  data.providerProfiles = settings.profiles;
  parseAppData(JSON.stringify(data));
  return settings;
}

export function peerLiveMessage(text: string): MessageData {
  const message = JSON.parse(text) as MessageData;
  if (!message || message.role !== 'assistant' || message.status !== 'generating' ||
    typeof message.id !== 'string' || !message.id || typeof message.content !== 'string' ||
    typeof message.error !== 'string' || (message.steps !== undefined && !Array.isArray(message.steps))) {
    throw new Error('Invalid synchronized live message');
  }
  const data = emptyData();
  data.threads = [{ id: 'live-check', title: '', updatedAt: 0, messages: [
    { id: 'live-check-user', role: 'user', content: '', status: 'complete', error: '' }, message
  ] }];
  parseAppData(JSON.stringify(data));
  return message;
}
