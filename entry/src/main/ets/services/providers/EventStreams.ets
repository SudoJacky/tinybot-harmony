import { t } from '../../model/I18n';
import { AnthropicContentBlock, validateAnthropicContent } from '../../model/AnthropicContent';
import { MAX_REASONING_CONTENT, MAX_TOOL_ARGUMENTS, MAX_TOOL_CALLS, ModelTurn, ToolCall, validateToolCalls } from '../../model/Agent';
import { AnthropicBlock } from './WireProtocols';

export interface ModelStream {
  push(text: string): void;
  finish(): ModelTurn;
}

function parseEvent(payload: string): Object {
  try { return JSON.parse(payload) as Object; }
  catch (_) { throw new Error(t("模型返回了无效的流式 JSON。")); }
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
    if (this.pending.length > 1024 * 1024) { throw new Error(t("模型数据帧过大。")); }
    let newline = this.pending.indexOf('\n');
    while (newline >= 0) {
      const line = this.pending.slice(0, newline).replace(/\r$/, '');
      this.pending = this.pending.slice(newline + 1);
      if (line.length === 0 && this.lines.length > 0) {
        const payload = this.lines.join('\n');
        this.lines = []; this.frameSize = 0; this.receive(payload);
      } else if (line.startsWith('data:')) {
        this.frameSize += line.length;
        if (this.frameSize > 1024 * 1024) { throw new Error(t("模型数据帧过大。")); }
        this.lines.push(line.slice(5).replace(/^ /, ''));
      }
      newline = this.pending.indexOf('\n');
    }
  }
  finish(): void {
    if (this.pending.trim().length > 0 || this.lines.length > 0) { throw new Error(t("流式数据帧不完整。")); }
  }
}

interface ResponseContent { type: string; text?: string; }
interface ResponseItem {
  type: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  content?: ResponseContent[];
  summary?: ResponseContent[];
}
interface ResponseError { code?: string; }
interface ResponseIncomplete { reason?: string; }
interface ResponseData {
  status: string;
  output: ResponseItem[];
  error?: ResponseError;
  incomplete_details?: ResponseIncomplete;
}
interface ResponseEvent {
  type: string; delta?: string; text?: string; response?: ResponseData; code?: string; error?: ResponseError;
  output_index?: number; summary_index?: number; content_index?: number;
}

function reasoningPartKey(output: number = 0, part: number = 0, summary: boolean): string {
  if (!Number.isSafeInteger(output) || output < 0 || !Number.isSafeInteger(part) || part < 0) {
    throw new Error(t('Responses 推理文本片段无效。'));
  }
  return output + (summary ? ':summary:' : ':content:') + part;
}

function responsesFailure(event: ResponseEvent): Error {
  const reason = event.response?.incomplete_details?.reason;
  if (event.type === 'response.incomplete' && reason === 'max_output_tokens') {
    return new Error(t('Responses 回答达到输出上限（包含思考 token），尚未完成。请提高输出上限或降低思考强度。'));
  }
  // Keep diagnostic identifiers, without copying upstream messages that may echo request data.
  const detail = event.type === 'response.incomplete' ? reason : event.response?.error?.code || event.error?.code || event.code;
  const identifier = typeof detail === 'string' && /^[a-zA-Z0-9_.-]{1,80}$/.test(detail) ? ': ' + detail : '';
  return new Error(t('Responses 模型服务返回错误或不完整回答。') + ' [' + event.type + identifier + ']');
}

export class ResponsesStream implements ModelStream {
  private frames: EventFrames;
  private content: string = '';
  private result?: ModelTurn;
  private reasoning: string = '';
  private reasoningParts: Map<string, string> = new Map<string, string>();
  private closedReasoningParts: Set<string> = new Set<string>();
  private lastReasoningPart: string = '';
  private onText: (text: string) => void;
  private onReasoning?: (text: string) => void;
  constructor(onText: (text: string) => void, onReasoning?: (text: string) => void) {
    this.onText = onText;
    this.onReasoning = onReasoning;
    this.frames = new EventFrames((payload: string) => this.event(payload));
  }
  push(text: string): void { this.frames.push(text); }
  finish(): ModelTurn {
    this.frames.finish();
    if (!this.result) { throw new Error(t("Responses 连接结束，但未收到完整回答的结束标记。")); }
    return this.result;
  }

