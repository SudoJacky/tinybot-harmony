import { image } from '@kit.ImageKit';
import { drawing } from '@kit.ArkGraphics2D';
import { AnnotationStroke } from '../model/BrowserAnnotation';

export async function renderBrowserAnnotation(source: image.PixelMap, strokes: AnnotationStroke[]): Promise<image.PixelMap> {
  const info = await source.getImageInfo();
  const scale = Math.min(1, 1600 / Math.max(info.size.width, info.size.height));
  const width = Math.max(1, Math.round(info.size.width * scale));
  const height = Math.max(1, Math.round(info.size.height * scale));
  const pixel = image.createEmptyPixelMap({ editable: true, pixelFormat: image.PixelMapFormat.RGBA_8888,
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
  } catch (error) { await pixel.release(); throw error as Error; }
}
