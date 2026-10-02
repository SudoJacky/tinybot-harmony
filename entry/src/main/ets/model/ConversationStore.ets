import { t } from './I18n';
﻿import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, ThreadData, emptyData, parseAppData } from './Conversation';
import { SessionRepository } from '../services/SessionContracts';

interface ThreadFile { id: string; file: string; }
interface Manifest { version: number; data: AppData; threads: ThreadFile[]; }

// Changed threads are immutable; the atomic manifest switch commits the entire snapshot.
export class ConversationStore implements SessionRepository {
  private root: string;
  private legacy: string;
  private pendingSave: Promise<void> = Promise.resolve();
  private serialized: Map<string, string> = new Map<string, string>();
  private files: Map<string, string> = new Map<string, string>();
  constructor(filesDir: string) { this.root = filesDir + '/sessions-v2'; this.legacy = filesDir + '/tinybot-v1.json'; }
  async load(): Promise<AppData> {
    if (!await fs.access(this.root + '/index.json')) {
      const data = await fs.access(this.legacy) ? parseAppData(await fs.readText(this.legacy)) : emptyData();
      await this.save(data); return data;
    }
    const manifest = JSON.parse(await fs.readText(this.root + '/index.json')) as Manifest;
    if (!manifest || manifest.version !== 2 || !manifest.data || !Array.isArray(manifest.threads)) { throw new Error(t("会话索引损坏，原文件已保留。")); }
    const threads: ThreadData[] = [];
    for (const entry of manifest.threads) {
      if (!entry || !/^[a-zA-Z0-9-]+\.json$/.test(entry.file)) { throw new Error(t("会话文件索引无效。")); }
      const text = await fs.readText(this.root + '/' + entry.file);
      const thread = JSON.parse(text) as ThreadData;
      if (thread.id !== entry.id) { throw new Error(t("会话索引与内容不一致。")); }
      threads.push(thread); this.files.set(entry.id, entry.file); this.serialized.set(entry.id, text);
    }
    manifest.data.threads = threads;
    return parseAppData(JSON.stringify(manifest.data));
  }
  save(data: AppData): Promise<void> {
    const snapshot = JSON.parse(JSON.stringify(data)) as AppData;
    const saved = this.pendingSave.then(() => this.commit(snapshot));
    this.pendingSave = saved.catch(() => {}); return saved;
  }
  private async commit(data: AppData): Promise<void> {
    if (!await fs.access(this.root)) { await fs.mkdir(this.root); }
    const entries: ThreadFile[] = [];
    const next = new Map<string, string>();
    for (const thread of data.threads) {
      const text = JSON.stringify(thread); next.set(thread.id, text);
      let name = this.files.get(thread.id);
      if (!name || text !== this.serialized.get(thread.id)) {
        name = util.generateRandomUUID() + '.json'; await this.write(this.root + '/' + name, text);
      }
      entries.push({ id: thread.id, file: name });
    }
    data.threads = [];
    const manifest: Manifest = { version: 2, data: data, threads: entries };
    await this.write(this.root + '/index.json.tmp', JSON.stringify(manifest));
    await fs.rename(this.root + '/index.json.tmp', this.root + '/index.json');
    const old = Array.from(this.files.values());
    this.files.clear(); this.serialized = next;
    for (const entry of entries) { this.files.set(entry.id, entry.file); }
    for (const file of old) {
      if (!entries.some((entry) => entry.file === file)) {
        try { await fs.unlink(this.root + '/' + file); } catch (_) { /* Harmless orphan, never referenced. */ }
      }
    }
  }
  private async write(path: string, text: string): Promise<void> {
    const bytes = new util.TextEncoder().encodeInto(text);
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let written = 0;
      while (written < bytes.byteLength) {
        const count = await fs.write(file.fd, bytes.buffer.slice(written), { offset: written });
        if (count <= 0) { throw new Error(t("本地会话写入未完成。")); }
        written += count;
      }
      await fs.fsync(file.fd);
    } finally { await fs.close(file); }
  }
}
