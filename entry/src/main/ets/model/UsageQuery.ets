import { RequestUsage } from './Usage';
import { UsageAccumulator, UsageFilter, UsageGroup, UsageSession, UsageStatistics, compareUsage, matchesUsage, usageStart } from './UsageStatistics';

export const USAGE_PAGE_SIZE = 30;
export interface UsageCursor { id: string; startedAt: number; }
export class UsageRequestPage {
  records: RequestUsage[] = [];
  next?: UsageCursor;
}
export class UsageOptions {
  providers: string[] = [];
  models: string[] = [];
  sessions: UsageSession[] = [];
}

// Yield between bounded batches so navigation and incoming stream updates can run.
export async function usageYield(): Promise<void> { await new Promise<void>((resolve) => setTimeout(resolve, 0)); }
export class UsageQuery {
  private records: RequestUsage[];
  private alive: boolean = true;
  constructor(records: RequestUsage[]) { this.records = records; }
  cancel(): void { this.alive = false; }
  private check(current?: () => boolean): void { if (!this.alive || (current && !current())) { throw new Error('Usage query superseded'); } }
  async summary(filter: UsageFilter, turnThread: string = '', current?: () => boolean): Promise<UsageStatistics> {
    const builder = new UsageAccumulator(filter, false, turnThread);
    let batchStarted = Date.now();
    for (let index = 0; index < this.records.length; index++) {
      if (index % 64 === 0 && (index % 1024 === 0 || Date.now() - batchStarted >= 4)) { await usageYield(); this.check(current); batchStarted = Date.now(); }
      builder.push(this.records[index]);
    }
    this.check(current); return builder.finish();
  }
  async options(provider: string): Promise<UsageOptions> {
    const providers = new Set<string>(); const models = new Set<string>(); const sessions = new Map<string, UsageSession>();
    let batchStarted = Date.now();
    for (let index = 0; index < this.records.length; index++) {
      if (index % 64 === 0 && (index % 1024 === 0 || Date.now() - batchStarted >= 4)) { await usageYield(); this.check(); batchStarted = Date.now(); }
      const item = this.records[index]; providers.add(item.provider);
      if (!provider || item.provider === provider) { models.add(item.model); }
      const key = item.origin?.threadId || 'unassigned'; let session = sessions.get(key);
      if (!session) { session = new UsageSession(); session.key = key; sessions.set(key, session); }
      if (item.startedAt >= session.startedAt) { session.label = item.origin?.threadTitle || session.label; session.startedAt = item.startedAt; }
    }
    const result = new UsageOptions(); result.providers = Array.from(providers).sort(); result.models = Array.from(models).sort();
    result.sessions = Array.from(sessions.values()).sort((a, b) => b.startedAt - a.startedAt || a.key.localeCompare(b.key));
    return result;
  }
  async turns(filter: UsageFilter, thread: string, current?: () => boolean): Promise<UsageGroup[]> {
    const scoped: UsageFilter = { range: filter.range, now: filter.now, provider: filter.provider, model: filter.model, threadId: thread };
    return (await this.summary(scoped, thread, current)).sessions[0]?.turns || [];
  }
  async page(filter: UsageFilter, cursor?: UsageCursor, thread: string = '', turn: string = '', current?: () => boolean): Promise<UsageRequestPage> {
    const result = new UsageRequestPage();
    const start = usageStart(filter);
    let batchStarted = Date.now();
    for (let index = 0; index < this.records.length; index++) {
      if (index % 64 === 0 && (index % 1024 === 0 || Date.now() - batchStarted >= 4)) { await usageYield(); this.check(); batchStarted = Date.now(); }
      this.check(current); const item = this.records[index];
      if (!matchesUsage(item, filter, start) || (thread && (item.origin?.threadId || 'unassigned') !== thread) ||
        (turn && (item.origin?.turnId || 'unassigned') !== turn)) { continue; }
      if (cursor && (item.startedAt > cursor.startedAt || (item.startedAt === cursor.startedAt && item.id.localeCompare(cursor.id) <= 0))) { continue; }
      // Keep just one page plus a look-ahead, even on deep pages. The ID tie-breaker
      // makes pagination deterministic when many calls share a millisecond.
      let low = 0; let high = result.records.length;
      while (low < high) { const middle = Math.floor((low + high) / 2); if (compareUsage(result.records[middle], item) <= 0) { low = middle + 1; } else { high = middle; } }
      if (low <= USAGE_PAGE_SIZE) { result.records.splice(low, 0, item); if (result.records.length > USAGE_PAGE_SIZE + 1) { result.records.pop(); } }
    }
    if (result.records.length > USAGE_PAGE_SIZE) {
      result.records.pop(); const last = result.records[result.records.length - 1]; result.next = { id: last.id, startedAt: last.startedAt };
    }
    this.check(current); return result;
  }
}
