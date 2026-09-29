import { MAX_REASONING_CONTENT, MAX_TOOL_ARGUMENTS, MAX_TOOL_CALLS, ModelTurn, ToolCall, validateToolCalls } from '../model/Agent';

interface StreamToolFunction {
  name?: string;
  arguments?: string;
}

interface StreamToolCall {
  index: number;
  id?: string;
  type?: string;
  function?: StreamToolFunction;
}

interface StreamDelta {
  content?: string | null;
  reasoning_content?: string | null;
  tool_calls?: StreamToolCall[];
}

interface StreamChoice {
  index: number;
  delta?: StreamDelta;
  finish_reason?: string | null;
}

interface StreamChunk {
  choices?: StreamChoice[];
  error?: Object;
}

// SSE framing survives arbitrary transport chunk boundaries, including CRLF splits.
export class ChatStream {
  private pending: string = '';
  private lines: string[] = [];
  private terminal: string = '';
  private done: boolean = false;
  private content: string = '';
  private reasoningContent: string = '';
  private calls: Map<number, ToolCall> = new Map<number, ToolCall>();
  private frameSize: number = 0;
  private onText: (text: string) => void;

  constructor(onText: (text: string) => void) {
    this.onText = onText;
  }

  push(text: string): void {
    this.pending += text;
    if (this.pending.length > 1024 * 1024) {
      throw new Error('模型服务返回的数据帧过大。');
    }
    let newline = this.pending.indexOf('\n');
    while (newline >= 0) {
      const line = this.pending.slice(0, newline).replace(/\r$/, '');
      this.pending = this.pending.slice(newline + 1);
      if (line.length === 0) {
        this.dispatch();
      } else if (line.startsWith('data:')) {
        this.frameSize += line.length;
        if (this.frameSize > 1024 * 1024) {
          throw new Error('模型服务返回的数据帧过大。');
        }
        this.lines.push(line.slice(5).replace(/^ /, ''));
      }
      newline = this.pending.indexOf('\n');
    }
  }

  finish(): ModelTurn {
    if (!this.done || (this.terminal !== 'stop' && this.terminal !== 'tool_calls') ||
      this.pending.trim().length > 0 || this.lines.length > 0) {
      if (this.terminal === 'length') {
        throw new Error('回答达到模型输出上限，内容不完整。');
      }
      if (this.terminal === 'content_filter') {
        throw new Error('模型服务因内容过滤中止了回答。');
      }
      throw new Error('连接结束，但未收到完整回答的结束标记。');
    }
    const calls: ToolCall[] = [];
    for (let index = 0; index < this.calls.size; index++) {
      const call = this.calls.get(index);
      if (!call) {
        throw new Error('模型返回了不连续的工具调用索引。');
      }
      calls.push(call);
    }
    validateToolCalls(calls);
    if ((this.terminal === 'tool_calls') !== (calls.length > 0)) {
      throw new Error('工具调用与模型结束原因不匹配。');
    }
    if (calls.length === 0 && this.content.trim().length === 0) {
      throw new Error('模型没有返回可显示的文本。');
    }
    return { content: this.content, toolCalls: calls,
      reasoningContent: this.reasoningContent.length > 0 ? this.reasoningContent : undefined };
  }

  private dispatch(): void {
    if (this.lines.length === 0) {
      return;
    }
    const payload = this.lines.join('\n');
    this.lines = [];
    this.frameSize = 0;
    if (this.done) {
      throw new Error('模型在结束标记后继续返回数据。');
    }
    if (payload === '[DONE]') {
      this.done = true;
      return;
    }
    let chunk: StreamChunk;
    try {
      chunk = JSON.parse(payload) as StreamChunk;
    } catch (_) {
      throw new Error('模型返回了无效的流式 JSON。');
    }
    if (!chunk || chunk.error) {
      throw new Error('模型服务在生成过程中返回错误。');
    }
    if (!Array.isArray(chunk.choices)) {
      throw new Error('模型返回的流式数据格式不受支持。');
    }
    for (const choice of chunk.choices) {
      if (!choice || typeof choice.index !== 'number') {
        throw new Error('模型返回了无效的候选回答。');
      }
      if (choice.index !== 0) {
        continue;
      }
      const reasoning = choice.delta?.reasoning_content;
      if (reasoning !== undefined && reasoning !== null && typeof reasoning !== 'string') {
        throw new Error('模型返回了无效的推理内容。');
      }
      if (reasoning) {
        if (this.terminal.length > 0 || this.reasoningContent.length + reasoning.length > MAX_REASONING_CONTENT) {
          throw new Error('模型返回的推理内容已结束或超出长度限制。');
        }
        // Protocol context for subsequent tool rounds; never mix it into the visible final answer.
        this.reasoningContent += reasoning;
      }
      const content = choice.delta?.content;
      if (content !== undefined && content !== null && typeof content !== 'string') {
        throw new Error('模型返回了非文本内容。');
      }
      if (content) {
        if (this.terminal.length > 0) {
          throw new Error('模型在完成回答后继续返回文本。');
        }
        this.content += content;
        this.onText(content);
      }
      const calls = choice.delta?.tool_calls;
      if (calls !== undefined && calls !== null) {
        if (!Array.isArray(calls) || this.terminal.length > 0) {
          throw new Error('模型返回了无效或已经结束的工具调用。');
        }
        for (const delta of calls) {
          this.mergeTool(delta);
        }
      }
      if (choice.finish_reason) {
        if (this.terminal.length > 0 || typeof choice.finish_reason !== 'string') {
          throw new Error('模型重复返回了结束原因。');
        }
        this.terminal = choice.finish_reason;
      }
    }
  }

  private mergeTool(delta: StreamToolCall): void {
    if (!delta || !Number.isInteger(delta.index) || delta.index < 0 || delta.index >= MAX_TOOL_CALLS ||
      (delta.id !== undefined && typeof delta.id !== 'string') ||
      (delta.type !== undefined && delta.type !== 'function') ||
      (delta.function?.name !== undefined && typeof delta.function.name !== 'string') ||
      (delta.function?.arguments !== undefined && typeof delta.function.arguments !== 'string')) {
      throw new Error('模型返回了无效的工具调用片段。');
    }
    let call = this.calls.get(delta.index);
    if (!call) {
      call = { id: '', type: '', function: { name: '', arguments: '' } };
      this.calls.set(delta.index, call);
    }
    call.id += delta.id || '';
    call.type = delta.type || call.type;
    call.function.name += delta.function?.name || '';
    call.function.arguments += delta.function?.arguments || '';
    if (call.id.length > 128 || call.function.name.length > 64 || call.function.arguments.length > MAX_TOOL_ARGUMENTS) {
      throw new Error('模型返回的工具调用过大。');
    }
  }
}
