import { RequestUsage, TokenUsage } from './Usage';

export class UsageTotals {
  calls: number = 0;
  reported: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  pending: number = 0;
  input: number = 0;
  output: number = 0;
  cached: number = 0;
  reasoning: number = 0;
  cacheWrite: number = 0;
  cachedReports: number = 0;
  reasoningReports: number = 0;
  cacheWriteReports: number = 0;
  get total(): number { return this.input + this.output; }
  get missing(): number { return this.calls - this.reported; }
}

export class UsageDay extends UsageTotals {
  date: string = '';
}

export class UsageModel extends UsageTotals {
  key: string = '';
  provider: string = '';
  model: string = '';
}

export class UsageGroup extends UsageTotals {
  key: string = '';
  label: string = '';
  startedAt: number = 0;
  records: RequestUsage[] = [];
}
export class UsageSession extends UsageGroup {
  turns: UsageGroup[] = [];
}
export class UsagePeriod extends UsageGroup {
  purposes: UsageGroup[] = [];
}
export class UsageActivity {
  key: string = '';
  label: string = '';
  calls: number = 0;
  failed: number = 0;
  durationMs: number = 0;
}

export class UsageStatistics {
  totals: UsageTotals = new UsageTotals();
  days: UsageDay[] = [];
  models: UsageModel[] = [];
  records: RequestUsage[] = [];
  sessions: UsageSession[] = [];
  purposes: UsageGroup[] = [];
  weeks: UsagePeriod[] = [];
  tools: UsageActivity[] = [];
  skills: UsageActivity[] = [];
  peak: number = 1;
}

function group(items: UsageGroup[], index: Map<string, UsageGroup>, indexKey: string, key: string, label: string, item: RequestUsage, details: boolean): UsageGroup {
  let found = index.get(indexKey);
  if (!found) { found = new UsageGroup(); found.key = key; found.label = label; items.push(found); index.set(indexKey, found); }
  add(found, item); found.startedAt = Math.max(found.startedAt, item.startedAt);
  if (details) { found.records.push(item); }
  return found;
}

function activity(items: UsageActivity[], index: Map<string, UsageActivity>, key: string, label: string, failed: boolean, duration: number): void {
  let found = index.get(key);
  if (!found) { found = new UsageActivity(); found.key = key; found.label = label; items.push(found); index.set(key, found); }
  found.calls++; found.failed += failed ? 1 : 0; found.durationMs += duration;
}

export function usageWeek(time: number): string {
  const date = new Date(time); date.setHours(0, 0, 0, 0); date.setDate(date.getDate() - (date.getDay() + 6) % 7);
  return usageDate(date.getTime());
}

function validCount(value: number | undefined): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

export function reportedTokens(tokens?: TokenUsage): boolean {
  return tokens !== undefined && validCount(tokens.input) && validCount(tokens.output);
}

export function usageDate(time: number): string {
  const date = new Date(time);
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
}

function add(total: UsageTotals, item: RequestUsage): void {
  total.calls++;
  if (item.status === 'failed') { total.failed++; }
  if (item.status === 'cancelled') { total.cancelled++; }
  if (item.status === 'running_or_unknown') { total.pending++; }
  const tokens = item.tokens;
  if (!tokens || !reportedTokens(tokens)) { return; }
  total.reported++; total.input += tokens.input; total.output += tokens.output;
  if (validCount(tokens.cached)) { total.cached += tokens.cached || 0; total.cachedReports++; }
  if (validCount(tokens.reasoning)) { total.reasoning += tokens.reasoning || 0; total.reasoningReports++; }
  if (validCount(tokens.cacheWrite)) { total.cacheWrite += tokens.cacheWrite || 0; total.cacheWriteReports++; }
}

export interface UsageFilter { range: number; provider: string; model: string; threadId: string; now: number; }

export function usageStart(filter: UsageFilter): number {
  const start = new Date(filter.now); start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - (filter.range === 0 ? 1 : filter.range === 1 ? 7 : 30) + 1);
  return start.getTime();
}
export function matchesUsage(item: RequestUsage, filter: UsageFilter, start: number = usageStart(filter)): boolean {
  return Number.isFinite(item.startedAt) && item.startedAt <= filter.now &&
    (filter.range === 3 || item.startedAt >= start) && (!filter.provider || item.provider === filter.provider) &&
    (!filter.model || item.model === filter.model) && (!filter.threadId || (item.origin?.threadId || 'unassigned') === filter.threadId);
}

