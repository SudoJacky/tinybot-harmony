import { t } from '../model/I18n';
import { MAX_AGENT_STEPS, ModelMessage, ToolDefinition } from '../model/Agent';
import { ModelConfig, ThreadData } from '../model/Conversation';
import { contextSettings, contextInputBudget, estimateContextTokens, prepareCompaction, threadHistory } from '../model/ConversationContext';
import { ExtensionSettings, skillCatalog } from '../model/Skills';
import { compactContext } from './ContextCompactor';
import { Cancellation } from './Cancellation';
import { ModelSession } from './providers/Provider';
import { DEFAULT_SYSTEM_PROMPT, runtimeInstructions, userDocumentContext } from '../model/SystemPrompt';

export function sessionInstructions(config: ModelConfig, extensions: ExtensionSettings, selected: string = ''): string {
  return DEFAULT_SYSTEM_PROMPT + runtimeInstructions(extensions.webEnabled, MAX_AGENT_STEPS) +
    userDocumentContext(config.userDocument || '') + skillCatalog(extensions.skills, selected);
}

// The caller owns the thread and commit boundary; this module owns budgeting and compaction policy.
export async function prepareSessionContext(thread: ThreadData, model: ModelSession, cancellation: Cancellation,
  manual: boolean, config: ModelConfig, instructions: string, tools: ToolDefinition[],
  persist: () => Promise<void>, progress: (status: string) => void): Promise<ModelMessage[]> {
  const settings = contextSettings(config);
  let history = threadHistory(thread, instructions);
  const tokens = estimateContextTokens(history, tools);
  if (manual || (settings.autoCompact && tokens > contextInputBudget(settings.window))) {
    const plan = prepareCompaction(thread, settings);
    if (!plan) { throw new Error(t("没有可压缩的较早完整轮次。最近一轮和当前输入会保留，请缩小任务或提高上下文窗口。")); }
    progress(t('正在压缩较早对话…'));
    const compacted = await compactContext(plan, settings, model, cancellation,
      (batch: number) => progress(t('正在压缩较早对话 · 第 {0} 批', [batch])));
    cancellation.check();
    const candidate = JSON.parse(JSON.stringify(thread)) as ThreadData;
    candidate.compaction = compacted;
    const candidateHistory = threadHistory(candidate, instructions);
    if (estimateContextTokens(candidateHistory, tools) >= tokens) {
      throw new Error(t("生成的摘要没有减少上下文用量，原摘要和历史已保留。请积累更多历史后再压缩，或提高窗口设置。"));
    }
    const previous = thread.compaction;
    thread.compaction = compacted;
    try { await persist(); } catch (error) { thread.compaction = previous; throw error as Error; }
    history = candidateHistory;
    progress(t('较早对话已压缩，完整记录保留'));
  }
  if (!manual && estimateContextTokens(history, tools) > contextInputBudget(settings.window)) {
    throw new Error(t("上下文仍超过预算。请压缩较早对话、缩小输入或提高窗口设置；没有静默丢弃历史。"));
  }
  return history;
}
