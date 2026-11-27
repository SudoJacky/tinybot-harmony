import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, fileShare, fileUri } from '@kit.CoreFileKit';
import native from 'libtinybot_sandbox.so';
import { t } from '../model/I18n';
import { SharedFolder, sharedFolderNameFromUri, uniqueSharedFolderName, validateSharedFolders } from '../model/SharedFolders';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { Cancellation } from './Cancellation';
import { readBounded, writeBytes } from './FileBytes';
import { copyLinuxBytes, LINUX_TREE_OFFSET, writeLinuxBytes } from './LinuxExchange';
import { ProjectFolderAccess } from './ProjectFolderAccess';

const LEGACY_ARCHIVE_BYTES: number = 7 * 1024 * 1024;

export interface LinuxWorkspaceScope { id: string; project: boolean; }
interface LegacyTreeEntry { path: string; data?: string; }
interface LinuxWorkspaceConfig { persistent: boolean; mounts: SharedFolder[]; }

export interface LinuxWorkspaceInfo {
  persistent: boolean;
  mounts: SharedFolder[];
  storedBytes: number;
}

function validPath(path: string): boolean {
  return typeof path === 'string' && !/[\\\u0000-\u001f\u007f]/.test(path) &&
    !path.split('/').some((part: string) => !part || part === '.' || part === '..');
}

async function readJson(path: string, limit?: number): Promise<string | undefined> {
  if (!await fs.access(path)) { return undefined; }
  const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
  try {
    const bytes = await readBounded(file.fd, limit ?? (await fs.stat(file.fd)).size);
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes));
  } finally { await fs.close(file); }
}

async function replace(path: string, write: (temporary: string) => Promise<void>): Promise<void> {
  const temporary = path + '.' + util.generateRandomUUID() + '.tmp';
  try {
    await write(temporary);
    await fs.rename(temporary, path);
  } finally {
    if (await fs.access(temporary)) { await fs.unlink(temporary); }
  }
}

async function replaceConfig(path: string, config: LinuxWorkspaceConfig): Promise<void> {
  const bytes = new util.TextEncoder().encodeInto(JSON.stringify(config));
  await replace(path, (temporary) => writeBytes(temporary, bytes.buffer as ArrayBuffer));
}

export class LinuxWorkspace {
  private store: WorkspaceStore;
  private scope: LinuxWorkspaceScope;
  private configPath: string;
  private archivePath: string;
  private legacyPath: string;

  constructor(context: common.Context, scope: LinuxWorkspaceScope) {
    this.store = new WorkspaceStore(context.filesDir);
    this.scope = scope;
    const root = this.store.pathFor(scope.id);
    this.configPath = root + '/.tinybot-linux-settings.json';
    this.archivePath = root + '/.tinybot-linux-project.tree';
    this.legacyPath = root + '/.tinybot-linux-project.json';
  }

  private async preparePath(): Promise<void> {
    if (this.scope.project) { await this.store.requireWorkspace(this.scope.id); }
    else { await this.store.ensureThread(this.scope.id); }
  }

  async config(): Promise<LinuxWorkspaceConfig> {
    const json = await readJson(this.configPath);
    if (json === undefined) { return { persistent: false, mounts: [] }; }
    const config = JSON.parse(json) as LinuxWorkspaceConfig;
    if (!config || typeof config.persistent !== 'boolean' || !Array.isArray(config.mounts) ||
        config.mounts.some((mount: SharedFolder) => !mount || mount.webDavConnectionId !== undefined ||
          !validPath(mount.name) || mount.name.includes('/'))) {
      throw new Error(t('Linux 沙盒配置无效。'));
    }
    validateSharedFolders(config.mounts, config.mounts.length);
    return config;
  }

  async info(): Promise<LinuxWorkspaceInfo> {
    const config = await this.config();
    const path = await fs.access(this.archivePath) ? this.archivePath : this.legacyPath;
    const bytes = await fs.access(path) ? (await fs.lstat(path)).size : 0;
    return { persistent: this.scope.project && config.persistent, mounts: config.mounts, storedBytes: bytes };
  }

  async setPersistent(enabled: boolean): Promise<void> {
    if (!this.scope.project) { throw new Error(t('持久目录仅适用于项目。')); }
    await this.preparePath();
    const config = await this.config();
    config.persistent = enabled;
    await replaceConfig(this.configPath, config);
  }

  async clearProject(): Promise<void> {
    if (!this.scope.project) { throw new Error(t('持久目录仅适用于项目。')); }
    await this.preparePath();
    if (await fs.access(this.legacyPath)) { await fs.unlink(this.legacyPath); }
    if (await fs.access(this.archivePath)) { await fs.unlink(this.archivePath); }
  }

