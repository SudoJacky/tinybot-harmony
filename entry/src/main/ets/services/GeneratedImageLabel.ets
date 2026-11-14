import { drawing, text } from '@kit.ArkGraphics2D';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { Diagnostics } from '../model/Diagnostics';
import { embedGeneratedImageXmp, generatedImageXmp } from '../model/GeneratedImageMetadata';
import { ToolFailure } from '../model/ToolFailure';
import { Cancellation } from './Cancellation';

const MAX_PIXELS = 24 * 1024 * 1024;
const LABEL = 'AI生成';

function labelLine(fontSize: number, shade: number = 255): text.TextLine {
  const builder = new text.ParagraphBuilder({}, text.FontCollection.getGlobalInstance());
  builder.pushStyle({ fontSize: fontSize, fontWeight: text.FontWeight.W600,
    color: { alpha: 255, red: shade, green: shade, blue: shade } });
  builder.addText(LABEL);
  return builder.buildLineTypeset().createLine(0, 0);
}

function drawLabel(pixel: image.PixelMap, width: number, height: number): void {
  const shortest = Math.min(width, height);
  const minimumHeight = Math.ceil(shortest * 0.05);
  let fontSize = Math.ceil(minimumHeight * 1.2);
  let line = labelLine(fontSize);
  let bounds = line.getImageBounds();
  const measuredHeight = bounds.bottom - bounds.top;
  if (measuredHeight > 0 && measuredHeight < minimumHeight) {
    fontSize = Math.ceil(fontSize * (minimumHeight + 1) / measuredHeight);
    line = labelLine(fontSize);
    bounds = line.getImageBounds();
  }
  const outlineWidth = Math.max(1, Math.round(minimumHeight * 0.045));
  const margin = Math.max(1, Math.ceil(shortest * 0.02)) + outlineWidth;
  const x = width - margin - bounds.right;
  const y = height - margin - bounds.bottom;
  const left = x + bounds.left - outlineWidth;
  const top = y + bounds.top - outlineWidth;
  if (bounds.bottom - bounds.top < minimumHeight || bounds.right <= bounds.left || left < 0 || top < 0) {
    throw new Error('The AI label does not fit the image.');
  }
  const canvas = new drawing.Canvas(pixel);
  // Paint the outline with the same shaped glyphs so Chinese font fallback matches the fill.
  const outline = labelLine(fontSize, 24);
  for (let i = 0; i < 8; i++) {
    const angle = i * Math.PI / 4;
    outline.paint(canvas, x + Math.cos(angle) * outlineWidth, y + Math.sin(angle) * outlineWidth);
  }
  line.paint(canvas, x, y);
}

export async function labelGeneratedImage(bytes: Uint8Array, mime: string, id: string,
  cancellation: Cancellation): Promise<Uint8Array> {
  let stage = 'decode';
  let source: image.ImageSource | undefined;
  let pixel: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  try {
    cancellation.check();
    const data = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes.buffer :
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    source = image.createImageSource(data as ArrayBuffer);
    const info = await source.getImageInfo();
    const frameCount = await source.getFrameCount();
    if (info.size.width * info.size.height > MAX_PIXELS || frameCount !== 1) {
      throw new ToolFailure('INVALID_RESPONSE', 'The image service must return a single image within the pixel limit.', 'inspect_service');
    }
    cancellation.check();
    pixel = await source.createPixelMap({ editable: true, desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
    const size = (await pixel.getImageInfo()).size;
    cancellation.check();
    stage = 'draw';
    drawLabel(pixel, size.width, size.height);
    stage = 'encode';
    packer = image.createImagePacker();
    const packed = new Uint8Array(await packer.packToData(pixel, { format: mime, quality: 95 }));
    cancellation.check();
    stage = 'metadata';
    const xmp = new util.TextEncoder().encodeInto(generatedImageXmp(id));
    return embedGeneratedImageXmp(packed, mime, xmp, size.width, size.height);
  } catch (error) {
    cancellation.check();
    const failure = error as BusinessError;
    Diagnostics.log('warn', 'image-generation', 'label_failed', { phase: stage, format: mime }, failure);
    if (error instanceof ToolFailure) { throw error; }
    throw new ToolFailure('EXECUTION_FAILED', 'Could not apply the required AI label to the generated image.',
      'inspect_result_before_retry', { nativeCode: failure.code });
  } finally {
    if (packer) { await packer.release(); }
    if (pixel) { await pixel.release(); }
    if (source) { await source.release(); }
  }
}
