import { AppData, copyModelConfig } from './Conversation';
import { PeerSettingsDelta, peerProfile, peerServer } from './PeerSyncData';
import { ProviderProfile } from './ProviderProfiles';
import { McpServer, MemoryEntry, defaultProductivity, validateProductivity } from './Productivity';
import { SkillData, defaultExtensions, validateExtensions } from './Skills';
import { AssistantOptions, defaultAssistantOptions } from './AssistantOptions';

function same<T>(a: T | undefined, b: T | undefined): boolean { return JSON.stringify(a) === JSON.stringify(b); }

function select<T>(key: string, local: T, remote: T, previous: T | undefined, conflicts: Set<string>, force: string[]): T {
  if (same(local, remote)) { conflicts.delete(key); return local; }
  if (force.includes(key) || same(local, previous)) { conflicts.delete(key); return remote; }
  if (!same(remote, previous)) { conflicts.add(key); }
  return local;
}

function records<T>(kind: string, local: T[], remote: T[], previous: T[], keyFor: (item: T) => string,
  publicValue: (item: T) => T, accept: (item: T, local?: T) => T, conflicts: Set<string>, force: string[]): T[] {
  const result = local.slice();
  const ids = new Set(remote.concat(previous).map(keyFor).concat(Array.from(conflicts).concat(force)
    .filter((key) => key.startsWith(kind + ':')).map((key) => key.slice(kind.length + 1))));
  for (const id of ids) {
    const index = result.findIndex((item) => keyFor(item) === id), current = result[index];
    const next = remote.find((item) => keyFor(item) === id), before = previous.find((item) => keyFor(item) === id);
    const projected = current ? publicValue(current) : undefined;
    const selected = select<T | undefined>(kind + ':' + id, projected, next, before, conflicts, force);
    if (same(projected, selected)) { continue; }
    if (!selected) { if (index >= 0) { result.splice(index, 1); } }
    else if (index < 0) { result.push(accept(selected)); }
    else { result[index] = accept(selected, current); }
  }
  return result;
}

function profile(incoming: ProviderProfile, local?: ProviderProfile): ProviderProfile {
  if (!local || local.baseUrl !== incoming.baseUrl || local.protocol !== incoming.protocol) {
    const result = JSON.parse(JSON.stringify(incoming)) as ProviderProfile;
    result.enabled = false; result.noApiKey = true; result.credentialAlias = ''; result.pendingSetup = true;
    return result;
  }
  const result = JSON.parse(JSON.stringify(local)) as ProviderProfile;
  result.name = incoming.name; result.models = incoming.models; result.presetId = incoming.presetId; result.contextWindow = incoming.contextWindow;
  return result;
}
function server(incoming: McpServer, local?: McpServer): McpServer {
  if (!local || local.url !== incoming.url) { return JSON.parse(JSON.stringify(incoming)) as McpServer; }
  const result = JSON.parse(JSON.stringify(local)) as McpServer; result.name = incoming.name; return result;
}

export function mergePeerSettings(candidate: AppData, deltas: PeerSettingsDelta[]): boolean {
  if (!deltas.length) { return false; }
  const before = JSON.stringify([candidate.config, candidate.productivity, candidate.extensions, candidate.providerProfiles, candidate.nearbyConflicts]);
  const productivity = candidate.productivity || defaultProductivity(), extensions = candidate.extensions || defaultExtensions();
  const options = JSON.parse(JSON.stringify(productivity.options || defaultAssistantOptions())) as AssistantOptions;
  let profiles = (candidate.providerProfiles || []).slice(), servers = productivity.servers.slice();
  let skills = extensions.skills.slice(), memories = productivity.memories.slice();
  candidate.config = copyModelConfig(candidate.config);
  for (const delta of deltas) {
    const current = delta.current, previous = delta.previous, origin = delta.origin || '', force = delta.force || [];
    const conflicts = new Set(candidate.nearbyConflicts?.find((item) => item.origin === origin)?.keys || []);
    candidate.config.userDocument = select('userDocument', candidate.config.userDocument || '', current.userDocument,
      previous?.userDocument ?? '', conflicts, force);
    if (current.autoCompact !== undefined) { candidate.config.autoCompact = select('autoCompact', candidate.config.autoCompact, current.autoCompact, previous?.autoCompact, conflicts, force); }
    if (current.autoMemory !== undefined) { options.autoMemory = select('autoMemory', options.autoMemory, current.autoMemory, previous?.autoMemory, conflicts, force); }
    if (current.saveSummary !== undefined) { options.saveSummary = select('saveSummary', options.saveSummary, current.saveSummary, previous?.saveSummary, conflicts, force); }
    profiles = records('profile', profiles, current.profiles, previous?.profiles || [], (item: ProviderProfile) => item.id, peerProfile, profile, conflicts, force);
    servers = records('server', servers, current.servers, previous?.servers || [], (item: McpServer) => item.id, peerServer, server, conflicts, force);
    skills = records('skill', skills, current.skills, previous?.skills || [], (item: SkillData) => item.name,
      (item: SkillData) => item, (item: SkillData) => item, conflicts, force);
    memories = records('memory', memories, current.memories, previous?.memories || [], (item: MemoryEntry) => item.id,
      (item: MemoryEntry) => item, (item: MemoryEntry) => item, conflicts, force);
    candidate.nearbyConflicts = (candidate.nearbyConflicts || []).filter((item) => item.origin !== origin);
    if (conflicts.size) { candidate.nearbyConflicts.push({ origin: origin, keys: Array.from(conflicts), current: current }); }
    if (!candidate.nearbyConflicts.length) { candidate.nearbyConflicts = undefined; }
  }
  candidate.productivity = { options: options, memories: memories, templates: productivity.templates, servers: servers };
  candidate.extensions = { browserPolicy: extensions.browserPolicy, webEnabled: extensions.webEnabled, skills: skills,
    seededBuiltinSkills: extensions.seededBuiltinSkills };
  candidate.providerProfiles = profiles;
  validateProductivity(candidate.productivity); validateExtensions(candidate.extensions);
  return before !== JSON.stringify([candidate.config, candidate.productivity, candidate.extensions, candidate.providerProfiles, candidate.nearbyConflicts]);
}
