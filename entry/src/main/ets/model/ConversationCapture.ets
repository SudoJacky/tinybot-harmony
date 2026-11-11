import { AppData, MessageData, ThreadData } from './Conversation';
import { ThreadCheckpoint } from '../services/SessionContracts';

interface CapturedMessage { source: MessageData; text: string; }
interface CapturedThread { text: string; messages: Map<string, CapturedMessage>; }
export interface CapturedConversation { header: string; threads: Map<string, string>; }

// Preserve every metadata field without walking the transcript. Values are JSON
// data; composing already encoded messages avoids escaping old tool output again.
function threadJson(thread: ThreadData, messages: string[]): string {
  const fields = thread as Object as Record<string, Object>;
  const parts: string[] = [];
  for (const key of Object.keys(thread)) {
    const text = key === 'messages' ? '[' + messages.join(',') + ']' : JSON.stringify(fields[key]);
    if (text !== undefined) { parts.push(JSON.stringify(key) + ':' + text); }
  }
  return '{' + parts.join(',') + '}';
}

export class ConversationCapture {
  private captured: Map<string, CapturedThread> = new Map<string, CapturedThread>();
  clear(): void { this.captured.clear(); }

  capture(data: AppData, changedThreadIds?: string[], checkpoint?: ThreadCheckpoint): CapturedConversation {
    const changed = changedThreadIds === undefined ? undefined : new Set(changedThreadIds);
    const next = new Map<string, CapturedThread>(); const threads = new Map<string, string>();
    for (const thread of data.threads) {
      const previous = this.captured.get(thread.id);
      if (previous && changed !== undefined && !changed.has(thread.id)) {
        next.set(thread.id, previous); threads.set(thread.id, previous.text); continue;
      }
      const messages = new Map<string, CapturedMessage>(); const texts: string[] = [];
      for (const item of thread.messages) {
        const cached = previous?.messages.get(item.id);
        // A checkpoint explicitly identifies the only changed message, if any.
        // Other writes recapture the whole changed thread.
        const snapshot: CapturedMessage = checkpoint?.threadId === thread.id && checkpoint.messageId !== item.id && cached?.source === item ?
          cached : { source: item, text: JSON.stringify(item) };
        messages.set(item.id, snapshot); texts.push(snapshot.text);
      }
      const text = threadJson(thread, texts);
      next.set(thread.id, { text: text, messages: messages }); threads.set(thread.id, text);
    }
    // Serialize root metadata generically too: a newer build may own more fields.
    // Do not deep-clone data here; that would walk all transcripts on every checkpoint.
    const fields = data as Object as Record<string, Object>; const parts: string[] = [];
    for (const key of Object.keys(data)) {
      const text = key === 'threads' ? '[]' : JSON.stringify(fields[key]);
      if (text !== undefined) { parts.push(JSON.stringify(key) + ':' + text); }
    }
    const header = '{' + parts.join(',') + '}';
    this.captured = next;
    return { header: header, threads: threads };
  }
}
