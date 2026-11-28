import { attachmentContext } from './AttachmentContext';
import { fileAnnotationContext } from './FileAnnotation';
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
export function textTokenThirds(text: string): number {
  let thirds = 0;
  for (let index = 0; index < text.length; index++) {
    thirds += text.charCodeAt(index) < 128 ? 1 : 6;
  }
  return thirds;
}

export function estimateTextTokens(text: string): number { return Math.ceil(textTokenThirds(text) / 3); }

export function estimateContextTokens(messages: ModelMessage[], tools: ToolDefinition[] = []): number {
  let tokens = 3 + (tools.length > 0 ? estimateTextTokens(JSON.stringify(toolSchemas(tools))) : 0);
  for (const message of messages) {
    tokens += 8 + estimateTextTokens(message.content) + estimateTextTokens(message.reasoningContent || '');
    for (const attachment of message.attachments || []) {
      if (attachment.mime === 'image/jpeg') { tokens += 1800; }
      if (attachment.mime !== 'image/jpeg' || attachment.browserAnnotation) { tokens += estimateTextTokens(attachmentContext(attachment)); }
    }
    if (message.annotations?.length) { tokens += estimateTextTokens(fileAnnotationContext(message.annotations)); }
    if (message.toolCalls) { tokens += estimateTextTokens(JSON.stringify(message.toolCalls)); }
    if (message.toolCallId) { tokens += estimateTextTokens(message.toolCallId); }
  }
  return tokens;
}

export function planContextCompaction(entries: ContextEntry[], checkpoint: CompactionData | undefined,
  keepRecent: number, tokensBefore: number): CompactionPlan | undefined {
  const start = contextBoundary(entries, checkpoint);
  if (start + 1 >= entries.length) { return undefined; }
  const anchors = new Map<string, number>();
  const costs: number[] = [];
  let remaining = 0;
  let lastNonempty = start;
  for (let index = 0; index < entries.length; index++) {
    const entry = entries[index];
    if (index < start && entry.step !== undefined) { continue; }
    const cost = estimateContextTokens(entry.messages) - 3;
    if (entry.step === undefined && !anchors.has(entry.messageId)) { anchors.set(entry.messageId, cost); }
    if (index >= start) {
      costs.push(cost); remaining += cost;
      if (entry.messages.length) { lastNonempty = index; }
    }
  }
  let cut = -1;
  let hasResponse = false;
  for (let index = start + 1; index < entries.length; index++) {
    const boundary = entries[index];
    remaining -= costs[index - start - 1];
    hasResponse = hasResponse || entries[index - 1].messages.some((message) => message.role === 'assistant' || message.role === 'tool');
    if (!hasResponse || (!boundary.messages.length && index < lastNonempty)) { continue; }
    cut = index;
    const anchor = boundary.step === undefined ? 0 : (anchors.get(boundary.messageId) ?? 0);
    if (remaining + anchor <= keepRecent) { break; }
  }
  if (cut < 0) { return undefined; }
  const boundary = entries[cut];
  return { firstKeptMessageId: boundary.messageId, firstKeptStep: boundary.step,
    messages: entries.slice(start, cut).flatMap((entry) => entry.messages),
    previousSummary: checkpoint?.summary || '', tokensBefore: tokensBefore,
    fileOperations: collectFileOperations(entries.slice(start, cut).flatMap((entry) => entry.results || []), checkpoint?.fileOperations) };
}
