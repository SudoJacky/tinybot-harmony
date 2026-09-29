export const MAX_TOOL_CALLS: number = 8;
export const MAX_TOOL_ARGUMENTS: number = 96 * 1024;
export const MAX_AGENT_STEPS: number = 8;
export const MAX_REASONING_CONTENT: number = 1024 * 1024;

export interface ToolFunction {
  name: string;
  arguments: string;
}

export interface ToolCall {
  id: string;
  type: string;
  function: ToolFunction;
}

export interface ToolProperty {
  type: string;
  description: string;
}

export interface ToolParameters {
  type: string;
  properties: Record<string, ToolProperty>;
  required: string[];
  additionalProperties: boolean;
}

export interface ToolDefinitionFunction {
  name: string;
  description: string;
  parameters: ToolParameters;
}

export interface ToolDefinition {
  type: string;
  function: ToolDefinitionFunction;
}

export interface ModelMessage {
  role: string;
  content: string;
  toolCalls?: ToolCall[];
  toolCallId?: string;
  reasoningContent?: string;
}

export interface ModelTurn {
  content: string;
  toolCalls: ToolCall[];
  reasoningContent?: string;
}

export interface ToolExecution {
  call: ToolCall;
  status: string;
  output: string;
}

export interface AgentStep {
  content: string;
  tools: ToolExecution[];
  reasoningContent?: string;
}

export interface AgentTurn {
  content: string;
  steps: AgentStep[];
}

export function validateToolCalls(calls: ToolCall[]): void {
  if (!Array.isArray(calls) || calls.length > MAX_TOOL_CALLS) {
    throw new Error('单步工具调用数量超出限制。');
  }
  const ids = new Set<string>();
  for (const call of calls) {
    if (!call || typeof call.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(call.id) ||
      ids.has(call.id) || call.type !== 'function' || !call.function ||
      typeof call.function.name !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(call.function.name) ||
      typeof call.function.arguments !== 'string' || call.function.arguments.length > MAX_TOOL_ARGUMENTS) {
      throw new Error('模型返回了无效或重复的工具调用。');
    }
    ids.add(call.id);
  }
}

export function toolError(message: string): string {
  return JSON.stringify({ error: message });
}

export function stepMessages(step: AgentStep): ModelMessage[] {
  if (step.tools.length === 0) {
    return [{ role: 'assistant', content: step.content, reasoningContent: step.reasoningContent }];
  }
  const result: ModelMessage[] = [{
    role: 'assistant', content: step.content, reasoningContent: step.reasoningContent,
    toolCalls: step.tools.map((tool: ToolExecution) => tool.call)
  }];
  for (const tool of step.tools) {
    result.push({ role: 'tool', toolCallId: tool.call.id, content: tool.output });
  }
  return result;
}

// Pending calls were never started; running calls may already have changed files.
export function interruptTools(steps: AgentStep[]): void {
  for (const step of steps) {
    for (const tool of step.tools) {
      if (tool.status === 'pending') {
        tool.status = 'cancelled';
        tool.output = toolError('本轮已中断，此工具未执行。');
      } else if (tool.status === 'running') {
        tool.status = 'interrupted';
        tool.output = toolError('执行中断，结果未知；再次写入前请先检查工作区中的文件。');
      }
    }
  }
}

export function validateSteps(steps: AgentStep[]): void {
  if (!Array.isArray(steps) || steps.length > MAX_AGENT_STEPS) {
    throw new Error('本地工具记录损坏，原文件已保留。');
  }
  const ids = new Set<string>();
  for (const step of steps) {
    if (!step || typeof step.content !== 'string' || !Array.isArray(step.tools) ||
      (step.reasoningContent !== undefined && (typeof step.reasoningContent !== 'string' ||
        step.reasoningContent.length > MAX_REASONING_CONTENT))) {
      throw new Error('本地工具记录损坏，原文件已保留。');
    }
    validateToolCalls(step.tools.map((tool: ToolExecution) => tool?.call));
    for (const tool of step.tools) {
      if (ids.has(tool.call.id) || typeof tool.output !== 'string' ||
        ['pending', 'running', 'complete', 'failed', 'cancelled', 'interrupted'].indexOf(tool.status) < 0) {
        throw new Error('本地工具记录损坏，原文件已保留。');
      }
      ids.add(tool.call.id);
    }
  }
}
