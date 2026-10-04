import { RequestUsage } from './Usage';

export class MessageUsageSummary {
  requests: number = 0;
  durationMs: number = 0;
  reported: number = 0;
  input: number = 0;
  output: number = 0;
  cached: number = 0;
  cacheReports: number = 0;
  cacheWrite: number = 0;
  writeReports: number = 0;
  reasoning: number = 0;
  reasoningReports: number = 0;

  get cacheHitRate(): number | undefined {
    // Missing cache usage is unknown, not a cache miss. Weight by input tokens,
    // never by the number of requests, and include cache writes in total input.
    return this.requests > 0 && this.cacheReports === this.requests && this.input > 0
      ? this.cached / this.input * 100 : undefined;
  }
}

export function summarizeUsage(records: (RequestUsage | undefined)[]): MessageUsageSummary {
  const result = new MessageUsageSummary();
  for (const record of records) {
    if (!record) { continue; }
    result.requests++;
    result.durationMs += record.durationMs;
    const tokens = record.tokens;
    if (!tokens) { continue; }
    result.reported++;
    result.input += tokens.input;
    result.output += tokens.output;
    if (tokens.cached !== undefined && tokens.cached >= 0 && tokens.cached <= tokens.input) {
      result.cached += tokens.cached; result.cacheReports++;
    }
    if (tokens.cacheWrite !== undefined) { result.cacheWrite += tokens.cacheWrite; result.writeReports++; }
    if (tokens.reasoning !== undefined) { result.reasoning += tokens.reasoning; result.reasoningReports++; }
  }
  return result;
}
