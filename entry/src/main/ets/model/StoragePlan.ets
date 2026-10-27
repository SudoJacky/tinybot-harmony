// Storage bookkeeping shared by the settings page and its regression test.
// No HarmonyOS imports here: every helper is a pure decision over paths and timestamps.
export type StorageCategoryId = 'sessions' | 'workspace' | 'attachments' | 'backups' | 'usage' | 'diagnostics' | 'cache' | 'feedback';

export const STORAGE_CATEGORIES: StorageCategoryId[] = ['sessions', 'workspace', 'attachments', 'backups',
  'usage', 'diagnostics', 'cache', 'feedback'];

export interface StorageCategorySummary {
  id: StorageCategoryId;
  bytes: number;
  files: number;
}

export interface StorageEntry {
  path: string;
  label: string;
  detail: string;
  bytes: number;
  category: StorageCategoryId;
  removable: boolean;
  directory: boolean;
}

export interface StorageEntryResult {
  entries: StorageEntry[];
  incomplete: boolean;
  failedPaths: string[];
}

export interface StorageReport {
  categories: StorageCategorySummary[];
  incomplete: boolean;
  failedPaths: string[];
  totalBytes: number;
  freeBytes: number;
  deviceBytes: number;
  appBytes: number;
  dataBytes: number;
  cacheBytes: number;
  safeBytes: number;
  safeFiles: number;
  cacheCleanBytes: number;
  orphanAttachmentBytes: number;
  orphanWorkspaceBytes: number;
  tempBytes: number;
  orphanAttachments: number;
  orphanWorkspaces: number;
  staleTemps: number;
  scannedAt: number;
}

export interface StorageCleanResult {
  freedBytes: number;
  removed: number;
  failed: number;
  incomplete: boolean;
  failedPaths: string[];
}

export interface DiskFile {
  path: string;
  relative: string;
  bytes: number;
  modifiedAt: number;
}

const HOUR: number = 60 * 60 * 1000;
const DAY: number = 24 * HOUR;

// New cache files may still be in use by an export or share sheet.
export function isCacheCleanable(modifiedAt: number, now: number): boolean {
  return now - modifiedAt >= 10 * 60 * 1000;
}

export function isStaleTemporary(name: string, modifiedAt: number, now: number): boolean {
  return name.startsWith('.tinybot-') && (name.endsWith('.tmp') || name.endsWith('.tmp.json')) && now - modifiedAt >= HOUR;
}

export function orphanAttachmentPaths(files: string[], referenced: string[]): string[] {
  const used = new Set<string>(referenced);
  return files.filter((file: string): boolean => !used.has(file));
}

export function orphanWorkspaceIds(dirs: string[], threadIds: string[], projectWorkspaceIds: string[]): string[] {
  const used = new Set<string>(threadIds.concat(projectWorkspaceIds));
  return dirs.filter((dir: string): boolean => !used.has(dir));
}

export function storageCategoryKey(id: string): string {
  switch (id) {
    case 'sessions': return '会话记录';
    case 'workspace': return '工作区文件';
    case 'attachments': return '附件';
    case 'backups': return '修改备份';
    case 'usage': return '用量账本';
    case 'diagnostics': return '诊断与性能日志';
    case 'cache': return '缓存与临时文件';
    case 'feedback': return '反馈附件';
    default: return '存储空间';
  }
}

export function storageCategorySummary(id: StorageCategoryId, bytes: number, files: number): StorageCategorySummary {
  return { id: id, bytes: bytes, files: files };
}

export function emptyStorageReport(): StorageReport {
  const categories: StorageCategorySummary[] = [];
  for (const id of STORAGE_CATEGORIES) { categories.push(storageCategorySummary(id, 0, 0)); }
  return { categories: categories, incomplete: false, failedPaths: [], totalBytes: 0, freeBytes: 0, deviceBytes: 0,
    appBytes: 0, dataBytes: 0, cacheBytes: 0, safeBytes: 0, safeFiles: 0, cacheCleanBytes: 0,
    orphanAttachmentBytes: 0, orphanWorkspaceBytes: 0, tempBytes: 0, orphanAttachments: 0,
    orphanWorkspaces: 0, staleTemps: 0, scannedAt: 0 };
}

export function emptyStorageEntryResult(): StorageEntryResult {
  return { entries: [], incomplete: false, failedPaths: [] };
}