  // done/completed contain full text, not another delta. Reconcile per output/part
  // so repeated snapshots do not duplicate thinking or merge distinct paragraphs.
  private reasoningPart(key: string, text: string | undefined, complete: boolean): void {
    if (typeof text !== 'string' || (!complete && this.closedReasoningParts.has(key))) {
      throw new Error(t('Responses 推理文本片段无效。'));
    }
    const previous = this.reasoningParts.get(key) || '';
    if (complete && !text.startsWith(previous)) {
      throw new Error(t('Responses 最终推理文本与流式片段不一致。'));
    }
    const delta = complete ? text.slice(previous.length) : text;
    const addition = delta && this.reasoning && this.lastReasoningPart !== key ? '\n\n' + delta : delta;
    if (this.reasoning.length + addition.length > MAX_REASONING_CONTENT) {
      throw new Error(t('模型返回的推理内容已结束或超出长度限制。'));
    }
    this.reasoningParts.set(key, complete ? text : previous + text);
    if (complete) { this.closedReasoningParts.add(key); }
    if (addition) {
      this.reasoning += addition; this.lastReasoningPart = key;
      this.onReasoning?.(addition);
    }
  }

  private completeReasoning(item: ResponseItem, index: number): void {
    // Only text is displayable. Opaque encrypted_content is never interpreted as text.
    for (const summary of [true, false]) {
      const parts = summary ? item.summary : item.content;
      if (parts === undefined) { continue; }
      if (!Array.isArray(parts)) { throw new Error(t('Responses 推理文本片段无效。')); }
      for (let part = 0; part < parts.length; part++) {
        if (!parts[part] || parts[part].type !== (summary ? 'summary_text' : 'reasoning_text')) {
          throw new Error(t('Responses 推理文本片段无效。'));
        }
        this.reasoningPart(reasoningPartKey(index, part, summary), parts[part].text, true);
      }
    }
  }

  private event(payload: string): void {
    if (this.result) { throw new Error(t("Responses 在结束后继续返回数据。")); }
    const event = parseEvent(payload) as ResponseEvent;
    if (!event || typeof event.type !== 'string') { throw new Error(t("Responses 流式事件无效。")); }
    if (event.type === 'error' || event.type === 'response.failed' || event.type === 'response.incomplete' ||
      event.type === 'response.refusal.delta') { throw responsesFailure(event); }
    if (['response.reasoning_summary_text.delta', 'response.reasoning_summary_text.done',
      'response.reasoning_text.delta', 'response.reasoning_text.done'].includes(event.type)) {
      const summary = event.type.startsWith('response.reasoning_summary_text.');
      const complete = event.type.endsWith('.done');
      this.reasoningPart(reasoningPartKey(event.output_index, summary ? event.summary_index : event.content_index, summary),
        complete ? event.text : event.delta, complete);
    } else if (event.type === 'response.output_text.delta') {
      if (typeof event.delta !== 'string') { throw new Error(t("Responses 文本片段无效。")); }
      this.content += event.delta;
      this.onText(event.delta);
    } else if (event.type === 'response.completed') {
      const response = event.response;
      if (!response || response.status !== 'completed' || !Array.isArray(response.output)) {
        throw new Error(t("Responses 结束状态无效。"));
      }
      const calls: ToolCall[] = [];
      let text = '';
      for (let index = 0; index < response.output.length; index++) {
        const item = response.output[index];
        if (item.type === 'function_call') {
          calls.push({ id: item.call_id || '', type: 'function', function: { name: item.name || '', arguments: item.arguments || '' } });
        } else if (item.type === 'message') {
          if (!Array.isArray(item.content)) { throw new Error(t("Responses 输出消息无效。")); }
          for (const part of item.content) {
            if (part.type !== 'output_text' || typeof part.text !== 'string') { throw new Error(t("Responses 返回了不支持的输出类型。")); }
            text += part.text;
          }
        } else if (item.type === 'reasoning') { this.completeReasoning(item, index); }
        else { throw new Error(t("Responses 返回了不支持的输出类型。")); }
      }
      validateToolCalls(calls);
      if (text !== this.content) { throw new Error(t("Responses 最终文本与流式片段不一致。")); }
      if (calls.length === 0 && text.trim().length === 0) { throw new Error(t("模型没有返回可显示的文本。")); }
      this.result = { content: text, toolCalls: calls, reasoningContent: this.reasoning || undefined };
    }
  }
}

