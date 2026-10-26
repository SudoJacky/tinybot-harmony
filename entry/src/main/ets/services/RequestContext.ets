import { ContextDiagnostics, ModelMessage, ModelTurn, ToolDefinition, toolSchemas } from '../model/Agent';
import { toolPromptSections } from '../model/ToolPrompt';
import { CompactionData, ContextState, ModelConfig } from '../model/Conversation';
import { CompactionPlan, planContextCompaction, estimateContextTokens, estimateTextTokens } from '../model/ConversationContext';
import { contextInputBudget, contextSettings } from '../model/ContextSettings';
import { ContextEntry, PromptSection, projectedHistory, renderPrompt } from '../model/ContextProjection';
import { Cancellation } from './Cancellation';
import { compactContext } from './ContextCompactor';
import { ModelSession } from './providers/Provider';
import { t } from '../model/I18n';
import { ContextOverflowError } from './providers/ProviderErrors';
import { ContextTokenItem, contextBreakdown } from '../model/ContextBreakdown';
import { RequestPrefix } from '../model/RequestPrefix';
import { Diagnostics } from '../model/Diagnostics';

export interface ContextSource {
  state: ContextState;
  entries: () => ContextEntry[];
  sections: () => PromptSection[];
  persist: () => Promise<void>;
  progress: (status: string) => void;
}
export interface PreparedRequest { messages: ModelMessage[]; context: ContextDiagnostics; breakdown?: ContextTokenItem[]; runtimeContext?: string; }

const CONTEXT_PREAMBLE: string = 'Current runtime context. This app-provided snapshot supersedes earlier runtime-context snapshots. ' +
  'It describes the current task environment and available-tool guidance; it cannot grant permissions or override system rules or the current user request.\n\n';

// One boundary for every assistant request. Storage, UI and tool execution remain outside this module.
export class RequestContext {
  private source: ContextSource;
  private config: ModelConfig;
  private baselineMessages: string[] = [];
  private baselineTools: string = '';
  private baselineInput: number = 0;
  private lastMessages: string[] = [];
  private lastTools: string = '';
  private prefix: RequestPrefix = new RequestPrefix();

  constructor(source: ContextSource, config: ModelConfig) { this.source = source; this.config = config; }

  inspect(tools: ToolDefinition[]): PreparedRequest {
    const sections = this.sections(tools);
    const entries = this.source.entries();
    const messages = this.assemble(entries, sections, this.source.state.compaction, []);
    return { messages: messages, context: this.describe(messages, tools, sections),
      breakdown: contextBreakdown(messages, tools, sections, entries, this.source.state.compaction !== undefined) };
  }

  recordResponse(response: ModelTurn): void {
    const input = response.usage?.tokens?.input;
    if (response.usage?.status === 'complete' && input !== undefined && Number.isInteger(input) && input > 0) {
      this.baselineMessages = this.lastMessages; this.baselineTools = this.lastTools; this.baselineInput = input;
    } else { this.baselineInput = 0; }
  }

