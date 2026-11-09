import { SessionPhase } from '../services/SessionContracts';

export interface CollaborationThread {
  id: string; title: string; updatedAt: number; phase: SessionPhase; status?: string; error: string; queued: number; model: string;
}

@Observed
export class CollaborationThreadState implements CollaborationThread {
  id: string = ''; title: string = ''; updatedAt: number = 0; phase: SessionPhase = 'idle'; status?: string;
  error: string = ''; queued: number = 0; model: string = '';
  constructor(thread: CollaborationThread) { this.update(thread); }
  update(thread: CollaborationThread): void {
    this.id = thread.id; this.title = thread.title; this.updatedAt = thread.updatedAt; this.phase = thread.phase;
    this.status = thread.status; this.error = thread.error; this.queued = thread.queued; this.model = thread.model;
  }
}

export function projectCollaborationThreads(previous: CollaborationThreadState[], threads: CollaborationThread[]): CollaborationThreadState[] {
  const states = new Map<string, CollaborationThreadState>();
  for (const thread of previous) { states.set(thread.id, thread); }
  return threads.map((thread): CollaborationThreadState => {
    const state = states.get(thread.id);
    if (state) { state.update(thread); return state; }
    return new CollaborationThreadState(thread);
  });
}
export interface CollaborationOutput {
  thread: CollaborationThread; messages: CollaborationMessage[];
}
export interface CollaborationTool { id: string; name: string; status: string; }
export interface CollaborationMessage {
  id: string; role: string; content: string; status: string; error: string; thinking: boolean; tools: CollaborationTool[];
  contentOffset?: number;
}

@Observed
export class CollaborationMessageState implements CollaborationMessage {
  id: string = ''; role: string = ''; content: string = ''; status: string = ''; error: string = '';
  thinking: boolean = false; tools: CollaborationTool[] = [];
  constructor(message: CollaborationMessage) { this.update(message); }
  update(message: CollaborationMessage): void {
    this.id = message.id; this.role = message.role; this.content = message.content;
    this.status = message.status; this.error = message.error; this.thinking = message.thinking; this.tools = message.tools;
  }
}
export interface CollaborationPacket {
  version: number;
  kind: 'hello' | 'catalog' | 'watch' | 'output' | 'command' | 'receipt';
  name?: string; threads?: CollaborationThread[]; threadId?: string; output?: CollaborationOutput;
  requestId?: string; action?: 'create' | 'send' | 'stop'; text?: string; error?: string;
  from?: number;
  watchId?: string;
}

// Initial selection is a snapshot; later packets replace a changed tail and append only new text.
export function collaborationUpdate(previous: CollaborationOutput | undefined, current: CollaborationOutput): CollaborationPacket | undefined {
  if (!previous || previous.thread.id !== current.thread.id) { return { version: 1, kind: 'output', output: current, from: 0 }; }
  let from = 0;
  while (from < Math.min(previous.messages.length, current.messages.length) &&
    JSON.stringify(previous.messages[from]) === JSON.stringify(current.messages[from])) { from++; }
  if (from === previous.messages.length && from === current.messages.length &&
    JSON.stringify(previous.thread) === JSON.stringify(current.thread)) { return undefined; }
  const messages = current.messages.slice(from).map((message, index): CollaborationMessage => {
    const old = previous.messages[from + index];
    if (!old || old.id !== message.id || !message.content.startsWith(old.content)) { return message; }
    return { id: message.id, role: message.role, content: message.content.slice(old.content.length),
      contentOffset: old.content.length, status: message.status, error: message.error, thinking: message.thinking, tools: message.tools };
  });
  return { version: 1, kind: 'output', from: from, output: { thread: current.thread, messages: messages } };
}

