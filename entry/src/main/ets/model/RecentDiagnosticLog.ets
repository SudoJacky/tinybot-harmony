import { LogData, LogValue } from './DiagnosticLog';

export interface RecentDiagnosticRecord { timestamp: string; data: LogData; }
export interface RecentDiagnosticSnapshot {
  createdAt: string; windowMinutes: number; capacity: number; overwritten: number; records: RecentDiagnosticRecord[];
}
export interface FeedbackLogApplication { versionName: string; versionCode: number; }
interface TimedDiagnosticRecord { time: number; data: LogData; }

// Retain only records already accepted and sanitized by Diagnostics. This does not enable new log levels or disk capture.
export class RecentDiagnosticLogs {
  private records: TimedDiagnosticRecord[] = [];
  private overwritten: number = 0;
  private clock: () => number;
  constructor(clock: () => number = () => Date.now()) { this.clock = clock; }
  record(data: LogData): void {
    const time = this.clock();
    while (this.records.length && time - this.records[0].time > 15 * 60 * 1000) { this.records.shift(); }
    if (this.records.length >= 1000) { this.records.shift(); this.overwritten++; }
    this.records.push({ time: time, data: data });
  }
  snapshot(): RecentDiagnosticSnapshot {
    const now = this.clock();
    const records = this.records.filter((record: TimedDiagnosticRecord) => record.time <= now && now - record.time <= 15 * 60 * 1000)
      .map((record: TimedDiagnosticRecord): RecentDiagnosticRecord => {
        const fields: Record<string, LogValue> = {};
        Object.keys(record.data.fields).forEach((key: string) => { fields[key] = record.data.fields[key]; });
        return { timestamp: new Date(record.time).toISOString(), data: {
          level: record.data.level, module: record.data.module, event: record.data.event, fields: fields } };
      });
    return { createdAt: new Date(now).toISOString(), windowMinutes: 15, capacity: 1000, overwritten: this.overwritten, records: records };
  }
  clear(): void { this.records = []; this.overwritten = 0; }
}

// JSON Lines is UTF-8 plain text, not an archive. Keep the newest records and leave headroom below the API's 2 MiB limit.
// A 512 Ki UTF-16-unit budget is at most 1.5 MiB when encoded as UTF-8, including non-ASCII version names.
export function formatFeedbackLog(snapshot: RecentDiagnosticSnapshot, application: FeedbackLogApplication): string {
  const lines: string[] = [];
  let length = 0;
  for (let index = snapshot.records.length - 1; index >= 0; index--) {
    const line = JSON.stringify(snapshot.records[index]);
    if (length + line.length + 1 > 512 * 1024 - 4096) { break; }
    lines.push(line); length += line.length + 1;
  }
  const header = JSON.stringify({ schemaVersion: 1, kind: 'tinybot.feedback.log', platform: 'HarmonyOS',
    versionName: application.versionName.slice(0, 128), versionCode: application.versionCode,
    createdAt: snapshot.createdAt, scope: 'current-process', windowMinutes: snapshot.windowMinutes,
    recordCount: lines.length, overwritten: snapshot.overwritten, omittedForSize: snapshot.records.length - lines.length,
    normalModeLevels: ['warn', 'error'] });
  return header + '\n' + lines.reverse().join('\n') + '\n';
}
