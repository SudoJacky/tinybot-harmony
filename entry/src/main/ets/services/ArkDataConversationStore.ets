import { AppData, ThreadData, parseAppData } from '../model/Conversation';
import { ConversationCapture, CapturedConversation } from '../model/ConversationCapture';
import { SessionRepository, ThreadCheckpoint } from './SessionContracts';
import { ArkDataRecords, StoredRecord } from './ArkDataRecords';

interface ConversationIndex { metadata: string; threadIds: string[]; }

export function conversationRecords(snapshot: CapturedConversation): StoredRecord[] {
  const index: ConversationIndex = { metadata: snapshot.header, threadIds: Array.from(snapshot.threads.keys()) };
  const records: StoredRecord[] = [{ scope: 'app', id: 'index', text: JSON.stringify(index) }];
  snapshot.threads.forEach((text: string, id: string) => { records.push({ scope: 'thread', id: id, text: text }); });
  return records;
}

export class ArkDataConversationStore implements SessionRepository {
  private database: () => Promise<ArkDataRecords>;
  private capture: ConversationCapture = new ConversationCapture();
  private saved: Map<string, string> = new Map();
  private index: string = '';
  private pending: Promise<void> = Promise.resolve();
  private failed: boolean = false;

  constructor(database: () => Promise<ArkDataRecords>) { this.database = database; }

  async load(): Promise<AppData> {
    await this.pending;
    const db = await this.database(), raw = await db.read('app', 'index');
    if (raw === undefined) { throw new Error('ArkData conversation index is missing'); }
    const index = JSON.parse(raw) as ConversationIndex;
    if (typeof index.metadata !== 'string' || !Array.isArray(index.threadIds) || new Set(index.threadIds).size !== index.threadIds.length) {
      throw new Error('ArkData conversation index is invalid');
    }
    const data = JSON.parse(index.metadata) as AppData;
    const saved = new Map<string, string>();
    for (const id of index.threadIds) {
      const text = await db.read('thread', id);
      if (text === undefined) { throw new Error('ArkData conversation is missing'); }
      const thread = JSON.parse(text) as ThreadData;
      if (thread.id !== id) { throw new Error('ArkData conversation does not match its index'); }
      data.threads.push(thread); saved.set(id, text);
    }
    const loaded = parseAppData(JSON.stringify(data));
    this.index = raw; this.saved = saved;
    this.capture.clear(); this.capture.capture(loaded); this.failed = false;
    return loaded;
  }

  save(data: AppData, changedThreadIds?: string[], checkpoint?: ThreadCheckpoint): Promise<void> {
    if (this.failed) { this.capture.clear(); }
    const snapshot = this.capture.capture(data, this.failed ? undefined : changedThreadIds, this.failed ? undefined : checkpoint);
    this.failed = false;
    const result = this.pending.then(async () => {
      const db = await this.database();
      const records = conversationRecords(snapshot);
      const changed = records.filter((record) => record.scope === 'app' ? record.text !== this.index : record.text !== this.saved.get(record.id));
      for (const id of this.saved.keys()) {
        if (!snapshot.threads.has(id)) { changed.push({ scope: 'thread', id: id }); }
      }
      await db.commit(changed);
      this.index = records[0].text!; this.saved = snapshot.threads;
    });
    this.pending = result.catch(() => { this.failed = true; });
    return result;
  }
}
