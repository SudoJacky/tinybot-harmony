import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Diagnostics } from '../model/Diagnostics';
import { ConversationSection } from '../model/ConversationExport';
import { exportMetadata, stampPng } from '../model/ExportMetadata';
import { t } from '../model/I18n';
import { writeBytes } from './Attachments';

const MAX_PIXELS = 24 * 1024 * 1024;
const MAX_BYTES = 20 * 1024 * 1024;
interface CapturedSection { path: string; width: number; height: number; }
async function pack(pixel: image.PixelMap): Promise<ArrayBuffer> {
  const packer = image.createImagePacker();
  try { return await packer.packToData(pixel, { format: 'image/png', quality: 100 }); }
  finally { await packer.release(); }
}

// Capture bounded sections to disk, then stitch them. GPU snapshot limits and
// virtualized chat rows must never turn a full-conversation export into a crop.
export async function conversationImage(context: common.UIAbilityContext, sections: ConversationSection[],
  capture: (section: ConversationSection) => Promise<image.PixelMap>, background: number = 0xffffffff): Promise<string> {
  const id = util.generateRandomUUID();
  const paths: string[] = [];
  const captures: CapturedSection[] = [];
  let result: image.PixelMap | undefined;
  let complete = false;
  let stage = 'capture';
  let currentSection = -1;
  const output = context.cacheDir + '/conversation-' + id + '.png';
  try {
    let height = 0; let width = 0;
    for (const section of sections) {
      currentSection++;
      const pixel = await capture(section);
      try {
        const info = await pixel.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0 || (width && info.size.width !== width)) {
          throw new Error(t('会话图片尺寸无效，未导出。'));
        }
        width = info.size.width; height += info.size.height;
        if (width * height > MAX_PIXELS) { throw new Error(t('会话过长，无法导出为一张图片；请导出 Markdown。')); }
        const path = context.cacheDir + '/conversation-' + id + '-' + captures.length + '.png';
        paths.push(path); await writeBytes(path, await pack(pixel));
        captures.push({ path: path, width: width, height: info.size.height });
      } finally { await pixel.release(); }
    }
    if (!width || !height) { throw new Error(t('会话图片尺寸无效，未导出。')); }
    stage = 'compose';
    result = image.createEmptyPixelMap({ editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.OPAQUE, size: { width: width, height: height } });
    const canvas = new drawing.Canvas(result);
    canvas.drawColor(255, (background >>> 16) & 255, (background >>> 8) & 255, background & 255);
    let top = 0;
    for (const section of captures) {
      const file = await fs.open(section.path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const source = image.createImageSource(file.fd);
        try {
          const pixel = await source.createPixelMap();
          try { canvas.drawImageRect(pixel, { left: 0, top: top, right: width, bottom: top + section.height }); }
          finally { await pixel.release(); }
        } finally { await source.release(); }
      } finally { await fs.close(file); }
      top += section.height;
    }
    stage = 'encode';
    // Add AI Metadata
    const bytes = stampPng(new Uint8Array(await pack(result)),
      new util.TextEncoder().encodeInto(JSON.stringify(exportMetadata(id))));
    if (bytes.byteLength > MAX_BYTES) { throw new Error(t('会话图片超过 20 MB，请导出 Markdown。')); }
    paths.push(output); await writeBytes(output, bytes.buffer as ArrayBuffer); complete = true;
    return output;
  } catch (error) {
    const failure = error as BusinessError;
    Diagnostics.log('error', 'export', 'image_failed',
      { phase: stage, chunk: currentSection, code: failure.code || 0 }, error as Error);
    throw error as Error;
  } finally {
    await result?.release();
    for (const path of paths) { if ((!complete || path !== output) && await fs.access(path)) { await fs.unlink(path); } }
  }
}
