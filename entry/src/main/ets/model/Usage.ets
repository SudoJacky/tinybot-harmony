export interface TokenUsage { input: number; output: number; cached?: number; reasoning?: number; cacheWrite?: number; }
export interface RequestUsage { id: string; provider: string; model: string; startedAt: number; durationMs: number; firstTokenMs?: number; status: string; tokens?: TokenUsage; }
interface Details { cached_tokens?: number; reasoning_tokens?: number; }
interface WireUsage {
  prompt_tokens?: number; completion_tokens?: number; input_tokens?: number; output_tokens?: number;
  cache_read_input_tokens?: number; cache_creation_input_tokens?: number;
  prompt_tokens_details?: Details; completion_tokens_details?: Details; input_tokens_details?: Details; output_tokens_details?: Details;
}
interface UsageEvent { type?: string; usage?: WireUsage; message?: UsageEvent; response?: UsageEvent; }
function count(value: number | undefined): number | undefined { return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined; }
export class UsageStream {
  private pending: string = '';
  private lines: string[] = [];
  private input?: number;
  private output?: number;
  private cached?: number;
  private reasoning?: number;
  private cacheWrite?: number;
  push(text: string): void {
    this.pending += text;
    let newline = this.pending.indexOf('\n');
    while (newline >= 0) {
      const line = this.pending.slice(0, newline).replace(/\r$/, ''); this.pending = this.pending.slice(newline + 1);
      if (line.startsWith('data:')) { this.lines.push(line.slice(5).trimStart()); }
      else if (!line && this.lines.length) { this.consume(this.lines.join('\n')); this.lines = []; }
      newline = this.pending.indexOf('\n');
    }
  }
  result(): TokenUsage | undefined {
    return this.input === undefined || this.output === undefined ? undefined : {
      input: this.input, output: this.output, cached: this.cached, reasoning: this.reasoning, cacheWrite: this.cacheWrite };
  }
  private consume(text: string): void {
    if (text === '[DONE]') { return; }
    let event: UsageEvent;
    try { event = JSON.parse(text) as UsageEvent; } catch (_) { return; }
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
