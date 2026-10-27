import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { readBounded, writeBytes } from './Attachments';
import { FeedbackAttachment, FeedbackUpload, redactFeedbackLog } from '../model/Feedback';
import { t } from '../model/I18n';
import { formatFeedbackLog } from '../model/RecentDiagnosticLog';
import { recentDiagnosticLogs } from './NativeDiagnosticLog';
import { readAppInformation } from './AppInformation';

// Private copies stay outside workspaces, conversations and their backups. No original log is uploaded.
export class FeedbackFiles {
  private static root: string = '';
  static configure(context: common.Context): void { FeedbackFiles.root = context.filesDir + '/feedback-files'; }
  private static async save(bytes: ArrayBuffer, kind: 'image' | 'log', suffix: string): Promise<FeedbackUpload> {
    if (!FeedbackFiles.root) { throw new Error(t('反馈尚未就绪，请重新打开页面。')); }
    if (!await fs.access(FeedbackFiles.root)) { await fs.mkdir(FeedbackFiles.root); }
    const id = util.generateRandomUUID(); const filename = (kind === 'image' ? 'screenshot-' : 'log-') + id + suffix;
    const path = FeedbackFiles.root + '/' + filename;
    await writeBytes(path, bytes);
    return { localId: id, kind: kind, filename: filename, mimeType: kind === 'image' ? 'image/jpeg' : 'text/plain; charset=utf-8',
      size: bytes.byteLength, path: path, state: 'pending', remoteId: '', beforeIds: [], error: '' };
  }
  static async pickImages(maximum: number): Promise<FeedbackUpload[]> {
    const uris = (await new photoAccessHelper.PhotoViewPicker().select({ MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: maximum })).photoUris;
    const result: FeedbackUpload[] = [];
    try {
      for (const uri of uris) {
        const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
        let bytes: ArrayBuffer;
        try { bytes = await readBounded(file.fd, 5 * 1024 * 1024); } finally { await fs.close(file); }
        const source = image.createImageSource(bytes);
        try {
          const info = await source.getImageInfo();
          if (info.size.width * info.size.height > 24000000) { throw new Error(t('图片最多 2,400 万像素，请先缩小。')); }
          const pixel = await source.createPixelMap(); const packer = image.createImagePacker();
          try { bytes = await packer.packing(pixel, { format: 'image/jpeg', quality: 90 }); }
          finally { await packer.release(); await pixel.release(); }
        } finally { await source.release(); }
        if (!bytes.byteLength || bytes.byteLength > 5 * 1024 * 1024) { throw new Error(t('每张图片最多 5 MiB，请先缩小。')); }
        result.push(await FeedbackFiles.save(bytes, 'image', '.jpg'));
      }
      return result;
    } catch (error) {
      for (const file of result) { await FeedbackFiles.remove(file.path); }
      throw error as Error;
    }
  }
  static collectLog(): string {
    const info = readAppInformation();
    return formatFeedbackLog(recentDiagnosticLogs(), { versionName: info.versionName, versionCode: info.versionCode });
  }
  static async saveLog(text: string): Promise<FeedbackUpload> {
    if (text.length > 2 * 1024 * 1024) { throw new Error(t('日志最多 2 MiB。')); }
    const bytes = new util.TextEncoder().encodeInto(redactFeedbackLog(text));
    if (bytes.byteLength > 2 * 1024 * 1024) { throw new Error(t('日志最多 2 MiB。')); }
    return FeedbackFiles.save(bytes.buffer as ArrayBuffer, 'log', '.log');
  }
  static async read(file: FeedbackUpload): Promise<ArrayBuffer> {
    FeedbackFiles.requirePath(file.path);
    const input = await fs.open(file.path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try { return await readBounded(input.fd, file.kind === 'image' ? 5 * 1024 * 1024 : 2 * 1024 * 1024); }
    finally { await fs.close(input); }
  }
  static logText(bytes: ArrayBuffer): string { return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes)); }
  static async cache(file: FeedbackAttachment, bytes: ArrayBuffer): Promise<string> {
    if (!await fs.access(FeedbackFiles.root)) { await fs.mkdir(FeedbackFiles.root); }
    const path = FeedbackFiles.root + '/preview-' + file.id + (file.kind === 'image' ? '.webp' : '.log');
    await writeBytes(path, bytes); return path;
  }
  private static requirePath(path: string): void {
    if (!FeedbackFiles.root || !path.startsWith(FeedbackFiles.root + '/') || /[\\/]/.test(path.slice(FeedbackFiles.root.length + 1))) {
      throw new Error(t('反馈附件路径无效，请重新选择。'));
    }
  }
  static async remove(path: string): Promise<void> {
    FeedbackFiles.requirePath(path);
    if (await fs.access(path)) { await fs.unlink(path); }
  }
}
