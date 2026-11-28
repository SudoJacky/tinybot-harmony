import { common } from '@kit.AbilityKit';
import { Diagnostics, TIMED_DIAGNOSTICS_FILE } from '../model/Diagnostics';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, storageStatistics } from '@kit.CoreFileKit';
import { StorageCatalog } from '../model/StorageCatalog';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { t } from '../model/I18n';
import { WorkspaceRetention, withWorkspaceLifecycle } from './WorkspaceRetention';
import { workspaceDatabase } from './ArkDataWorkspace';
import { RecordSize } from './ArkDataRecords';
import { DiskFile, StorageCategoryId, StorageCleanResult, StorageEntry, StorageEntryResult, StorageReport,
  emptyStorageReport, isCacheCleanable, isStaleTemporary } from '../model/StoragePlan';

const MAX_ENTRIES: number = 300;
const REVIEW_DIR: string = '.tinybot-review';

interface ManifestEntry { id: string; file: string; }
interface SessionManifest { threads?: ManifestEntry[]; }
interface DeleteOutcome { bytes: number; complete: boolean; }

// The app keeps data in two private roots: the ability directory holds conversations, usage and
// feedback copies, while the application directory holds workspaces, attachments and the CPU profile.
interface StorageRoots {
  abilityFilesDir: string;
  appFilesDir: string;
  cacheDir: string;
}

function baseName(path: string): string { return path.substring(path.lastIndexOf('/') + 1); }

function sumFiles(files: DiskFile[]): number {
  let total = 0;
  for (const file of files) { total += file.bytes; }
  return total;
}

function addCategory(report: StorageReport, id: StorageCategoryId, bytes: number, files: number): void {
  for (const item of report.categories) {
    if (item.id === id) { item.bytes = bytes; item.files = files; }
  }
  report.categorizedBytes += bytes;
}

function fileEntry(file: DiskFile, category: StorageCategoryId, label: string, detail: string,
  removable: boolean): StorageEntry {
  return { path: file.path, label: label, detail: detail, bytes: file.bytes, category: category,
    removable: removable, directory: false };
}

interface CleanupInventory {
  workspace: DiskFile[];
  workspaceDirs: string[];
  cache: DiskFile[];
  attachments: DiskFile[];
}

export class StorageUsage {
  private static roots(context: common.Context): StorageRoots {
    return { abilityFilesDir: context.filesDir, appFilesDir: context.getApplicationContext().filesDir,
      cacheDir: context.cacheDir };
  }

  private static workspaceRoot(roots: StorageRoots): string {
    return new WorkspaceStore(roots.appFilesDir).rootDir;
  }

  // Missing files are normal; other failures make the report explicitly incomplete.
  private static missing(error: Error): boolean {
    if ((error as BusinessError).code === 13900002) { return true; }
    const message = (error.message || '').toLowerCase();
    return message.indexOf('enoent') >= 0 || message.indexOf('no such file') >= 0;
  }

  private static failed(failures: string[], path: string, error: Error, operation: string): void {
    if (failures.indexOf(path) < 0) {
      failures.push(path);
      Diagnostics.log('warn', 'storage', 'scan_failed', { operation: operation, count: failures.length }, error);
    }
  }

  private static async arkDataSizes(roots: StorageRoots, scope: string, failures: string[]): Promise<RecordSize[] | undefined> {
    const database = workspaceDatabase(StorageUsage.workspaceRoot(roots));
    if (!database) { return undefined; }
    try { return await (await database()).sizes(scope); }
    catch (error) { StorageUsage.failed(failures, 'ArkData/' + scope, error as Error, 'read'); return []; }
  }

