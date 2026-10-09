import { validateUiAnswer, uiParts } from '../model/InteractiveUi';
import { t } from '../model/I18n';
import { AgentStep, AgentTurn, MAX_AGENT_STEPS, ModelMessage, ToolCall, ToolDefinition, ToolExecution, ToolExecutionMode,
  interruptTools, stepMessages, toolError, validateToolCalls } from '../model/Agent';
import { Cancellation, RunCancelledError } from './Cancellation';
import { ModelSession } from './providers/Provider';
import { contextInputBudget, estimateContextTokens } from '../model/ConversationContext';
import { PendingInput, validatePendingInput } from '../model/PendingInput';
import { UsageToolActivity } from '../model/Usage';
import { PreparedRequest } from './RequestContext';
import { ModelTurn } from '../model/Agent';
import { ContextOverflowError } from './providers/ProviderErrors';
import { executeToolBatch } from './ToolExecution';

export interface SteeringInput {
  peek: () => PendingInput | undefined;
  consume: (id: string) => void;
}

export interface AgentTools {
  definitions(): ToolDefinition[];
  execute(call: ToolCall, cancellation: Cancellation): Promise<string>;
  beforeFinish?(cancellation: Cancellation): Promise<string | undefined>;
}

export type LoopEventType = 'step_start' | 'text_delta' | 'reasoning_delta' | 'model_end' | 'tool_start' | 'tool_end' | 'step_end';

export interface LoopEvent {
  type: LoopEventType;
  step: number;
  toolCallId?: string;
  delta?: string;
}

export interface LoopObserver {
  toolActivity?: (requestId: string, activity: UsageToolActivity) => void;
  event: (event: LoopEvent) => void;
  checkpoint: () => Promise<void>;
  steering?: SteeringInput;
}

export interface LoopContext {
  toolExecution?: ToolExecutionMode;
  prepareRequest?: (tools: ToolDefinition[], pending: ModelMessage[], cancellation: Cancellation, recoverOverflow?: boolean) => Promise<PreparedRequest>;
  recordResponse?: (response: ModelTurn) => void;
  validateAnswer?: (content: string, cancellation: Cancellation) => Promise<void>;
  model: ModelSession;
  tools: AgentTools;
  messages: ModelMessage[];
  turn: AgentTurn;
  maxSteps: number;
  contextWindow?: number;
}

