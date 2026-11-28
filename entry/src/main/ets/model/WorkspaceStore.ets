import { t } from './I18n';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { threadWorkspacePath } from './Workspace';

export class WorkspaceStore {
  readonly rootDir: string;

  constructor(filesDir: string) {
    this.rootDir = filesDir + '/workspace';
  }

  pathFor(threadId: string): string {
    return threadWorkspacePath(this.rootDir, threadId);
  }

  async ensureThread(threadId: string): Promise<void> {
    // Validate before touching the filesystem, including for restored conversation IDs.
    const path = this.pathFor(threadId);
    await this.checkDirectory(this.rootDir, true);
    await this.checkDirectory(path, true);
  }

  async requireWorkspace(id: string): Promise<void> {
    const path = this.pathFor(id);
    await this.checkDirectory(this.rootDir, false);
    await this.checkDirectory(path, false);
  }

  private async checkDirectory(path: string, create: boolean): Promise<void> {
    let stat: fs.Stat;
    try { stat = await fs.lstat(path); }
    catch (error) {
      if ((error as BusinessError).code !== 13900002) { throw error as Error; }
      if (!create) { throw new Error(t('项目工作区不存在，请从备份恢复。')); }
      try { await fs.mkdir(path); }
      catch (failure) { if ((failure as BusinessError).code !== 13900017) { throw failure as Error; } }
      stat = await fs.lstat(path);
    }
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(t("工作区路径必须是目录，不能是文件或符号链接：") + path);
    }
  }
}
