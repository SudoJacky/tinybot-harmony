import { fileIo as fs } from '@kit.CoreFileKit';
import { AppData } from '../model/Conversation';
import { PanelSource, validatePanelSource } from '../model/PanelSource';
import { threadWorkspacePath } from '../model/Workspace';
import { withFileMutation } from './FileMutationQueue';
export interface WorkspaceOwnership {
  id: string; miniApps: boolean; lifePanels: boolean; lifeBoards: boolean; review: boolean; sources: string[]; manifests: string[];
}
interface SourceOwner { definition?: SourceDefinition; }
interface SourceDefinition { source?: PanelSource; }
// Publications and workspace deletion share one short admission lane. A stale
// cleanup snapshot cannot remove a newly published artifact or its source files.
export function withWorkspaceLifecycle<T>(workspace: string, operation: () => Promise<T>): Promise<T> {
  return withFileMutation('workspace-lifecycle:' + workspace.slice(0, workspace.lastIndexOf('/')), operation);
}
export class WorkspaceRetention {
  static async inventory(root: string): Promise<WorkspaceOwnership[]> {
    const result: WorkspaceOwnership[] = [];
    if (!await fs.access(root)) { return result; }
    for (const id of await fs.listFile(root)) {
      const path = threadWorkspacePath(root, id), stat = await fs.lstat(path);
      if (stat.isSymbolicLink()) { throw new Error('Workspace ownership cannot follow symbolic links'); }
      if (!stat.isDirectory()) { continue; }
      const item: WorkspaceOwnership = { id: id, miniApps: false, lifePanels: false, lifeBoards: false, review: false, sources: [], manifests: [] };
      for (const kind of ['mini-apps', 'life-panels', 'life-boards', '.tinybot-review']) {
        const directory = path + '/' + kind; if (!await fs.access(directory)) { continue; }
        const info = await fs.lstat(directory);
        if (info.isSymbolicLink() || !info.isDirectory()) { throw new Error('Invalid persistent workspace directory'); }
        const names = await fs.listFile(directory), present = names.length > 0;
        if (kind === 'mini-apps') { item.miniApps = present; }
        else if (kind === 'life-panels') { item.lifePanels = present; }
        else if (kind === 'life-boards') { item.lifeBoards = present; }
        else { item.review = present; }
        if (kind === '.tinybot-review') { continue; }
        for (const panel of names) {
          const folder = threadWorkspacePath(directory, panel), folderStat = await fs.lstat(folder);
          if (!folderStat.isDirectory() || folderStat.isSymbolicLink()) { throw new Error('Invalid persistent card directory'); }
          const manifest = folder + '/' + (kind === 'mini-apps' ? 'app.json' : kind === 'life-boards' ? 'board.json' : 'panel.json'); if (!await fs.access(manifest)) { continue; }
          const file = await fs.lstat(manifest); if (!file.isFile() || file.isSymbolicLink()) { throw new Error('Invalid persistent card manifest'); }
          if (!item.manifests.includes(kind)) { item.manifests.push(kind); }
          if (kind !== 'life-panels') { continue; }
          const saved = JSON.parse(await fs.readText(manifest)) as SourceOwner, source = saved.definition?.source;
          if (source?.type === 'workspace-json' && source.workspaceId !== undefined) {
            validatePanelSource(source); item.sources.push(source.workspaceId);
          }
        }
      }
      result.push(item);
    }
    return result;
  }
  static retained(data: AppData | undefined, inventory: WorkspaceOwnership[], review: boolean = true): Set<string> {
    const ids = new Set<string>((data?.threads || []).filter((thread) => !thread.projectId).map((thread) => thread.id)
      .concat((data?.projects || []).map((project) => project.workspaceId)));
    for (const item of inventory) {
      if (item.miniApps || item.lifePanels || item.lifeBoards || review && item.review) { ids.add(item.id); }
      item.sources.forEach((id: string) => ids.add(id));
    }
    return ids;
  }
}