  private static async listFiles(root: string, failures: string[], rootDirs?: string[]): Promise<DiskFile[]> {
    const result: DiskFile[] = [];
    try {
      if (!await fs.access(root)) { return result; }
    } catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root, error as Error, 'access'); }
      return result;
    }
    const pending: string[] = [''];
    while (pending.length > 0) {
      const relativeDir = pending.pop() as string;
      const directory = relativeDir.length === 0 ? root : root + '/' + relativeDir;
      let names: string[] = [];
      try { names = await fs.listFile(directory); }
      catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, directory, error as Error, 'list'); }
        continue;
      }
      for (const name of names) {
        const relative = relativeDir.length === 0 ? name : relativeDir + '/' + name;
        const absolute = root + '/' + relative;
        try {
          const stat = await fs.lstat(absolute);
          if (stat.isSymbolicLink()) { continue; }
          if (stat.isDirectory()) { pending.push(relative); }
          else if (stat.isFile()) {
            result.push({ path: absolute, relative: relative, bytes: stat.size, modifiedAt: stat.mtime * 1000 });
          }
        } catch (error) {
          if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, directory, error as Error, 'stat'); }
          continue;
        }
      }
    }
    return result;
  }

  private static async listDirectories(root: string, failures: string[]): Promise<string[]> {
    const result: string[] = [];
    try {
      if (!await fs.access(root)) { return result; }
    } catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root, error as Error, 'access'); }
      return result;
    }
    let names: string[] = [];
    try { names = await fs.listFile(root); }
    catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root, error as Error, 'list'); }
      return result;
    }
    for (const name of names) {
      try {
        const stat = await fs.lstat(root + '/' + name);
        if (stat.isDirectory() && !stat.isSymbolicLink()) { result.push(name); }
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root + '/' + name, error as Error, 'stat'); }
        continue;
      }
    }
    return result;
  }

  private static async workspaceFiles(roots: StorageRoots, failures: string[]): Promise<DiskFile[]> {
    return StorageUsage.listFiles(StorageUsage.workspaceRoot(roots), failures);
  }

  private static isReview(file: DiskFile): boolean {
    const parts = file.relative.split('/');
    for (const part of parts) { if (part === REVIEW_DIR) { return true; } }
    return false;
  }

  private static reviewLabel(file: DiskFile, owner: string): string {
    const relative = file.relative;
    const marker = relative.indexOf(REVIEW_DIR + '/');
    const encoded = marker >= 0 ? relative.substring(marker + REVIEW_DIR.length + 1) : baseName(relative);
    let label = encoded;
    try { label = decodeURIComponent(encoded.replace(/\.json$/, '')); } catch (_) { /* Keep the encoded name. */ }
    return owner.length > 0 ? owner + ' / ' + label : label;
  }

  private static async cleanupInventory(roots: StorageRoots, failures: string[]): Promise<CleanupInventory> {
    const dirs: string[] = [];
    const workspace = await StorageUsage.listFiles(StorageUsage.workspaceRoot(roots), failures, dirs);
    const cache = await StorageUsage.listFiles(roots.cacheDir, failures);
    const attachments = await StorageUsage.listFiles(roots.appFilesDir + '/attachments', failures);
    return { workspace: workspace, workspaceDirs: dirs, cache: cache, attachments: attachments };
  }

  private static async safeCandidates(roots: StorageRoots, data: StorageCatalog, now: number,
    failures: string[], inventory: CleanupInventory): Promise<StorageEntry[]> {
    const workspaceRoot = StorageUsage.workspaceRoot(roots);
    const retained = await StorageUsage.retained(roots, data, failures);
    const orphanSizes = new Map<string, number>();
    for (const dir of inventory.workspaceDirs) {
      if (!retained.has(dir)) { orphanSizes.set(dir, 0); }
    }
    const result: StorageEntry[] = [];
    for (const file of inventory.workspace) {
      const slash = file.relative.indexOf('/');
      const owner = slash < 0 ? '' : file.relative.slice(0, slash);
      const bytes = orphanSizes.get(owner);
      if (bytes !== undefined) { orphanSizes.set(owner, bytes + file.bytes); }
      else if (isStaleTemporary(baseName(file.relative), file.modifiedAt, now)) {
        result.push(fileEntry(file, 'workspace', file.relative, t('临时文件'), true));
      }
    }
    orphanSizes.forEach((bytes, dir) => {
      result.push({ path: workspaceRoot + '/' + dir, label: dir, detail: t('已删除会话的残留工作区'),
        bytes: bytes, category: 'workspace', removable: true, directory: true });
    });
    for (const file of inventory.cache) {
      if (isCacheCleanable(file.modifiedAt, now)) {
        result.push(fileEntry(file, 'cache', file.relative, t('缓存文件'), true));
      }
    }
    const references = data.attachments;
    for (const file of inventory.attachments) {
      if (!references.has(file.relative)) {
        result.push(fileEntry(file, 'attachments', baseName(file.relative), t('未使用'), true));
      }
    }
    return result;
  }

  static async scan(context: common.Context, data: StorageCatalog): Promise<StorageReport> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    const report = emptyStorageReport();
    const now = Date.now();
    const threadSizes = await StorageUsage.arkDataSizes(roots, 'thread', failures);
    const sessions = await StorageUsage.listFiles(roots.abilityFilesDir + '/sessions-v2', failures);
    addCategory(report, 'sessions', sumFiles(sessions) + (threadSizes || []).reduce((total, item) => total + item.bytes, 0), sessions.length + (threadSizes?.length || 0));
    const inventory = await StorageUsage.cleanupInventory(roots, failures);
    let workspaceBytes = 0, workspaceCount = 0, backupBytes = 0, backupCount = 0;
    for (const file of inventory.workspace) {
      if (StorageUsage.isReview(file)) { backupBytes += file.bytes; backupCount++; }
      else { workspaceBytes += file.bytes; workspaceCount++; }
    }
    addCategory(report, 'workspace', workspaceBytes, workspaceCount);
    addCategory(report, 'backups', backupBytes, backupCount);
    const attachments = inventory.attachments;
    addCategory(report, 'attachments', sumFiles(attachments), attachments.length);
    const requestSizes = await StorageUsage.arkDataSizes(roots, 'usage', failures);
    const usage = await StorageUsage.listFiles(roots.abilityFilesDir + '/usage-records', failures);
    addCategory(report, 'usage', sumFiles(usage) + (requestSizes || []).reduce((total, item) => total + item.bytes, 0), usage.length + (requestSizes?.length || 0));
    let diagnosticsBytes = 0, diagnosticsFiles = 0;
    const diagnosticPaths: string[] = [roots.abilityFilesDir + '/performance-current.jsonl',
      roots.abilityFilesDir + '/performance-previous.jsonl', roots.abilityFilesDir + '/' + TIMED_DIAGNOSTICS_FILE,
      roots.appFilesDir + '/tinybot-cpu.json'];
    for (const path of diagnosticPaths) {
      let operation: string = 'access';
      try {
        if (await fs.access(path)) {
          operation = 'stat';
          const stat = await fs.lstat(path);
          if (stat.isFile() && !stat.isSymbolicLink()) { diagnosticsBytes += stat.size; diagnosticsFiles++; }
        }
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, path, error as Error, operation); }
        continue;
      }
    }
    addCategory(report, 'diagnostics', diagnosticsBytes, diagnosticsFiles);
    const cache = inventory.cache;
    addCategory(report, 'cache', sumFiles(cache), cache.length);
    const feedback = await StorageUsage.listFiles(roots.abilityFilesDir + '/feedback-files', failures);
    addCategory(report, 'feedback', sumFiles(feedback), feedback.length);

    try {
      const stats = await storageStatistics.getCurrentBundleStats();
      // System dataSize already includes cacheSize.
      report.bundle = { totalBytes: stats.appSize + stats.dataSize, appBytes: stats.appSize,
        dataBytes: stats.dataSize, cacheBytes: stats.cacheSize };
    } catch (error) { Diagnostics.log('warn', 'storage', 'metric_failed', { operation: 'bundle_stats' }, error as Error); }
    try { report.freeBytes = await storageStatistics.getFreeSize(); }
    catch (error) { Diagnostics.log('warn', 'storage', 'metric_failed', { operation: 'free_size' }, error as Error); }
    try { report.deviceBytes = await storageStatistics.getTotalSize(); }
    catch (error) { Diagnostics.log('warn', 'storage', 'metric_failed', { operation: 'total_size' }, error as Error); }

    const candidates = await StorageUsage.safeCandidates(roots, data, now, failures, inventory);
    for (const entry of candidates) {
      report.safeBytes += entry.bytes;
      if (entry.category === 'cache') { report.cacheCleanBytes += entry.bytes; }
      else if (entry.category === 'attachments') { report.orphanAttachmentBytes += entry.bytes; report.orphanAttachments++; }
      else if (entry.category === 'workspace' && entry.directory) { report.orphanWorkspaceBytes += entry.bytes; report.orphanWorkspaces++; }
      else { report.tempBytes += entry.bytes; report.staleTemps++; }
    }
    report.safeFiles = candidates.length;
    report.incomplete = failures.length > 0;
    report.failedPaths = failures;
    report.scannedAt = now;
    return report;
  }

  private static async sessionEntries(roots: StorageRoots, data: StorageCatalog,
    failures: string[]): Promise<StorageEntry[]> {
    const root = roots.abilityFilesDir + '/sessions-v2';
    const threads = data.sessions;
    const result: StorageEntry[] = [];
    const current = await StorageUsage.arkDataSizes(roots, 'thread', failures);
    if (current) {
      for (const item of current) {
        const thread = threads.get(item.id);
        result.push({ path: 'ArkData/thread/' + item.id, label: thread?.title || item.id,
          detail: t('{0} 条消息', [thread?.messageCount || 0]), bytes: item.bytes,
          category: 'sessions', removable: false, directory: false });
      }
      return result;
    }
    let text = '';
    try { text = await fs.readText(root + '/index.json'); }
    catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root + '/index.json', error as Error, 'read'); }
      return result;
    }
    let manifest: SessionManifest = {};
    try { manifest = JSON.parse(text) as SessionManifest; }
    catch (error) { StorageUsage.failed(failures, root + '/index.json', error as Error, 'parse'); return result; }
    for (const item of manifest.threads || []) {
      try {
        const stat = await fs.lstat(root + '/' + item.file);
        if (!stat.isFile() || stat.isSymbolicLink()) { continue; }
        const thread = threads.get(item.id);
        result.push({ path: root + '/' + item.file, label: thread && thread.title.length > 0 ? thread.title : item.id,
          detail: t('{0} 条消息', [thread?.messageCount || 0]), bytes: stat.size,
          category: 'sessions', removable: false, directory: false });
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root, error as Error, 'stat'); }
        continue;
      }
    }
    return result;
  }

  private static async workspaceEntries(roots: StorageRoots, data: StorageCatalog,
    failures: string[]): Promise<StorageEntry[]> {
    const names = data.workspaces;
    const files = await StorageUsage.workspaceFiles(roots, failures);
    const retained = await StorageUsage.retained(roots, data, failures);
    const result: StorageEntry[] = [];
    for (const file of files) {
      if (StorageUsage.isReview(file)) { continue; }
      const parts = file.relative.split('/');
      const owner = names.get(parts[0]) || parts[0];
      const rest = parts.slice(1).join('/');
      result.push(fileEntry(file, 'workspace', rest.length > 0 ? owner + ' / ' + rest : owner, file.relative,
        !retained.has(parts[0])));
    }
    return result;
  }

  private static async backupEntries(roots: StorageRoots, data: StorageCatalog,
    failures: string[]): Promise<StorageEntry[]> {
    const names = data.workspaces;
    const files = await StorageUsage.workspaceFiles(roots, failures);
    const result: StorageEntry[] = [];
    for (const file of files) {
      if (!StorageUsage.isReview(file)) { continue; }
      const owner = names.get(file.relative.split('/')[0]) || '';
      result.push(fileEntry(file, 'backups', StorageUsage.reviewLabel(file, owner), file.relative, true));
    }
    return result;
  }

  private static async attachmentEntries(roots: StorageRoots, data: StorageCatalog,
    failures: string[]): Promise<StorageEntry[]> {
    const references = data.attachments;
    const files = await StorageUsage.listFiles(roots.appFilesDir + '/attachments', failures);
    const result: StorageEntry[] = [];
    for (const file of files) {
      // Referenced attachments can legitimately have an empty display name; use path presence.
      const used = references.has(file.relative);
      const name = references.get(file.relative);
      result.push(fileEntry(file, 'attachments', name && name.length > 0 ? name : baseName(file.relative),
        used ? t('使用中') : t('未使用'), !used));
    }
    return result;
  }

  static async entries(context: common.Context, data: StorageCatalog, category: string): Promise<StorageEntryResult> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    let result: StorageEntry[] = [];
    if (category === 'sessions') { result = await StorageUsage.sessionEntries(roots, data, failures); }
    else if (category === 'workspace') { result = await StorageUsage.workspaceEntries(roots, data, failures); }
    else if (category === 'backups') { result = await StorageUsage.backupEntries(roots, data, failures); }
    else if (category === 'attachments') { result = await StorageUsage.attachmentEntries(roots, data, failures); }
    else if (category === 'usage') {
      const current = await StorageUsage.arkDataSizes(roots, 'usage', failures);
      if (current) {
        result.push({ path: 'ArkData/usage', label: t('用量账本'), detail: 'ArkData',
          bytes: current.reduce((total, item) => total + item.bytes, 0), category: 'usage', removable: false, directory: false });
      } else {
        for (const file of await StorageUsage.listFiles(roots.abilityFilesDir + '/usage-records', failures)) {
          result.push(fileEntry(file, 'usage', file.relative, t('用量账本'), false));
        }
      }
    } else if (category === 'diagnostics') {
      const paths: string[] = [roots.abilityFilesDir + '/performance-current.jsonl',
        roots.abilityFilesDir + '/performance-previous.jsonl', roots.abilityFilesDir + '/' + TIMED_DIAGNOSTICS_FILE,
        roots.appFilesDir + '/tinybot-cpu.json'];
      for (const path of paths) {
        let operation: string = 'access';
        try {
          if (await fs.access(path)) {
            operation = 'stat';
            const stat = await fs.lstat(path);
            if (stat.isFile() && !stat.isSymbolicLink()) {
              result.push({ path: path, label: baseName(path), detail: t('开发者模式中清理'), bytes: stat.size,
                category: 'diagnostics', removable: false, directory: false });
            }
          }
        } catch (error) {
          if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, path, error as Error, operation); }
          continue;
        }
      }
    } else if (category === 'cache') {
      for (const file of await StorageUsage.listFiles(roots.cacheDir, failures)) {
        const cleanable = isCacheCleanable(file.modifiedAt, Date.now());
        result.push(fileEntry(file, 'cache', file.relative, cleanable ? t('缓存文件') : t('刚生成，稍后可清理'), cleanable));
      }
    } else if (category === 'feedback') {
      for (const file of await StorageUsage.listFiles(roots.abilityFilesDir + '/feedback-files', failures)) {
        result.push(fileEntry(file, 'feedback', file.relative, t('反馈记录使用中'), false));
      }
    }
    result.sort((left: StorageEntry, right: StorageEntry): number => right.bytes - left.bytes);
    return { entries: result.slice(0, MAX_ENTRIES), incomplete: failures.length > 0, failedPaths: failures };
  }

  private static allowed(path: string, roots: string[]): boolean {
    if (path.includes('/../') || path.endsWith('/..') || path.length === 0) { return false; }
    for (const root of roots) {
      if (path.length > root.length + 1 && path.startsWith(root + '/')) { return true; }
    }
    return false;
  }

  private static deleteFailure(error: Error, operation: string): DeleteOutcome {
    const missing = StorageUsage.missing(error);
    if (!missing) { Diagnostics.log('warn', 'storage', 'cleanup_failed', { operation: operation }, error); }
    return { bytes: 0, complete: missing };
  }

  // Best effort: a partial tree returns the bytes that were actually removed and complete=false.
  private static async deletePath(path: string): Promise<DeleteOutcome> {
    try {
      const stat = await fs.lstat(path);
      if (stat.isSymbolicLink()) {
        try { await fs.unlink(path); return { bytes: 0, complete: true }; }
        catch (error) { return StorageUsage.deleteFailure(error as Error, 'unlink'); }
      }
      if (stat.isDirectory()) {
        let bytes = 0, complete = true;
        let names: string[] = [];
        try { names = await fs.listFile(path); }
        catch (error) { return StorageUsage.deleteFailure(error as Error, 'list'); }
        for (const name of names) {
          const outcome = await StorageUsage.deletePath(path + '/' + name);
          bytes += outcome.bytes;
          if (!outcome.complete) { complete = false; }
        }
        try { await fs.rmdir(path); }
        catch (error) { if (!StorageUsage.deleteFailure(error as Error, 'rmdir').complete) { complete = false; } }
        return { bytes: bytes, complete: complete };
      }
      try { await fs.unlink(path); return { bytes: stat.size, complete: true }; }
      catch (error) { return StorageUsage.deleteFailure(error as Error, 'unlink'); }
    } catch (error) {
      return StorageUsage.deleteFailure(error as Error, 'stat');
    }
  }

  private static async retained(roots: StorageRoots, data: StorageCatalog | undefined, failures: string[]): Promise<Set<string>> {
    const root = StorageUsage.workspaceRoot(roots);
    try { return WorkspaceRetention.retained(new Set(data?.workspaces.keys()), await WorkspaceRetention.inventory(root)); }
    catch (error) {
      StorageUsage.failed(failures, root, error as Error, 'list');
      // An incomplete ownership scan cannot authorize workspace deletion.
      return new Set(await StorageUsage.listDirectories(root, failures));
    }
  }
  static async remove(context: common.Context, entries: StorageEntry[], data?: StorageCatalog): Promise<StorageCleanResult> {
    const storage = StorageUsage.roots(context);
    const roots: string[] = [storage.abilityFilesDir, storage.appFilesDir, storage.cacheDir];
    let freedBytes = 0, removed = 0, failed = 0;
    for (const entry of entries) {
      if (!entry.removable || !StorageUsage.allowed(entry.path, roots)) { failed++; continue; }
      try {
        const workspace = StorageUsage.workspaceRoot(storage), relative = entry.path.slice(workspace.length + 1), owner = relative.split('/')[0];
        const outcome = await withWorkspaceLifecycle(workspace + '/' + owner, async (): Promise<DeleteOutcome> => {
          if (entry.category === 'workspace' && entry.path.startsWith(workspace + '/') && !isStaleTemporary(baseName(entry.path), 0, Date.now())) {
            const failures: string[] = [];
            if ((await StorageUsage.retained(storage, data, failures)).has(owner) || failures.length) {
              Diagnostics.log('warn', 'storage', 'cleanup_protected', { count: 1 }); return { bytes: 0, complete: false };
            }
          }
          return StorageUsage.deletePath(entry.path);
        });
        freedBytes += outcome.bytes;
        if (outcome.complete) { removed++; } else { failed++; }
      } catch (error) {
        Diagnostics.log('warn', 'storage', 'cleanup_failed', undefined, error as Error);
        failed++;
      }
    }
    return { freedBytes: freedBytes, removed: removed, failed: failed, incomplete: false, failedPaths: [] };
  }

  static async cleanSafe(context: common.Context, data: StorageCatalog): Promise<StorageCleanResult> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    const inventory = await StorageUsage.cleanupInventory(roots, failures);
    const candidates = await StorageUsage.safeCandidates(roots, data, Date.now(), failures, inventory);
    const result = await StorageUsage.remove(context, candidates, data);
    result.incomplete = failures.length > 0;
    result.failedPaths = failures;
    return result;
  }
}
