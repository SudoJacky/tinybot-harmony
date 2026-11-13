import { ProjectData } from './Project';
import { ThreadViewModel } from '../viewmodel/SessionViewModels';

export type DesktopCommand = 'new-chat' | 'standalone' | 'history' | 'files' | 'browser' | 'detail' |
  'tools' | 'skills' | 'life-panels' | 'settings' | 'help' | 'thread';

export class DesktopCommandItem {
  id: string;
  action: DesktopCommand;
  label: string;
  detail: string;
  messageId: string;
  query: string;
  excerpt: string = '';

  constructor(action: DesktopCommand, label: string, detail: string = '', threadId: string = '', messageId: string = '', query: string = '') {
    this.id = threadId || action;
    this.action = action;
    this.label = label;
    this.detail = detail;
    this.messageId = messageId;
    this.query = query;
  }
}

const RESULT_LIMIT: number = 24;

export function desktopCommandResults(commands: DesktopCommandItem[], query: string,
  threads: ThreadViewModel[], projects: ProjectData[], ordinaryLabel: string): DesktopCommandItem[] {
  const commandsOnly = query.trimStart().startsWith('>');
  const needle = (commandsOnly ? query.trimStart().slice(1) : query).trim().toLocaleLowerCase();
  const matchingCommands = commands.filter((command) =>
    (command.label + ' ' + command.detail).toLocaleLowerCase().includes(needle));
  if (commandsOnly) { return matchingCommands; }

  const threadResults: DesktopCommandItem[] = [];
  const titles: DesktopCommandItem[] = [];
  const projectsById = new Map(projects.map((project: ProjectData) => [project.id, project.name]));
  // The caller has already matched message contents with the same search as the sidebar.
  const candidates = needle.length === 0 ? threads.slice().sort((left, right) => right.updatedAt - left.updatedAt).slice(0, 6) : threads;
  for (const thread of candidates) {
    const titleMatch = thread.displayTitle.toLocaleLowerCase().includes(needle);
    const message = needle.length === 0 || titleMatch ? undefined :
      thread.messages.find((item) => item.content.toLocaleLowerCase().includes(needle));
    const project = projectsById.get(thread.projectId || '') || ordinaryLabel;
    const item = new DesktopCommandItem('thread', thread.displayTitle, project, thread.id, message?.id || '', message ? needle : '');
    if (message) {
      const match = message.content.toLocaleLowerCase().indexOf(needle);
      const start = Math.max(0, match - 24);
      const end = Math.min(message.content.length, match + Math.max(needle.length, 56));
      item.excerpt = (start > 0 ? '…' : '') + message.content.slice(start, end).replace(/\s+/g, ' ').trim() +
        (end < message.content.length ? '…' : '');
    }
    if (titleMatch && needle.length > 0) {
      if (titles.length < RESULT_LIMIT) { titles.push(item); }
    } else if (threadResults.length < RESULT_LIMIT) { threadResults.push(item); }
    if (titles.length >= RESULT_LIMIT) { break; }
  }
  if (needle.length === 0) { return threadResults.concat(matchingCommands); }
  return matchingCommands.concat(titles, threadResults).slice(0, RESULT_LIMIT);
}
