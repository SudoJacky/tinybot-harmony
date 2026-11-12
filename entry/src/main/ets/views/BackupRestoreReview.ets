import { UIContext } from '@kit.ArkUI';
import { AppData } from '../model/Conversation';
import { backupRestoreReport } from '../model/BackupRestoreReport';
import { discardBackupImport } from '../model/BackupImport';
import { t } from '../model/I18n';

export async function reviewBackupRestore(context: UIContext, data: AppData): Promise<boolean> {
  const report = backupRestoreReport(data);
  let accepted = false;
  try {
    accepted = await new Promise<boolean>((resolve) => {
      context.showAlertDialog({ title: t('确认恢复内容'),
        message: t('新增 {0} 个会话，跳过 {1} 个已有版本，另存 {2} 个冲突副本。\n{3} 个会话继续由原设备执行。备份副本可在本机继续，原有会话和文件会保留。',
          [report.added, report.skipped, report.copied, report.remote]),
        primaryButton: { value: t('取消'), action: () => resolve(false) },
        secondaryButton: { value: t('恢复备份'), action: () => resolve(true) }, cancel: () => resolve(false) });
    });
    return accepted;
  } finally { if (!accepted) { await discardBackupImport(data); } }
}
