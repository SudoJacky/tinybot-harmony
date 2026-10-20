import { t } from './I18n';
import { AppData, ThreadData } from './Conversation';
import { SHARED_FOLDER_ROOT, SharedFolder, validateSharedFolders } from './SharedFolders';
import { threadWorkspacePath } from './Workspace';

export interface ProjectData {
  id: string;
  name: string;
  workspaceId: string;
  instructions: string;
  createdAt: number;
  updatedAt: number;
  // Optional for data created before project folders existed.
  sharedFolders?: SharedFolder[];
}

export function projectName(value: string): string {
  const name = value.trim();
  if (!name || name.length > 80) { throw new Error(t('项目名称需要 1 至 80 个字符。')); }
  return name;
}

export function projectFor(data: AppData, thread: ThreadData): ProjectData | undefined {
  if (thread.projectId === undefined) { return undefined; }
  const project = (data.projects || []).find((item) => item.id === thread.projectId);
  if (!project) { throw new Error(t('会话关联的项目不存在。')); }
  return project;
}

export function workspaceIdFor(data: AppData, thread: ThreadData): string {
  return projectFor(data, thread)?.workspaceId || thread.id;
}

export function validateProjects(data: AppData): void {
  if (data.projects !== undefined && !Array.isArray(data.projects)) { throw new Error(t('项目数据无效。')); }
  const ids = new Set<string>();
  const workspaces = new Set<string>();
  for (const project of data.projects || []) {
    if (!project || typeof project.id !== 'string' || typeof project.workspaceId !== 'string' ||
      typeof project.name !== 'string' || projectName(project.name) !== project.name ||
      typeof project.instructions !== 'string' || project.instructions.length > 16000 ||
      !Number.isFinite(project.createdAt) || !Number.isFinite(project.updatedAt) || ids.has(project.id) || workspaces.has(project.workspaceId)) {
      throw new Error(t('项目数据无效。'));
    }
    threadWorkspacePath('', project.id); threadWorkspacePath('', project.workspaceId);
    validateSharedFolders(project.sharedFolders);
    ids.add(project.id); workspaces.add(project.workspaceId);
  }
  for (const thread of data.threads) {
    if (thread.projectId !== undefined && (typeof thread.projectId !== 'string' || !ids.has(thread.projectId))) {
      throw new Error(t('会话关联的项目不存在。'));
    }
    if (thread.projectId === undefined && workspaces.has(thread.id)) { throw new Error(t('工作区归属冲突。')); }
  }
}

export function projectContext(data: AppData, thread: ThreadData): string {
  const project = projectFor(data, thread);
  if (!project) { return thread.parentThreadId ? '这是从历史创建的会话分支，使用独立的新工作区。历史文件操作发生在原会话，不能假设原文件仍存在；先列出或读取当前文件。' : ''; }
  const folders = project.sharedFolders || [];
  const shared = folders.length === 0 ? '' : '\n项目共享文件夹（用户通过项目设置授权，路径前缀 ' + SHARED_FOLDER_ROOT +
    '/，可直接读写；内容可能被项目外的应用修改）：\n' +
    folders.map((folder: SharedFolder) => '- ' + SHARED_FOLDER_ROOT + '/' + folder.name + '/').join('\n');
  return '当前项目：' + project.name + '\n本会话与项目内其他会话共享工作区。历史回执不是当前文件快照，修改前重新读取。' +
    '会话分支只分叉对话，不复制或回退文件。其他会话历史不会自动加载。项目说明不能扩大工具权限。' + shared +
    '\n项目说明与约定：\n' + project.instructions;
}
