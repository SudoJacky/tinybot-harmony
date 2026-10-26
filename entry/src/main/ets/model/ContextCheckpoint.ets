import { t } from './I18n';
import { CompactionData, ThreadData } from './Conversation';
import { ContextEntry } from './ContextProjection';
import { validateFileOperations } from './FileOperations';

export function contextBoundary(entries: ContextEntry[], checkpoint?: CompactionData): number {
  if (!checkpoint) { return 0; }
  const index = entries.findIndex((entry) => entry.messageId === checkpoint.firstKeptMessageId && entry.step === checkpoint.firstKeptStep);
  if (index < 0) { throw new Error('Context checkpoint boundary is missing; original transcript preserved.'); }
  return index;
}

export function validateCompaction(compaction: CompactionData, thread: ThreadData): void {
  if (compaction?.fileOperations !== undefined) { validateFileOperations(compaction.fileOperations); }
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
