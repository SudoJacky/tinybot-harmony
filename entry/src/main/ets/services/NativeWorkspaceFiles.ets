import { t } from '../model/I18n';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Cancellation } from './Cancellation';
import { workspaceRelativePath } from './WorkspaceTools';
import { readUtf8File } from './TextFiles';
import { copyFileBytes } from './FileBytes';
import { isDocumentPath, readDocumentFile } from './DocumentFiles';
import { TextEdit, applyTextEdits, validateEdits } from '../model/WorkspaceEdit';
import { withFileMutation } from './FileMutationQueue';
import { ToolFailure } from '../model/ToolFailure';
import { SHARED_FOLDER_ROOT, SharedFolder } from '../model/SharedFolders';
import { ProjectFolderAccess } from './ProjectFolderAccess';

import { WorkspaceFiles, WorkspaceEntry, WorkspaceListing, WorkspaceText, WorkspaceWrite, WorkspaceWriteGuard, FileBaseline } from './WorkspaceFiles';

async function contentVersion(content: string): Promise<string> {
  const hash = cryptoFramework.createMd('SHA256');
  // The device encoder returns undefined for an empty string.
  if (content.length > 0) { await hash.update({ data: new util.TextEncoder().encodeInto(content) }); }
  return new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
}

interface MountPath { folder: SharedFolder; relative: string; }

export class NativeWorkspaceFiles implements WorkspaceFiles {
  private root: string;
  private mounts: SharedFolder[];

  constructor(workspaceDir: string, sharedFolders: SharedFolder[] = []) {
    this.root = workspaceDir;
    this.mounts = sharedFolders.slice();
  }

  async importFile(source: string, path: string, reuse: boolean = false): Promise<void> {
    if (this.isShared(path)) { throw new Error('Import files into the private workspace.'); }
    await withFileMutation(this.root + '/' + path, async () => {
      const destination = await this.resolve(path, true, new Cancellation());
      if (await this.optionalStat(destination)) {
        await this.checkedPath(path);
        if (reuse && await this.fileDigest(source) === await this.fileDigest(destination)) { return; }
        throw new Error('The destination already exists with different content: ' + path);
      }
      await copyFileBytes(source, destination);
    });
  }

