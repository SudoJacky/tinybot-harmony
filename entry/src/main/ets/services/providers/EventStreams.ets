import { MAX_TOOL_ARGUMENTS, MAX_TOOL_CALLS, ModelTurn, ToolCall, validateToolCalls } from '../../model/Agent';
import { AnthropicBlock } from './WireProtocols';

export interface ModelStream {
  push(text: string): void;
  finish(): ModelTurn;
}

function parseEvent(payload: string): Object {
  try { return JSON.parse(payload) as Object; }
  catch (_) { throw new Error('模型返回了无效的流式 JSON。'); }
}

// Shared framing only; completion semantics belong to each protocol.
class EventFrames {
  private pending: string = '';
  private lines: string[] = [];
  private frameSize: number = 0;
  private receive: (payload: string) => void;
  constructor(receive: (payload: string) => void) { this.receive = receive; }
  push(text: string): void {
    this.pending += text;
    if (this.pending.length > 1024 * 1024) { throw new Error('模型数据帧过大。'); }
    let newline = this.pending.indexOf('\n');
    while (newline >= 0) {
      const line = this.pending.slice(0, newline).replace(/\r$/, '');
      this.pending = this.pending.slice(newline + 1);
      if (line.length === 0 && this.lines.length > 0) {
        const payload = this.lines.join('\n');
        this.lines = []; this.frameSize = 0; this.receive(payload);
      } else if (line.startsWith('data:')) {
        this.frameSize += line.length;
        if (this.frameSize > 1024 * 1024) { throw new Error('模型数据帧过大。'); }
        this.lines.push(line.slice(5).replace(/^ /, ''));
      }
      newline = this.pending.indexOf('\n');
    }
  }
  finish(): void {
    if (this.pending.trim().length > 0 || this.lines.length > 0) { throw new Error('流式数据帧不完整。'); }
  }
}

interface ResponseContent { type: string; text?: string; }
interface ResponseItem {
  type: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  content?: ResponseContent[];
}
interface ResponseData { status: string; output: ResponseItem[]; }
interface ResponseEvent { type: string; delta?: string; response?: ResponseData; }

export class ResponsesStream implements ModelStream {
  private frames: EventFrames;
  private content: string = '';
  private result?: ModelTurn;
  private onText: (text: string) => void;
  constructor(onText: (text: string) => void) {
    this.onText = onText;
    this.frames = new EventFrames((payload: string) => this.event(payload));
  }
  push(text: string): void { this.frames.push(text); }
  finish(): ModelTurn {
    this.frames.finish();
    if (!this.result) { throw new Error('Responses 连接结束，但未收到完整回答的结束标记。'); }
    return this.result;
  }
  private event(payload: string): void {
    if (this.result) { throw new Error('Responses 在结束后继续返回数据。'); }
    const event = parseEvent(payload) as ResponseEvent;
    if (!event || typeof event.type !== 'string') { throw new Error('Responses 流式事件无效。'); }
    if (event.type === 'error' || event.type === 'response.failed' || event.type === 'response.incomplete' ||
      event.type === 'response.refusal.delta') { throw new Error('Responses 模型服务返回错误或不完整回答。'); }
    if (event.type === 'response.output_text.delta') {
      if (typeof event.delta !== 'string') { throw new Error('Responses 文本片段无效。'); }
      this.content += event.delta;
      this.onText(event.delta);
    } else if (event.type === 'response.completed') {
      const response = event.response;
      if (!response || response.status !== 'completed' || !Array.isArray(response.output)) {
        throw new Error('Responses 结束状态无效。');
      }
      const calls: ToolCall[] = [];
      let text = '';
      for (const item of response.output) {
        if (item.type === 'function_call') {
          calls.push({ id: item.call_id || '', type: 'function', function: { name: item.name || '', arguments: item.arguments || '' } });
        } else if (item.type === 'message') {
          if (!Array.isArray(item.content)) { throw new Error('Responses 输出消息无效。'); }
          for (const part of item.content) {
            if (part.type !== 'output_text' || typeof part.text !== 'string') { throw new Error('Responses 返回了不支持的输出类型。'); }
            text += part.text;
          }
        } else if (item.type !== 'reasoning') { throw new Error('Responses 返回了不支持的输出类型。'); }
      }
      validateToolCalls(calls);
      if (text !== this.content) { throw new Error('Responses 最终文本与流式片段不一致。'); }
      if (calls.length === 0 && text.trim().length === 0) { throw new Error('模型没有返回可显示的文本。'); }
      this.result = { content: text, toolCalls: calls };
    }
  }
}

interface AnthropicDelta { type?: string; text?: string; partial_json?: string; stop_reason?: string; }
interface AnthropicEvent { type: string; index?: number; content_block?: AnthropicBlock; delta?: AnthropicDelta; }

