import { AppData } from './Conversation';
export interface BackupRestoreReport {
  added: number;
  skipped: number;
  copied: number;
}
const reports = new WeakMap<AppData, BackupRestoreReport>();
export function attachBackupRestoreReport(data: AppData, report: BackupRestoreReport): void { reports.set(data, report); }
export function backupRestoreReport(data: AppData): BackupRestoreReport {
  return reports.get(data) || { added: data.threads.length, skipped: 0, copied: 0 };
}
