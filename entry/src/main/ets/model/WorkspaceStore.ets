import { t } from './I18n';
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
    await this.ensureDirectory(this.rootDir);
    await this.ensureDirectory(path);
  }

  async requireWorkspace(id: string): Promise<void> {
    const path = this.pathFor(id);
    for (const directory of [this.rootDir, path]) {
      if (!await fs.access(directory)) { throw new Error(t('项目工作区不存在，请从备份恢复。')); }
      const stat = await fs.lstat(directory);
      if (!stat.isDirectory() || stat.isSymbolicLink()) { throw new Error(t('工作区路径必须是目录，不能是符号链接。')); }
    }
  }

  private async ensureDirectory(path: string): Promise<void> {
    if (!await fs.access(path)) {
      await fs.mkdir(path);
    }
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(t("工作区路径必须是目录，不能是文件或符号链接：") + path);
    }
  }
}
