import { t } from '../model/I18n';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { util } from '@kit.ArkTS';
import { Attachment, validateAttachments } from '../model/Productivity';
import { ModelMessage } from '../model/Agent';
import { copyFileBytes, readBounded, writeBytes } from './FileBytes';
import { WorkspaceStore } from '../model/WorkspaceStore';
import { NativeWorkspaceFiles } from './NativeWorkspaceFiles';
import { attachmentContext } from '../model/AttachmentContext';
import { createEmptyPixel } from './EmptyPixel';

export class Attachments {
  private static root: string = '';
  private static filesDir: string = '';
  static configure(filesDir: string): void { Attachments.filesDir = filesDir; Attachments.root = filesDir + '/attachments'; }
  static path(item: Attachment): string {
    validateAttachments([item]);
    return item.original && item.workspaceId ? new WorkspaceStore(Attachments.filesDir).pathFor(item.workspaceId) + '/' + item.path :
      Attachments.root + '/' + item.path;
  }
  static async inWorkspace(items: Attachment[], workspaceId: string): Promise<Attachment[]> {
    validateAttachments(items);
    const workspace = new WorkspaceStore(Attachments.filesDir);
    const files = new NativeWorkspaceFiles(workspace.pathFor(workspaceId));
    const result: Attachment[] = [];
    for (const item of items) {
      if (!item.original || item.workspaceId === workspaceId) { result.push(item); continue; }
      // Forks retain the same relative path. Existing copies must still match the original bytes.
      await files.importFile(Attachments.path(item), item.path, true);
      result.push({ id: item.id, name: item.name, mime: item.mime, size: item.size, path: item.path, original: true, workspaceId: workspaceId });
    }
    return result;
  }
  static async savePreview(pixel: image.PixelMap): Promise<Attachment> {
    return Attachments.saveImage(pixel, 'Preview screenshot.jpg');
  }
  static saveBrowserAnnotation(pixel: image.PixelMap): Promise<Attachment> {
    return Attachments.saveImage(pixel, t('网页批注.jpg'));
  }
  static async saveDrawing(pixel: image.PixelMap): Promise<Attachment> {
    const info = await pixel.getImageInfo();
    const scale = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
    if (scale < 1) { await pixel.scale(scale, scale); }
    const opaque = createEmptyPixel({ editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE, size: {
        width: Math.max(1, Math.round(info.size.width * scale)), height: Math.max(1, Math.round(info.size.height * scale)) } });
    try {
      // Pen Kit exports transparent ink; JPEG needs a solid background to keep black strokes visible.
      const canvas = new drawing.Canvas(opaque);
      canvas.drawColor(255, 255, 255, 255); canvas.drawImage(pixel, 0, 0);
      return await Attachments.saveImage(opaque, t('手绘示意.jpg'));
    } finally { await opaque.release(); }
  }
  private static async saveImage(pixel: image.PixelMap, name: string): Promise<Attachment> {
    if (!Attachments.root) { throw new Error(t('附件存储尚未就绪。')); }
    if (!await fs.access(Attachments.root)) { await fs.mkdir(Attachments.root); }
    const info = await pixel.getImageInfo();
    const scale = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
    if (scale < 1) { await pixel.scale(scale, scale); }
    const packer = image.createImagePacker();
    let bytes: ArrayBuffer;
    try { bytes = await packer.packing(pixel, { format: 'image/jpeg', quality: 85 }); }
    finally { await packer.release(); }
    if (bytes.byteLength > 4 * 1024 * 1024) { throw new Error(t('压缩后图片仍超过 4 MB。')); }
    const id = util.generateRandomUUID();
    const item: Attachment = { id: id, name: name, mime: 'image/jpeg', path: id + '.jpg', size: bytes.byteLength };
    await writeBytes(Attachments.path(item), bytes);
    return item;
  }
  static async import(uri: string, photo: boolean): Promise<Attachment> {
    if (!Attachments.root) { throw new Error(t("附件存储尚未就绪。")); }
    if (!await fs.access(Attachments.root)) { await fs.mkdir(Attachments.root); }
    const id = util.generateRandomUUID();
    let name = uri.slice(uri.lastIndexOf('/') + 1).split('?')[0];
    try { name = decodeURIComponent(name); } catch (_) { /* Keep literal URI name. */ }
    name = name.replace(/[\\/:*?"<>|\u0000-\u001f\u007f]/g, '_').slice(-200);
    if (!name || ['.', '..'].includes(name) || name.startsWith('.tinybot-')) { name = 'file'; }
    if (!photo) {
      const relative = 'attachments/' + id + '/' + name;
      await fs.mkdir(Attachments.root + '/attachments/' + id, true);
      const size = await copyFileBytes(uri, Attachments.root + '/' + relative);
      const mime = /\.pdf$/i.test(name) ? 'application/pdf' : /\.docx$/i.test(name) ?
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' : /\.xlsx$/i.test(name) ?
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : /\.pptx$/i.test(name) ?
        'application/vnd.openxmlformats-officedocument.presentationml.presentation' : 'application/octet-stream';
      return { id: id, name: name, mime: mime, path: relative, size: size, original: true };
    }
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = await fs.stat(file.fd);
      if (!stat.isFile()) { throw new Error(t('请选择普通文件。')); }
      if (stat.size > 20 * 1024 * 1024) { throw new Error(t('图片最多 20 MB。')); }
      let bytes: ArrayBuffer;
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
      if (bytes.byteLength > 4 * 1024 * 1024) { throw new Error(t("压缩后图片仍超过 4 MB。")); }
      const item: Attachment = { id: id, name: name,
        mime: 'image/jpeg', path: id + '.jpg', size: bytes.byteLength };
      await writeBytes(Attachments.path(item), bytes); return item;
    } finally { await fs.close(file); }
  }
  static async hydrate(messages: ModelMessage[]): Promise<ModelMessage[]> {
    const result: ModelMessage[] = [];
    for (const original of messages) {
      const message = JSON.parse(JSON.stringify(original)) as ModelMessage;
      message.images = [];
      for (const item of message.attachments || []) {
        if (item.original || item.mime === 'text/plain') { message.content += attachmentContext(item); }
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

export { readBounded, writeBytes } from './FileBytes';
