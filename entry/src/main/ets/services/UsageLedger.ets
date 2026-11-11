import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RequestUsage, UsageToolActivity } from '../model/Usage';
import { writeBytes } from './Attachments';
import { util } from '@kit.ArkTS';
import { BackupChanges } from '../model/BackupChanges';
import { Diagnostics } from '../model/Diagnostics';
import { withFileMutation } from './FileMutationQueue';
import { ArkDataRecords, StoredRecord } from './ArkDataRecords';

interface UsageManifest { version: number; pages: number; }
const PAGE_SIZE = 256;
export const USAGE_SCOPE = 'usage';
export function usageRecordId(position: number): string { return position.toString().padStart(16, '0'); }

export async function readLegacyUsage(root: string): Promise<RequestUsage[]> {
  const byId = new Map<string, RequestUsage>();
  const append = (text: string): void => {
    const items = JSON.parse(text) as RequestUsage[];
    if (!Array.isArray(items)) { throw new Error(t('用量记录格式损坏。')); }
    for (const item of items) {
      if (!item || typeof item.id !== 'string' || !item.id) { throw new Error(t('用量记录格式损坏。')); }
      byId.set(item.id, item);
    }
  };
  const directory = root + '/usage-records';
  if (await fs.access(directory + '/index.json')) {
    const manifest = JSON.parse(await fs.readText(directory + '/index.json')) as UsageManifest;
    if (manifest.version !== 1 || !Number.isSafeInteger(manifest.pages) || manifest.pages < 0) { throw new Error(t('用量记录格式损坏。')); }
    for (let page = 0; page < manifest.pages; page++) {
      append(await fs.readText(directory + '/' + page + '.json'));
    }
  } else if (await fs.access(root + '/usage-ledger.json')) { append(await fs.readText(root + '/usage-ledger.json')); }
  return Array.from(byId.values());
}

