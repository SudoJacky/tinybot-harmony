import { t } from '../model/I18n';
import { common, Want } from '@kit.AbilityKit';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { systemShare } from '@kit.ShareKit';
import { util } from '@kit.ArkTS';
import { Attachment } from '../model/Productivity';
import { Attachments, readBounded, writeBytes } from './Attachments';
import { exportMetadata, stampHtml, stampMarkdown } from '../model/ExportMetadata';

export async function selectAttachments(context: common.UIAbilityContext, photo: boolean, maximum: number): Promise<Attachment[]> {
  if (maximum < 1) { throw new Error(t("每条消息最多添加 4 个附件。")); }
  const uris = photo ? (await new photoAccessHelper.PhotoViewPicker().select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
    maxSelectNumber: maximum })).photoUris : await new picker.DocumentViewPicker(context).select({ maxSelectNumber: maximum, fileSuffixFilters: [t('资料|.txt,.md,.csv,.tsv,.json,.log,.pdf,.docx,.xlsx,.pptx')] });
  const result: Attachment[] = [];
  for (const uri of uris) { result.push(await Attachments.import(uri, photo)); }
  return result;
}

export async function exportFile(context: common.UIAbilityContext, source: string, name: string, aiAssisted: boolean = false): Promise<void> {
  const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
  if (!uris.length) { return; }
  const input = await fs.open(source, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    let bytes = await readBounded(input.fd, 20 * 1024 * 1024);
    if (aiAssisted && /\.(md|markdown|html|htm)$/i.test(name)) {
      const text = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(new Uint8Array(bytes));
      const metadata = exportMetadata(util.generateRandomUUID());
      bytes = new util.TextEncoder().encodeInto(/\.html?$/i.test(name) ? stampHtml(text, metadata) : stampMarkdown(text, metadata)).buffer as ArrayBuffer;
      if (bytes.byteLength > 20 * 1024 * 1024) { throw new Error(t('文件超出读取上限。')); }
    }
    await writeBytes(uris[0], bytes);
  }
  finally { await fs.close(input); }
}

export async function shareFile(context: common.UIAbilityContext, source: string, name: string): Promise<void> {
  // Share a stable copy: changes to a workspace file after confirmation cannot change shared bytes.
  const path = context.cacheDir + '/' + util.generateRandomUUID() + '-' + name.replace(/[^a-zA-Z0-9._\u4e00-\u9fff-]/g, '_').slice(-100);
  const input = await fs.open(source, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try { await writeBytes(path, await readBounded(input.fd, 20 * 1024 * 1024)); } finally { await fs.close(input); }
  const utd = /\.jpe?g$/i.test(name) ? 'general.jpeg' : /\.png$/i.test(name) ? 'general.png' :
    /\.md$/i.test(name) ? 'general.markdown' : /\.(txt|csv|json|log)$/i.test(name) ? 'general.plain-text' : 'general.file';
  await new systemShare.ShareController(new systemShare.SharedData({ utd: utd, uri: fileUri.getUriFromPath(path), title: name })).show(context, {});
}

export interface SharedInput { text: string; attachments: Attachment[]; error: string; }
export class ShareInbox {
  private static queue: SharedInput[] = [];
  private static listener?: () => void;
  static subscribe(listener: () => void): void { ShareInbox.listener = listener; if (ShareInbox.queue.length) { listener(); } }
  static peek(): SharedInput | undefined { return ShareInbox.queue[0]; }
  static take(): SharedInput | undefined { return ShareInbox.queue.shift(); }
  static async receive(want: Want, filesDir: string): Promise<void> {
    if (want.action !== 'ohos.want.action.sendData') { return; }
    Attachments.configure(filesDir);
    const input: SharedInput = { text: '', attachments: [], error: '' };
    try {
      const records = (await systemShare.getSharedData(want)).getRecords();
      if (records.length > 4) { throw new Error(t("一次最多接收 4 项分享内容。")); }
      for (const record of records) {
        if (record.content) { input.text += (input.text ? '\n\n' : '') + record.content; }
        if (record.uri) {
          if (!record.uri.startsWith('file://')) { throw new Error(t("分享文件需要系统授予的文件 URI。")); }
          const photo = ['general.image', 'general.jpeg', 'general.png', 'general.webp', 'general.heic'].includes(record.utd);
          input.attachments.push(await Attachments.import(record.uri, photo));
        }
      }
      if (input.text.length > 24000) { throw new Error(t("分享文本超过 24000 字符，请缩小内容。")); }
    } catch (error) { input.error = t('接收分享失败：') + (error as Error).message; }
    ShareInbox.queue.push(input); if (ShareInbox.listener) { ShareInbox.listener(); }
  }
}