export class AnthropicStream implements ModelStream {
  private frames: EventFrames;
  private onText: (text: string) => void;
  private content: string = '';
  private started: boolean = false;
  private done: boolean = false;
  private reason: string = '';
  private blocks: Map<number, string> = new Map<number, string>();
  private closed: Set<number> = new Set<number>();
  private fragments: Set<number> = new Set<number>();
  private calls: Map<number, ToolCall> = new Map<number, ToolCall>();
  constructor(onText: (text: string) => void) {
    this.onText = onText;
    this.frames = new EventFrames((payload: string) => this.event(payload));
  }
  push(text: string): void { this.frames.push(text); }
  finish(): ModelTurn {
    this.frames.finish();
    if (!this.done || !this.started || !['end_turn', 'stop_sequence', 'tool_use'].includes(this.reason) ||
      this.closed.size !== this.blocks.size) { throw new Error('Anthropic 连接结束，但未收到完整回答的结束标记。'); }
    const calls = Array.from(this.calls.values());
    validateToolCalls(calls);
    if ((this.reason === 'tool_use') !== (calls.length > 0)) { throw new Error('Anthropic 工具调用与结束原因不匹配。'); }
    if (calls.length === 0 && this.content.trim().length === 0) { throw new Error('模型没有返回可显示的文本。'); }
    return { content: this.content, toolCalls: calls };
  }
  private append(text: string): void { this.content += text; this.onText(text); }
  private event(payload: string): void {
    if (this.done) { throw new Error('Anthropic 在结束后继续返回数据。'); }
    const event = parseEvent(payload) as AnthropicEvent;
    if (!event || typeof event.type !== 'string') { throw new Error('Anthropic 流式事件无效。'); }
    if (event.type === 'error') { throw new Error('Anthropic 模型服务在生成过程中返回错误。'); }
    if (event.type === 'ping') { return; }
    if (event.type === 'message_start') {
      if (this.started) { throw new Error('Anthropic 重复开始消息。'); }
      this.started = true; return;
    }
    if (!this.started) { throw new Error('Anthropic 消息尚未开始。'); }
    if (event.type === 'message_delta') {
      if (event.delta?.stop_reason) {
        if (this.reason.length > 0) { throw new Error('Anthropic 重复结束消息。'); }
        this.reason = event.delta.stop_reason;
        if (!['end_turn', 'stop_sequence', 'tool_use'].includes(this.reason)) {
          throw new Error('Anthropic 回答达到输出上限、被拒绝或执行未完成。');
        }
      }
      return;
    }
    if (event.type === 'message_stop') { this.done = true; return; }
    if (!event.type.startsWith('content_block_')) { return; }
    const index = event.index;
    if (index === undefined || !Number.isInteger(index) || index < 0 || index > 128 || this.reason.length > 0) {
      throw new Error('Anthropic 内容块索引或状态无效。');
    }
    if (event.type === 'content_block_start') {
      const block = event.content_block;
      if (!block || this.blocks.has(index) || !['text', 'tool_use'].includes(block.type)) { throw new Error('Anthropic 内容块无效或不支持。'); }
      this.blocks.set(index, block.type);
      if (block.type === 'text') {
        if (typeof block.text !== 'string') { throw new Error('Anthropic 文本无效。'); }
        if (block.text) { this.append(block.text); }
      } else {
        if (this.calls.size >= MAX_TOOL_CALLS || !block.input || typeof block.input !== 'object' || Array.isArray(block.input)) {
          throw new Error('Anthropic 工具输入无效。');
        }
        this.calls.set(index, { id: block.id || '', type: 'function', function: { name: block.name || '', arguments: JSON.stringify(block.input) } });
      }
    } else {
      if (!this.blocks.has(index) || this.closed.has(index)) { throw new Error('Anthropic 内容块尚未开始或已经结束。'); }
      if (event.type === 'content_block_stop') { this.closed.add(index); return; }
      if (event.type !== 'content_block_delta') { throw new Error('Anthropic 内容块事件不支持。'); }
      const delta = event.delta;
      if (this.blocks.get(index) === 'text' && delta?.type === 'text_delta' && typeof delta.text === 'string') {
        this.append(delta.text);
      } else if (this.blocks.get(index) === 'tool_use' && delta?.type === 'input_json_delta' && typeof delta.partial_json === 'string') {
        const call = this.calls.get(index);
        if (!call) { throw new Error('Anthropic 工具调用不存在。'); }
        if (!this.fragments.has(index)) {
          if (call.function.arguments !== '{}') { throw new Error('Anthropic 工具输入混合了完整值与增量值。'); }
          call.function.arguments = ''; this.fragments.add(index);
        }
        call.function.arguments += delta.partial_json;
        if (call.function.arguments.length > MAX_TOOL_ARGUMENTS) { throw new Error('Anthropic 工具输入过大。'); }
      } else { throw new Error('Anthropic 内容片段无效或不支持。'); }
    }
  }
}
