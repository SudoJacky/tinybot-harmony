import { attachmentContext } from './AttachmentContext';
import { ModelMessage, ToolDefinition, toolSchemas } from './Agent';
import { FileOperations, collectFileOperations } from './FileOperations';
import { CompactionData } from './Conversation';
import { ContextEntry } from './ContextProjection';
import { contextBoundary } from './ContextCheckpoint';

export interface CompactionPlan {
  fileOperations?: FileOperations;
  firstKeptMessageId: string;
  firstKeptStep?: number;
  messages: ModelMessage[];
  previousSummary: string;
  tokensBefore: number;
}

// A heuristic, not a tokenizer: count CJK/non-ASCII conservatively instead of dividing all text by four.
export function estimateTextTokens(text: string): number {
  let ascii = 0;
  let other = 0;
  for (let index = 0; index < text.length; index++) {
    if (text.charCodeAt(index) < 128) { ascii++; } else { other++; }
  }
  return Math.ceil(ascii / 3) + other * 2;
}

export function estimateContextTokens(messages: ModelMessage[], tools: ToolDefinition[] = []): number {
  let tokens = 3 + (tools.length > 0 ? estimateTextTokens(JSON.stringify(toolSchemas(tools))) : 0);
  for (const message of messages) {
    tokens += 8 + estimateTextTokens(message.content) + estimateTextTokens(message.reasoningContent || '');
    for (const attachment of message.attachments || []) { tokens += attachment.mime === 'image/jpeg' ? 1800 : estimateTextTokens(attachmentContext(attachment)); }
    if (message.toolCalls) { tokens += estimateTextTokens(JSON.stringify(message.toolCalls)); }
    if (message.toolCallId) { tokens += estimateTextTokens(message.toolCallId); }
  }
  return tokens;
}

export function planContextCompaction(entries: ContextEntry[], checkpoint: CompactionData | undefined,
  keepRecent: number, tokensBefore: number): CompactionPlan | undefined {
  const start = contextBoundary(entries, checkpoint);
  let cut = -1;
  for (let index = start + 1; index < entries.length; index++) {
    const boundary = entries[index];
    if (!boundary.messages.length && entries.slice(index + 1).some((entry) => entry.messages.length > 0)) { continue; }
    const removed = entries.slice(start, index).flatMap((entry) => entry.messages);
    // Do not summarize only a user request and then reinsert that same request as the anchor.
    if (!removed.some((message) => message.role === 'assistant' || message.role === 'tool')) { continue; }
    cut = index;
    const anchor = boundary.step === undefined ? [] : entries.find((entry) => entry.messageId === boundary.messageId && entry.step === undefined)?.messages || [];
    if (estimateContextTokens(anchor.concat(entries.slice(index).flatMap((entry) => entry.messages))) - 3 <= keepRecent) { break; }
  }
  if (cut < 0) { return undefined; }
  const boundary = entries[cut];
  return { firstKeptMessageId: boundary.messageId, firstKeptStep: boundary.step,
    messages: entries.slice(start, cut).flatMap((entry) => entry.messages),
    previousSummary: checkpoint?.summary || '', tokensBefore: tokensBefore,
    fileOperations: collectFileOperations(entries.slice(start, cut).flatMap((entry) => entry.results || []), checkpoint?.fileOperations) };
}
