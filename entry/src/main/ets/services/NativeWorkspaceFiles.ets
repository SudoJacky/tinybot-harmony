import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Cancellation } from './Cancellation';
import { workspaceRelativePath } from './WorkspaceTools';
import { readUtf8File } from './TextFiles';
import { TextEdit, applyTextEdits, validateEdits } from '../model/WorkspaceEdit';
import { withFileMutation } from './FileMutationQueue';
import { ToolFailure } from '../model/ToolFailure';

import { WorkspaceFiles, WorkspaceEntry, WorkspaceListing, WorkspaceText, WorkspaceWrite, WorkspaceWriteGuard, FileBaseline } from './WorkspaceFiles';

async function contentVersion(content: string): Promise<string> {
  const hash = cryptoFramework.createMd('SHA256');
  // The device encoder returns undefined for an empty string.
  if (content.length > 0) { await hash.update({ data: new util.TextEncoder().encodeInto(content) }); }
  return new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
}

export class NativeWorkspaceFiles implements WorkspaceFiles {
  private root: string;

  constructor(workspaceDir: string) {
    this.root = workspaceDir;
  }

  async checkedPath(path: string): Promise<string> {
    const absolute = await this.resolve(path, false, new Cancellation());
    const stat = await fs.lstat(absolute);
    if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t("请选择普通文件。")); }
    return absolute;
  }

  async list(path: string, cancellation: Cancellation, offset: number = 0): Promise<WorkspaceListing> {
    if (!Number.isSafeInteger(offset) || offset < 0) { throw new ToolFailure('FS_INVALID_ARGUMENTS', 'Invalid directory offset.', 'fix_arguments', path); }
    const absolute = await this.resolve(path, false, cancellation);
    await this.requireDirectory(absolute);
    cancellation.check();
    const names = (await fs.listFile(absolute, { recursion: false })).filter((name: string) => !name.startsWith('.tinybot-')).sort();
    const entries: WorkspaceEntry[] = [];
    for (const name of names.slice(offset, offset + 200)) {
      cancellation.check();
      const stat = await fs.lstat(absolute + '/' + name);
      entries.push({ name: name, kind: stat.isSymbolicLink() ? 'symlink' : stat.isDirectory() ? 'directory' : 'file' });
    }
    return { path: path || '.', entries: entries, truncated: names.length > offset + 200,
      nextOffset: names.length > offset + 200 ? offset + 200 : undefined };
  }

  async read(path: string, cancellation: Cancellation): Promise<WorkspaceText> {
    const absolute = await this.resolve(path, false, cancellation);
    cancellation.check();
    const file = await fs.open(absolute, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const content = await readUtf8File(file.fd, cancellation);
      return { path: path, content: content, version: await contentVersion(content) };
    } finally {
      await fs.close(file);
    }
  }

  async write(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite> {
    workspaceRelativePath(path, false);
    return withFileMutation(this.root + '/' + path, () => this.mutate(path, content, [], cancellation, guard));
  }

  async edit(path: string, edits: TextEdit[], version: string, cancellation: Cancellation): Promise<WorkspaceWrite> {
    workspaceRelativePath(path, false);
    validateEdits(edits);
    return withFileMutation(this.root + '/' + path, () => this.mutate(path, '', edits, cancellation, { version: version }));
  }

  private async mutate(path: string, content: string, edits: TextEdit[], cancellation: Cancellation,
    guard?: WorkspaceWriteGuard, capture: boolean = true): Promise<WorkspaceWrite> {
    cancellation.check();
    const absolute = await this.resolve(path, true, cancellation);
    const existing = await this.optionalStat(absolute);
    if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
      throw new Error(t("只能写入普通文件，不能覆盖目录或符号链接。"));
    }
    if (guard && guard.version === null && existing) { throw new ToolFailure('FS_NOT_OBSERVED', t('覆盖已有文件前，请先用 read_file 或 read_file_lines 读取。'), 'read_file', path); }
    const original = existing ? await this.read(path, cancellation) : undefined;
    if (guard && guard.version !== null && (!original || original.version !== guard.version)) {
      throw new ToolFailure('FS_STALE_VERSION', t('文件自上次读取后已变化，请重新读取再修改。'), 'read_file', path);
    }
    const before = original ? original.content : '';
    if (edits.length > 0) { content = applyTextEdits(before, edits); }
    // Some device SDKs return undefined for encodeInto(''), despite its declared return type.
    const bytes = content.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(content);
    if (content.includes('\u0000')) {
      throw new Error(t('文本不能包含空字符。'));
    }
    const version = await contentVersion(content);
    if (capture) { await this.capture(path, existing !== undefined, cancellation, before); }
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
            throw new Error(t("工作区文件写入未完成。"));
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
      return { path: path, bytes: bytes.byteLength, written: true, before: before, after: content, created: !existing, version: version };
    } catch (error) {
      if (!committed) {
        try {
          await fs.unlink(temporary);
        } catch (cleanupError) {
          throw new Error((error as Error).message + t("；临时文件清理也失败：") + (cleanupError as Error).message);
        }
      }
      throw error as Error;
    }
  }

  private baselinePath(path: string): string { return this.root + '/.tinybot-review/' + encodeURIComponent(path) + '.json'; }

  async baseline(path: string): Promise<FileBaseline | undefined> {
    workspaceRelativePath(path, false);
    const location = this.baselinePath(path);
    if (!await fs.access(location)) { return undefined; }
    const item = JSON.parse(await fs.readText(location)) as FileBaseline;
    if (item.path !== path || typeof item.content !== 'string' || typeof item.existed !== 'boolean') { throw new Error(t("文件基线损坏。")); }
    return item;
  }

  private async capture(path: string, existed: boolean, cancellation: Cancellation, content: string): Promise<void> {
    const directory = this.root + '/.tinybot-review';
    if (!await fs.access(directory)) { await fs.mkdir(directory, true); }
    await this.requireDirectory(directory);
    if (await this.baseline(path)) { return; }
    cancellation.check();
    const text = JSON.stringify({ path: path, existed: existed, content: content } as FileBaseline);
    const temporary = directory + '/pending-' + util.generateRandomUUID();
    const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const bytes = new util.TextEncoder().encodeInto(text); let offset = 0;
      while (offset < bytes.byteLength) {
        const count = await fs.write(file.fd, bytes.buffer.slice(offset), { offset: offset });
        if (count <= 0) { throw new Error(t("文件基线写入未完成。")); } offset += count;
      }
      await fs.fsync(file.fd);
    } finally { await fs.close(file); }
    await fs.rename(temporary, this.baselinePath(path));
  }

  async accept(path: string): Promise<void> {
    workspaceRelativePath(path, false);
    return withFileMutation(this.root + '/' + path, () => this.acceptUnlocked(path));
  }

  private async acceptUnlocked(path: string): Promise<void> {
    if (await this.baseline(path)) { await fs.unlink(this.baselinePath(path)); }
  }

  async restore(path: string, expected: string): Promise<void> {
    workspaceRelativePath(path, false);
    return withFileMutation(this.root + '/' + path, () => this.restoreUnlocked(path, expected));
  }

  private async restoreUnlocked(path: string, expected: string): Promise<void> {
    const baseline = await this.baseline(path);
    if (!baseline) { throw new Error(t("没有保存的修改基线。")); }
    const current = await this.read(path, new Cancellation());
    if (current.content !== expected) { throw new Error(t("文件已变化，请重新打开并检查。")); }
    if (baseline.existed) { await this.mutate(path, baseline.content, [], new Cancellation(), { version: current.version }, false); }
    else { await fs.unlink(await this.checkedPath(path)); }
    await this.acceptUnlocked(path);
  }

  // Every component is checked: a nested symlink must never widen the workspace.
  private async resolve(path: string, createParents: boolean, cancellation: Cancellation): Promise<string> {
    cancellation.check();
    if (!this.root.startsWith('/') || this.root.endsWith('/')) {
      throw new Error(t("会话工作区尚未就绪。"));
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
        await fs.mkdir(current, true);
        stat = await fs.lstat(current);
      }
      if (stat?.isSymbolicLink()) {
        throw new Error(t("工作区工具不允许访问符号链接。"));
      }
      if (index < parts.length - 1 && (!stat || !stat.isDirectory())) {
        throw new Error(t("工作区路径中的父目录不存在或不是目录。"));
      }
    }
    return current;
  }

  private async requireDirectory(path: string): Promise<void> {
    const stat = await fs.lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(t("工作区路径必须是目录，不能是符号链接。"));
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
