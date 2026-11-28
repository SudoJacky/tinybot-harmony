import { EventFrames } from './EventFrames';
import { ContextDiagnostics } from './Agent';
export interface TokenUsage { input: number; output: number; cached?: number; reasoning?: number; cacheWrite?: number; }
export interface UsageOrigin {
  threadId?: string; threadTitle?: string; turnId?: string; turnLabel?: string;
  purpose?: string; step?: number; skill?: string;
  teamId?: string; taskId?: string; taskTitle?: string; memberName?: string; attemptId?: string; attempt?: number;
}
export interface UsageToolActivity {
  id: string; name: string; status: string; startedAt: number; durationMs: number;
  skill?: string; server?: string; remoteTool?: string;
}
export interface UsageRecorder {
  recordTool(requestId: string, activity: UsageToolActivity): void;
  recordContext?(sessionId: string, diagnostics: ContextDiagnostics): void;
}
export interface RequestUsage {
  id: string; provider: string; model: string; startedAt: number; durationMs: number; firstTokenMs?: number;
  status: string; tokens?: TokenUsage; origin?: UsageOrigin; tools?: UsageToolActivity[];
}
interface Details { cached_tokens?: number; reasoning_tokens?: number; }
interface WireUsage {
  prompt_tokens?: number; completion_tokens?: number; input_tokens?: number; output_tokens?: number;
  cache_read_input_tokens?: number; cache_creation_input_tokens?: number;
  prompt_tokens_details?: Details; completion_tokens_details?: Details; input_tokens_details?: Details; output_tokens_details?: Details;
}
interface GeminiUsage { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number; cachedContentTokenCount?: number; }
interface UsageEvent { type?: string; usage?: WireUsage; usageMetadata?: GeminiUsage; message?: UsageEvent; response?: UsageEvent; }
function count(value: number | undefined): number | undefined { return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined; }
export class UsageStream {
  private frames?: EventFrames;
  private input?: number;
  private output?: number;
  private cached?: number;
  private reasoning?: number;
  private cacheWrite?: number;
  push(text: string): void {
    if (!this.frames) {
      this.frames = new EventFrames((payload: string) => {
        let event: Object;
        try { event = JSON.parse(payload) as Object; } catch (_) { return; }
        this.observe(event);
      });
    }
    this.frames.push(text);
  }
  result(): TokenUsage | undefined {
    return this.input === undefined || this.output === undefined ? undefined : {
      input: this.input, output: this.output, cached: this.cached, reasoning: this.reasoning, cacheWrite: this.cacheWrite };
  }
  observe(value: Object): void {
    const event = value as UsageEvent;
    if (event?.usageMetadata) {
      const metadata = event.usageMetadata;
      const input = count(metadata.promptTokenCount); const output = count(metadata.candidatesTokenCount);
      const reasoning = count(metadata.thoughtsTokenCount); const cached = count(metadata.cachedContentTokenCount);
      if (input !== undefined) { this.input = input; }
      if (output !== undefined) { this.output = output + (reasoning || 0); }
      if (reasoning !== undefined) { this.reasoning = reasoning; }
      if (cached !== undefined) { this.cached = cached; }
      return;
    }
    const usage = event?.usage || event?.message?.usage || event?.response?.usage;
    if (!usage) { return; }
    const input = count(usage.prompt_tokens ?? usage.input_tokens); const output = count(usage.completion_tokens ?? usage.output_tokens);
    const cached = count(usage.cache_read_input_tokens ?? usage.prompt_tokens_details?.cached_tokens ?? usage.input_tokens_details?.cached_tokens);
    const written = count(usage.cache_creation_input_tokens);
    if (input !== undefined) {
      this.input = input + (usage.cache_read_input_tokens !== undefined ? cached || 0 : 0) + (written || 0);
    }
    if (output !== undefined) { this.output = output; }
    if (cached !== undefined) { this.cached = cached; }
    if (written !== undefined) { this.cacheWrite = written; }
    const reasoning = count(usage.completion_tokens_details?.reasoning_tokens ?? usage.output_tokens_details?.reasoning_tokens);
    if (reasoning !== undefined) { this.reasoning = reasoning; }
  }
}
