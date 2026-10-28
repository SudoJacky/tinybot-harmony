import { ToolFailure, parseToolArguments } from './ToolFailure';
import { ExtensionSettings, SkillData, SkillFile, parseSkill, validateExtensions } from './Skills';
import { McpServer, ProductivityData, validateProductivity } from './Productivity';
import { mergeSavedConfiguration } from './SavedConfiguration';

export interface SkillRequest {
  action: string;
  name?: string;
  document?: string;
  files?: SkillFile[];
  source?: string;
  paths?: string[];
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
  if (original && !existing) { throw new ToolFailure('NOT_FOUND', 'Skill does not exist: ' + original, 'check_resource'); }
  if (next.skills.some((item) => item.name === skill.name && item.name !== original)) { throw new ToolFailure('ALREADY_EXISTS', 'Skill already exists: ' + skill.name, 'check_resource'); }
  skill.enabled = existing ? existing.enabled : true;
  skill.files = JSON.parse(JSON.stringify(files)) as SkillFile[];
  skill.source = imported?.source || existing?.source;
  if (!imported && skill.source) { skill.source.modified = true; }
  const saved = mergeSavedConfiguration(existing, skill);
  next.skills = existing ? next.skills.map((item) => item.name === original ? saved : item) : next.skills.concat([saved]);
  validateExtensions(next); return next;
}

export function changeSkillCandidate(settings: ExtensionSettings, name: string, action: string): ExtensionSettings {
  const next = JSON.parse(JSON.stringify(settings)) as ExtensionSettings;
  const skill = next.skills.find((item) => item.name === name);
  if (!skill) { throw new ToolFailure('NOT_FOUND', 'Skill does not exist: ' + name, 'check_resource'); }
  if (action === 'remove') { next.skills = next.skills.filter((item) => item.name !== name); }
  else if (action === 'enable' || action === 'disable') { skill.enabled = action === 'enable'; }
  else { throw new ToolFailure('INVALID_ARGUMENTS', 'Unknown skill action: ' + action, 'fix_arguments'); }
  validateExtensions(next); return next;
}

export function saveMcpCandidate(data: ProductivityData, server: McpServer): ProductivityData {
  const next = JSON.parse(JSON.stringify(data)) as ProductivityData;
  const index = next.servers.findIndex((item) => item.id === server.id);
  if (index < 0) { next.servers.push(server); } else { next.servers[index] = mergeSavedConfiguration(next.servers[index], server); }
  validateProductivity(next); return next;
}

export function parseSkillRequest(text: string): SkillRequest {
  const fieldsValue = parseToolArguments(text) as Record<string, Object>;
  const value = parseToolArguments(text) as SkillRequest;
  if (!value || Array.isArray(value) || typeof value.action !== 'string' ||
    Object.keys(value).some((key) => !['action', 'name', 'document', 'files', 'source', 'paths'].includes(key) ||
      (!['files', 'paths'].includes(key) && typeof fieldsValue[key] !== 'string')) ||
    (value.files !== undefined && (!Array.isArray(value.files) || value.files.length > 16 || value.files.some((file) =>
      !file || Array.isArray(file) || typeof file.path !== 'string' || typeof file.content !== 'string' ||
      Object.keys(file).some((key) => key !== 'path' && key !== 'content')))) ||
    (value.paths !== undefined && (!Array.isArray(value.paths) || value.paths.length > 16 || value.paths.some((item) => typeof item !== 'string')))) {
    throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid skill_manage arguments.', 'fix_arguments');
  }
  const fields: Record<string, string[]> = { 'create': ['document', 'files'], 'update': ['name', 'document', 'files'],
    'install': ['name', 'source', 'paths'], 'remove': ['name'], 'enable': ['name'], 'disable': ['name'] };
  if (!fields[value.action] || Object.keys(value).some((key) => key !== 'action' && !fields[value.action].includes(key))) { throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid skill action or fields.', 'fix_arguments'); }
  if (['update', 'remove', 'enable', 'disable'].includes(value.action) && !value.name) { throw new ToolFailure('INVALID_ARGUMENTS', 'Skill name is required.', 'fix_arguments'); }
  if (['create', 'update'].includes(value.action) && !value.document) { throw new ToolFailure('INVALID_ARGUMENTS', 'Complete SKILL.md is required.', 'fix_arguments'); }
  if (value.action === 'install' && !value.source) { throw new ToolFailure('INVALID_ARGUMENTS', 'Skill source URL is required.', 'fix_arguments'); }
  return value;
}

export function parseMcpRequest(text: string): McpRequest {
  const fieldsValue = parseToolArguments(text) as Record<string, Object>;
  const value = parseToolArguments(text) as McpRequest;
  if (!value || Array.isArray(value) || typeof value.action !== 'string' ||
    Object.keys(value).some((key) => !['action', 'id', 'name', 'url', 'auth', 'clientId'].includes(key) || typeof fieldsValue[key] !== 'string')) {
    throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid mcp_manage arguments. Do not pass secrets; use the native authentication form.', 'fix_arguments');
  }
  if (!['list', 'save', 'remove', 'enable', 'disable', 'test'].includes(value.action)) { throw new ToolFailure('INVALID_ARGUMENTS', 'Invalid MCP action.', 'fix_arguments'); }
  if (value.action !== 'save' && Object.keys(value).some((key) => key !== 'action' && key !== 'id')) { throw new ToolFailure('INVALID_ARGUMENTS', 'Unexpected MCP fields.', 'fix_arguments'); }
  if (!['list', 'save'].includes(value.action) && !value.id) { throw new ToolFailure('INVALID_ARGUMENTS', 'MCP id is required.', 'fix_arguments'); }
  if (value.action === 'save' && (!value.name || !value.url || !['none', 'bearer', 'oauth', 'keep'].includes(value.auth || ''))) {
    throw new ToolFailure('INVALID_ARGUMENTS', 'MCP save requires name, HTTPS url and auth: none|bearer|oauth|keep.', 'fix_arguments');
  }
  if (value.clientId && value.auth !== 'oauth') { throw new ToolFailure('INVALID_ARGUMENTS', 'clientId requires OAuth.', 'fix_arguments'); }
  return value;
}
