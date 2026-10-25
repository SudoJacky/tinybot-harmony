import { image } from '@kit.ImageKit';
import { t } from '../model/I18n';

// image.createEmptyPixelMap() is API 26 only. createPixelMapSync() has provided the same
// empty-bitmap overload since API 12, so one call site covers both systems. That overload
// documents a possible undefined result instead of a throw, and every caller owns PixelMap
// release ordering, so a failure is converted into a normal error here rather than a null
// PixelMap leaking into export code.
export function createEmptyPixel(options: image.InitializationOptions): image.PixelMap {
  const pixel: image.PixelMap | undefined = image.createPixelMapSync(options);
  if (!pixel) { throw new Error(t('无法创建空白画布，请检查可用内存。')); }
  return pixel;
}
