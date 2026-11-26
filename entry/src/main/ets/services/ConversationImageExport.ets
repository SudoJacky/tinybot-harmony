import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { common2D, drawing } from '@kit.ArkGraphics2D';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Diagnostics } from '../model/Diagnostics';
import { ConversationSection } from '../model/ConversationExport';
import { Attachment } from '../model/Productivity';
import { exportMetadata, stampPng } from '../model/ExportMetadata';
import { t } from '../model/I18n';
import { Attachments, writeBytes } from './Attachments';
import { createEmptyPixel } from './EmptyPixel';

const MAX_PIXELS = 24 * 1024 * 1024;
const MAX_BYTES = 20 * 1024 * 1024;
const MAX_BUFFERED_BYTES = 16 * 1024 * 1024;
interface CapturedSection { height: number; path: string; pixel?: image.PixelMap; }
export interface ConversationImage { path: string; width: number; height: number; }

async function pack(pixel: image.PixelMap): Promise<ArrayBuffer> {
  const packer = image.createImagePacker();
  try { return await packer.packToData(pixel, { format: 'image/png', quality: 100 }); }
  finally { await packer.release(); }
}

async function attachmentRatio(attachment: Attachment): Promise<number> {
  const file = await fs.open(Attachments.path(attachment), fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const source = image.createImageSource(file.fd);
    try {
      const size = (await source.getImageInfo()).size;
      if (size.width <= 0 || size.height <= 0) { throw new Error(t('会话图片尺寸无效，未导出。')); }
      return size.height / size.width;
    } finally { await source.release(); }
  } finally { await fs.close(file); }
}

async function drawSection(canvas: drawing.Canvas, section: CapturedSection, top: number, width: number): Promise<void> {
  const rect: common2D.Rect = { left: 0, top: top, right: width, bottom: top + section.height };
  if (section.pixel) {
    const pixel = section.pixel;
    canvas.drawImageRect(pixel, rect);
    section.pixel = undefined;
    await pixel.release();
    return;
  }
  const file = await fs.open(section.path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
  try {
    const source = image.createImageSource(file.fd);
    try {
      const pixel = await source.createPixelMap();
      try { canvas.drawImageRect(pixel, rect); }
      finally { await pixel.release(); }
    } finally { await source.release(); }
  } finally { await fs.close(file); }
}

// Keep common exports in memory and bound the extra bitmap memory needed to stitch long exports.
export async function conversationImage(context: common.UIAbilityContext, sections: ConversationSection[],
  capture: (section: ConversationSection) => Promise<image.PixelMap>, background: number = 0xffffffff): Promise<ConversationImage> {
  const id = util.generateRandomUUID();
  const captures: CapturedSection[] = [];
  let result: image.PixelMap | undefined;
  let complete = false;
  let stage = 'capture';
  let currentSection = -1;
  const output = context.cacheDir + '/conversation-' + id + '.png';
  try {
    let height = 0;
    let width = 0;
    let bufferedBytes = 0;
    for (const section of sections) {
      currentSection++;
      if (section.kind === 'attachment-image' && section.imageRatio === undefined) {
        section.imageRatio = await attachmentRatio(section.attachment!);
      }
      const pixel = await capture(section);
      let retained = false;
      try {
        const info = await pixel.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0 || (width && info.size.width !== width)) {
          throw new Error(t('会话图片尺寸无效，未导出。'));
        }
        width = info.size.width; height += info.size.height;
        if (width * height > MAX_PIXELS) { throw new Error(t('会话过长，无法导出为一张图片；请导出 Markdown。')); }
        const bytes = pixel.getPixelBytesNumber();
        if (bufferedBytes + bytes <= MAX_BUFFERED_BYTES) {
          captures.push({ height: info.size.height, path: '', pixel: pixel });
          bufferedBytes += bytes;
          retained = true;
        } else {
          const path = context.cacheDir + '/conversation-' + id + '-' + captures.length + '.png';
          captures.push({ height: info.size.height, path: path });
          await writeBytes(path, await pack(pixel));
        }
      } finally { if (!retained) { await pixel.release(); } }
    }
    if (!width || !height) { throw new Error(t('会话图片尺寸无效，未导出。')); }
    stage = 'compose';
    result = createEmptyPixel({ editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE, size: { width: width, height: height } });
    const canvas = new drawing.Canvas(result);
    canvas.drawColor(255, (background >>> 16) & 255, (background >>> 8) & 255, background & 255);
    let top = 0;
    currentSection = -1;
    for (const section of captures) {
      currentSection++;
      await drawSection(canvas, section, top, width);
      top += section.height;
    }
    stage = 'encode';
    const bytes = stampPng(new Uint8Array(await pack(result)),
      new util.TextEncoder().encodeInto(JSON.stringify(exportMetadata(id))));
    if (bytes.byteLength > MAX_BYTES) { throw new Error(t('会话图片超过 20 MB，请导出 Markdown。')); }
    await writeBytes(output, bytes.buffer as ArrayBuffer);
    complete = true;
    return { path: output, width: width, height: height };
  } catch (error) {
    const failure = error as BusinessError;
    Diagnostics.log('error', 'export', 'image_failed',
      { phase: stage, chunk: currentSection, code: failure.code || 0 }, error as Error);
    throw error as Error;
  } finally {
    await result?.release();
    for (const section of captures) {
      await section.pixel?.release();
      if (section.path && await fs.access(section.path)) { await fs.unlink(section.path); }
    }
    if (!complete && await fs.access(output)) { await fs.unlink(output); }
  }
}
