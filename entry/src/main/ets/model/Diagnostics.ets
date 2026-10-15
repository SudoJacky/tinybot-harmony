import { LogData, LogFields, LogLevel, LogSanitizer, knownLogEvent, logRank, LOG_LEVELS } from './DiagnosticLog';
export interface PerfValues {
  current?: number;
  sourceChars?: number;
  changedBlocks?: number;
  startBlock?: number;
  newChunks?: number;
  mountedChunks?: number;
  totalChunks?: number;
  blocks?: number;
  visible?: number;
  blockOffset?: number;
  chars?: number;
  spans?: number;
  tokens?: number;
  expanded?: number;
  rows?: number;
  columns?: number;
  heightVp?: number;
  widthVp?: number;
  offset?: number;
  previousHeightVp?: number;
  following?: number;
  cumulativeChars?: number;
  chunk?: number;
  bytes?: number;
  http?: number;
  failed?: number;
  cancelled?: number;
  textChunks?: number;
  textChars?: number;
  round?: number;
  argumentChars?: number;
  outputChars?: number;
  active?: number;
  generation?: number;
  preflight?: number;
  enabled?: number;
  delayMs?: number;
  pssSwapKiB?: number;
  rssKiB?: number;
  vssKiB?: number;
  privateDirtyKiB?: number;
  sharedDirtyKiB?: number;
  cpuPercent?: number;
  vmUsedKiB?: number;
  vmTotalKiB?: number;
  vmArraysKiB?: number;
  threadsReported?: number;
  source?: number;
  code?: number;
  number?: number;
  time?: number;
  begin_time?: number;
  end_time?: number;
  duration?: number;
  pid?: number;
  tid?: number;
  happen_time?: number;
  threads?: number;
  changed?: number;
  metadataChars?: number;
}
// Platform-free collector for numeric performance events and allowlisted runtime log metadata.
export interface PerfMark { session: number; time: number; id: number; }
export interface PerfEvent {
  seq: number; time: number; name: string; duration: number; id: number; values: Record<string, number>;
  log?: LogData;
}
export interface PerfMetric {
  name: string; unit: string; count: number; sum: number; min: number; max: number; last: number; buckets: number[];
}
export interface PerfSummary extends PerfMetric { p50Upper: number; p95Upper: number; p99Upper: number; }
export interface PerfSnapshot {
  schema: number; session: number; recording: boolean; detailed: boolean; startedAt: number; elapsedMs: number;
  eventCapacity: number; overwritten: number; omitted: number; events: PerfEvent[]; metrics: PerfSummary[];
  logging: LogSnapshot;
}
export interface LogSnapshot {
  minimumLevel: LogLevel; capacity: number; overwritten: number; filtered: number; rejected: number; sinkFailures: number;
  counts: Record<string, number>; records: PerfEvent[];
}
const LIMITS: number[] = [0.1, 0.5, 1, 2, 4, 8, 16.7, 33.4, 50, 100, 250, 500, 1000, 5000, 30000, Number.MAX_VALUE];

class EventRing {
  private items: PerfEvent[] = [];
  private next: number = 0;
  overwritten: number = 0;
  readonly capacity: number;
  constructor(capacity: number) { this.capacity = capacity; }
  push(event: PerfEvent): void {
    if (this.items.length < this.capacity) { this.items.push(event); }
    else { this.items[this.next] = event; this.overwritten++; }
    this.next = (this.next + 1) % this.capacity;
  }
  read(): PerfEvent[] {
    return this.items.length < this.capacity ? this.items.slice() : this.items.slice(this.next).concat(this.items.slice(0, this.next));
  }
}

