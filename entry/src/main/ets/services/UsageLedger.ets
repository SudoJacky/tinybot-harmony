import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { RequestUsage } from '../model/Usage';
import { writeBytes } from './Attachments';
import { util } from '@kit.ArkTS';
export class UsageLedger {
  private static path: string = '';
  private static records: RequestUsage[] = [];
  private static queue: Promise<void> = Promise.resolve();
  static error: string = '';
  static configure(root: string): Promise<void> {
    UsageLedger.path = root + '/usage-ledger.json';
    UsageLedger.queue = UsageLedger.queue.then(() => UsageLedger.load());
    return UsageLedger.queue;
  }
  private static async load(): Promise<void> {
    if (await fs.access(UsageLedger.path)) {
      const records = JSON.parse(await fs.readText(UsageLedger.path)) as RequestUsage[];
      if (!Array.isArray(records)) { throw new Error(t("用量记录格式损坏。")); }
      UsageLedger.records = records.filter((saved) => !UsageLedger.records.some((current) => current.id === saved.id)).concat(UsageLedger.records);
    }
  }
  static list(): RequestUsage[] { return UsageLedger.records.slice().reverse(); }
  static record(item: RequestUsage): void {
    const index = UsageLedger.records.findIndex((existing) => existing.id === item.id);
    if (index < 0) { UsageLedger.records.push(item); } else { UsageLedger.records[index] = item; }
    if (!UsageLedger.path) { return; }
    UsageLedger.queue = UsageLedger.queue.catch(() => {}).then(async () => {
      try {
        const text = JSON.stringify(UsageLedger.records);
        await writeBytes(UsageLedger.path + '.tmp', new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer);
        await fs.rename(UsageLedger.path + '.tmp', UsageLedger.path); UsageLedger.error = '';
      } catch (error) { UsageLedger.error = '用量保存失败：' + (error as Error).message; }
    });
  }
}
