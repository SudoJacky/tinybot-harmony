import { util } from '@kit.ArkTS';
import { t } from '../../model/I18n';
import { MAX_REASONING_CONTENT, MAX_TOOL_CALLS, ModelTurn, ToolCall, validateToolCalls } from '../../model/Agent';
import { GeminiPart, validateGeminiContent } from '../../model/GeminiContent';
import { EventFrames, ModelStream } from './EventStreams';

interface GeminiCandidate { index?: number; content?: GeminiOutput; finishReason?: string; }
interface GeminiOutput { role?: string; parts: GeminiPart[]; }
interface GeminiFeedback { blockReason?: string; }
interface GeminiError { code?: number; status?: string; }
interface GeminiEvent { candidates?: GeminiCandidate[]; promptFeedback?: GeminiFeedback; error?: GeminiError; usageMetadata?: Object; }

export class GeminiStream implements ModelStream {
  private frames: EventFrames;
  private parts: GeminiPart[] = [];
  private calls: ToolCall[] = [];
  private content: string = '';
  private reasoning: string = '';
  private size: number = 0;
  private done: boolean = false;
  private callPrefix: string = 'gemini_' + util.generateRandomUUID();
  private onText: (text: string) => void;
  private onReasoning?: (text: string) => void;

  constructor(onText: (text: string) => void, onReasoning?: (text: string) => void) {
    this.onText = onText; this.onReasoning = onReasoning;
    this.frames = new EventFrames((payload) => this.event(payload));
  }
  push(text: string): void { this.frames.push(text); }
  finish(): ModelTurn {
    this.frames.finish();
    if (!this.done) { throw new Error(t('Gemini 连接结束，但未收到完整回答的结束标记。')); }
    validateToolCalls(this.calls); validateGeminiContent(this.parts);
    if (!this.calls.length && !this.content.trim()) { throw new Error(t('模型没有返回可显示的文本。')); }
    return { content: this.content, toolCalls: this.calls, reasoningContent: this.reasoning || undefined, geminiContent: this.parts };
  }
  private event(payload: string): void {
    let event: GeminiEvent;
    try { event = JSON.parse(payload) as GeminiEvent; }
    catch (_) { throw new Error(t('模型返回了无效的流式 JSON。')); }
    if (!event || typeof event !== 'object' || Array.isArray(event)) { throw new Error(t('Gemini 流式事件无效。')); }
    if (event.error) { throw new Error(t('Gemini 模型服务返回错误。') + ' [' + (Number.isInteger(event.error.code) ? event.error.code : 'unknown') + ']'); }
    if (event.promptFeedback?.blockReason) { throw new Error(t('Gemini 请求或回答被拦截。')); }
    if (event.candidates === undefined && event.usageMetadata) { return; }
    if (!Array.isArray(event.candidates) || event.candidates.length > 1) { throw new Error(t('Gemini 流式事件无效。')); }
    if (!event.candidates.length) { return; }
    if (this.done) { throw new Error(t('Gemini 在结束后继续返回数据。')); }
    const candidate = event.candidates[0];
    if (!candidate || (candidate.index !== undefined && candidate.index !== 0) ||
      (candidate.content !== undefined && (!candidate.content || !Array.isArray(candidate.content.parts))) ||
      (candidate.content?.role !== undefined && candidate.content.role !== 'model')) { throw new Error(t('Gemini 流式事件无效。')); }
    const parts = candidate.content?.parts || [];
    validateGeminiContent(parts);
    this.size += JSON.stringify(parts).length;
    if (this.size > 2 * 1024 * 1024 || this.parts.length + parts.length > 65536) { throw new Error(t('Gemini 内容记录无效或过大。')); }
    for (const part of parts) {
      this.parts.push(part);
      if (part.functionCall) {
        if (this.calls.length >= MAX_TOOL_CALLS) { throw new Error(t('单步工具调用数量超出限制。')); }
        this.calls.push({ id: this.callPrefix + '_' + this.calls.length, type: 'function',
          function: { name: part.functionCall.name, arguments: JSON.stringify(part.functionCall.args || {}) } });
        validateToolCalls(this.calls);
      } else if (part.text !== undefined) {
        if (part.thought) {
          this.reasoning += part.text;
          if (this.reasoning.length > MAX_REASONING_CONTENT) { throw new Error(t('Gemini 内容记录无效或过大。')); }
          if (part.text) { this.onReasoning?.(part.text); }
        } else { this.content += part.text; if (part.text) { this.onText(part.text); } }
      }
    }
    if (candidate.finishReason !== undefined) {
      if (candidate.finishReason !== 'STOP') { throw new Error(t('Gemini 回答达到输出上限、被拦截或执行未完成。')); }
      this.done = true;
    }
  }
}
