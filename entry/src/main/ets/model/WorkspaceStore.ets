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

  private async ensureDirectory(path: string): Promise<void> {
    if (!await fs.access(path)) {
      await fs.mkdir(path);
    }
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('工作区路径必须是目录，不能是文件或符号链接：' + path);
    }
  }
}
