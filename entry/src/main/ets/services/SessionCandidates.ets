import { t } from '../model/I18n';
import { AppData, MessageData, ThreadData } from '../model/Conversation';
import { prepareBackupServices } from '../model/BackupRestore';
import { ToolSelection } from '../model/AgentMode';
import { Attachment, defaultProductivity, validateProductivity } from '../model/Productivity';
import { defaultExtensions, validateExtensions } from '../model/Skills';
import { ProjectData, projectName, validateProjects } from '../model/Project';
import { SharedFolder, validateSharedFolders } from '../model/SharedFolders';
import { ThreadReference } from '../model/ThreadReferences';

export interface SessionImportCandidate { data: AppData; threads: ThreadData[]; providerIds: Map<string, string>; }

// Build detached candidates only. SessionService owns admission, platform effects and commits.
export function importedSessionCandidate(local: AppData, imported: AppData, createId: () => string): SessionImportCandidate {
  const candidate = JSON.parse(JSON.stringify(local)) as AppData;
  const restored = JSON.parse(JSON.stringify(imported)) as AppData;
  const known = new Set(candidate.threads.map((item) => item.id));
  restored.threads = restored.threads.filter((item) => !known.has(item.id));
  const providerIds = prepareBackupServices(local, restored, createId);
  candidate.projects = (candidate.projects || []).concat((restored.projects || []).filter((project) =>
    !(candidate.projects || []).some((item) => item.id === project.id)));
  candidate.threads = candidate.threads.concat(restored.threads);
  validateProjects(candidate);
  // Restore preferences on a fresh install without overwriting an existing personal document.
  if (!(candidate.config.userDocument || '').trim()) { candidate.config.userDocument = restored.config.userDocument || ''; }
  candidate.providerProfiles = (candidate.providerProfiles || []).concat(restored.providerProfiles || []);
  const extensions = candidate.extensions || defaultExtensions();
  for (const skill of restored.extensions?.skills || []) {
    if (!extensions.skills.some((item) => item.name === skill.name)) { extensions.skills.push(skill); }
  }
  candidate.extensions = extensions; validateExtensions(extensions);
  const extras = candidate.productivity || defaultProductivity();
  const source = restored.productivity || defaultProductivity();
  for (const memory of source.memories) {
    if (!extras.memories.some((item) => item.id === memory.id)) { extras.memories.push(memory); }
  }
  for (const template of source.templates) {
    // Older restores regenerated template IDs, including the built-in templates.
    if (!extras.templates.some((item) => item.id === template.id ||
      (item.name === template.name && item.content === template.content))) { extras.templates.push(template); }
  }
  extras.servers = extras.servers.concat(source.servers);
  candidate.productivity = extras; validateProductivity(extras);
  return { data: candidate, threads: restored.threads, providerIds: providerIds };
}

export interface ProjectCandidate {
  data: AppData;
  project: ProjectData;
  addedFolders: SharedFolder[];
  removedFolders: SharedFolder[];
}

export function savedProjectCandidate(local: AppData, name: string, instructions: string,
  createThread: () => ThreadData, createId: () => string, id?: string, folders?: SharedFolder[]): ProjectCandidate {
  const candidate = JSON.parse(JSON.stringify(local)) as AppData;
  const projects = candidate.projects || [];
  let project = id ? projects.find((item) => item.id === id) : undefined;
  if (id && !project) { throw new Error(t('会话关联的项目不存在。')); }
  validateSharedFolders(folders);
  const previousFolders = project?.sharedFolders || [];
  const nextFolders = folders === undefined ? previousFolders.slice() : JSON.parse(JSON.stringify(folders)) as SharedFolder[];
  const now = Date.now();
  if (project) {
    project.name = projectName(name); project.instructions = instructions; project.updatedAt = now;
    project.sharedFolders = nextFolders;
  } else {
    const projectId = createId();
    project = { id: projectId, name: projectName(name), workspaceId: 'project-' + projectId,
      instructions: instructions, createdAt: now, updatedAt: now, sharedFolders: nextFolders };
    projects.push(project);
    const thread = createThread(); thread.projectId = project.id;
    candidate.threads.unshift(thread); candidate.activeThreadId = thread.id;
  }
  candidate.projects = projects;
  validateProjects(candidate);
  const previousUris = new Set<string>(previousFolders.map((folder) => folder.uri));
  const nextUris = new Set<string>(nextFolders.map((folder) => folder.uri));
  return { data: candidate, project: project,
    addedFolders: nextFolders.filter((folder) => !previousUris.has(folder.uri)),
    removedFolders: previousFolders.filter((folder) => !nextUris.has(folder.uri) &&
      !projects.some((item) => (item.sharedFolders || []).some((shared) => shared.uri === folder.uri))) };
}

export function forkedThreadCandidate(source: ThreadData, createThread: () => ThreadData,
  selection: ToolSelection, messageId: string): ThreadData {
  const index = messageId ? source.messages.findIndex((item) => item.id === messageId) : source.messages.length - 1;
  if (messageId && index < 0) { throw new Error(t('消息已不存在。')); }
  const end = index < 0 ? 0 : index % 2 === 0 ? index : index + 1;
  const branch = createThread();
  branch.title = source.title.slice(0, 26) + t(' · 分支'); branch.titleEdited = true;
  branch.parentThreadId = source.id; branch.parentMessageId = index >= 0 ? source.messages[index].id : undefined;
  branch.modelRef = source.modelRef; branch.projectId = source.projectId; branch.reasoningEffort = source.reasoningEffort;
  branch.teamEnabled = source.teamEnabled; branch.agentMode = selection.agentMode; branch.disabledTools = selection.disabledTools;
  branch.disabledMcpIds = source.disabledMcpIds?.slice();
  branch.messages = JSON.parse(JSON.stringify(source.messages.slice(0, end))) as MessageData[];
  branch.draft = index >= 0 && index % 2 === 0 ? source.messages[index].content : '';
  branch.attachments = index >= 0 && index % 2 === 0 ? JSON.parse(JSON.stringify(source.messages[index].attachments || [])) as Attachment[] : [];
  branch.references = index >= 0 && index % 2 === 0 ? (source.messages[index].references || []).map((item): ThreadReference => ({
    threadId: item.threadId, title: item.title, content: item.content, capturedAt: item.capturedAt,
    truncated: item.truncated, fullContent: item.fullContent })) : [];
  return branch;
}