  private async fileDigest(path: string): Promise<string> {
    const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const hash = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(64 * 1024);
      while (true) {
        const count = await fs.read(file.fd, buffer); if (!count) { break; }
        await hash.update({ data: new Uint8Array(buffer.slice(0, count)) });
      }
      return new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
    } finally { await fs.close(file); }
  }

  private assertTextWritable(path: string): void {
    if (path.startsWith('attachments/') || isDocumentPath(path)) {
      throw new ToolFailure('READ_ONLY', 'Original attachments and binary documents cannot be edited as text. Save changes to a separate text file.',
        'choose_another_path', { path: path });
    }
  }

  async checkedPath(path: string): Promise<string> {
    if (this.isShared(path)) {
      const mount = await this.requireMount(path);
      const stat = await this.externalStat(mount.folder, mount.relative);
      if (!stat || !stat.isFile() || stat.isSymbolicLink()) { throw new Error(t("请选择普通文件。")); }
      return this.externalUri(mount.folder, mount.relative);
    }
    const absolute = await this.resolve(path, false, new Cancellation());
    const stat = await fs.lstat(absolute);
    if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t("请选择普通文件。")); }
    return absolute;
  }

  async list(path: string, cancellation: Cancellation, offset: number = 0): Promise<WorkspaceListing> {
    if (!Number.isSafeInteger(offset) || offset < 0) { throw new ToolFailure('FS_INVALID_ARGUMENTS', 'Invalid directory offset.', 'fix_arguments', { path: path }); }
    if (this.isShared(path)) {
      await this.activate();
      if (path === SHARED_FOLDER_ROOT) {
        const entries: WorkspaceEntry[] = this.mounts.map((folder: SharedFolder): WorkspaceEntry => {
          return { name: folder.name, kind: 'directory' };
        });
        entries.sort((a: WorkspaceEntry, b: WorkspaceEntry) => a.name.localeCompare(b.name));
        return { path: path, entries: entries.slice(offset, offset + 200), truncated: entries.length > offset + 200,
          nextOffset: entries.length > offset + 200 ? offset + 200 : undefined };
      }
      const mount = await this.requireMount(path);
      return this.externalList(mount, path, cancellation, offset);
    }
    const absolute = await this.resolve(path, false, cancellation);
    await this.requireDirectory(absolute);
    cancellation.check();
    const names = (await fs.listFile(absolute, { recursion: false })).filter((name: string) => !name.startsWith('.tinybot-'));
    if (this.mounts.length > 0 && (path === '' || path === '.') && !names.includes(SHARED_FOLDER_ROOT)) { names.push(SHARED_FOLDER_ROOT); }
    names.sort();
    const entries: WorkspaceEntry[] = [];
    for (const name of names.slice(offset, offset + 200)) {
      cancellation.check();
      if (this.mounts.length > 0 && (path === '' || path === '.') && name === SHARED_FOLDER_ROOT) {
        entries.push({ name: name, kind: 'directory' });
        continue;
      }
      const stat = await fs.lstat(absolute + '/' + name);
      entries.push({ name: name, kind: stat.isSymbolicLink() ? 'symlink' : stat.isDirectory() ? 'directory' : 'file' });
    }
    return { path: path || '.', entries: entries, truncated: names.length > offset + 200,
      nextOffset: names.length > offset + 200 ? offset + 200 : undefined };
  }

  async read(path: string, cancellation: Cancellation): Promise<WorkspaceText> {
    // Public shared-folder writes happen in place. Readers must wait for the whole
    // mutation, otherwise a partial write could become an observed file version.
    return withFileMutation(await this.fileKey(path), () => this.readUnlocked(path, cancellation));
  }

  private async fileKey(path: string): Promise<string> {
    workspaceRelativePath(path, false);
    if (this.isShared(path)) {
      const mount = await this.requireMount(path);
      return this.externalUri(mount.folder, mount.relative);
    }
    return this.root + '/' + path;
  }

  private async readUnlocked(path: string, cancellation: Cancellation): Promise<WorkspaceText> {
    if (this.isShared(path)) {
      const mount = await this.requireMount(path);
      if (!mount.relative) { throw new Error(t("请选择共享文件夹中的文件。")); }
      cancellation.check();
      const file = await this.openExternal(mount.folder, mount.relative, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const content = await readDocumentFile(file.fd, path, this.root, cancellation);
        return { path: path, content: content, version: await contentVersion(content) };
      } finally {
        await fs.close(file);
      }
    }
    const absolute = await this.resolve(path, false, cancellation);
    cancellation.check();
    const file = await fs.open(absolute, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const content = await readDocumentFile(file.fd, path, this.root, cancellation);
      return { path: path, content: content, version: await contentVersion(content) };
    } finally {
      await fs.close(file);
    }
  }

  async write(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite> {
    this.assertTextWritable(path);
    workspaceRelativePath(path, false);
    if (this.isShared(path)) {
      const mount = await this.requireMount(path, true);
      return withFileMutation(this.externalUri(mount.folder, mount.relative),
        () => this.mutateExternal(mount, path, content, [], cancellation, guard));
    }
    return withFileMutation(this.root + '/' + path, () => this.mutate(path, content, [], cancellation, guard));
  }

  async edit(path: string, edits: TextEdit[], version: string, cancellation: Cancellation): Promise<WorkspaceWrite> {
    this.assertTextWritable(path);
    workspaceRelativePath(path, false);
    validateEdits(edits);
    if (this.isShared(path)) {
      const mount = await this.requireMount(path, true);
      return withFileMutation(this.externalUri(mount.folder, mount.relative),
        () => this.mutateExternal(mount, path, '', edits, cancellation, { version: version }));
    }
    return withFileMutation(this.root + '/' + path, () => this.mutate(path, '', edits, cancellation, { version: version }));
  }

  // App-owned state is atomic and version-checked, but is not an agent edit to review/revert.
  async writeMiniApp(path: string, content: string, cancellation: Cancellation, guard?: WorkspaceWriteGuard): Promise<WorkspaceWrite> {
    workspaceRelativePath(path, false);
    if (!/^mini-apps\/[A-Za-z0-9][A-Za-z0-9_-]{0,127}\/(app|data)\.json$/.test(path)) { throw new Error('Invalid managed mini app path'); }
    return withFileMutation(this.root + '/' + path, () => this.mutate(path, content, [], cancellation, guard, false));
  }

  // Capture before showing the confirmation, including for binary/image files.
  async removalVersion(path: string): Promise<string> {
    return withFileMutation(await this.fileKey(path), () => this.removalVersionUnlocked(path));
  }

  private async removalVersionUnlocked(path: string): Promise<string> {
    const mount = this.isShared(path) ? await this.requireMount(path) : undefined;
    const absolute = mount ? '' : await this.resolve(path, false, new Cancellation());
    const stat = mount ? await this.externalStat(mount.folder, mount.relative) : await this.optionalStat(absolute);
    if (!stat) { throw new ToolFailure('FS_STALE_VERSION', t('文件已变化，请重新打开并检查。'), 'read_file', { path: path }); }
    if (!stat.isFile() || stat.isSymbolicLink()) { throw new Error(t('请选择普通文件。')); }
    const file = mount ? await this.openExternal(mount.folder, mount.relative, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW) :
      await fs.open(absolute, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const hash = cryptoFramework.createMd('SHA256');
      const buffer = new ArrayBuffer(64 * 1024);
      while (true) {
        const count = await fs.read(file.fd, buffer);
        if (count === 0) { break; }
        await hash.update({ data: new Uint8Array(buffer, 0, count) });
      }
      return new util.Base64Helper().encodeToStringSync((await hash.digest()).data);
    } finally { await fs.close(file); }
  }

  async remove(path: string, version: string): Promise<void> {
    return withFileMutation(await this.fileKey(path), async () => {
      if (await this.removalVersionUnlocked(path) !== version) {
        throw new ToolFailure('FS_STALE_VERSION', t('文件已变化，请重新打开并检查。'), 'read_file', { path: path });
      }
      if (this.isShared(path)) {
        const mount = await this.requireMount(path);
        await this.unlinkExternal(mount.folder, mount.relative);
      } else { await fs.unlink(await this.resolve(path, false, new Cancellation())); }
    });
  }

  private async mutate(path: string, content: string, edits: TextEdit[], cancellation: Cancellation,
    guard?: WorkspaceWriteGuard, capture: boolean = true): Promise<WorkspaceWrite> {
    cancellation.check();
    const absolute = await this.resolve(path, true, cancellation);
    const existing = await this.optionalStat(absolute);
    if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
      throw new Error(t("只能写入普通文件，不能覆盖目录或符号链接。"));
    }
    if (guard && guard.version === null && existing) { throw new ToolFailure('FS_NOT_OBSERVED', t('覆盖已有文件前，请先用 read_file 读取。'), 'read_file', { path: path }); }
    const original = existing ? await this.readUnlocked(path, cancellation) : undefined;
    if (guard && guard.version !== null && (!original || original.version !== guard.version)) {
      throw new ToolFailure('FS_STALE_VERSION', t('文件自上次读取后已变化，请重新读取再修改。'), 'read_file', { path: path });
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
        await this.writeFd(file.fd, bytes, cancellation);
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

  private async mutateExternal(mount: MountPath, path: string, content: string, edits: TextEdit[],
    cancellation: Cancellation, guard?: WorkspaceWriteGuard, capture: boolean = true): Promise<WorkspaceWrite> {
    if (!mount.relative) { throw new Error(t("请选择共享文件夹中的文件。")); }
    cancellation.check();
    const existing = await this.externalStat(mount.folder, mount.relative);
    if (existing && (!existing.isFile() || existing.isSymbolicLink())) {
      throw new Error(t("只能写入普通文件，不能覆盖目录或符号链接。"));
    }
    if (guard && guard.version === null && existing) { throw new ToolFailure('FS_NOT_OBSERVED', t('覆盖已有文件前，请先用 read_file 读取。'), 'read_file', { path: path }); }
    const original = existing ? await this.readUnlocked(path, cancellation) : undefined;
    if (guard && guard.version !== null && (!original || original.version !== guard.version)) {
      throw new ToolFailure('FS_STALE_VERSION', t('文件自上次读取后已变化，请重新读取再修改。'), 'read_file', { path: path });
    }
    const before = original ? original.content : '';
    if (edits.length > 0) { content = applyTextEdits(before, edits); }
    const bytes = content.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(content);
    if (content.includes('\u0000')) { throw new Error(t('文本不能包含空字符。')); }
    const version = await contentVersion(content);
    // Public providers may allow open/write while rejecting rename/unlink. Never truncate on open.
    // Keep the first unreviewed backup in our private workspace before touching target bytes.
    let stage = 'backup';
    let file: fs.File;
    try {
      if (capture) { await this.capture(path, existing !== undefined, cancellation, before); }
      cancellation.check();
      stage = 'open';
      file = await this.openExternal(mount.folder, mount.relative,
        fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW | (existing ? 0 : fs.OpenMode.CREATE));
    } catch (error) {
      if (error instanceof ToolFailure) { throw error; }
      throw this.externalFailure(stage, mount.folder, mount.relative, error as BusinessError);
    }
    let failure: Error | undefined;
    try {
      stage = 'verify';
      const opened = await readUtf8File(file.fd, cancellation);
      if (opened !== before) {
        throw new ToolFailure('FS_STALE_VERSION', t('文件自上次读取后已变化，请重新读取再修改。'), 'read_file', { path: path });
      }
      stage = 'write';
      await this.writeFd(file.fd, bytes, cancellation);
      stage = 'truncate';
      cancellation.check();
      await fs.truncate(file.fd, bytes.byteLength);
      stage = 'fsync';
      await fs.fsync(file.fd);
    } catch (error) {
      failure = error as Error;
    }
    try { await fs.close(file); }
    catch (error) {
      if (!failure) { stage = 'close'; failure = error as Error; }
      else { failure = new Error(failure.message + '; close: ' + (error as Error).message); }
    }
    if (failure) {
      if (failure instanceof ToolFailure && failure.code !== 'CANCELLED') { throw failure; }
      const message = t('共享文件保存失败，文件可能只写入了一部分。请打开文件查看修改前备份，恢复或导出后再重试。') +
        ' (' + stage + '): ' + failure.message;
      if (failure instanceof ToolFailure) {
        failure.message = message; failure.recovery = 'inspect_backup';
        failure.details = { path: path, category: stage }; throw failure;
      }
      throw new ToolFailure('FS_EXTERNAL_IO', message, 'inspect_backup',
        { path: path, category: stage, nativeCode: (failure as BusinessError).code });
    }
    return { path: path, bytes: bytes.byteLength, written: true, before: before, after: content, created: !existing, version: version };
  }

  private async writeFd(fd: number, bytes: Uint8Array, cancellation: Cancellation): Promise<void> {
    let written = 0;
    while (written < bytes.byteLength) {
      cancellation.check();
      const count = await fs.write(fd, bytes.buffer.slice(written), { offset: written });
      if (count <= 0) { throw new Error(t("工作区文件写入未完成。")); }
      written += count;
    }
  }

  private async baselinePath(path: string): Promise<string> {
    const mount = this.mountPath(path);
    // URI identity survives a mount rename and prevents a replacement mount inheriting another file's backup.
    const key = mount ? 'shared-' + (await contentVersion(this.externalUri(mount.folder, mount.relative)))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '') : encodeURIComponent(path);
    return this.root + '/.tinybot-review/' + key + '.json';
  }

  async baseline(path: string): Promise<FileBaseline | undefined> {
    workspaceRelativePath(path, false);
    const location = await this.baselinePath(path);
    if (!await fs.access(location)) { return undefined; }
    const item = JSON.parse(await fs.readText(location)) as FileBaseline;
    const mount = this.mountPath(path);
    if ((mount ? item.sourceUri !== this.externalUri(mount.folder, mount.relative) : item.path !== path || item.sourceUri !== undefined) ||
      typeof item.content !== 'string' || typeof item.existed !== 'boolean') { throw new Error(t("文件基线损坏。")); }
    item.path = path;
    return item;
  }

  private async capture(path: string, existed: boolean, cancellation: Cancellation, content: string): Promise<void> {
    const directory = this.root + '/.tinybot-review';
    if (!await fs.access(directory)) { await fs.mkdir(directory, true); }
    await this.requireDirectory(directory);
    if (await this.baseline(path)) { return; }
    cancellation.check();
    const mount = this.mountPath(path);
    const text = JSON.stringify({ path: path, existed: existed, content: content,
      sourceUri: mount ? this.externalUri(mount.folder, mount.relative) : undefined } as FileBaseline);
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
    await fs.rename(temporary, await this.baselinePath(path));
  }

  private async acceptUnlocked(path: string): Promise<void> {
    if (await this.baseline(path)) { await fs.unlink(await this.baselinePath(path)); }
  }

  async restore(path: string, expected: string): Promise<void> {
    workspaceRelativePath(path, false);
    if (this.isShared(path)) {
      const mount = await this.requireMount(path);
      return withFileMutation(this.externalUri(mount.folder, mount.relative), async () => {
        const baseline = await this.baseline(path);
        if (!baseline) { throw new Error(t("没有保存的修改基线。")); }
        const current = await this.readUnlocked(path, new Cancellation());
        if (current.content !== expected) { throw new Error(t("文件已变化，请重新打开并检查。")); }
        if (baseline.existed) {
          await this.mutateExternal(mount, path, baseline.content, [], new Cancellation(), { version: current.version }, false);
        } else { await this.unlinkExternal(mount.folder, mount.relative); }
        await this.acceptUnlocked(path);
      });
    }
    return withFileMutation(this.root + '/' + path, () => this.restoreUnlocked(path, expected));
  }

  private async restoreUnlocked(path: string, expected: string): Promise<void> {
    const baseline = await this.baseline(path);
    if (!baseline) { throw new Error(t("没有保存的修改基线。")); }
    const current = await this.readUnlocked(path, new Cancellation());
    if (current.content !== expected) { throw new Error(t("文件已变化，请重新打开并检查。")); }
    if (baseline.existed) { await this.mutate(path, baseline.content, [], new Cancellation(), { version: current.version }, false); }
    else { await fs.unlink(await this.checkedPath(path)); }
    await this.acceptUnlocked(path);
  }

  private isShared(path: string): boolean {
    return this.mounts.length > 0 && (path === SHARED_FOLDER_ROOT || path.startsWith(SHARED_FOLDER_ROOT + '/'));
  }

  private mountPath(path: string): MountPath | undefined {
    if (!this.isShared(path)) { return undefined; }
    const rest = path === SHARED_FOLDER_ROOT ? '' : path.slice(SHARED_FOLDER_ROOT.length + 1);
    const slash = rest.indexOf('/');
    const name = slash < 0 ? rest : rest.slice(0, slash);
    const folder = this.mounts.find((item: SharedFolder) => item.name === name);
    if (!folder) { return undefined; }
    return { folder: folder, relative: slash < 0 ? '' : rest.slice(slash + 1) };
  }

  private async requireMount(path: string, createParents: boolean = false): Promise<MountPath> {
    workspaceRelativePath(path, false);
    await this.activate();
    const mount = this.mountPath(path);
    if (!mount) { throw new Error(t('共享文件夹不存在，可能已在项目设置中移除。')); }
    const parts = mount.relative.length > 0 ? mount.relative.split('/') : [];
    let relative = '';
    for (let index = -1; index < parts.length; index++) {
      if (index >= 0) { relative += (relative ? '/' : '') + parts[index]; }
      let stat = await this.externalStat(mount.folder, relative);
      if (!stat && createParents && index >= 0 && index < parts.length - 1) {
        await this.mkdirExternal(mount.folder, relative);
        stat = await this.externalStat(mount.folder, relative);
      }
      if (stat?.isSymbolicLink()) { throw new Error(t('工作区工具不允许访问符号链接。')); }
      if (index < parts.length - 1 && (!stat || !stat.isDirectory())) {
        throw new Error(t('工作区路径中的父目录不存在或不是目录。'));
      }
    }
    return mount;
  }

  private async activate(): Promise<void> {
    if (this.mounts.length > 0) { await ProjectFolderAccess.activate(this.mounts); }
  }

  private externalUri(folder: SharedFolder, relative: string): string {
    const base = folder.uri.replace(/\/+$/, '');
    if (!relative) { return base; }
    return base + '/' + relative.split('/').map((part: string) => encodeURIComponent(part)).join('/');
  }

  // Directory APIs take the structured path; the full picker URI is not a POSIX path.
  private externalPath(folder: SharedFolder, relative: string): string {
    const base = new fileUri.FileUri(folder.uri).path.replace(/\/+$/, '');
    return relative ? base + '/' + relative : base;
  }

  private async openExternal(folder: SharedFolder, relative: string, mode: number): Promise<fs.File> {
    try {
      return await fs.open(this.externalPath(folder, relative), mode);
    } catch (error) {
      try { return await fs.open(this.externalUri(folder, relative), mode); }
      catch (uriError) {
        // URI providers may only open existing files even when CREATE is requested.
        const failure = this.externalFailure('open', folder, relative, error as BusinessError);
        failure.message += '; URI (' + (uriError as BusinessError).code + '): ' + (uriError as Error).message;
        throw failure;
      }
    }
  }

  private async externalStat(folder: SharedFolder, relative: string): Promise<fs.Stat | undefined> {
    let first: Error | undefined;
    try {
      return await fs.lstat(this.externalPath(folder, relative));
    } catch (error) {
      first = error as Error;
      if ((error as BusinessError).code === 13900002) { return undefined; }
    }
    try {
      return await fs.lstat(this.externalUri(folder, relative));
    } catch (error) {
      if ((error as BusinessError).code === 13900002) { return undefined; }
      throw first || error as Error;
    }
  }

  private async externalList(mount: MountPath, path: string, cancellation: Cancellation, offset: number): Promise<WorkspaceListing> {
    let names: string[];
    try {
      names = await fs.listFile(this.externalPath(mount.folder, mount.relative), { recursion: false });
    } catch (error) {
      try {
        names = await fs.listFile(this.externalUri(mount.folder, mount.relative), { recursion: false });
      } catch (_) {
        throw new Error(t('无法列出共享文件夹：') + (error as Error).message);
      }
    }
    names = names.filter((name: string) => !name.startsWith('.tinybot-')).sort();
    const entries: WorkspaceEntry[] = [];
    for (const name of names.slice(offset, offset + 200)) {
      cancellation.check();
      const stat = await this.externalStat(mount.folder, (mount.relative ? mount.relative + '/' : '') + name);
      entries.push({ name: name, kind: stat?.isSymbolicLink() ? 'symlink' : stat?.isDirectory() ? 'directory' : 'file' });
    }
    return { path: path, entries: entries, truncated: names.length > offset + 200,
      nextOffset: names.length > offset + 200 ? offset + 200 : undefined };
  }

  private async mkdirExternal(folder: SharedFolder, relative: string): Promise<void> {
    try {
      await fs.mkdir(this.externalPath(folder, relative), true);
    } catch (error) {
      if ((error as BusinessError).code === 13900015) { return; }
      try {
        await fs.mkdir(this.externalUri(folder, relative), true);
      } catch (fallback) {
        if ((fallback as BusinessError).code === 13900015) { return; }
        throw error as Error;
      }
    }
  }

  private externalFailure(operation: string, folder: SharedFolder, relative: string, error: BusinessError): ToolFailure {
    return new ToolFailure('FS_EXTERNAL_IO', 'Shared folder ' + operation + ' failed (' + error.code + '): ' +
      error.message, 'inspect_error', { path: SHARED_FOLDER_ROOT + '/' + folder.name + '/' + relative,
        category: operation, nativeCode: error.code });
  }

  private async unlinkExternal(folder: SharedFolder, relative: string): Promise<void> {
    try {
      await fs.unlink(this.externalPath(folder, relative));
    } catch (error) {
      await fs.unlink(this.externalUri(folder, relative));
    }
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