// A compact accumulator retains counters only. Request bodies and per-turn groups
// are collected only by explicitly requested detail queries.
export class UsageAccumulator {
  result: UsageStatistics = new UsageStatistics();
  private days: Map<string, UsageDay> = new Map();
  private models: Map<string, UsageModel> = new Map();
  private sessions: Map<string, UsageSession> = new Map();
  private weeks: Map<string, UsagePeriod> = new Map();
  private groups: Map<string, UsageGroup> = new Map();
  private tools: Map<string, UsageActivity> = new Map();
  private skills: Map<string, UsageActivity> = new Map();
  private skillTurns: Set<string> = new Set();
  private filter: UsageFilter;
  private details: boolean;
  private turnThread: string;
  private start: number;
  constructor(filter: UsageFilter, details: boolean = false, turnThread: string = '') {
    this.filter = filter; this.details = details; this.turnThread = turnThread; this.start = usageStart(filter);
    const count = filter.range === 0 ? 1 : filter.range === 1 ? 7 : 30;
    const start = new Date(filter.now); start.setHours(0, 0, 0, 0); start.setDate(start.getDate() - count + 1);
    for (let index = 0; index < count; index++) {
      const date = new Date(start.getTime()); date.setDate(date.getDate() + index);
      const day = new UsageDay(); day.date = usageDate(date.getTime());
      this.result.days.push(day); this.days.set(day.date, day);
    }
  }
  push(item: RequestUsage): void {
    if (!matchesUsage(item, this.filter, this.start)) { return; }
    const result = this.result;
    if (this.details) { result.records.push(item); }
    add(result.totals, item);
    const day = this.days.get(usageDate(item.startedAt)); if (day) { add(day, item); }
    const key = JSON.stringify([item.provider, item.model]);
    let model = this.models.get(key);
    if (!model) { model = new UsageModel(); model.key = key; model.provider = item.provider; model.model = item.model; this.models.set(key, model); result.models.push(model); }
    add(model, item);
    const origin = item.origin; const purpose = origin?.purpose || 'unclassified';
    group(result.purposes, this.groups, 'purpose:' + purpose, purpose, purpose, item, this.details);
    const sessionKey = origin?.threadId || 'unassigned';
    let session = this.sessions.get(sessionKey);
    if (!session) { session = new UsageSession(); session.key = sessionKey; this.sessions.set(sessionKey, session); result.sessions.push(session); }
    if (item.startedAt >= session.startedAt && origin?.threadTitle) { session.label = origin.threadTitle; }
    add(session, item); session.startedAt = Math.max(session.startedAt, item.startedAt);
    if (this.details) { session.records.push(item); }
    if (this.details || this.turnThread === sessionKey) {
      const turnKey = origin?.turnId || 'unassigned';
      group(session.turns, this.groups, JSON.stringify(['turn', sessionKey, turnKey]), turnKey, origin?.turnLabel || '', item, this.details);
    }
    const week = usageWeek(item.startedAt);
    let period = this.weeks.get(week);
    if (!period) { period = new UsagePeriod(); period.key = week; this.weeks.set(week, period); result.weeks.push(period); }
    add(period, item); group(period.purposes, this.groups, JSON.stringify(['week', week, purpose]), purpose, purpose, item, this.details);
    const skills = new Set<string>();
    if (origin?.skill) { skills.add(origin.skill); }
    for (const tool of item.tools || []) {
      const toolKey = JSON.stringify([tool.name, tool.server, tool.remoteTool]);
      const label = tool.name === 'mcp_call' ? (tool.server || 'MCP') + ' / ' + (tool.remoteTool || tool.name) : tool.name;
      activity(result.tools, this.tools, toolKey, label, tool.status === 'failed', tool.durationMs);
      if (tool.skill && tool.status === 'complete') { skills.add(tool.skill); }
    }
    for (const skill of skills) {
      const skillKey = JSON.stringify([sessionKey, origin?.turnId || item.id, skill]);
      if (this.skillTurns.has(skillKey)) { continue; }
      this.skillTurns.add(skillKey); activity(result.skills, this.skills, skill, skill, false, 0);
    }
  }
  finish(): UsageStatistics {
    const result = this.result;
    result.records.sort(compareUsage);
    result.models.sort((a, b) => b.total - a.total || b.calls - a.calls || a.key.localeCompare(b.key));
    result.peak = Math.max(1, ...result.days.map((day: UsageDay) => day.total));
    result.sessions.sort((a, b) => b.total - a.total || b.startedAt - a.startedAt || a.key.localeCompare(b.key));
    for (const session of result.sessions) {
      session.turns.sort((a, b) => b.startedAt - a.startedAt || a.key.localeCompare(b.key));
      for (const turn of session.turns) { turn.records.sort(compareUsage); }
    }
    result.purposes.sort((a, b) => b.total - a.total || b.calls - a.calls);
    result.weeks.sort((a, b) => b.key.localeCompare(a.key));
    result.tools.sort((a, b) => b.calls - a.calls || a.key.localeCompare(b.key));
    result.skills.sort((a, b) => b.calls - a.calls || a.key.localeCompare(b.key));
    return result;
  }
}

export function compareUsage(a: RequestUsage, b: RequestUsage): number {
  return b.startedAt - a.startedAt || a.id.localeCompare(b.id);
}

// Synchronous compatibility helper for small fixtures and callers needing all details.
export function summarizeUsage(records: RequestUsage[], range: number = 2, provider: string = '',
  model: string = '', now: number = Date.now(), threadId: string = ''): UsageStatistics {
  const builder = new UsageAccumulator({ range: range, provider: provider, model: model, now: now, threadId: threadId }, true);
  for (const item of records) { builder.push(item); }
  return builder.finish();
}
