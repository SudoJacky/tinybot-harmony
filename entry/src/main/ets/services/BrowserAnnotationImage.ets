import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { AnnotationPage, AnnotationStroke, BrowserAnnotation } from '../model/BrowserAnnotation';
import { Diagnostics } from '../model/Diagnostics';
import { createEmptyPixel } from './EmptyPixel';
import { NativeBrowserCapture } from './NativeBrowserDriver';

export type BrowserDraftDestination = 'screenshot' | 'note' | 'editor';

export async function releaseAnnotationPixel(pixel?: image.PixelMap): Promise<void> {
  if (!pixel) { return; }
  try { await pixel.release(); }
  catch (error) { Diagnostics.log('error', 'browser', 'annotation_failed', undefined, error as Error); }
}

export async function submitBrowserAnnotation(source: image.PixelMap, draft: BrowserAnnotation,
  submit: (pixel: image.PixelMap, note: string) => Promise<void>): Promise<void> {
  const note = draft.note;
  const rendered = await renderBrowserAnnotation(source, draft.strokes);
  try { await submit(rendered, note); }
  finally { await releaseAnnotationPixel(rendered); }
}

// The capture is borrowed during submission and transferred only to the annotation editor.
export async function captureBrowserDraft(captureAfterTakeover: () => Promise<NativeBrowserCapture>, isCurrent: () => boolean,
  destination: BrowserDraftDestination, note: string,
  submit: (pixel: image.PixelMap, page: AnnotationPage | undefined, note: string) => Promise<void>,
  openEditor: (capture: NativeBrowserCapture, draft: BrowserAnnotation) => void): Promise<boolean> {
  let capture: NativeBrowserCapture | undefined = await captureAfterTakeover();
  try {
    if (!isCurrent()) { return false; }
    if (destination === 'screenshot') {
      await submit(capture.pixel, undefined, '');
      return true;
    }
    const draft = new BrowserAnnotation(); draft.note = note;
    if (capture.element) { draft.markElement(capture.element); }
    if (destination === 'note') {
      const page = capture;
      await submitBrowserAnnotation(page.pixel, draft, (pixel, text) => submit(pixel, page, text));
      return true;
    }
    openEditor(capture, draft);
    capture = undefined;
    return true;
  } finally { await releaseAnnotationPixel(capture?.pixel); }
}

export async function renderBrowserAnnotation(source: image.PixelMap, strokes: AnnotationStroke[]): Promise<image.PixelMap> {
  const info = await source.getImageInfo();
  const scale = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
  const width = Math.max(1, Math.round(info.size.width * scale));
  const height = Math.max(1, Math.round(info.size.height * scale));
  const pixel = createEmptyPixel({ editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
    alphaType: image.AlphaType.OPAQUE, size: { width: width, height: height } });
  try {
    const canvas = new drawing.Canvas(pixel);
    canvas.drawColor(255, 255, 255, 255);
    canvas.drawImageRect(source, { left: 0, top: 0, right: width, bottom: height });
    const pen = new drawing.Pen();
    pen.setColor(255, 229, 57, 53); pen.setAntiAlias(true); pen.setCapStyle(drawing.CapStyle.ROUND_CAP);
    for (const stroke of strokes) {
      if (!stroke.points.length) { continue; }
      const path = new drawing.Path(); const first = stroke.points[0];
      path.moveTo(first.x * width, first.y * height);
      // A tap is a dot, using the same round cap as a longer stroke.
      path.lineTo(first.x * width + 0.01, first.y * height);
      for (const point of stroke.points.slice(1)) { path.lineTo(point.x * width, point.y * height); }
      pen.setStrokeWidth(stroke.width * width); canvas.attachPen(pen); canvas.drawPath(path); canvas.detachPen();
    }
    return pixel;
  } catch (error) { await releaseAnnotationPixel(pixel); throw error as Error; }
}
