import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppData, ThreadData, emptyData, normalizeAppData } from '../model/Conversation';
import { Attachment } from '../model/Productivity';
import { DEEPSEEK_SESSION_PATH, DeepSeekPlan, appendDeepSeekSession } from '../model/DeepSeekImport';
import { rollbackBackupActions, rollbackBackupFailure } from '../model/BackupImport';
import { t } from '../model/I18n';
import { Attachments } from './Attachments';
import { ZipArchive } from './ZipArchive';

interface DeepSeekManifest { export_format_version: number; }
export type PrepareImportedFiles = (threads: ThreadData[]) => Promise<() => Promise<void>>;
type CommitImport = (threads: ThreadData[], prepare: PrepareImportedFiles) => Promise<number>;
const MiB: number = 1024 * 1024;

export async function readDeepSeekPlan(zip: ZipArchive): Promise<DeepSeekPlan> {
  const manifest = zip.entry('manifest.json');
  if (!manifest) { throw new Error(t('请选择 DeepSeek 导出的会话 ZIP 文件。')); }
  const decoder = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
  const header = JSON.parse(decoder.decodeToString(new Uint8Array(await zip.read(manifest, 64 * 1024)))) as DeepSeekManifest;
  if (!header || header.export_format_version !== 3) { throw new Error(t('此 DeepSeek 导出版本暂不支持。')); }
  const plan: DeepSeekPlan = { threads: [], files: new Map() };
  let jsonBytes = 0;
  let messages = 0;
  for (const entry of zip.entries()) {
    const match = DEEPSEEK_SESSION_PATH.exec(entry.name);
    if (!match) { continue; }
    jsonBytes += entry.size;
    if (jsonBytes > 128 * MiB) { throw new Error(t('DeepSeek 导出包中的会话超过导入上限。')); }
    const previous = plan.threads.length;
    appendDeepSeekSession(plan, match[1], decoder.decodeToString(new Uint8Array(await zip.read(entry, 16 * MiB))));
    for (let index = previous; index < plan.threads.length; index++) { messages += plan.threads[index].messages.length; }
    if (plan.threads.length > 10000 || messages > 250000) { throw new Error(t('DeepSeek 导出包中的会话超过导入上限。')); }
  }
  if (!plan.threads.length) { throw new Error(t('此 DeepSeek 导出包中没有可导入的会话。')); }
  const snapshot: AppData = emptyData();
  snapshot.threads = plan.threads;
  normalizeAppData(snapshot);
  return plan;
}

async function stageFiles(zip: ZipArchive, plan: DeepSeekPlan, threads: ThreadData[]): Promise<() => Promise<void>> {
  const saved = new Map<string, Attachment>();
  const completed = new Set<string>();
  let bytes = 0;
  const rollback = async (): Promise<void> => {
    await rollbackBackupActions(Array.from(saved.values()).map(item => () => Attachments.discardImportedFile(item)));
  };
  try {
    for (const thread of threads) {
      for (const message of thread.messages) {
        const files = plan.files.get(message.id);
        if (!files || completed.has(message.id)) { continue; }
        const attachments: Attachment[] = [];
        for (const file of files) {
          let attachment = saved.get(file.path);
          if (!attachment) {
            const entry = zip.entry(file.path);
            if (!entry) { throw new Error(t('DeepSeek 导出包中缺少附件：{0}', [file.name])); }
            bytes += entry.size;
            if (bytes > 256 * MiB) { throw new Error(t('DeepSeek 导出包中的附件超过导入上限。')); }
            attachment = await Attachments.saveImportedFile(await zip.read(entry, 20 * MiB), file.name, file.image);
            saved.set(file.path, attachment);
          }
          attachments.push(attachment);
        }
        message.attachments = attachments;
        completed.add(message.id);
      }
    }
  } catch (error) { await rollbackBackupFailure(error as Error, rollback); }
  return rollback;
}

export async function chooseDeepSeekArchive(context: common.UIAbilityContext, commit: CommitImport): Promise<number | undefined> {
  const uris = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: 1, fileSuffixFilters: ['DeepSeek|.zip'] });
  if (!uris.length) { return undefined; }
  return importDeepSeekArchive(uris[0], commit);
}

export async function importDeepSeekArchive(path: string, commit: CommitImport): Promise<number> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const zip = await ZipArchive.readDirectory(file.fd);
    const plan = await readDeepSeekPlan(zip);
    return await commit(plan.threads, (threads: ThreadData[]) => stageFiles(zip, plan, threads));
  } finally { await fs.close(file); }
}
