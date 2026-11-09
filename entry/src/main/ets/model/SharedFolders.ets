import { t } from './I18n';

export const SHARED_FOLDER_ROOT: string = 'shared';
export const MAX_PROJECT_SHARED_FOLDERS: number = 8;

export interface SharedFolder {
  id: string;
  name: string;
  uri: string;
  addedAt: number;
  webDavConnectionId?: string;
}

export function cloudSharedFolder(folders: SharedFolder[] | undefined, path: string): SharedFolder | undefined {
  if (!path.startsWith(SHARED_FOLDER_ROOT + '/')) { return undefined; }
  const name = path.slice(SHARED_FOLDER_ROOT.length + 1).split('/')[0];
  return folders?.find((folder) => folder.name === name && folder.webDavConnectionId !== undefined);
}

export function sharedFolderName(value: string): string {
  const name = value.trim().replace(/[\\/:*?"<>|\u0000-\u001f\u007f]/g, '_').replace(/^\.+$/, '').slice(0, 80);
  if (!name) { throw new Error(t('共享文件夹名称需要 1 至 80 个字符。')); }
  return name;
}

export function sharedFolderNameFromUri(uri: string): string {
  let value = uri.split('?')[0].replace(/\/+$/, '');
  value = value.slice(value.lastIndexOf('/') + 1);
  try { value = decodeURIComponent(value); } catch (_) { /* Keep the literal name. */ }
  value = value.trim();
  return value ? value.slice(0, 80) : t('共享文件夹');
}

export function uniqueSharedFolderName(base: string, existing: SharedFolder[], excludeId: string = ''): string {
  const names = new Set<string>();
  for (const item of existing) { if (item.id !== excludeId) { names.add(item.name.toLocaleLowerCase()); } }
  const name = sharedFolderName(base);
  if (!names.has(name.toLocaleLowerCase())) { return name; }
  for (let index = 2; index < 1000; index++) {
    const suffix = ' (' + index + ')';
    const stem = name.length + suffix.length > 80 ? name.slice(0, 80 - suffix.length) : name;
    const candidate = stem + suffix;
    if (!names.has(candidate.toLocaleLowerCase())) { return candidate; }
  }
  throw new Error(t('共享文件夹名称重复。'));
}

export function validateSharedFolders(folders: SharedFolder[] | undefined): void {
  if (folders === undefined) { return; }
  if (!Array.isArray(folders) || folders.length > MAX_PROJECT_SHARED_FOLDERS) { throw new Error(t('共享文件夹数据无效。')); }
  const ids = new Set<string>();
  const names = new Set<string>();
  const uris = new Set<string>();
  for (const folder of folders) {
    if (!folder || typeof folder.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(folder.id) ||
      typeof folder.name !== 'string' || sharedFolderName(folder.name) !== folder.name ||
      typeof folder.uri !== 'string' || folder.uri.length > 4096 ||
      (folder.webDavConnectionId === undefined ? !folder.uri.startsWith('file://') :
        typeof folder.webDavConnectionId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(folder.webDavConnectionId) ||
        !/^https:\/\/[^/?#@]+\/[^?#\\\u0000-\u001f\u007f]*$/.test(folder.uri) || !folder.uri.endsWith('/')) ||
      !Number.isFinite(folder.addedAt) || ids.has(folder.id) || names.has(folder.name.toLocaleLowerCase()) ||
      uris.has((folder.webDavConnectionId || '') + ' ' + folder.uri)) {
      throw new Error(t('共享文件夹数据无效。'));
    }
    ids.add(folder.id);
    names.add(folder.name.toLocaleLowerCase());
    uris.add((folder.webDavConnectionId || '') + ' ' + folder.uri);
  }
}
