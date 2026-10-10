import { ExtensionSettings, SkillData, SkillFile, parseSkill, validateExtensions } from './Skills';
import { McpServer, ProductivityData, validateProductivity } from './Productivity';

export interface SkillRequest {
  action: string;
  name?: string;
  document?: string;
  files?: string;
  source?: string;
  paths?: string;
}
export interface McpRequest {
  action: string;
  id?: string;
  name?: string;
  url?: string;
  auth?: string;
  clientId?: string;
}
export interface LiveResources {
  skills: () => SkillData[];
  servers: () => McpServer[];
}
export interface McpSummary { id: string; name: string; url: string; enabled: boolean; available: boolean; auth: string; }

// Shared by settings and chat. Work on detached candidates; callers own the durable commit.
export function saveSkillCandidate(settings: ExtensionSettings, original: string, document: string,
  files: SkillFile[], imported?: SkillData): ExtensionSettings {
  const next = JSON.parse(JSON.stringify(settings)) as ExtensionSettings;
  const skill = parseSkill(document);
  const existing = next.skills.find((item) => item.name === original);
  if (original && !existing) { throw new Error('Skill does not exist: ' + original); }
  if (next.skills.some((item) => item.name === skill.name && item.name !== original)) { throw new Error('Skill already exists: ' + skill.name); }
  skill.enabled = existing ? existing.enabled : true;
  skill.files = JSON.parse(JSON.stringify(files)) as SkillFile[];
  skill.source = imported?.source || existing?.source;
  if (!imported && skill.source) { skill.source.modified = true; }
  next.skills = existing ? next.skills.map((item) => item.name === original ? skill : item) : next.skills.concat([skill]);
  validateExtensions(next); return next;
}

export function changeSkillCandidate(settings: ExtensionSettings, name: string, action: string): ExtensionSettings {
  const next = JSON.parse(JSON.stringify(settings)) as ExtensionSettings;
  const skill = next.skills.find((item) => item.name === name);
  if (!skill) { throw new Error('Skill does not exist: ' + name); }
  if (action === 'remove') { next.skills = next.skills.filter((item) => item.name !== name); }
  else if (action === 'enable' || action === 'disable') { skill.enabled = action === 'enable'; }
  else { throw new Error('Unknown skill action: ' + action); }
  validateExtensions(next); return next;
}

export function saveMcpCandidate(data: ProductivityData, server: McpServer): ProductivityData {
  const next = JSON.parse(JSON.stringify(data)) as ProductivityData;
  const index = next.servers.findIndex((item) => item.id === server.id);
  if (index < 0) { next.servers.push(server); } else { next.servers[index] = server; }
  validateProductivity(next); return next;
}

export function parseSkillRequest(text: string): SkillRequest {
  const fieldsValue = JSON.parse(text) as Record<string, Object>;
  const value = JSON.parse(text) as SkillRequest;
  if (!value || Array.isArray(value) || typeof value.action !== 'string' ||
    Object.keys(value).some((key) => !['action', 'name', 'document', 'files', 'source', 'paths'].includes(key) || typeof fieldsValue[key] !== 'string')) {
    throw new Error('Invalid skill_manage arguments.');
  }
  const fields: Record<string, string[]> = { 'create': ['document', 'files'], 'update': ['name', 'document', 'files'],
    'install': ['name', 'source', 'paths'], 'remove': ['name'], 'enable': ['name'], 'disable': ['name'] };
  if (!fields[value.action] || Object.keys(value).some((key) => key !== 'action' && !fields[value.action].includes(key))) { throw new Error('Invalid skill action or fields.'); }
  if (['update', 'remove', 'enable', 'disable'].includes(value.action) && !value.name) { throw new Error('Skill name is required.'); }
  if (['create', 'update'].includes(value.action) && !value.document) { throw new Error('Complete SKILL.md is required.'); }
  if (value.action === 'install' && !value.source) { throw new Error('Skill source URL is required.'); }
  return value;
}

export function parseMcpRequest(text: string): McpRequest {
  const fieldsValue = JSON.parse(text) as Record<string, Object>;
  const value = JSON.parse(text) as McpRequest;
  if (!value || Array.isArray(value) || typeof value.action !== 'string' ||
    Object.keys(value).some((key) => !['action', 'id', 'name', 'url', 'auth', 'clientId'].includes(key) || typeof fieldsValue[key] !== 'string')) {
    throw new Error('Invalid mcp_manage arguments. Do not pass secrets; use the native authentication form.');
  }
  if (!['list', 'save', 'remove', 'enable', 'disable', 'test'].includes(value.action)) { throw new Error('Invalid MCP action.'); }
  if (value.action !== 'save' && Object.keys(value).some((key) => key !== 'action' && key !== 'id')) { throw new Error('Unexpected MCP fields.'); }
  if (!['list', 'save'].includes(value.action) && !value.id) { throw new Error('MCP id is required.'); }
  if (value.action === 'save' && (!value.name || !value.url || !['none', 'bearer', 'oauth', 'keep'].includes(value.auth || ''))) {
    throw new Error('MCP save requires name, HTTPS url and auth: none|bearer|oauth|keep.');
  }
  if (value.clientId && value.auth !== 'oauth') { throw new Error('clientId requires OAuth.'); }
  return value;
}
