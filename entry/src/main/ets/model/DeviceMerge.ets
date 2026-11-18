import { AppData, MessageData, ThreadData, emptyData, parseAppData } from './Conversation';
import { ProjectData, workspaceIdFor, validateProjects } from './Project';
import { defaultProductivity } from './Productivity';
import { mergeBackupSkills } from './BackupSettings';
import { defaultExtensions } from './Skills';
import { threadWorkspacePath } from './Workspace';
import { contentVersion } from '../services/TextDigest';
import { threadAttachments } from './ThreadAttachments';
import { t } from './I18n';

export function deviceData(source: AppData): AppData {
  const data = emptyData();
  data.config.userDocument = source.config.userDocument;
  data.threads = source.threads; data.activeThreadId = source.activeThreadId;
  data.projects = (source.projects || []).map((project): ProjectData => ({ id: project.id, workspaceId: project.workspaceId,
    name: project.name, instructions: project.instructions, createdAt: project.createdAt, updatedAt: project.updatedAt }));
  data.productivity = { memories: source.productivity?.memories || [], templates: source.productivity?.templates || [], servers: [] };
  if (source.extensions) { data.extensions = { webEnabled: true, skills: source.extensions.skills }; }
  return data;
}

export interface DeviceMerge { data: AppData; roots: Map<string, string>; threads: number; branches: number; }

function messageHistory(message: MessageData): string {
  // A document can have a different physical workspace on a peer or branch.
  return JSON.stringify(message, (key: string, value: Object): Object | undefined => key === 'workspaceId' ? undefined : value);
}

function commonMessages(a: ThreadData, b: ThreadData): number {
  let count = 0;
  while (count < a.messages.length && count < b.messages.length && a.messages[count].id === b.messages[count].id &&
    messageHistory(a.messages[count]) === messageHistory(b.messages[count])) { count++; }
  return count;
}

// The caller supplies a detached local snapshot. The owning session commits it after files are verified.
export async function mergeDeviceData(local: AppData, remote: AppData): Promise<DeviceMerge> {
  const incoming = parseAppData(JSON.stringify(remote));
  const roots = new Map<string, string>(), ids = new Map<string, string>();
  const projects = local.projects || [];
  for (const project of incoming.projects || []) {
    project.sharedFolders = undefined;
    const current = projects.find(item => item.id === project.id);
    if (current) {
      roots.set(project.workspaceId, current.workspaceId);
      if (project.updatedAt > current.updatedAt) {
        current.name = project.name; current.instructions = project.instructions; current.updatedAt = project.updatedAt;
      }
    } else { projects.push(project); }
  }
  local.projects = projects;
  const accepted: ThreadData[] = [];
  let branches = 0;
  const sourceRoots = new Map<string, string>();
  for (const thread of incoming.threads) { sourceRoots.set(thread.id, workspaceIdFor(incoming, thread)); }
  for (const thread of incoming.threads) {
    const original = thread.id, family = thread.syncRootId || original;
    threadWorkspacePath('', original); threadWorkspacePath('', family);
    const siblings = local.threads.filter(item => (item.syncRootId || item.id) === family);
    let current = siblings.find(item => item.id === original);
    let shared = current ? commonMessages(current, thread) : -1;
    // A peer can send back a branch which this installation still displays as the original.
    for (const sibling of siblings) {
      if (sibling === current) { continue; }
      const overlap = commonMessages(sibling, thread);
      if (overlap > shared) { current = sibling; shared = overlap; }
    }
    const diverged = current !== undefined && shared < Math.min(current.messages.length, thread.messages.length);
    if (diverged && current) {
      const hash = await contentVersion(JSON.stringify([family, shared, messageHistory(thread.messages[shared])]));
      const branch = 'branch-' + hash.replace(/\+/g, '-').replace(/\//g, '_').slice(0, 43);
      if (local.threads.some(item => item.id === branch)) { throw new Error('Conflicting device branch identity'); }
      if (thread.sideChatContext === undefined) {
        thread.parentThreadId = current.id;
        thread.parentMessageId = shared ? current.messages[shared - 1].id : undefined;
      }
      thread.id = branch; thread.syncRootId = family;
      thread.title = t('{0}（分支）', [thread.title]); current = undefined; branches++;
    } else if (current) {
      thread.id = current.id; thread.syncRootId = current.syncRootId;
      thread.parentThreadId = current.parentThreadId; thread.parentMessageId = current.parentMessageId;
    }
    if (original !== thread.id) {
      ids.set(original, thread.id);
      if (sourceRoots.get(original) === original) { roots.set(original, thread.id); }
    }
    if (current) {
      if (thread.messages.length < current.messages.length ||
        (thread.messages.length === current.messages.length && thread.updatedAt <= current.updatedAt)) { continue; }
      thread.draft = current.draft; thread.attachments = current.attachments;
      thread.pendingInputs = current.pendingInputs;
    }
    thread.queuePaused = true; thread.toolApprovalMode = undefined;
    if (current) { local.threads[local.threads.indexOf(current)] = thread; } else { local.threads.push(thread); }
    accepted.push(thread);
  }
  for (const thread of accepted) {
    if (thread.parentThreadId && thread.id !== ids.get(thread.parentThreadId)) {
      thread.parentThreadId = ids.get(thread.parentThreadId) || thread.parentThreadId;
    }
    for (const attachment of threadAttachments(thread)) {
      if (attachment.workspaceId) { attachment.workspaceId = roots.get(attachment.workspaceId) || attachment.workspaceId; }
    }
    for (const reference of (thread.references || []).concat(...thread.messages.map(item => item.references || []),
      ...(thread.pendingInputs || []).map(item => item.references || []))) {
      reference.threadId = ids.get(reference.threadId) || reference.threadId;
    }
  }
  const extras = local.productivity || defaultProductivity();
  for (const memory of incoming.productivity?.memories || []) {
    memory.threadId = ids.get(memory.threadId) || memory.threadId;
    if (memory.sourceThreadId) { memory.sourceThreadId = ids.get(memory.sourceThreadId) || memory.sourceThreadId; }
    const pos = extras.memories.findIndex(item => item.id === memory.id);
    if (pos < 0) { extras.memories.push(memory); } else if (memory.updatedAt > extras.memories[pos].updatedAt) { extras.memories[pos] = memory; }
  }
  for (const template of incoming.productivity?.templates || []) {
    if (!extras.templates.some(item => item.id === template.id)) { extras.templates.push(template); }
  }
  local.productivity = extras;
  if (!local.config.userDocument) { local.config.userDocument = incoming.config.userDocument; }
  local.extensions = local.extensions || defaultExtensions();
  if (incoming.extensions) {
    incoming.extensions.webEnabled = local.extensions.webEnabled;
    incoming.extensions.browserPolicy = local.extensions.browserPolicy;
    mergeBackupSkills(local, incoming);
  }
  if (!local.activeThreadId) {
    local.activeThreadId = ids.get(incoming.activeThreadId) || incoming.activeThreadId ||
      accepted.find(thread => !thread.sideChatContext)?.id || '';
  }
  validateProjects(local);
  return { data: local, roots: roots, threads: accepted.length, branches: branches };
}
