import { util, worker, MessageEvents } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { mathBitmapSize, MathDrawing, MathRequest, MathResponse } from '../model/MathContent';
import { typesetMath } from './MathEngine';

const port = worker.workerPort;
const encoder = new util.TextEncoder();

async function rasterize(data: ArrayBuffer, drawing: MathDrawing, emPixels: number): Promise<image.PixelMap> {
  const size = mathBitmapSize(drawing, emPixels);
  const source = image.createImageSource(data);
  try {
    return source.createPixelMapSync({ desiredSize: { width: size[0], height: size[1] },
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
  } finally { await source.release(); }
}

port.onmessage = async (event: MessageEvents): Promise<void> => {
  const job = event.data as MathRequest;
  let response: MathResponse = { width: 0, height: 0, descent: 0, bytes: 0 };
  let drawing: MathDrawing;
  try {
    drawing = typesetMath(job.tex, job.display, job.color) as MathDrawing;
  } catch (_) {
    response.error = 'invalid_formula';
    port.postMessage(response);
    return;
  }
  const data = encoder.encodeInto(drawing.svg);
  if (data.byteLength > 256 * 1024) {
    response.error = 'formula_too_large';
    port.postMessage(response);
    return;
  }
  let bitmap: image.PixelMap | undefined;
  try {
    bitmap = await rasterize(data.buffer as ArrayBuffer, drawing, job.emPixels);
    const bytes = bitmap.getPixelBytesNumber();
    bitmap.setTransferDetached(true);
    response = { width: drawing.width, height: drawing.height, descent: drawing.descent, bytes: bytes, pixelMap: bitmap };
  } catch (error) {
    await bitmap?.release();
    response.error = 'rasterize_failed';
    response.nativeCode = (error as BusinessError).code;
  }
  port.postMessage(response);
};
