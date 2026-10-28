import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, storageStatistics } from '@kit.CoreFileKit';
import { AppData, ThreadData } from '../model/Conversation';
import { Attachment } from '../model/Productivity';
import { toolReceipts } from '../model/Agent';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { t } from '../model/I18n';
import { DiskFile, StorageCategoryId, StorageCleanResult, StorageEntry, StorageEntryResult, StorageReport,
  emptyStorageReport, isCacheCleanable, isStaleTemporary, orphanAttachmentPaths, orphanWorkspaceIds } from '../model/StoragePlan';

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
  report.totalBytes += bytes;
}

function fileEntry(file: DiskFile, category: StorageCategoryId, label: string, detail: string,
  removable: boolean): StorageEntry {
  return { path: file.path, label: label, detail: detail, bytes: file.bytes, category: category,
    removable: removable, directory: false };
}

function under(relative: string, dirs: string[]): boolean {
  for (const dir of dirs) { if (relative.startsWith(dir + '/')) { return true; } }
  return false;
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

  private static failed(failures: string[], path: string): void {
    if (failures.indexOf(path) < 0) { failures.push(path); }
  }

  private static async listFiles(root: string, failures: string[]): Promise<DiskFile[]> {
    const result: DiskFile[] = [];
    try {
      if (!await fs.access(root)) { return result; }
    } catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root); }
      return result;
    }
    const pending: string[] = [''];
    while (pending.length > 0) {
      const relativeDir = pending.pop() as string;
      const directory = relativeDir.length === 0 ? root : root + '/' + relativeDir;
      let names: string[] = [];
      try { names = await fs.listFile(directory); }
      catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, directory); }
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
          if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, directory); }
          continue;
        }
      }
    }
    return result;
  }

  private static async sizeOf(path: string, failures: string[]): Promise<number> {
    return sumFiles(await StorageUsage.listFiles(path, failures));
  }

  private static async listDirectories(root: string, failures: string[]): Promise<string[]> {
    const result: string[] = [];
    try {
      if (!await fs.access(root)) { return result; }
    } catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root); }
      return result;
    }
    let names: string[] = [];
    try { names = await fs.listFile(root); }
    catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root); }
      return result;
    }
    for (const name of names) {
      try {
        const stat = await fs.lstat(root + '/' + name);
        if (stat.isDirectory() && !stat.isSymbolicLink()) { result.push(name); }
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root + '/' + name); }
        continue;
      }
    }
    return result;
  }

  // Attachment paths referenced by any live thread, including pending inputs and tool screenshots.
  private static references(data: AppData): Map<string, string> {
    const result = new Map<string, string>();
    const add = (item: Attachment): void => { if (item && item.path && !item.workspaceId) { result.set(item.path, item.name); } };
    for (const thread of data.threads) {
      for (const item of thread.attachments || []) { add(item); }
      for (const input of thread.pendingInputs || []) {
        for (const item of input.attachments || []) { add(item); }
      }
      for (const message of thread.messages) {
        for (const item of message.attachments || []) { add(item); }
        for (const step of message.steps || []) {
          for (const item of step.steering?.attachments || []) { add(item); }
          for (const tool of toolReceipts(step.tools)) {
            if (tool.previewScreenshot) { add(tool.previewScreenshot.image); }
            for (const frame of tool.browserObservation?.frames || []) { add(frame.image); }
          }
        }
      }
    }
    return result;
  }

  private static workspaceNames(data: AppData): Map<string, string> {
    const result = new Map<string, string>();
    for (const thread of data.threads) {
      if (!thread.projectId) { result.set(thread.id, thread.title || thread.id); }
    }
    for (const project of data.projects || []) { result.set(project.workspaceId, project.name); }
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

  // An empty review folder no longer protects a leftover workspace; unreadable ones still do.
  private static async reviewHasBackups(path: string, failures: string[]): Promise<boolean> {
    try {
      if (!await fs.access(path)) { return false; }
      const stat = await fs.lstat(path);
      if (stat.isSymbolicLink() || !stat.isDirectory()) { return true; }
      return (await fs.listFile(path)).length > 0;
    } catch (error) {
      if (StorageUsage.missing(error as Error)) { return false; }
      StorageUsage.failed(failures, path);
      return true;
    }
  }

  private static async safeCandidates(roots: StorageRoots, data: AppData, now: number,
    failures: string[]): Promise<StorageEntry[]> {
    const workspaceRoot = StorageUsage.workspaceRoot(roots);
    const workspace = await StorageUsage.workspaceFiles(roots, failures);
    const cache = await StorageUsage.listFiles(roots.cacheDir, failures);
    const attachments = await StorageUsage.listFiles(roots.appFilesDir + '/attachments', failures);
    const dirs = await StorageUsage.listDirectories(workspaceRoot, failures);
    const threadIds = data.threads.filter((thread: ThreadData): boolean => !thread.projectId)
      .map((thread: ThreadData): string => thread.id);
    const projectIds = (data.projects || []).map((project): string => project.workspaceId);
    const orphanDirs = orphanWorkspaceIds(dirs, threadIds, projectIds);
    // A leftover folder that still holds edit baselines is kept: the backups category owns them.
    const cleanDirs: string[] = [];
    for (const dir of orphanDirs) {
      const reviewPath = workspaceRoot + '/' + dir + '/' + REVIEW_DIR;
      const appsPath = workspaceRoot + '/' + dir + '/mini-apps';
      if (!await StorageUsage.reviewHasBackups(reviewPath, failures) && !await StorageUsage.reviewHasBackups(appsPath, failures)) { cleanDirs.push(dir); }
    }
    const result: StorageEntry[] = [];
    for (const dir of cleanDirs) {
      const bytes = await StorageUsage.sizeOf(workspaceRoot + '/' + dir, failures);
      result.push({ path: workspaceRoot + '/' + dir, label: dir, detail: t('已删除会话的残留工作区'),
        bytes: bytes, category: 'workspace', removable: true, directory: true });
    }
    for (const file of workspace) {
      // A whole orphan folder already counts this file once.
      if (isStaleTemporary(baseName(file.relative), file.modifiedAt, now) && !under(file.relative, cleanDirs)) {
        result.push(fileEntry(file, 'workspace', file.relative, t('临时文件'), true));
      }
    }
    for (const file of cache) {
      if (isCacheCleanable(file.modifiedAt, now)) {
        result.push(fileEntry(file, 'cache', file.relative, t('缓存文件'), true));
      }
    }
    const references = StorageUsage.references(data);
    const attachmentNames = attachments.map((file: DiskFile): string => file.relative);
    const orphans = new Set<string>(orphanAttachmentPaths(attachmentNames, Array.from(references.keys())));
    for (const file of attachments) {
      if (orphans.has(file.relative)) {
        result.push(fileEntry(file, 'attachments', baseName(file.relative), t('未使用'), true));
      }
    }
    return result;
  }

  static async scan(context: common.Context, data: AppData): Promise<StorageReport> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    const report = emptyStorageReport();
    const now = Date.now();
    const sessions = await StorageUsage.listFiles(roots.abilityFilesDir + '/sessions-v2', failures);
    addCategory(report, 'sessions', sumFiles(sessions), sessions.length);
    const workspace = await StorageUsage.workspaceFiles(roots, failures);
    let workspaceBytes = 0, workspaceCount = 0, backupBytes = 0, backupCount = 0;
    for (const file of workspace) {
      if (StorageUsage.isReview(file)) { backupBytes += file.bytes; backupCount++; }
      else { workspaceBytes += file.bytes; workspaceCount++; }
    }
    addCategory(report, 'workspace', workspaceBytes, workspaceCount);
    addCategory(report, 'backups', backupBytes, backupCount);
    const attachments = await StorageUsage.listFiles(roots.appFilesDir + '/attachments', failures);
    addCategory(report, 'attachments', sumFiles(attachments), attachments.length);
    const usage = await StorageUsage.listFiles(roots.abilityFilesDir + '/usage-records', failures);
    addCategory(report, 'usage', sumFiles(usage), usage.length);
    let diagnosticsBytes = 0, diagnosticsFiles = 0;
    const diagnosticPaths: string[] = [roots.abilityFilesDir + '/performance-current.jsonl',
      roots.abilityFilesDir + '/performance-previous.jsonl', roots.appFilesDir + '/tinybot-cpu.json'];
    for (const path of diagnosticPaths) {
      try {
        if (await fs.access(path)) {
          const stat = await fs.lstat(path);
          if (stat.isFile() && !stat.isSymbolicLink()) { diagnosticsBytes += stat.size; diagnosticsFiles++; }
        }
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, path); }
        continue;
      }
    }
    addCategory(report, 'diagnostics', diagnosticsBytes, diagnosticsFiles);
    const cache = await StorageUsage.listFiles(roots.cacheDir, failures);
    addCategory(report, 'cache', sumFiles(cache), cache.length);
    const feedback = await StorageUsage.listFiles(roots.abilityFilesDir + '/feedback-files', failures);
    addCategory(report, 'feedback', sumFiles(feedback), feedback.length);

    try {
      const stats = await storageStatistics.getCurrentBundleStats();
      report.appBytes = stats.appSize; report.dataBytes = stats.dataSize; report.cacheBytes = stats.cacheSize;
    } catch (_) { /* Categories still describe local data without the system rollup. */ }
    try { report.freeBytes = await storageStatistics.getFreeSize(); } catch (_) { report.freeBytes = 0; }
    try { report.deviceBytes = await storageStatistics.getTotalSize(); } catch (_) { report.deviceBytes = 0; }

    const candidates = await StorageUsage.safeCandidates(roots, data, now, failures);
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

  private static async sessionEntries(roots: StorageRoots, data: AppData,
    failures: string[]): Promise<StorageEntry[]> {
    const root = roots.abilityFilesDir + '/sessions-v2';
    const threads = new Map<string, ThreadData>();
    for (const thread of data.threads) { threads.set(thread.id, thread); }
    const result: StorageEntry[] = [];
    let text = '';
    try { text = await fs.readText(root + '/index.json'); }
    catch (error) {
      if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root + '/index.json'); }
      return result;
    }
    let manifest: SessionManifest = {};
    try { manifest = JSON.parse(text) as SessionManifest; }
    catch (_) { StorageUsage.failed(failures, root + '/index.json'); return result; }
    for (const item of manifest.threads || []) {
      try {
        const stat = await fs.lstat(root + '/' + item.file);
        if (!stat.isFile() || stat.isSymbolicLink()) { continue; }
        const thread = threads.get(item.id);
        result.push({ path: root + '/' + item.file, label: thread && thread.title.length > 0 ? thread.title : item.id,
          detail: t('{0} 条消息', [thread ? thread.messages.length : 0]), bytes: stat.size,
          category: 'sessions', removable: false, directory: false });
      } catch (error) {
        if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, root); }
        continue;
      }
    }
    return result;
  }

  private static async workspaceEntries(roots: StorageRoots, data: AppData,
    failures: string[]): Promise<StorageEntry[]> {
    const names = StorageUsage.workspaceNames(data);
    const files = await StorageUsage.workspaceFiles(roots, failures);
    const dirs = new Set<string>(await StorageUsage.listDirectories(StorageUsage.workspaceRoot(roots), failures));
    const orphans = new Set<string>(orphanWorkspaceIds(Array.from(dirs),
      data.threads.filter((thread: ThreadData): boolean => !thread.projectId).map((thread: ThreadData): string => thread.id),
      (data.projects || []).map((project): string => project.workspaceId)));
    for (const id of Array.from(orphans)) {
      if (await StorageUsage.reviewHasBackups(StorageUsage.workspaceRoot(roots) + '/' + id + '/mini-apps', failures)) { orphans.delete(id); }
    }
    const result: StorageEntry[] = [];
    for (const file of files) {
      if (StorageUsage.isReview(file)) { continue; }
      const parts = file.relative.split('/');
      const owner = names.get(parts[0]) || parts[0];
      const rest = parts.slice(1).join('/');
      result.push(fileEntry(file, 'workspace', rest.length > 0 ? owner + ' / ' + rest : owner, file.relative,
        orphans.has(parts[0])));
    }
    return result;
  }

  private static async backupEntries(roots: StorageRoots, data: AppData,
    failures: string[]): Promise<StorageEntry[]> {
    const names = StorageUsage.workspaceNames(data);
    const files = await StorageUsage.workspaceFiles(roots, failures);
    const result: StorageEntry[] = [];
    for (const file of files) {
      if (!StorageUsage.isReview(file)) { continue; }
      const owner = names.get(file.relative.split('/')[0]) || '';
      result.push(fileEntry(file, 'backups', StorageUsage.reviewLabel(file, owner), file.relative, true));
    }
    return result;
  }

  private static async attachmentEntries(roots: StorageRoots, data: AppData,
    failures: string[]): Promise<StorageEntry[]> {
    const references = StorageUsage.references(data);
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

  static async entries(context: common.Context, data: AppData, category: string): Promise<StorageEntryResult> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    let result: StorageEntry[] = [];
    if (category === 'sessions') { result = await StorageUsage.sessionEntries(roots, data, failures); }
    else if (category === 'workspace') { result = await StorageUsage.workspaceEntries(roots, data, failures); }
    else if (category === 'backups') { result = await StorageUsage.backupEntries(roots, data, failures); }
    else if (category === 'attachments') { result = await StorageUsage.attachmentEntries(roots, data, failures); }
    else if (category === 'usage') {
      for (const file of await StorageUsage.listFiles(roots.abilityFilesDir + '/usage-records', failures)) {
        result.push(fileEntry(file, 'usage', file.relative, t('用量账本'), false));
      }
    } else if (category === 'diagnostics') {
      const paths: string[] = [roots.abilityFilesDir + '/performance-current.jsonl',
        roots.abilityFilesDir + '/performance-previous.jsonl', roots.appFilesDir + '/tinybot-cpu.json'];
      for (const path of paths) {
        try {
          if (await fs.access(path)) {
            const stat = await fs.lstat(path);
            if (stat.isFile() && !stat.isSymbolicLink()) {
              result.push({ path: path, label: baseName(path), detail: t('开发者模式中清理'), bytes: stat.size,
                category: 'diagnostics', removable: false, directory: false });
            }
          }
        } catch (error) {
          if (!StorageUsage.missing(error as Error)) { StorageUsage.failed(failures, path); }
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

  // Best effort: a partial tree returns the bytes that were actually removed and complete=false.
  private static async deletePath(path: string): Promise<DeleteOutcome> {
    try {
      const stat = await fs.lstat(path);
      if (stat.isSymbolicLink()) {
        try { await fs.unlink(path); return { bytes: 0, complete: true }; }
        catch (error) { return { bytes: 0, complete: StorageUsage.missing(error as Error) }; }
      }
      if (stat.isDirectory()) {
        let bytes = 0, complete = true;
        let names: string[] = [];
        try { names = await fs.listFile(path); }
        catch (error) { return { bytes: 0, complete: StorageUsage.missing(error as Error) }; }
        for (const name of names) {
          const outcome = await StorageUsage.deletePath(path + '/' + name);
          bytes += outcome.bytes;
          if (!outcome.complete) { complete = false; }
        }
        try { await fs.rmdir(path); }
        catch (error) { if (!StorageUsage.missing(error as Error)) { complete = false; } }
        return { bytes: bytes, complete: complete };
      }
      try { await fs.unlink(path); return { bytes: stat.size, complete: true }; }
      catch (error) { return { bytes: 0, complete: StorageUsage.missing(error as Error) }; }
    } catch (error) {
      return { bytes: 0, complete: StorageUsage.missing(error as Error) };
    }
  }

  static async remove(context: common.Context, entries: StorageEntry[]): Promise<StorageCleanResult> {
    const storage = StorageUsage.roots(context);
    const roots: string[] = [storage.abilityFilesDir, storage.appFilesDir, storage.cacheDir];
    let freedBytes = 0, removed = 0, failed = 0;
    for (const entry of entries) {
      if (!entry.removable || !StorageUsage.allowed(entry.path, roots)) { failed++; continue; }
      try {
        const outcome = await StorageUsage.deletePath(entry.path);
        freedBytes += outcome.bytes;
        if (outcome.complete) { removed++; } else { failed++; }
      } catch (_) { failed++; }
    }
    return { freedBytes: freedBytes, removed: removed, failed: failed, incomplete: false, failedPaths: [] };
  }

  static async cleanSafe(context: common.Context, data: AppData): Promise<StorageCleanResult> {
    const roots = StorageUsage.roots(context);
    const failures: string[] = [];
    const result = await StorageUsage.remove(context,
      await StorageUsage.safeCandidates(roots, data, Date.now(), failures));
    result.incomplete = failures.length > 0;
    result.failedPaths = failures;
    return result;
  }
}
