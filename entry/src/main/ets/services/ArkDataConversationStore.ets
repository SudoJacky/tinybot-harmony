import { AppData, MessageData, ThreadData, parseAppData } from '../model/Conversation';
import { CapturedConversation } from '../model/ConversationCapture';
import { SessionRepository, ThreadCheckpoint } from './SessionContracts';
import { ArkDataRecords, CONVERSATION_MESSAGE_SCOPE_PREFIX, StoredRecord } from './ArkDataRecords';
import { Diagnostics } from '../model/Diagnostics';

interface ConversationIndex { format?: number; header?: string; metadata?: string; threadIds: string[]; }
interface StoredThread { metadata: ThreadData; messageCount: number; }
interface StoredMessageSnapshot { source?: MessageData; text: string; }
interface StoredThreadSnapshot { text: string; messages: StoredMessageSnapshot[]; }

const SEPARATE_MESSAGES = 2;

function messageScope(threadId: string): string { return CONVERSATION_MESSAGE_SCOPE_PREFIX + threadId; }
function messagePosition(index: number): string { return index.toString().padStart(12, '0'); }

function encodeMetadata(data: Object, collection: string): string {
  const fields = data as Record<string, Object>;
  const encoded: string[] = [];
  for (const key of Object.keys(data)) {
    const value = key === collection ? '[]' : JSON.stringify(fields[key]);
    if (value !== undefined) { encoded.push(JSON.stringify(key) + ':' + value); }
  }
  return '{' + encoded.join(',') + '}';
}

export function conversationRecords(snapshot: CapturedConversation): StoredRecord[] {
  const index: ConversationIndex = { metadata: snapshot.header, threadIds: Array.from(snapshot.threads.keys()) };
  const records: StoredRecord[] = [{ scope: 'app', id: 'index', text: JSON.stringify(index) }];
  snapshot.threads.forEach((text: string, id: string) => { records.push({ scope: 'thread', id: id, text: text }); });
  return records;
}

export class ArkDataConversationStore implements SessionRepository {
  private database: () => Promise<ArkDataRecords>;
  private databaseSnapshot: Map<string, StoredThreadSnapshot> = new Map();
  private captured: Map<string, StoredThreadSnapshot> = new Map();
  private index: string = '';
  private pending: Promise<void> = Promise.resolve();
  private failed: boolean = false;

  constructor(database: () => Promise<ArkDataRecords>) { this.database = database; }

  async load(): Promise<AppData> {
    await this.pending;
    const db = await this.database(), raw = await db.read('app', 'index');
    if (raw === undefined) { throw new Error('ArkData conversation index is missing'); }
    const index = JSON.parse(raw) as ConversationIndex;
    const legacy = index.format === undefined;
    const header = legacy ? index.metadata : index.header;
    if ((!legacy && index.format !== SEPARATE_MESSAGES) || typeof header !== 'string' || !Array.isArray(index.threadIds) ||
      new Set(index.threadIds).size !== index.threadIds.length) {
      throw new Error('ArkData conversation index is invalid');
    }
    const data = JSON.parse(header) as AppData;
    const saved = new Map<string, StoredThreadSnapshot>();
    for (const id of index.threadIds) {
      const text = await db.read('thread', id);
      if (text === undefined) { throw new Error('ArkData conversation is missing'); }
      let thread: ThreadData;
      if (legacy) { thread = JSON.parse(text) as ThreadData; }
      else {
        const stored = JSON.parse(text) as StoredThread;
        thread = stored.metadata;
        const records = await db.readScope(messageScope(id));
        if (records.length !== stored.messageCount) { throw new Error('ArkData conversation message count does not match'); }
        const messages = records.map((record, position): StoredMessageSnapshot => {
          if (record.id !== messagePosition(position)) { throw new Error('ArkData conversation message position is invalid'); }
          return { text: record.text };
        });
        thread.messages = messages.map((message): MessageData => JSON.parse(message.text) as MessageData);
        saved.set(id, { text: text, messages: messages });
      }
      if (thread.id !== id) { throw new Error('ArkData conversation does not match its index'); }
      data.threads.push(thread);
    }
    const loaded = parseAppData(JSON.stringify(data));
    this.index = raw; this.databaseSnapshot = saved; this.captured.clear(); this.failed = false;
    if (legacy) {
      // Conversion and its format marker commit together. An older app rejects the new index
      // instead of interpreting metadata-only thread records as empty chats.
      await this.save(loaded);
      Diagnostics.log('info', 'storage', 'conversation_message_records_migrated', { threads: loaded.threads.length });
    } else { this.captured = this.capture(loaded); }
    return loaded;
  }

  save(data: AppData, changedThreadIds?: string[], checkpoint?: ThreadCheckpoint): Promise<void> {
    if (this.failed) { this.captured.clear(); }
    const snapshot = this.capture(data, this.failed ? undefined : changedThreadIds, this.failed ? undefined : checkpoint);
    this.captured = snapshot;
    const header = encodeMetadata(data, 'threads');
    const index: ConversationIndex = { format: SEPARATE_MESSAGES, header: header, threadIds: Array.from(snapshot.keys()) };
    const text = JSON.stringify(index);
    this.failed = false;
    const result = this.pending.then(async () => {
      const db = await this.database();
      const changed: StoredRecord[] = [];
      if (text !== this.index) { changed.push({ scope: 'app', id: 'index', text: text }); }
      snapshot.forEach((thread, id) => {
        const previous = this.databaseSnapshot.get(id);
        if (thread === previous) { return; }
        if (thread.text !== previous?.text) { changed.push({ scope: 'thread', id: id, text: thread.text }); }
        this.collectMessageChanges(changed, id, previous?.messages || [], thread.messages);
      });
      this.databaseSnapshot.forEach((thread, id) => {
        if (snapshot.has(id)) { return; }
        changed.push({ scope: 'thread', id: id });
        this.collectMessageChanges(changed, id, thread.messages, []);
      });
      await db.commit(changed);
      this.index = text; this.databaseSnapshot = snapshot;
    });
    this.pending = result.catch(() => { this.failed = true; });
    return result;
  }

  private capture(data: AppData, changedThreadIds?: string[], checkpoint?: ThreadCheckpoint): Map<string, StoredThreadSnapshot> {
    const changed = changedThreadIds === undefined ? undefined : new Set(changedThreadIds);
    const snapshot = new Map<string, StoredThreadSnapshot>();
    for (const thread of data.threads) {
      const previous = this.captured.get(thread.id);
      if (previous && changed !== undefined && !changed.has(thread.id)) { snapshot.set(thread.id, previous); continue; }
      const messages = thread.messages.map((message, index): StoredMessageSnapshot => {
        const cached = previous?.messages[index];
        return checkpoint?.threadId === thread.id && checkpoint.messageId !== message.id && cached?.source === message ?
          cached : { source: message, text: JSON.stringify(message) };
      });
      const text = '{"metadata":' + encodeMetadata(thread, 'messages') + ',"messageCount":' + messages.length + '}';
      snapshot.set(thread.id, { text: text, messages: messages });
    }
    return snapshot;
  }

  private collectMessageChanges(changed: StoredRecord[], threadId: string, previous: StoredMessageSnapshot[],
    current: StoredMessageSnapshot[]): void {
    const scope = messageScope(threadId);
    for (let position = 0; position < Math.max(previous.length, current.length); position++) {
      const text = current[position]?.text;
      if (text !== previous[position]?.text) { changed.push({ scope: scope, id: messagePosition(position), text: text }); }
    }
  }
}