interface AnthropicDelta { type?: string; text?: string; thinking?: string; signature?: string; partial_json?: string; stop_reason?: string; }
interface AnthropicEvent { type: string; index?: number; content_block?: AnthropicBlock; delta?: AnthropicDelta; }

export class AnthropicStream implements ModelStream {
  private preserved: Map<number, AnthropicContentBlock> = new Map<number, AnthropicContentBlock>();
  private reasoning: string = '';
  private thinkingSize: number = 0;
  private onReasoning?: (text: string) => void;
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
  constructor(onText: (text: string) => void, onReasoning?: (text: string) => void) {
    this.onText = onText;
    this.onReasoning = onReasoning;
    this.frames = new EventFrames((payload: string) => this.event(payload));
  }
  push(text: string): void { this.frames.push(text); }
  finish(): ModelTurn {
    this.frames.finish();
    if (!this.done || !this.started || !['end_turn', 'stop_sequence', 'tool_use'].includes(this.reason) ||
      this.closed.size !== this.blocks.size) { throw new Error(t("Anthropic 连接结束，但未收到完整回答的结束标记。")); }
    const calls = Array.from(this.calls.values());
    validateToolCalls(calls);
    if ((this.reason === 'tool_use') !== (calls.length > 0)) { throw new Error(t("Anthropic 工具调用与结束原因不匹配。")); }
    if (calls.length === 0 && this.content.trim().length === 0) { throw new Error(t("模型没有返回可显示的文本。")); }
    const preserved: AnthropicContentBlock[] = [];
    for (const index of Array.from(this.preserved.keys()).sort((a: number, b: number) => a - b)) {
      const block = this.preserved.get(index)!;
      const call = this.calls.get(index);
      if (call) block.input = JSON.parse(call.function.arguments) as Object;
      preserved.push(block);
    }
    validateAnthropicContent(preserved);
    return { content: this.content, toolCalls: calls, reasoningContent: this.reasoning || undefined, anthropicContent: preserved };
  }
  private append(text: string): void { this.content += text; this.onText(text); }
  private appendThinking(text: string): void {
    this.thinkingSize += text.length;
    if (this.thinkingSize > 1024 * 1024) throw new Error(t('Anthropic 思考记录无效或过大。'));
    this.reasoning += text;
    if (text) this.onReasoning?.(text);
  }
  private event(payload: string): void {
    if (this.done) { throw new Error(t("Anthropic 在结束后继续返回数据。")); }
    const event = parseEvent(payload) as AnthropicEvent;
    if (!event || typeof event.type !== 'string') { throw new Error(t("Anthropic 流式事件无效。")); }
    if (event.type === 'error') { throw new Error(t("Anthropic 模型服务在生成过程中返回错误。")); }
    if (event.type === 'ping') { return; }
    if (event.type === 'message_start') {
      if (this.started) { throw new Error(t("Anthropic 重复开始消息。")); }
      this.started = true; return;
    }
    if (!this.started) { throw new Error(t("Anthropic 消息尚未开始。")); }
    if (event.type === 'message_delta') {
      if (event.delta?.stop_reason) {
        if (this.reason.length > 0) { throw new Error(t("Anthropic 重复结束消息。")); }
        this.reason = event.delta.stop_reason;
        if (!['end_turn', 'stop_sequence', 'tool_use'].includes(this.reason)) {
          throw new Error(t("Anthropic 回答达到输出上限、被拒绝或执行未完成。"));
        }
      }
      return;
    }
    if (event.type === 'message_stop') { this.done = true; return; }
    if (!event.type.startsWith('content_block_')) { return; }
    const index = event.index;
    if (index === undefined || !Number.isInteger(index) || index < 0 || index > 128 || this.reason.length > 0) {
      throw new Error(t("Anthropic 内容块索引或状态无效。"));
    }
    if (event.type === 'content_block_start') {
      const block = event.content_block;
      if (!block || this.blocks.has(index) || !['text', 'tool_use', 'thinking', 'redacted_thinking'].includes(block.type)) { throw new Error(t("Anthropic 内容块无效或不支持。")); }
      this.blocks.set(index, block.type);
      this.preserved.set(index, JSON.parse(JSON.stringify(block)) as AnthropicContentBlock);
      if (block.type === 'text') {
        if (typeof block.text !== 'string') { throw new Error(t("Anthropic 文本无效。")); }
        if (block.text) { this.append(block.text); }
      } else if (block.type === 'thinking') {
        if (typeof block.thinking !== 'string' || (block.signature !== undefined && typeof block.signature !== 'string')) {
          throw new Error(t('Anthropic 思考记录无效或过大。'));
        }
        this.appendThinking(block.thinking);
      } else if (block.type === 'redacted_thinking') {
        if (typeof block.data !== 'string' || !block.data) throw new Error(t('Anthropic 思考记录无效或过大。'));
        this.thinkingSize += block.data.length;
        if (this.thinkingSize > 1024 * 1024) throw new Error(t('Anthropic 思考记录无效或过大。'));
      } else {
        if (this.calls.size >= MAX_TOOL_CALLS || !block.input || typeof block.input !== 'object' || Array.isArray(block.input)) {
          throw new Error(t("Anthropic 工具输入无效。"));
        }
        this.calls.set(index, { id: block.id || '', type: 'function', function: { name: block.name || '', arguments: JSON.stringify(block.input) } });
      }
    } else {
      if (!this.blocks.has(index) || this.closed.has(index)) { throw new Error(t("Anthropic 内容块尚未开始或已经结束。")); }
      if (event.type === 'content_block_stop') { this.closed.add(index); return; }
      if (event.type !== 'content_block_delta') { throw new Error(t("Anthropic 内容块事件不支持。")); }
      const delta = event.delta;
      const preserved = this.preserved.get(index)!;
      if (this.blocks.get(index) === 'text' && delta?.type === 'text_delta' && typeof delta.text === 'string') {
        this.append(delta.text);
        preserved.text = (preserved.text || '') + delta.text;
      } else if (preserved.type === 'thinking' && delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') {
        this.appendThinking(delta.thinking);
        preserved.thinking = (preserved.thinking || '') + delta.thinking;
      } else if (preserved.type === 'thinking' && delta?.type === 'signature_delta' && typeof delta.signature === 'string') {
        this.thinkingSize += delta.signature.length;
        if (this.thinkingSize > 1024 * 1024) throw new Error(t('Anthropic 思考记录无效或过大。'));
        preserved.signature = (preserved.signature || '') + delta.signature;
      } else if (this.blocks.get(index) === 'tool_use' && delta?.type === 'input_json_delta' && typeof delta.partial_json === 'string') {
        const call = this.calls.get(index);
        if (!call) { throw new Error(t("Anthropic 工具调用不存在。")); }
        if (!this.fragments.has(index)) {
          if (call.function.arguments !== '{}') { throw new Error(t("Anthropic 工具输入混合了完整值与增量值。")); }
          call.function.arguments = ''; this.fragments.add(index);
        }
        call.function.arguments += delta.partial_json;
        if (call.function.arguments.length > MAX_TOOL_ARGUMENTS) { throw new Error(t("Anthropic 工具输入过大。")); }
      } else { throw new Error(t("Anthropic 内容片段无效或不支持。")); }
    }
  }
}