export class DiagnosticsCollector {
  recording: boolean = false;
  detailed: boolean = true;
  session: number = 0;
  private startedAt: number = 0;
  private origin: number = 0;
  private stopped: number = 0;
  private sequence: number = 0;
  private identity: number = 0;
  private omitted: number = 0;
  private events: EventRing = new EventRing(12000);
  private metrics: Map<string, PerfMetric> = new Map<string, PerfMetric>();
  private live: Map<string, number> = new Map<string, number>();
  private clock: () => number = () => Date.now();
  private logs: EventRing = new EventRing(1000);
  private sanitizer: LogSanitizer = new LogSanitizer();
  private sink?: (data: LogData) => void;
  private counts: Record<string, number> = this.emptyCounts();
  private filtered: number = 0;
  private rejected: number = 0;
  private sinkFailures: number = 0;
  logLevel: LogLevel = 'info';
  configureLogSink(sink: (data: LogData) => void): void { this.sink = sink; }
  acceptsLog(level: LogLevel): boolean {
    const rank = logRank(level);
    return rank >= 0 && ((this.recording && rank >= logRank(this.logLevel)) || (rank >= 2 && this.sink !== undefined));
  }
  log(level: LogLevel, module: string, event: string, fields?: LogFields, error?: Error | string): void {
    // Check before clocks, metadata access, redaction, name concatenation, buffering or native IO.
    const capture = this.recording && logRank(level) >= logRank(this.logLevel);
    if (this.recording && !capture) { this.filtered++; }
    if (!this.acceptsLog(level)) { return; }
    if (!knownLogEvent(module, event)) { if (this.recording) { this.rejected++; } return; }
    const data: LogData = { level: level, module: module, event: event, fields: this.sanitizer.sanitize(fields, error, capture) };
    if (capture) {
      this.counts[level]++;
      this.logs.push({ seq: ++this.sequence, time: Math.max(0, this.now() - this.origin), name: 'log.' + module + '.' + event,
        duration: 0, id: 0, values: {}, log: data });
    }
    if (this.sink) {
      try { this.sink(data); }
      catch (_) { this.sinkFailures++; } // Visible in diagnostics; logging must not replace the original application failure.
    }
  }
  private emptyCounts(): Record<string, number> {
    const counts: Record<string, number> = {}; LOG_LEVELS.forEach((level: LogLevel) => { counts[level] = 0; }); return counts;
  }
  private resetLogs(): void {
    this.logs = new EventRing(1000); this.sanitizer.reset(); this.counts = this.emptyCounts();
    this.filtered = 0; this.rejected = 0; this.sinkFailures = 0;
  }
  configureClock(clock: () => number): void { this.clock = clock; }
  now(): number { return this.clock(); }
  nextId(): number { return ++this.identity; }
  adjust(name: string, delta: number): void {
    const value = (this.live.get(name) || 0) + delta; this.live.set(name, value);
    if (this.recording) { this.measure(name, value, 'count'); this.event(name, { current: value }); }
  }
  start(): void {
    this.resetLogs();
    this.session++; this.events = new EventRing(12000); this.metrics.clear(); this.sequence = 0; this.omitted = 0;
    this.startedAt = Date.now(); this.origin = this.now(); this.stopped = this.origin; this.recording = true;
    this.event('capture.start');
    this.live.forEach((value: number, name: string) => { this.measure(name, value, 'count'); this.event(name, { current: value }); });
  }
  stop(): void {
    if (!this.recording) { return; }
    this.event('capture.stop'); this.stopped = this.now(); this.recording = false;
  }
  clear(): void {
    this.resetLogs();
    this.recording = false; this.session++; this.events = new EventRing(12000); this.metrics.clear(); this.sequence = 0; this.omitted = 0;
    this.startedAt = 0; this.origin = this.now(); this.stopped = this.origin;
  }
  begin(id: number = 0): PerfMark | undefined {
    return this.recording ? { session: this.session, time: this.now(), id: id } : undefined;
  }
  end(name: string, mark: PerfMark | undefined, values: PerfValues = {}): void {
    if (!this.recording || !mark || mark.session !== this.session) { return; }
    const duration = Math.max(0, this.now() - mark.time);
    this.measure(name, duration, 'ms');
    this.append(name, mark.time, duration, mark.id, values, duration >= 16.7);
  }
  measure(name: string, value: number, unit: string = 'ms'): void {
    if (!this.recording || !Number.isFinite(value)) { return; }
    let metric = this.metrics.get(name);
    if (!metric) {
      if (this.metrics.size >= 128) { this.omitted++; return; }
      metric = { name: name, unit: unit, count: 0, sum: 0, min: value, max: value, last: value, buckets: LIMITS.map(() => 0) };
      this.metrics.set(name, metric);
    }
    metric.count++; metric.sum += value; metric.min = Math.min(metric.min, value); metric.max = Math.max(metric.max, value); metric.last = value;
    const bucket = LIMITS.findIndex((limit: number) => value <= limit); metric.buckets[bucket < 0 ? LIMITS.length - 1 : bucket]++;
  }
  event(name: string, values: PerfValues = {}, id: number = 0, always: boolean = false): void {
    if (!this.recording) { return; }
    this.append(name, this.now(), 0, id, values, always);
  }
  private append(name: string, time: number, duration: number, id: number, values: PerfValues, always: boolean): void {
    if (!this.detailed && !always) { this.omitted++; return; }
    // Copy finite numeric fields only: never retain references to mutable application state.
    const safe: Record<string, number> = {};
    const raw = values as Record<string, number>;
    Object.keys(raw).slice(0, 16).forEach((key: string) => { if (typeof raw[key] === 'number' && Number.isFinite(raw[key])) { safe[key] = raw[key]; } });
    this.events.push({ seq: ++this.sequence, time: Math.max(0, time - this.origin), name: name, duration: duration, id: id, values: safe });
  }
  eventsSince(sequence: number): PerfEvent[] {
    return this.events.read().concat(this.logs.read()).filter((event: PerfEvent) => event.seq > sequence).sort((a: PerfEvent, b: PerfEvent) => a.seq - b.seq);
  }
  private percentile(metric: PerfMetric, fraction: number): number {
    let count = 0;
    for (let index = 0; index < LIMITS.length; index++) {
      count += metric.buckets[index];
      if (count >= Math.ceil(metric.count * fraction)) { return Math.min(metric.max, LIMITS[index]); }
    }
    return metric.max;
  }
  snapshot(includeEvents: boolean = true): PerfSnapshot {
    const metrics: PerfSummary[] = [];
    this.metrics.forEach((metric: PerfMetric) => metrics.push({ name: metric.name, unit: metric.unit, count: metric.count,
      sum: metric.sum, min: metric.min, max: metric.max, last: metric.last, buckets: metric.buckets.slice(),
      p50Upper: this.percentile(metric, 0.5), p95Upper: this.percentile(metric, 0.95), p99Upper: this.percentile(metric, 0.99) }));
    const counts: Record<string, number> = {};
    Object.keys(this.counts).forEach((level: string) => { counts[level] = this.counts[level]; });
    return { schema: 2, session: this.session, recording: this.recording, detailed: this.detailed, startedAt: this.startedAt,
      elapsedMs: Math.max(0, (this.recording ? this.now() : this.stopped) - this.origin), eventCapacity: 12000,
      overwritten: this.events.overwritten, omitted: this.omitted, events: includeEvents ? this.events.read() : [], metrics: metrics,
      logging: { minimumLevel: this.logLevel, capacity: 1000, overwritten: this.logs.overwritten, filtered: this.filtered,
        rejected: this.rejected, sinkFailures: this.sinkFailures, counts: counts, records: includeEvents ? this.logs.read() : [] } };
  }
}
export const Diagnostics: DiagnosticsCollector = new DiagnosticsCollector();

// This is a local feature gate, not an authentication/security boundary.
export class DeveloperGate {
  private taps: number = 0;
  private lastTap: number = -1;
  private failures: number = 0;
  private blockedUntil: number = 0;
  private ready: boolean = false;
  tap(now: number): boolean {
    if (this.lastTap < 0 || now - this.lastTap > 2000) { this.taps = 0; }
    this.lastTap = now;
    if (++this.taps < 7) { return false; }
    this.taps = 0; this.ready = true; return true;
  }
  verify(password: string, now: number): boolean {
    if (!this.ready || now < this.blockedUntil) { return false; }
    if (password !== 'TB2026&') {
      if (++this.failures >= 5) { this.blockedUntil = now + 30000; this.failures = 0; }
      return false;
    }
    this.failures = 0; return true;
  }
  remaining(now: number): number { return Math.max(0, Math.ceil((this.blockedUntil - now) / 1000)); }
  cancel(): void { this.ready = false; this.taps = 0; this.lastTap = -1; }
}