export class UsageLedger {
  private static path: string = '';
  private static records: RequestUsage[] = [];
  private static positions: Map<string, number> = new Map();
  private static dirty: Set<number> = new Set();
  private static persistedPages: number = 0;
  private static database?: () => Promise<ArkDataRecords>;
  private static ready: boolean = false;
  private static scheduled: boolean = false;
  private static queue: Promise<void> = Promise.resolve();
  private static listeners: (() => void)[] = [];
  static revision: number = 0;
  static error: string = '';
  static get isReady(): boolean { return UsageLedger.ready; }
  static subscribe(listener: () => void): () => void {
    UsageLedger.listeners.push(listener);
    return () => { UsageLedger.listeners = UsageLedger.listeners.filter((item) => item !== listener); };
  }
  private static notify(): void {
    for (const listener of UsageLedger.listeners) {
      try { listener(); } catch (_) { /* Views cannot interrupt accounting. */ }
    }
  }
  static configure(root: string, database?: () => Promise<ArkDataRecords>): Promise<void> {
    UsageLedger.path = root + '/usage-records'; UsageLedger.ready = false;
    UsageLedger.database = database;
    UsageLedger.queue = UsageLedger.queue.catch(() => {}).then(async () => {
      try {
        await UsageLedger.load(root); UsageLedger.ready = true;
        await UsageLedger.flush(); UsageLedger.error = '';
      } catch (error) { UsageLedger.error = (error as Error).message; throw new Error(UsageLedger.error); }
      finally { UsageLedger.revision++; UsageLedger.notify(); }
    });
    return UsageLedger.queue;
  }
  private static async load(root: string): Promise<void> {
    if (UsageLedger.database) {
      const db = await UsageLedger.database();
      const loaded: RequestUsage[] = [];
      for (const id of await db.ids(USAGE_SCOPE)) {
        const text = await db.read(USAGE_SCOPE, id);
        if (id !== usageRecordId(loaded.length) || text === undefined) { throw new Error(t('用量记录格式损坏。')); }
        loaded.push(JSON.parse(text) as RequestUsage);
      }
      const index = new Map<string, number>();
      for (let i = 0; i < loaded.length; i++) {
        const id = loaded[i]?.id;
        if (typeof id !== 'string' || !id || index.has(id)) { throw new Error(t('用量记录格式损坏。')); }
        index.set(id, i);
      }
      UsageLedger.dirty.clear();
      for (const current of UsageLedger.records) {
        const position = index.get(current.id) ?? loaded.length;
        loaded[position] = current; index.set(current.id, position); UsageLedger.dirty.add(position);
      }
      UsageLedger.records = loaded; UsageLedger.positions = index;
      return;
    }
    const loaded: RequestUsage[] = []; const index = new Map<string, number>();
    const append = (items: RequestUsage[]): void => {
      if (!Array.isArray(items)) { throw new Error(t('用量记录格式损坏。')); }
      for (const item of items) {
        const found = index.get(item.id);
        if (found === undefined) { index.set(item.id, loaded.length); loaded.push(item); } else { loaded[found] = item; }
      }
    };
    UsageLedger.persistedPages = 0;
    const manifestPath = UsageLedger.path + '/index.json';
    if (await fs.access(manifestPath)) {
      const manifest = JSON.parse(await fs.readText(manifestPath)) as UsageManifest;
      if (manifest.version !== 1 || !Number.isSafeInteger(manifest.pages) || manifest.pages < 0) { throw new Error(t('用量记录格式损坏。')); }
      for (let page = 0; page < manifest.pages; page++) {
        append(JSON.parse(await fs.readText(UsageLedger.pagePath(page))) as RequestUsage[]);
        await new Promise<void>((resolve) => setTimeout(resolve, 0));
      }
      UsageLedger.persistedPages = manifest.pages;
    } else if (await fs.access(root + '/usage-ledger.json')) {
      // One-time migration. Keep the legacy file until all shards and the manifest
      // commit successfully; it remains a recovery copy afterwards.
      append(JSON.parse(await fs.readText(root + '/usage-ledger.json')) as RequestUsage[]);
    }
    UsageLedger.dirty.clear();
    // Calls arriving during asynchronous restore win over disk copies.
    for (const current of UsageLedger.records) {
      const found = index.get(current.id); const position = found === undefined ? loaded.length : found;
      if (found === undefined) { index.set(current.id, position); loaded.push(current); } else { loaded[position] = current; }
      UsageLedger.dirty.add(Math.floor(position / PAGE_SIZE));
    }
    UsageLedger.records = loaded; UsageLedger.positions = index;
    if (UsageLedger.persistedPages === 0) {
      for (let page = 0; page < Math.ceil(loaded.length / PAGE_SIZE); page++) { UsageLedger.dirty.add(page); }
    }
    if (!await fs.access(UsageLedger.path)) { await fs.mkdir(UsageLedger.path); }
  }
  private static pagePath(page: number): string { return UsageLedger.path + '/' + page + '.json'; }
  private static async write(path: string, value: string): Promise<void> {
    await writeBytes(path + '.tmp', new util.TextEncoder().encodeInto(value).buffer as ArrayBuffer);
    await fs.rename(path + '.tmp', path);
  }
  private static flush(): Promise<void> {
    // Backups can flush directly while request accounting schedules its own flush.
    return withFileMutation(UsageLedger.path, async () => {
      if (!UsageLedger.ready) { return; }
      if (UsageLedger.database) {
        const db = await UsageLedger.database();
        while (UsageLedger.dirty.size > 0) {
          const positions = Array.from(UsageLedger.dirty).slice(0, PAGE_SIZE);
          const records = positions.map((position: number): StoredRecord => ({ scope: USAGE_SCOPE,
            id: usageRecordId(position), text: JSON.stringify(UsageLedger.records[position]) }));
          positions.forEach((position) => { UsageLedger.dirty.delete(position); });
          try { await db.commit(records); }
          catch (error) { positions.forEach((position) => { UsageLedger.dirty.add(position); }); throw error as Error; }
        }
        return;
      }
      do {
        while (UsageLedger.dirty.size > 0) {
          const page = UsageLedger.dirty.values().next().value as number;
          UsageLedger.dirty.delete(page);
          try {
            await UsageLedger.write(UsageLedger.pagePath(page), JSON.stringify(UsageLedger.records.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)));
          } catch (error) { UsageLedger.dirty.add(page); throw error as Error; }
        }
        const pages = Math.ceil(UsageLedger.records.length / PAGE_SIZE);
        if (pages !== UsageLedger.persistedPages || !await fs.access(UsageLedger.path + '/index.json')) {
          const manifest: UsageManifest = { version: 1, pages: pages };
          await UsageLedger.write(UsageLedger.path + '/index.json', JSON.stringify(manifest)); UsageLedger.persistedPages = pages;
        }
      } while (UsageLedger.dirty.size > 0);
    });
  }
  // A shallow snapshot is held by the query service, never by an observed view.
  static list(): RequestUsage[] { return UsageLedger.records.slice(); }
  static async backup(root: string): Promise<RequestUsage[]> {
    if (UsageLedger.path === root + '/usage-records') {
      await UsageLedger.queue;
      if (!UsageLedger.ready) { throw new Error(UsageLedger.error || 'Usage storage is not ready for backup'); }
      await UsageLedger.flush();
      return JSON.parse(JSON.stringify(UsageLedger.records)) as RequestUsage[];
    }
    return readLegacyUsage(root);
  }
  static async restoreBackup(root: string, records: RequestUsage[]): Promise<void> {
    if (!records.length) { return; }
    if (UsageLedger.path !== root + '/usage-records' || !UsageLedger.ready) { throw new Error('Usage storage is not ready for restore'); }
    await UsageLedger.queue;
    for (const item of records) { if (!UsageLedger.positions.has(item.id)) { UsageLedger.record(item); } }
    await UsageLedger.queue;
    await UsageLedger.flush();
    if (UsageLedger.error) { UsageLedger.error = ''; UsageLedger.notify(); }
  }
  static recordTool(requestId: string, activity: UsageToolActivity): void {
    const position = UsageLedger.positions.get(requestId); if (position === undefined) { return; }
    const updated = JSON.parse(JSON.stringify(UsageLedger.records[position])) as RequestUsage;
    updated.tools = (updated.tools || []).filter((item) => item.id !== activity.id)
      .concat([JSON.parse(JSON.stringify(activity)) as UsageToolActivity]);
    UsageLedger.record(updated);
  }
  static record(item: RequestUsage): void {
    let index = UsageLedger.positions.get(item.id);
    if (index === undefined) { index = UsageLedger.records.length; UsageLedger.positions.set(item.id, index); UsageLedger.records.push(item); }
    else { UsageLedger.records[index] = item; }
    UsageLedger.dirty.add(UsageLedger.database ? index : Math.floor(index / PAGE_SIZE));
    UsageLedger.revision++; BackupChanges.revision++; UsageLedger.notify();
    if (!UsageLedger.path || UsageLedger.scheduled) { return; }
    UsageLedger.scheduled = true;
    UsageLedger.queue = UsageLedger.queue.catch(() => {}).then(async () => {
      UsageLedger.scheduled = false;
      const previousError = UsageLedger.error;
      try { await UsageLedger.flush(); if (UsageLedger.ready) { UsageLedger.error = ''; } }
      catch (error) {
        Diagnostics.log('error', 'storage', 'usage_save_failed', undefined, error as Error);
        UsageLedger.error = '用量保存失败：' + (error as Error).message;
      }
      if (UsageLedger.error !== previousError) { UsageLedger.notify(); }
    });
  }
}