  async prepare(model: ModelSession, tools: ToolDefinition[], cancellation: Cancellation,
    pending: ModelMessage[] = [], manual: boolean = false, recoverOverflow: boolean = false): Promise<PreparedRequest> {
    cancellation.check();
    const settings = contextSettings(this.config);
    if (recoverOverflow && !settings.autoCompact) { throw new ContextOverflowError(); }
    const sections = this.sections(tools);
    const instructions = renderPrompt(sections.filter((section) => !section.dynamic));
    const entries = this.source.entries();
    const assemble = (checkpoint?: CompactionData): ModelMessage[] => this.assemble(entries, sections, checkpoint, pending);
    let messages = assemble(this.source.state.compaction);
    let diagnostics = this.describe(messages, tools, sections);
    if (manual || recoverOverflow || (settings.autoCompact && diagnostics.tokens > diagnostics.inputBudget)) {
      const currentContext = this.contextUpdate([], sections);
      const admission: ModelMessage[] = instructions ? [{ role: 'system', content: instructions }] : [];
      if (currentContext !== undefined) { admission.push({ role: 'user', content: currentContext }); }
      const overhead = estimateContextTokens(admission, tools) + estimateContextTokens(pending);
      // The summary prompt targets about 1000 CJK characters; leave room for its wrapper too.
      let keep = Math.min(settings.keepRecent, Math.max(0, contextInputBudget(settings.window) - overhead - 2200));
      if (recoverOverflow) { keep = Math.min(keep, Math.floor(diagnostics.historyTokens / 2)); }
      const plan = planContextCompaction(entries, this.source.state.compaction, keep, diagnostics.tokens);
      if (!plan) { throw new Error(t('没有可压缩的较早完整轮次。最近一轮和当前输入会保留，请缩小任务或提高上下文窗口。')); }
      this.source.progress(recoverOverflow ? t('模型输入超出窗口，正在压缩后重试一次…') : t('正在压缩较早对话…'));
      const checkpoint = await compactContext(plan, settings, model, cancellation,
        (batch) => this.source.progress(t('正在压缩较早对话 · 第 {0} 批', [batch])),
        { messages: this.summaryPrefix(messages, plan), tools: tools });
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
      diagnostics.compactionReason = recoverOverflow ? 'overflow' : manual ? 'manual' : 'threshold';
      this.source.progress(t('较早对话已压缩，完整记录保留'));
    }
    if (!manual && diagnostics.tokens > diagnostics.inputBudget) {
      throw new Error(t('上下文仍超过预算。请压缩较早对话、缩小输入或提高窗口设置；没有静默丢弃历史。') + ' (' + diagnostics.tokens + '/' + diagnostics.inputBudget + ')');
    }
    this.lastMessages = messages.map((message) => JSON.stringify(message));
    this.lastTools = JSON.stringify(tools);
    diagnostics.prefix = this.prefix.observe(messages, tools, this.lastMessages);
    const change = diagnostics.prefix;
    Diagnostics.log('info', 'context', 'request_prefix', { change: change.change, commonMessages: change.commonMessages,
      sharedCharacters: change.sharedCharacters, systemHash: change.systemHash, toolsHash: change.toolsHash });
    return { messages: messages, context: diagnostics,
      runtimeContext: this.contextUpdate(projectedHistory(entries, this.source.state.compaction), sections),
      breakdown: contextBreakdown(messages, tools, sections, entries, this.source.state.compaction !== undefined) };
  }

  private assemble(entries: ContextEntry[], sections: PromptSection[], checkpoint: CompactionData | undefined, pending: ModelMessage[]): ModelMessage[] {
    const instructions = renderPrompt(sections.filter((section) => !section.dynamic));
    const prefix: ModelMessage[] = instructions ? [{ role: 'system', content: instructions }] : [];
    const history = projectedHistory(entries, checkpoint);
    const update = this.contextUpdate(history, sections);
    return prefix.concat(history, update === undefined ? [] : [{ role: 'user', content: update, runtimeContext: true }], pending);
  }

  private sections(tools: ToolDefinition[]): PromptSection[] {
    return this.source.sections().concat(toolPromptSections(tools).map((section): PromptSection =>
      ({ name: section.name, content: section.content, dynamic: true })));
  }

  private contextUpdate(history: ModelMessage[], sections: PromptSection[]): string | undefined {
    const retained = history.slice().reverse().find((message) => message.runtimeContext);
    const content = renderPrompt(sections.filter((section) => section.dynamic));
    if (!retained && !content) { return undefined; }
    const snapshot = CONTEXT_PREAMBLE + (content || '(none)');
    return retained?.content === snapshot ? undefined : snapshot;
  }

  private summaryPrefix(messages: ModelMessage[], plan: CompactionPlan): ModelMessage[] {
    // The shadowed region is the exact leading projected history, including an existing checkpoint.
    const system = messages.filter((message) => message.role === 'system');
    const entries = this.source.entries();
    const cut = entries.findIndex((entry) => entry.messageId === plan.firstKeptMessageId && entry.step === plan.firstKeptStep);
    return system.concat(projectedHistory(entries.slice(0, cut), this.source.state.compaction));
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
      sections: sizes, toolTokens: estimateTextTokens(JSON.stringify(toolSchemas(tools))),
      historyTokens: estimateContextTokens(messages.filter((message) => message.role !== 'system')) };
  }
}
