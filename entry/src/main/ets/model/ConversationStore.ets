import { Diagnostics } from './Diagnostics';
import { t } from './I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool, util } from '@kit.ArkTS';
import { AppData, ThreadData, emptyData, parseAppData } from './Conversation';
import { MessageCheckpoint, SessionRepository } from '../services/SessionContracts';
import { ConversationCapture } from './ConversationCapture';
import { writeConversationFile } from '../services/ConversationWriter';

interface ThreadFile { id: string; file: string; }
interface Manifest { version: number; data: AppData; threads: ThreadFile[]; }

// Changed threads are immutable; the atomic manifest switch commits the entire snapshot.
export class ConversationStore implements SessionRepository {
  private root: string;
  private legacy: string;
  private pendingSave: Promise<void> = Promise.resolve();
  private serialized: Map<string, string> = new Map<string, string>();
  private capture: ConversationCapture = new ConversationCapture();
  private captureFailed: boolean = false;
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
    const data = parseAppData(JSON.stringify(manifest.data));
    // Recovery/normalization belongs to the loaded state, even for an inactive thread.
    this.capture.clear(); this.capture.capture(data);
    this.captureFailed = false;
    return data;
  }
  save(data: AppData, changedThreadIds?: string[], message?: MessageCheckpoint): Promise<void> {
    // Capture synchronously, before any queued IO. Immutable strings can be shared across saves.
    // Failed candidates may have been rolled back by the caller. Re-capture its authoritative state.
    const mark = Diagnostics.begin();
    if (this.captureFailed) { this.capture.clear(); }
    const snapshot = this.capture.capture(data, this.captureFailed ? undefined : changedThreadIds, message);
    const header = snapshot.header; const next = snapshot.threads;
    this.captureFailed = false;
    if (Diagnostics.recording) { Diagnostics.end('storage.capture', mark, { threads: data.threads.length, changed: changedThreadIds ? changedThreadIds.length : data.threads.length, metadataChars: header.length }); }
    const saved = this.pendingSave.then(() => this.commit(header, next));
    // Keep the queue usable; the failed operation still rejects to its caller.
    this.pendingSave = saved.catch(() => { this.captureFailed = true; }); return saved;
  }
  private async commit(header: string, next: Map<string, string>): Promise<void> {
    if (!await fs.access(this.root)) { await fs.mkdir(this.root); }
    const entries: ThreadFile[] = [];
    for (const id of Array.from(next.keys())) {
      const text = next.get(id) as string;
      let name = this.files.get(id);
      if (!name || text !== this.serialized.get(id)) {
        name = util.generateRandomUUID() + '.json'; await this.write(this.root + '/' + name, text);
      }
      entries.push({ id: id, file: name });
    }
    const manifest: Manifest = { version: 2, data: JSON.parse(header) as AppData, threads: entries };
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
    const mark = Diagnostics.begin();
    let bytes = 0;
    try {
      bytes = await taskpool.execute(writeConversationFile, path, text) as number;
    } finally { if (Diagnostics.recording) { Diagnostics.end('storage.write', mark, { bytes: bytes }); } }
  }
}
