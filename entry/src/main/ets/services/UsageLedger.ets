import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RequestUsage, UsageToolActivity } from '../model/Usage';
import { writeBytes } from './Attachments';
import { util } from '@kit.ArkTS';

interface UsageManifest { version: number; pages: number; }
const PAGE_SIZE = 256;

export class UsageLedger {
  private static path: string = '';
  private static records: RequestUsage[] = [];
  private static positions: Map<string, number> = new Map();
  private static dirty: Set<number> = new Set();
  private static persistedPages: number = 0;
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
  static configure(root: string): Promise<void> {
    UsageLedger.path = root + '/usage-records'; UsageLedger.ready = false;
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
  private static async flush(): Promise<void> {
    if (!UsageLedger.ready) { return; }
    do {
    while (UsageLedger.dirty.size > 0) {
      const page = UsageLedger.dirty.values().next().value as number;
      UsageLedger.dirty.delete(page);
      try {
        await UsageLedger.write(UsageLedger.pagePath(page), JSON.stringify(UsageLedger.records.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE)));
      } catch (error) { UsageLedger.dirty.add(page); throw new Error((error as Error).message); }
    }
    const pages = Math.ceil(UsageLedger.records.length / PAGE_SIZE);
    if (pages !== UsageLedger.persistedPages || !await fs.access(UsageLedger.path + '/index.json')) {
      const manifest: UsageManifest = { version: 1, pages: pages };
      await UsageLedger.write(UsageLedger.path + '/index.json', JSON.stringify(manifest)); UsageLedger.persistedPages = pages;
    }
    } while (UsageLedger.dirty.size > 0);
  }
  // A shallow snapshot is held by the query service, never by an observed view.
  static list(): RequestUsage[] { return UsageLedger.records.slice(); }
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
    UsageLedger.dirty.add(Math.floor(index / PAGE_SIZE)); UsageLedger.revision++; UsageLedger.notify();
    if (!UsageLedger.path || UsageLedger.scheduled) { return; }
    UsageLedger.scheduled = true;
    UsageLedger.queue = UsageLedger.queue.catch(() => {}).then(async () => {
      UsageLedger.scheduled = false;
      const previousError = UsageLedger.error;
      try { await UsageLedger.flush(); if (UsageLedger.ready) { UsageLedger.error = ''; } }
      catch (error) { UsageLedger.error = '用量保存失败：' + (error as Error).message; }
      if (UsageLedger.error !== previousError) { UsageLedger.notify(); }
    });
  }
}
