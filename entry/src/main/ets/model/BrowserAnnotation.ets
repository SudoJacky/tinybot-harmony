import { t } from './I18n';

export interface AnnotationPoint { x: number; y: number; }
export interface AnnotationStroke { points: AnnotationPoint[]; width: number; }
export interface AnnotationPage { url: string; title: string; }

// Coordinates are relative to the captured image, so resizing never moves a mark.
@Observed
export class BrowserAnnotation {
  note: string = '';
  strokes: AnnotationStroke[] = [];
  saving: boolean = false;
  private active?: AnnotationStroke;
  begin(x: number, y: number, width: number): void {
    this.active = { points: [{ x: x, y: y }], width: width };
    this.strokes = this.strokes.concat([this.active]);
  }
  move(x: number, y: number): void { this.active?.points.push({ x: x, y: y }); }
  end(): void { this.active = undefined; }
  undo(): void { this.end(); this.strokes = this.strokes.slice(0, -1); }
  clear(): void { this.end(); this.strokes = []; }
  dirty(): boolean { return this.strokes.length > 0 || this.note.trim().length > 0; }
}

export function browserAnnotationText(page: AnnotationPage, note: string): string {
  return t('网页批注：{0}\n网址：{1}\n附件是批注时的当前可见区域截图，红色笔迹为用户标记。\n{2}',
    [page.title || page.url, page.url, note.trim()]);
}
