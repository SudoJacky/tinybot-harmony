import { t } from '../model/I18n';
import { AgentStep, AgentTurn, MAX_AGENT_STEPS, ModelMessage, ToolCall, ToolDefinition, ToolExecution,
  interruptTools, stepMessages, toolError, validateToolCalls } from '../model/Agent';
import { Cancellation, RunCancelledError } from './Cancellation';
import { ModelSession } from './providers/Provider';
import { OUTPUT_RESERVE, estimateContextTokens } from '../model/ConversationContext';
import { PendingInput, validatePendingInput } from '../model/PendingInput';

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
  event: (event: LoopEvent) => void;
  checkpoint: () => Promise<void>;
  steering?: SteeringInput;
}

export interface LoopContext {
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
  const messages = context.messages.slice();
  const definitions = context.tools.definitions();
  const turn = context.turn;
  const seen = new Set<string>();
  try {
    for (let round = 0; round < limit; round++) {
      cancellation.check();
      const pending = observer.steering?.peek();
      if (pending) {
        validatePendingInput(pending);
        if (pending.mode !== 'steer') { throw new Error(t("本轮只能接收追加指令。")); }
      }
      const input: PendingInput | undefined = pending ? { id: pending.id, mode: pending.mode, text: pending.text } : undefined;
      const requestMessages: ModelMessage[] = input ? messages.concat([{ role: 'user', content: input.text }]) : messages;
      if (context.contextWindow !== undefined && estimateContextTokens(requestMessages, definitions) > context.contextWindow - OUTPUT_RESERVE) {
        throw new Error(t("本轮内容超过上下文预算，执行已停止。已完成的工具结果已保留；请压缩历史、缩小任务或提高窗口设置。"));
      }
      const step: AgentStep = { content: '', tools: [], steering: input };
      turn.steps = turn.steps.concat([step]);
      observer.event({ type: 'step_start', step: round });
      if (input) {
        // Record input in the transcript and remove it from the outbox in one checkpoint.
        observer.steering?.consume(input.id);
        await observer.checkpoint();
        cancellation.check();
        messages.push({ role: 'user', content: input.text });
      }
      let acceptingText = true;
      const response = await context.model.stream(messages, definitions, cancellation, (text: string) => {
        if (!acceptingText || cancellation.cancelled) {
          return;
        }
        if (step.content.length === 0 && turn.content.length > 0) {
          turn.content += '\n\n';
        }
        step.content += text;
        turn.content += text;
        observer.event({ type: 'text_delta', step: round, delta: text });
      }, { maxOutputTokens: context.contextWindow === undefined ? undefined : OUTPUT_RESERVE,
        onReasoning: (text: string) => {
          if (!acceptingText || cancellation.cancelled) { return; }
          step.reasoningContent = (step.reasoningContent || '') + text;
          observer.event({ type: 'reasoning_delta', step: round, delta: text });
        } })
        .finally(() => { acceptingText = false; });
      cancellation.check();
      // The provider's final message is authoritative even when it emitted no deltas.
      step.content = response.content;
      step.reasoningContent = response.reasoningContent;
      step.usage = response.usage;
      turn.content = turn.steps.map((item: AgentStep) => item.content).filter((content: string) => content.length > 0).join('\n\n');
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
      observer.event({ type: 'model_end', step: round });
      if (step.tools.length === 0) {
        observer.event({ type: 'step_end', step: round });
        const continuation = await context.tools.beforeFinish?.(cancellation);
        cancellation.check();
        if (continuation) {
          if (round === limit - 1) { throw new Error(t("团队结果已保存，但本轮达到模型调用上限，请继续汇总。")); }
          messages.push(...stepMessages(step, false), { role: 'user', content: continuation });
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
      // Tools run sequentially, including multiple calls in one provider response.
      for (const tool of step.tools) {
        cancellation.check();
        tool.status = 'running';
        observer.event({ type: 'tool_start', step: round, toolCallId: tool.call.id });
        // Never execute a tool unless its intent has been durably recorded first.
        await observer.checkpoint();
        cancellation.check();
        try {
          tool.output = await context.tools.execute(tool.call, cancellation);
          tool.status = 'complete';
        } catch (error) {
          tool.output = toolError((error as Error).message);
          tool.status = error instanceof RunCancelledError ? 'cancelled' : 'failed';
        }
        observer.event({ type: 'tool_end', step: round, toolCallId: tool.call.id });
        // Preserve a committed write receipt even if stop was pressed during that write.
        await observer.checkpoint();
        cancellation.check();
      }
      messages.push(...stepMessages(step, false));
      observer.event({ type: 'step_end', step: round });
    }
  } finally {
    interruptTools(turn.steps);
  }
}
