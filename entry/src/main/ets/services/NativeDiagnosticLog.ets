import { hilog } from '@kit.PerformanceAnalysisKit';
import { Diagnostics } from '../model/Diagnostics';
import { LogData } from '../model/DiagnosticLog';

// Only this adapter writes application logs to HiLog. Both sinks receive the same sanitized record.
export function configureNativeDiagnosticLog(): void {
  Diagnostics.configureLogSink((data: LogData) => {
    const record = JSON.stringify(data);
    if (data.level === 'debug') { hilog.debug(0x0000, 'Tinybot', '%{public}s', record); }
    else if (data.level === 'info') { hilog.info(0x0000, 'Tinybot', '%{public}s', record); }
    else if (data.level === 'warn') { hilog.warn(0x0000, 'Tinybot', '%{public}s', record); }
    else { hilog.error(0x0000, 'Tinybot', '%{public}s', record); }
  });
}