export function applyCollaborationUpdate(previous: CollaborationOutput | undefined, packet: CollaborationPacket): CollaborationOutput {
  const output = packet.output!; const from = packet.from ?? 0;
  if (!Number.isSafeInteger(from) || from < 0 || (from > 0 && (!previous || previous.thread.id !== output.thread.id || from > previous.messages.length))) {
    throw new Error('Collaboration output sequence mismatch.');
  }
  const messages = output.messages.map((message, index): CollaborationMessage => {
    const offset = message.contentOffset;
    const old = previous?.thread.id === output.thread.id ? previous.messages[from + index] : undefined;
    if (offset !== undefined && (!old || old.id !== message.id || offset !== old.content.length)) {
      throw new Error('Collaboration text sequence mismatch.');
    }
    return { id: message.id, role: message.role, content: (offset !== undefined ? old!.content : '') + message.content,
      status: message.status, error: message.error, thinking: message.thinking, tools: message.tools };
  });
  return { thread: output.thread, messages: (from > 0 ? previous!.messages.slice(0, from) : []).concat(messages) };
}

export interface CollaborationFrame { v: number; id: number; index: number; last: boolean; text: string; }
export const COLLABORATION_MAX_CHARS: number = 2 * 1024 * 1024;

// sendMessage accepts at most 1 KiB, including JSON escaping and UTF-8 encoding.
export function collaborationBytes(text: string): number {
  let bytes = 0;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code < 128) { bytes++; }
    else if (code < 2048) { bytes += 2; }
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length &&
      text.charCodeAt(index + 1) >= 0xdc00 && text.charCodeAt(index + 1) <= 0xdfff) { bytes += 4; index++; }
    else { bytes += 3; }
  }
  return bytes;
}

export function collaborationFrames(packet: CollaborationPacket, id: number): string[] {
  const body = JSON.stringify(packet);
  if (body.length > COLLABORATION_MAX_CHARS) { throw new Error('Collaboration message exceeds 2 MiB.'); }
  const frames: string[] = [];
  let offset = 0;
  while (offset < body.length) {
    let end = Math.min(body.length, offset + 700);
    let frame: CollaborationFrame = { v: 1, id: id, index: frames.length, last: end === body.length, text: body.slice(offset, end) };
    while (collaborationBytes(JSON.stringify(frame)) > 1000) {
      end -= 32; frame.text = body.slice(offset, end); frame.last = end === body.length;
    }
    frames.push(JSON.stringify(frame)); offset = end;
  }
  return frames;
}

// A connection has one ordered send lane. Gaps and interleaving are protocol errors.
export class CollaborationReceiver {
  private id: number = -1;
  private next: number = 0;
  private parts: string[] = [];
  private size: number = 0;
  private completed: number = -1;
  receive(text: string): CollaborationPacket | undefined {
    if (collaborationBytes(text) > 1024) { throw new Error('Oversized collaboration frame.'); }
    const frame = JSON.parse(text) as CollaborationFrame;
    if (!frame || frame.v !== 1 || !Number.isSafeInteger(frame.id) || frame.id < 0 ||
      !Number.isSafeInteger(frame.index) || typeof frame.last !== 'boolean' || typeof frame.text !== 'string') {
      throw new Error('Invalid collaboration frame.');
    }
    if (this.id === -1) {
      if (frame.index !== 0 || frame.id <= this.completed) { throw new Error('Stale collaboration frame.'); }
      this.id = frame.id;
    }
    if (frame.id !== this.id || frame.index !== this.next) { throw new Error('Collaboration frame sequence mismatch.'); }
    this.size += frame.text.length;
    if (this.size > COLLABORATION_MAX_CHARS) { throw new Error('Oversized collaboration message.'); }
    this.parts.push(frame.text); this.next++;
    if (!frame.last) { return undefined; }
    const packet = JSON.parse(this.parts.join('')) as CollaborationPacket;
    this.completed = this.id; this.id = -1; this.next = 0; this.parts = []; this.size = 0;
    if (!packet || packet.version !== 1 || !['hello', 'catalog', 'watch', 'output', 'command', 'receipt'].includes(packet.kind)) {
      throw new Error('Unsupported collaboration protocol.');
    }
    return packet;
  }
}
