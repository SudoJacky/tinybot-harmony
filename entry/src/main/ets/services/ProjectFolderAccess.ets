import { t } from '../model/I18n';
import { ProjectData } from '../model/Project';
import { SharedFolder } from '../model/SharedFolders';
import { fileShare } from '@kit.CoreFileKit';

const FOLDER_CAPABILITY: string = 'SystemCapability.FileManagement.AppFileService.FolderAuthorization';
const READ_WRITE: number = fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE;
const activated: Set<string> = new Set<string>();
let queue: Promise<void> = Promise.resolve();

// Persist once when the user saves a project, then activate again after each process start.
export class ProjectFolderAccess {
  static supported(): boolean {
    try { return canIUse(FOLDER_CAPABILITY); } catch (_) { return false; }
  }

  static canSelectFolders(): boolean {
    try { return canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection'); } catch (_) { return false; }
  }

  static async persist(folders: SharedFolder[]): Promise<void> {
    if (folders.length === 0) { return; }
    ProjectFolderAccess.requireSupport();
    const policies: fileShare.PolicyInfo[] = folders.map((folder: SharedFolder): fileShare.PolicyInfo => {
      return { uri: folder.uri, operationMode: READ_WRITE };
    });
    try {
      // Retrying a failed project save must not fail because the grant was already persisted.
      const existing = await fileShare.checkPersistentPermission(policies);
      const missing = policies.filter((policy: fileShare.PolicyInfo, index: number) => !existing[index]);
      if (missing.length > 0) { await fileShare.persistPermission(missing); }
    } catch (error) {
      throw new Error(t('无法保存共享文件夹权限：') + (error as Error).message);
    }
  }

  static activate(folders: SharedFolder[]): Promise<void> {
    const run = async (): Promise<void> => {
      const pending = folders.filter((folder: SharedFolder) => folder.uri.length > 0 && !activated.has(folder.uri));
      if (pending.length === 0) { return; }
      ProjectFolderAccess.requireSupport();
      const policies: fileShare.PolicyInfo[] = pending.map((folder: SharedFolder): fileShare.PolicyInfo => {
        return { uri: folder.uri, operationMode: READ_WRITE };
      });
      try {
        await fileShare.activatePermission(policies);
      } catch (error) {
        const name = pending[0].name;
        throw new Error(t('无法访问共享文件夹 {0}：', [name]) + (error as Error).message);
      }
      for (const folder of pending) { activated.add(folder.uri); }
    };
    const next = queue.then(run, run);
    // Keep the queue healthy after a failed activation; callers still receive the original error.
    queue = next.catch(() => {});
    return next;
  }

  // Removing a project folder is already committed; stale system permission must not fail that save.
  static async revoke(folders: SharedFolder[]): Promise<void> {
    if (folders.length === 0 || !ProjectFolderAccess.supported()) { return; }
    const policies: fileShare.PolicyInfo[] = folders.map((folder: SharedFolder): fileShare.PolicyInfo => {
      return { uri: folder.uri, operationMode: READ_WRITE };
    });
    try { await fileShare.revokePermission(policies); } catch (_) { /* Permission may already be gone. */ }
    for (const folder of folders) { activated.delete(folder.uri); }
  }

  // Startup activation is best effort: a missing or revoked grant must not hide the rest of the app.
  static async activateAll(projects: ProjectData[]): Promise<void> {
    for (const project of projects) {
      const folders = project.sharedFolders || [];
      if (folders.length === 0) { continue; }
      try { await ProjectFolderAccess.activate(folders); } catch (_) { /* Surface on first file access. */ }
    }
  }

  private static requireSupport(): void {
    if (!ProjectFolderAccess.supported()) { throw new Error(t('当前设备不支持项目共享文件夹。')); }
  }
}
