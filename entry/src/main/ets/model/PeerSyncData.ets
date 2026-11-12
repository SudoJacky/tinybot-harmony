import { AppData, MessageData, ThreadData, emptyData, parseAppData } from './Conversation';
import { ProjectData, validateProjects } from './Project';
import { threadWorkspacePath } from './Workspace';

export interface PeerThreadUpdate {
  origin: string;
  id: string;
  collisionId: string;
  thread?: ThreadData;
  direct?: boolean;
}

// A request's random prefix correlates device logs without recording the request or conversation identifier.
export function nearbyTraceId(id?: string): number | undefined {
  return id && /^remote-[0-9a-f]{8}-/.test(id) ? parseInt(id.slice(7, 15), 16) : undefined;
}

export function peerHasOutput(message: MessageData): boolean {
  return !!message.content || !!message.steps?.some((step) => !!step.content || !!step.reasoningContent || step.tools.length > 0);
}

export function peerThreadText(thread: ThreadData): string {
  const copy = JSON.parse(JSON.stringify(thread)) as ThreadData;
  copy.peerOwner = undefined; copy.peerThreadId = undefined;
  copy.peerDraft = undefined;
  copy.peerAttachments = undefined; copy.peerReferences = undefined;
  copy.peerInputReceipts = undefined;
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
  const checked = parseAppData(JSON.stringify(data), false).threads[0];
  checked.projectId = projectId;
  checked.peerDraft = undefined;
  checked.peerAttachments = undefined; checked.peerReferences = undefined;
  checked.peerInputReceipts = undefined;
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
