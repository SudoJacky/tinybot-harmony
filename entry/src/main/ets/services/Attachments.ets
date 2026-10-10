import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { Attachment, validateAttachments } from '../model/Productivity';
import { ModelMessage } from '../model/Agent';
import { officeText, pdfText } from './DocumentText';
import { readUtf8File } from './TextFiles';
import { attachmentContext } from '../model/AttachmentContext';

export class Attachments {
  private static root: string = '';
  static configure(filesDir: string): void { Attachments.root = filesDir + '/attachments'; }
  static path(item: Attachment): string { validateAttachments([item]); return Attachments.root + '/' + item.path; }
  static async import(uri: string, photo: boolean): Promise<Attachment> {
    if (!Attachments.root) { throw new Error(t("附件存储尚未就绪。")); }
    if (!await fs.access(Attachments.root)) { await fs.mkdir(Attachments.root); }
    const id = util.generateRandomUUID();
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const document = !photo && /\.(pdf|docx|xlsx|pptx)(?:\?|$)/i.test(uri);
      const stat = await fs.stat(file.fd);
      if (!stat.isFile()) { throw new Error(t('请选择普通文件。')); }
      if ((photo && stat.size > 20 * 1024 * 1024) || (document && stat.size > 8 * 1024 * 1024)) { throw new Error(t('图片最多 20 MB，文档最多 8 MB。')); }
      let bytes: ArrayBuffer;
      let text: string | undefined;
      if (photo) {
        const source = image.createImageSource(file.fd);
        try {
          const info = await source.getImageInfo();
          if (info.size.width * info.size.height > 80000000) { throw new Error(t("图片像素过大，请先缩小。")); }
          const scale = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
          const pixel = await source.createPixelMap({ desiredSize: {
            width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) } });
          const packer = image.createImagePacker();
          try { bytes = await packer.packing(pixel, { format: 'image/jpeg', quality: 85 }); }
          finally { await packer.release(); await pixel.release(); }
        } finally { await source.release(); }
      } else if (document) {
        const source = await readBounded(file.fd, 8 * 1024 * 1024);
        if (/\.pdf(?:\?|$)/i.test(uri)) {
          const temporary = Attachments.root + '/extract-' + id + '.pdf'; await writeBytes(temporary, source);
          try { text = pdfText(temporary); } finally { await fs.unlink(temporary); }
        } else { text = await officeText(source); }
        bytes = new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer;
      } else {
        text = await readUtf8File(file.fd);
        bytes = text.length ? new util.TextEncoder().encodeInto(text).buffer as ArrayBuffer : new ArrayBuffer(0);
      }
      if (photo && bytes.byteLength > 4 * 1024 * 1024) { throw new Error(t("压缩后图片仍超过 4 MB。")); }
      let name = uri.slice(uri.lastIndexOf('/') + 1).split('?')[0];
      try { name = decodeURIComponent(name); } catch (_) { /* Keep literal URI name. */ }
      const item: Attachment = { id: id, name: (name || (photo ? '图片' : '文本')).slice(0, 200),
        mime: photo ? 'image/jpeg' : 'text/plain', path: id + (photo ? '.jpg' : '.txt'), size: bytes.byteLength, text: text };
      await writeBytes(Attachments.path(item), bytes); return item;
    } finally { await fs.close(file); }
  }
  static async hydrate(messages: ModelMessage[]): Promise<ModelMessage[]> {
    const result: ModelMessage[] = [];
    for (const original of messages) {
      const message = JSON.parse(JSON.stringify(original)) as ModelMessage;
      message.images = [];
      for (const item of message.attachments || []) {
        if (item.mime === 'text/plain') { message.content += attachmentContext(item); }
        else {
          const file = await fs.open(Attachments.path(item), fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
          try { message.images.push('data:image/jpeg;base64,' + new util.Base64Helper().encodeToStringSync(new Uint8Array(await readBounded(file.fd, 4 * 1024 * 1024)))); }
          finally { await fs.close(file); }
        }
      }
      result.push(message);
    }
    return result;
  }
}

export async function readBounded(fd: number, maximum: number): Promise<ArrayBuffer> {
  const stat = await fs.stat(fd);
  if (!stat.isFile() || stat.size > maximum) { throw new Error(t("文件超出读取上限。")); }
  const bytes = new Uint8Array(maximum + 1); let length = 0;
  while (length < bytes.length) {
    const buffer = new ArrayBuffer(bytes.length - length); const count = await fs.read(fd, buffer);
    if (count === 0) { break; } bytes.set(new Uint8Array(buffer, 0, count), length); length += count;
  }
  if (length > maximum) { throw new Error(t("文件超出读取上限。")); }
  return bytes.buffer.slice(0, length);
}

export async function writeBytes(path: string, bytes: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    let offset = 0;
    while (offset < bytes.byteLength) {
      const count = await fs.write(file.fd, bytes.slice(offset), { offset: offset });
      if (count <= 0) { throw new Error(t("文件写入未完成。")); } offset += count;
    }
    await fs.fsync(file.fd);
  } finally { await fs.close(file); }
}
