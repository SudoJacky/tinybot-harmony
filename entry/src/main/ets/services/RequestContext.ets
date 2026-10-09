import { ContextDiagnostics, ModelMessage, ModelTurn, ToolDefinition } from '../model/Agent';
import { CompactionData, ContextState, ModelConfig } from '../model/Conversation';
import { planContextCompaction, contextInputBudget, contextSettings, estimateContextTokens, estimateTextTokens } from '../model/ConversationContext';
import { ContextEntry, PromptSection, projectedHistory, renderPrompt } from '../model/ContextProjection';
import { Cancellation } from './Cancellation';
import { compactContext } from './ContextCompactor';
import { projectResults } from './ContextTools';
import { ModelSession } from './providers/Provider';
import { t } from '../model/I18n';

export interface ContextSource {
  state: ContextState;
  entries: () => ContextEntry[];
  sections: () => PromptSection[];
  persist: () => Promise<void>;
  progress: (status: string) => void;
}
export interface PreparedRequest { messages: ModelMessage[]; context: ContextDiagnostics; }

// One boundary for every assistant request. Storage, UI and tool execution remain outside this module.
export class RequestContext {
  private source: ContextSource;
  private config: ModelConfig;
  private baselineMessages: string[] = [];
  private baselineTools: string = '';
  private baselineInput: number = 0;
  private lastMessages: string[] = [];
  private lastTools: string = '';

  constructor(source: ContextSource, config: ModelConfig) { this.source = source; this.config = config; }

  inspect(tools: ToolDefinition[]): PreparedRequest {
    const sections = this.source.sections();
    const entries = projectResults(this.source.entries(), contextSettings(this.config).window);
    const messages = this.assemble(entries, sections, this.source.state.compaction, []);
    return { messages: messages, context: this.describe(messages, tools, sections) };
  }

  recordResponse(response: ModelTurn): void {
    const input = response.usage?.tokens?.input;
    if (response.usage?.status === 'complete' && input !== undefined && Number.isInteger(input) && input > 0) {
      this.baselineMessages = this.lastMessages; this.baselineTools = this.lastTools; this.baselineInput = input;
    } else { this.baselineInput = 0; }
  }

  async prepare(model: ModelSession, tools: ToolDefinition[], cancellation: Cancellation,
    pending: ModelMessage[] = [], manual: boolean = false): Promise<PreparedRequest> {
    cancellation.check();
    const settings = contextSettings(this.config);
    const sections = this.source.sections();
    const instructions = renderPrompt(sections);
    const entries = projectResults(this.source.entries(), settings.window);
    const assemble = (checkpoint?: CompactionData): ModelMessage[] => this.assemble(entries, sections, checkpoint, pending);
    let messages = assemble(this.source.state.compaction);
    let diagnostics = this.describe(messages, tools, sections);
    if (manual || (settings.autoCompact && diagnostics.tokens > diagnostics.inputBudget)) {
      const overhead = estimateContextTokens(instructions ? [{ role: 'system', content: instructions }] : [], tools) + estimateContextTokens(pending);
      // The summary prompt targets about 1000 CJK characters; leave room for its wrapper too.
      const keep = Math.min(settings.keepRecent, Math.max(0, contextInputBudget(settings.window) - overhead - 2200));
      const plan = planContextCompaction(entries, this.source.state.compaction, keep, diagnostics.tokens);
      if (!plan) { throw new Error(t('没有可压缩的较早完整轮次。最近一轮和当前输入会保留，请缩小任务或提高上下文窗口。')); }
      this.source.progress(t('正在压缩较早对话…'));
      const checkpoint = await compactContext(plan, settings, model, cancellation,
        (batch) => this.source.progress(t('正在压缩较早对话 · 第 {0} 批', [batch])));
      cancellation.check();
      const candidate = assemble(checkpoint);
      if (estimateContextTokens(candidate, tools) >= estimateContextTokens(messages, tools)) {
        throw new Error(t('生成的摘要没有减少上下文用量，原摘要和历史已保留。请积累更多历史后再压缩，或提高窗口设置。'));
      }
      const previous = this.source.state.compaction;
      this.source.state.compaction = checkpoint;
      try { await this.source.persist(); } catch (error) { this.source.state.compaction = previous; throw error as Error; }
      cancellation.check();
      this.baselineInput = 0;
      messages = candidate; diagnostics = this.describe(messages, tools, sections);
      this.source.progress(t('较早对话已压缩，完整记录保留'));
    }
    if (!manual && diagnostics.tokens > diagnostics.inputBudget) {
      throw new Error(t('上下文仍超过预算。请压缩较早对话、缩小输入或提高窗口设置；没有静默丢弃历史。') + ' (' + diagnostics.tokens + '/' + diagnostics.inputBudget + ')');
    }
    this.lastMessages = messages.map((message) => JSON.stringify(message));
    this.lastTools = JSON.stringify(tools);
    return { messages: messages, context: diagnostics };
  }

  private assemble(entries: ContextEntry[], sections: PromptSection[], checkpoint: CompactionData | undefined, pending: ModelMessage[]): ModelMessage[] {
    const instructions = renderPrompt(sections);
    const prefix: ModelMessage[] = instructions ? [{ role: 'system', content: instructions }] : [];
    return prefix.concat(projectedHistory(entries, checkpoint), pending);
  }

  private describe(messages: ModelMessage[], tools: ToolDefinition[], sections: PromptSection[]): ContextDiagnostics {
    const heuristic = estimateContextTokens(messages, tools);
    let tokens = heuristic; let source = 'estimate';
    // Never reuse usage across compaction, a prompt/tool change, or another request prefix.
    if (this.baselineInput > 0 && this.baselineTools === JSON.stringify(tools) && messages.length >= this.baselineMessages.length &&
      this.baselineMessages.every((message, index) => message === JSON.stringify(messages[index]))) {
      tokens = this.baselineInput + estimateContextTokens(messages.slice(this.baselineMessages.length)) - 3; source = 'usage+estimate';
    }
    const sizes: Record<string, number> = {};
    for (const section of sections) { sizes[section.name] = estimateTextTokens(section.content); }
    return { tokens: tokens, heuristicTokens: heuristic, source: source, inputBudget: contextInputBudget(contextSettings(this.config).window),
      sections: sizes, toolTokens: estimateTextTokens(JSON.stringify(tools)),
      historyTokens: estimateContextTokens(messages.filter((message) => message.role !== 'system')),
      projectedResults: messages.filter((message) => message.role === 'tool' && message.content.startsWith('{"contextPreview":true,')).length };
  }
}
