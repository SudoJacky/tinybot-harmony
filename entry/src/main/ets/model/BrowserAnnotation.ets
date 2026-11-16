export interface AnnotationPoint { x: number; y: number; }
export interface AnnotationStroke { points: AnnotationPoint[]; width: number; }
export interface BrowserElementMark extends AnnotationPoint { width: number; height: number; label: string; location: string; }
export interface BrowserPropertyChange { property: string; before: string; after: string; }
export interface AnnotationPage { url: string; title: string; element?: BrowserElementMark; tag?: string; changes?: BrowserPropertyChange[]; }

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
  markElement(element: BrowserElementMark): void {
    const right = element.x + element.width, bottom = element.y + element.height;
    this.begin(element.x, element.y, 0.003);
    this.move(right, element.y); this.move(right, bottom); this.move(element.x, bottom); this.move(element.x, element.y);
    this.end();
  }
  dirty(): boolean { return this.strokes.length > 0 || this.note.trim().length > 0; }
}
