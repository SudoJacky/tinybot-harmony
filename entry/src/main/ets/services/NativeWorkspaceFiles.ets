import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Cancellation } from './Cancellation';
import { MAX_FILE_BYTES, WorkspaceFiles, workspaceRelativePath } from './WorkspaceTools';

interface FileEntry {
  name: string;
  kind: string;
}

export class NativeWorkspaceFiles implements WorkspaceFiles {
  private root: string;

  constructor(workspaceDir: string) {
    this.root = workspaceDir;
  }

  async list(path: string, cancellation: Cancellation): Promise<string> {
    const absolute = await this.resolve(path, false, cancellation);
    await this.requireDirectory(absolute);
    cancellation.check();
    const names = await fs.listFile(absolute, { recursion: false, listNum: 201 });
    const entries: FileEntry[] = [];
    for (const name of names.slice(0, 200).sort()) {
      cancellation.check();
      const stat = await fs.lstat(absolute + '/' + name);
      entries.push({ name: name, kind: stat.isSymbolicLink() ? 'symlink' : stat.isDirectory() ? 'directory' : 'file' });
    }
    return JSON.stringify({ path: path || '.', entries: entries, truncated: names.length > 200 });
  }

  async read(path: string, cancellation: Cancellation): Promise<string> {
    const absolute = await this.resolve(path, false, cancellation);
    cancellation.check();
    const file = await fs.open(absolute, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile() || stat.size > MAX_FILE_BYTES) {
        throw new Error('只能读取不超过 64 KiB 的普通文本文件。');
      }
      const buffer = new Uint8Array(MAX_FILE_BYTES + 1);
      let total = 0;
      while (total < buffer.byteLength) {
        cancellation.check();
        const chunk = new ArrayBuffer(buffer.byteLength - total);
        const count = await fs.read(file.fd, chunk);
        if (count === 0) {
          break;
        }
        buffer.set(new Uint8Array(chunk, 0, count), total);
        total += count;
      }
      if (total > MAX_FILE_BYTES) {
        throw new Error('文件超过 64 KiB 读取上限。');
      }
      const content = new util.TextDecoder('utf-8', { fatal: true }).decodeToString(buffer.slice(0, total));
      if (content.includes('\u0000')) {
        throw new Error('此文件不是可读取的文本文件。');
      }
      cancellation.check();
      return JSON.stringify({ path: path, content: content });
    } finally {
      await fs.close(file);
    }
  }

  async write(path: string, content: string, cancellation: Cancellation): Promise<string> {
    const bytes = new util.TextEncoder().encodeInto(content);
    if (bytes.byteLength > MAX_FILE_BYTES || content.includes('\u0000')) {
      throw new Error('写入内容必须是不超过 64 KiB 的文本，不能包含空字符。');
    }
    const absolute = await this.resolve(path, true, cancellation);
    const existing = await this.optionalStat(absolute);
    if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
      throw new Error('只能写入普通文件，不能覆盖目录或符号链接。');
    }
    cancellation.check();
    const parent = absolute.slice(0, absolute.lastIndexOf('/'));
    const temporary = parent + '/.tinybot-' + util.generateRandomUUID() + '.tmp';
    const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
    let committed = false;
    try {
      try {
        let written = 0;
        while (written < bytes.byteLength) {
          cancellation.check();
          const count = await fs.write(file.fd, bytes.buffer.slice(written), { offset: written });
          if (count <= 0) {
            throw new Error('工作区文件写入未完成。');
          }
          written += count;
        }
        await fs.fsync(file.fd);
      } finally {
        await fs.close(file);
      }
      cancellation.check();
      await fs.rename(temporary, absolute);
      committed = true;
      return JSON.stringify({ path: path, bytes: bytes.byteLength, written: true });
    } catch (error) {
      if (!committed) {
        try {
          await fs.unlink(temporary);
        } catch (cleanupError) {
          throw new Error((error as Error).message + '；临时文件清理也失败：' + (cleanupError as Error).message);
        }
      }
      throw error as Error;
    }
  }

  // Every component is checked: a nested symlink must never widen the workspace.
  private async resolve(path: string, createParents: boolean, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (!this.root.startsWith('/') || this.root.endsWith('/')) {
      throw new Error('会话工作区尚未就绪。');
    }
    const relative = workspaceRelativePath(path || '.', !createParents);
    await this.requireDirectory(this.root.slice(0, this.root.lastIndexOf('/')));
    await this.requireDirectory(this.root);
    let current = this.root;
    const parts = relative.length > 0 ? relative.split('/') : [];
    for (let index = 0; index < parts.length; index++) {
      cancellation.check();
      current += '/' + parts[index];
      let stat = await this.optionalStat(current);
      if (!stat && createParents && index < parts.length - 1) {
        await fs.mkdir(current);
        stat = await fs.lstat(current);
      }
      if (stat?.isSymbolicLink()) {
        throw new Error('工作区工具不允许访问符号链接。');
      }
      if (index < parts.length - 1 && (!stat || !stat.isDirectory())) {
        throw new Error('工作区路径中的父目录不存在或不是目录。');
      }
    }
    return current;
  }

  private async requireDirectory(path: string): Promise<void> {
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('工作区路径必须是目录，不能是符号链接。');
    }
  }

  private async optionalStat(path: string): Promise<fs.Stat | undefined> {
    try {
      return await fs.lstat(path);
    } catch (error) {
      if ((error as BusinessError).code === 13900002) {
        return undefined;
      }
      throw error as Error;
    }
  }
}
