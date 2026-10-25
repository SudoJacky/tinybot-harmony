import { hilog } from '@kit.PerformanceAnalysisKit';
import { Diagnostics } from '../model/Diagnostics';
import { LogData } from '../model/DiagnosticLog';
import { RecentDiagnosticLogs, RecentDiagnosticSnapshot } from '../model/RecentDiagnosticLog';

const recent: RecentDiagnosticLogs = new RecentDiagnosticLogs();
export function recentDiagnosticLogs(): RecentDiagnosticSnapshot { return recent.snapshot(); }
export function clearRecentDiagnosticLogs(): void { recent.clear(); }

// Only this adapter writes application logs to HiLog. Both sinks receive the same sanitized record.
export function configureNativeDiagnosticLog(): void {
  Diagnostics.configureLogSink((data: LogData) => {
    recent.record(data);
    const record = JSON.stringify(data);
    if (data.level === 'debug') { hilog.debug(0x0000, 'Tinybot', '%{public}s', record); }
    else if (data.level === 'info') { hilog.info(0x0000, 'Tinybot', '%{public}s', record); }
    else if (data.level === 'warn') { hilog.warn(0x0000, 'Tinybot', '%{public}s', record); }
    else { hilog.error(0x0000, 'Tinybot', '%{public}s', record); }
  });
}
