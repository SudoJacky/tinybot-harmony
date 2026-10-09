import { t } from './I18n';
import { ModelMessage, ToolDefinition } from './Agent';
import { CompactionData, ModelConfig, ThreadData } from './Conversation';
import { ContextEntry, contextBoundary, projectedHistory, threadEntries } from './ContextProjection';

export const DEFAULT_CONTEXT_WINDOW: number = 200000;
// Tinybot desktop: src-tauri/src/agent/provider/model-defaults.json.
const MILLION_TOKEN_MODELS: string[] = ['deepseek-flash', 'deepseek-v4-flash', 'deepseek-v4-flash-vision-exp',
  'deepseek-v4-pro', 'glm-5.3', 'glm-5.3-flash'];
// Used only when neither the model nor its service has an explicit override.
export function defaultContextWindow(model: string): number {
  return MILLION_TOKEN_MODELS.includes(model.trim().toLowerCase()) ? 1000000 : DEFAULT_CONTEXT_WINDOW;
}
// pi coding-agent compaction defaults. Small windows retain usable input space.
export const DEFAULT_CONTEXT_RESERVE: number = 16384;
export const DEFAULT_KEEP_RECENT: number = 20000;
export const SUMMARY_MAX_TOKENS: number = 4096;
export function contextInputBudget(window: number): number {
  return window - Math.min(DEFAULT_CONTEXT_RESERVE, Math.floor(window / 2));
}

export interface ContextSettings {
  window: number;
  autoCompact: boolean;
  keepRecent: number;
}

export interface CompactionPlan {
  firstKeptMessageId: string;
  firstKeptStep?: number;
  messages: ModelMessage[];
  previousSummary: string;
  tokensBefore: number;
}

export function contextSettings(config: ModelConfig): ContextSettings {
  const window = config.contextWindow === undefined ? defaultContextWindow(config.model) : config.contextWindow;
  const autoCompact = config.autoCompact === undefined ? true : config.autoCompact;
  if (!Number.isInteger(window) || window < 8192 || window > 2000000 || typeof autoCompact !== 'boolean') {
    throw new Error(t("上下文窗口必须是 8192 至 2000000 的整数，自动压缩设置必须是布尔值。"));
  }
  return { window: window, autoCompact: autoCompact, keepRecent: Math.min(DEFAULT_KEEP_RECENT, Math.floor(window / 4)) };
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
  let tokens = 3 + (tools.length > 0 ? estimateTextTokens(JSON.stringify(tools)) : 0);
  for (const message of messages) {
    tokens += 8 + estimateTextTokens(message.content) + estimateTextTokens(message.reasoningContent || '');
    for (const attachment of message.attachments || []) { tokens += attachment.mime === 'image/jpeg' ? 1800 : estimateTextTokens(attachment.text || ''); }
    if (message.toolCalls) { tokens += estimateTextTokens(JSON.stringify(message.toolCalls)); }
    if (message.toolCallId) { tokens += estimateTextTokens(message.toolCallId); }
  }
  return tokens;
}

export function threadHistory(thread: ThreadData, instructions: string): ModelMessage[] {
  const prefix: ModelMessage[] = instructions.trim() ? [{ role: 'system', content: instructions }] : [];
  return prefix.concat(projectedHistory(threadEntries(thread), thread.compaction));
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
    previousSummary: checkpoint?.summary || '', tokensBefore: tokensBefore };
}

export function prepareCompaction(thread: ThreadData, settings: ContextSettings): CompactionPlan | undefined {
  return planContextCompaction(threadEntries(thread), thread.compaction, settings.keepRecent,
    estimateContextTokens(threadHistory(thread, '')));
}

export function validateCompaction(compaction: CompactionData, thread: ThreadData): void {
  if (!compaction || typeof compaction.summary !== 'string' || compaction.summary.trim().length === 0 ||
    compaction.summary.length > 32768 || typeof compaction.firstKeptMessageId !== 'string' ||
    !Number.isInteger(compaction.tokensBefore) || compaction.tokensBefore < 0 ||
    !Number.isFinite(compaction.createdAt) || compaction.createdAt < 0) {
    throw new Error(t("本地上下文摘要损坏，原文件已保留。"));
  }
  const index = thread.messages.findIndex((message) => message.id === compaction.firstKeptMessageId);
  if (index < 0 || index % 2 !== 0) { throw new Error(t("本地上下文摘要边界损坏，原文件已保留。")); }
  if (compaction.firstKeptStep !== undefined) {
    const answer = thread.messages[index + 1];
    const count = answer?.steps?.length || (answer && answer.status !== 'generating' ? 1 : 0);
    if (!Number.isInteger(compaction.firstKeptStep) || compaction.firstKeptStep < 0 || compaction.firstKeptStep > count) {
      throw new Error('Invalid context step boundary; original transcript preserved.');
    }
  }
}
