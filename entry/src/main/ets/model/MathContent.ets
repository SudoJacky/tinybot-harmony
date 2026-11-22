import { image } from '@kit.ImageKit';
export interface MathDimensions {
  width: number;
  height: number;
  descent: number;
}

export interface MathDrawing extends MathDimensions {
  svg: string;
}

export interface MathRequest {
  tex: string;
  display: boolean;
  color: string;
  emPixels: number;
}

export function mathBitmapSize(drawing: MathDimensions, emPixels: number): [number, number] {
  const width = drawing.width * emPixels;
  const height = drawing.height * emPixels;
  const scale = Math.min(1, 8192 / Math.max(width, height), Math.sqrt(2 * 1024 * 1024 / (width * height)));
  return [Math.max(1, Math.floor(width * scale)), Math.max(1, Math.floor(height * scale))];
}

export interface MathResponse extends MathDimensions {
  bytes: number;
  pixelMap?: image.PixelMap;
  error?: string;
  nativeCode?: number;
}