// No UI, credentials, provider routing or run-lifecycle ownership in the loop.
export async function runAgentLoop(context: LoopContext, cancellation: Cancellation,
  observer: LoopObserver): Promise<void> {
  const limit = context.maxSteps;
  if (!Number.isInteger(limit) || limit < 1 || limit > MAX_AGENT_STEPS) {
    throw new Error(t("执行步数必须在 1 至 {0} 之间。", [MAX_AGENT_STEPS]));
  }
  let messages = context.messages.slice();
  const turn = context.turn;
  const seen = new Set<string>();
  let validationFailures = 0;
  let recoveryPending = false;
  let recoveryAttempted = false;
  try {
    for (let round = 0; round < limit; round++) {
      cancellation.check();
      const pending = observer.steering?.peek();
      if (pending) {
        validatePendingInput(pending);
        if (pending.mode !== 'steer') { throw new Error(t("本轮只能接收追加指令。")); }
      }
      const input: PendingInput | undefined = pending ? { id: pending.id, mode: pending.mode, text: pending.text } : undefined;
      const definitions = context.tools.definitions();
      const prepared = context.prepareRequest ? await context.prepareRequest(definitions, input ? [{ role: 'user', content: input.text }] : [], cancellation, recoveryPending) : undefined;
      recoveryPending = false;
      cancellation.check();
      if (prepared) { messages = prepared.messages; }
      const requestMessages: ModelMessage[] = input ? messages.concat([{ role: 'user', content: input.text }]) : messages;
      if (!prepared && context.contextWindow !== undefined && estimateContextTokens(requestMessages, definitions) > contextInputBudget(context.contextWindow)) {
        throw new Error(t("本轮内容超过上下文预算，执行已停止。已完成的工具结果已保留；请压缩历史、缩小任务或提高窗口设置。"));
      }
      const step: AgentStep = { content: '', tools: [], steering: input, uiValidation: 'pending', context: prepared?.context };
      turn.steps = turn.steps.concat([step]);
      observer.event({ type: 'step_start', step: round });
      if (input) {
        // Record input in the transcript and remove it from the outbox in one checkpoint.
        observer.steering?.consume(input.id);
        await observer.checkpoint();
        cancellation.check();
        if (!prepared) { messages.push({ role: 'user', content: input.text }); }
      }
      let acceptingText = true;
      let response: ModelTurn;
      try {
        response = await context.model.stream(messages, definitions, cancellation, (text: string) => {
          if (!acceptingText || cancellation.cancelled) { return; }
          if (step.content.length === 0 && turn.content.length > 0) { turn.content += '\n\n'; }
          step.content += text;
          turn.content += text;
          observer.event({ type: 'text_delta', step: round, delta: text });
        }, {
          usageStep: round + 1,
          onReasoning: (text: string) => {
            if (!acceptingText || cancellation.cancelled) { return; }
            step.reasoningContent = (step.reasoningContent || '') + text;
            observer.event({ type: 'reasoning_delta', step: round, delta: text });
          } })
          .finally(() => { acceptingText = false; });
      } catch (error) {
        cancellation.check();
        if (!(error instanceof ContextOverflowError)) { throw error as Error; }
        step.requestError = 'context_overflow';
        turn.content = turn.steps.filter((item) => !item.requestError && !item.uiValidation).map((item) => item.content).filter((content) => content.length > 0).join('\n\n');
        observer.event({ type: 'step_end', step: round });
        await observer.checkpoint();
        cancellation.check();
        if (recoveryAttempted || round === limit - 1 || !context.prepareRequest) { throw error; }
        recoveryAttempted = true; recoveryPending = true;
        continue;
      }
      cancellation.check();
      // The provider's final message is authoritative even when it emitted no deltas.
      context.recordResponse?.(response);
      step.content = response.content;
      step.reasoningContent = response.reasoningContent;
      step.anthropicContent = response.anthropicContent;
      step.usage = response.usage;
      turn.content = turn.steps.filter((item) => !item.requestError).map((item: AgentStep) => item.content).filter((content: string) => content.length > 0).join('\n\n');
      validateToolCalls(response.toolCalls);
      for (const call of response.toolCalls) {
        if (seen.has(call.id)) {
          throw new Error(t("模型重复使用了工具调用 ID，已停止本轮执行。"));
        }
        seen.add(call.id);
      }
      step.tools = response.toolCalls.map((call: ToolCall): ToolExecution => {
        return { call: call, status: 'pending', output: '' };
      });
      const hasUi = uiParts(response.content, false).some((part) => part.kind === 'ui');
      if (hasUi) {
        observer.event({ type: 'model_end', step: round });
        try {
          validateUiAnswer(response.content);
          await context.validateAnswer?.(response.content, cancellation);
          cancellation.check();
          step.uiValidation = '';
        } catch (error) {
          cancellation.check();
          if (error instanceof RunCancelledError) { throw error; }
          step.uiValidation = (error as Error).message.slice(0, 8000) || 'UI validation failed without an error message';
          validationFailures++;
        }
      } else { step.uiValidation = ''; }
      turn.content = turn.steps.filter((item) => !item.requestError && !item.uiValidation).map((item) => item.content).filter((content) => content.length > 0).join('\n\n');
      observer.event({ type: 'model_end', step: round });
      if (step.uiValidation) {
        for (const tool of step.tools) { tool.status = 'cancelled'; tool.output = toolError('UI validation failed; this tool was not executed.'); }
      }
      if (hasUi) { await observer.checkpoint(); cancellation.check(); }
      if (step.uiValidation && (validationFailures >= 3 || round === limit - 1)) {
        throw new Error('UI validation failed after repair attempts: ' + step.uiValidation);
      }
      if (step.uiValidation) {
        observer.event({ type: 'step_end', step: round });
        messages.push(...stepMessages(step, false)); continue;
      }
      if (step.tools.length === 0) {
        observer.event({ type: 'step_end', step: round });
        const continuation = await context.tools.beforeFinish?.(cancellation);
        cancellation.check();
        if (continuation) {
          if (round === limit - 1) { throw new Error(t("团队结果已保存，但本轮达到模型调用上限，请继续汇总。")); }
          step.continuation = continuation;
          await observer.checkpoint(); cancellation.check();
          messages.push(...stepMessages(step, false));
          continue;
        }
        if (!observer.steering?.peek()) { return; }
        if (round === limit - 1) { throw new Error(t("本轮已达到模型调用上限，待发送指令已保留。请继续队列。")); }
        messages.push(...stepMessages(step, false));
        continue;
      }
      if (round === limit - 1) {
        for (const tool of step.tools) {
          tool.status = 'cancelled';
          tool.output = toolError(`已达到本轮 ${limit} 次模型调用上限，此工具未执行。`);
        }
        throw new Error(t("已达到本轮 {0} 次模型调用上限，执行已停止。你可以继续发送指令。", [limit]));
      }
      await executeToolBatch(step, round, context.tools, definitions, cancellation, observer, context.toolExecution);
      messages.push(...stepMessages(step, false));
      observer.event({ type: 'step_end', step: round });
    }
  } finally {
    interruptTools(turn.steps);
  }
}