  async addMount(uri: string): Promise<void> {
    if (!ProjectFolderAccess.supported() || !uri.startsWith('file://') || uri.length > 4096) {
      throw new Error(t('无法为 Linux 沙盒授权此目录。'));
    }
    await this.preparePath();
    const config = await this.config();
    if (config.mounts.some((mount: SharedFolder) => mount.uri === uri)) { return; }
    const name = uniqueSharedFolderName(sharedFolderNameFromUri(uri), config.mounts);
    if (!validPath(name) || name.includes('/')) { throw new Error(t('无法为 Linux 沙盒授权此目录。')); }
    const policy: fileShare.PolicyInfo = { uri: uri, operationMode: fileShare.OperationMode.READ_MODE };
    if (!(await fileShare.checkPersistentPermission([policy]))[0]) { await fileShare.persistPermission([policy]); }
    config.mounts.push({ id: util.generateRandomUUID(), name: name, uri: uri, addedAt: Date.now() });
    await replaceConfig(this.configPath, config);
  }

  async removeMount(id: string): Promise<void> {
    await this.preparePath();
    const config = await this.config();
    config.mounts = config.mounts.filter((mount: SharedFolder) => mount.id !== id);
    // OS folder grants are app-wide and may still be used by another workspace.
    await replaceConfig(this.configPath, config);
  }

  async packMounts(folders: SharedFolder[], fd: number, offset: number, signal: Cancellation): Promise<number> {
    let size = 0;
    for (const folder of folders) {
      signal.check();
      const policy: fileShare.PolicyInfo = { uri: folder.uri, operationMode: fileShare.OperationMode.READ_MODE };
      if (!(await fileShare.checkPersistentPermission([policy]))[0]) {
        throw new Error(t('目录 {0} 的授权已失效，请卸载后重新选择。', [folder.name]));
      }
      await fileShare.activatePermission([policy]);
      signal.check();
      const path = new fileUri.FileUri(folder.uri).path.replace(/\/+$/, '') || '/';
      const pending = native.packLinuxDirectory(path, folder.name, fd, offset + size);
      const unsubscribe = signal.onCancel(() => { native.cancelLinuxDirectory(); });
      try { size += await pending; }
      finally { unsubscribe(); signal.check(); }
    }
    return size;
  }

  async packProject(fd: number, signal: Cancellation): Promise<number> {
    if (await fs.access(this.archivePath)) {
      const file = await fs.open(this.archivePath, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
      try {
        const info = await fs.stat(file.fd);
        if (!info.isFile() || info.size > (await fs.stat(fd)).size - LINUX_TREE_OFFSET) {
          throw new Error('The Linux project archive does not fit on the exchange disk');
        }
        await copyLinuxBytes(file.fd, fd, 0, LINUX_TREE_OFFSET, info.size, signal);
        return info.size;
      } finally { await fs.close(file); }
    }
    return this.packLegacyProject(fd, signal);
  }

  private async packLegacyProject(fd: number, signal: Cancellation): Promise<number> {
    const json = await readJson(this.legacyPath, LEGACY_ARCHIVE_BYTES);
    if (json === undefined) { return 0; }
    const entries = JSON.parse(json) as LegacyTreeEntry[];
    if (!Array.isArray(entries)) { throw new Error('Invalid Linux project archive'); }
    const base64 = new util.Base64Helper();
    const encoder = new util.TextEncoder();
    let offset = LINUX_TREE_OFFSET;
    for (const entry of entries) {
      signal.check();
      if (!entry || !validPath(entry.path) || (entry.data !== undefined && typeof entry.data !== 'string')) {
        throw new Error('Invalid Linux project archive entry');
      }
      const path = encoder.encodeInto(entry.path);
      const bytes = entry.data ? base64.decodeSync(entry.data) : new Uint8Array(0);
      const header = new ArrayBuffer(13);
      const fields = new DataView(header);
      fields.setUint32(0, path.byteLength, true);
      fields.setUint8(4, entry.data === undefined ? 0 : 1);
      fields.setUint32(5, bytes.byteLength, true);
      await writeLinuxBytes(fd, header, offset);
      await writeLinuxBytes(fd, path.buffer as ArrayBuffer, offset + header.byteLength);
      if (bytes.byteLength) { await writeLinuxBytes(fd, bytes.buffer as ArrayBuffer, offset + header.byteLength + path.byteLength); }
      offset += header.byteLength + path.byteLength + bytes.byteLength;
    }
    return offset - LINUX_TREE_OFFSET;
  }

  async saveProject(source: number, size: number, signal: Cancellation, publishOutput: () => Promise<void>): Promise<void> {
    if (!Number.isSafeInteger(size) || size < 0 || size > (await fs.stat(source)).size - LINUX_TREE_OFFSET) {
      throw new Error('Invalid Linux project archive size');
    }
    await this.preparePath();
    await replace(this.archivePath, async (temporary) => {
      const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        await copyLinuxBytes(source, file.fd, LINUX_TREE_OFFSET, 0, size, signal);
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      signal.check();
      // Only publish the explicit output after staging the cancellable project copy.
      await publishOutput();
    });
    if (await fs.access(this.legacyPath)) { await fs.unlink(this.legacyPath); }
  }
}
