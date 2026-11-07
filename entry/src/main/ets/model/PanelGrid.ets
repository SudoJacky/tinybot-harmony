import { PanelRect } from './PanelPresentation';
export interface GridRect { x: number; y: number; w: number; h: number; }
export const GRID_COLUMNS: number = 12;
export const GRID_GAP: number = 12;
export const GRID_ROW_HEIGHT: number = 32;
export const GRID_ROW_STEP: number = GRID_ROW_HEIGHT + GRID_GAP;
export const GRID_MAX_ROWS: number = 33;
export function gridStep(width: number): number { return (width + GRID_GAP) / GRID_COLUMNS; }
export function gridPixels(rect: GridRect, width: number): PanelRect {
  const step = gridStep(width);
  return { x: rect.x * step, y: rect.y * GRID_ROW_STEP, width: rect.w * step - GRID_GAP, height: rect.h * GRID_ROW_STEP - GRID_GAP };
}
export function gridOverlap(a: GridRect, b: GridRect): boolean {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}
export function validateGridRect(rect: GridRect): void {
  if (![rect.x, rect.y, rect.w, rect.h].every((value: number) => Number.isSafeInteger(value)) ||
    rect.x < 0 || rect.y < 0 || rect.w < 2 || rect.w > GRID_COLUMNS || rect.h < 2 || rect.h > GRID_MAX_ROWS || rect.x + rect.w > GRID_COLUMNS) {
    throw new Error('Invalid grid rectangle: use nonnegative coordinates, width 2–12 and height 2–33');
  }
}
export function gridSnap(origin: GridRect, dx: number, dy: number, width: number, resize: boolean): GridRect {
  const step = gridStep(width);
  return resize ? { x: origin.x, y: origin.y,
    w: Math.max(2, Math.min(12 - origin.x, Math.round(origin.w + dx / step))),
    h: Math.max(2, Math.min(GRID_MAX_ROWS, Math.round(origin.h + dy / GRID_ROW_STEP))) } :
    { x: Math.max(0, Math.min(12 - origin.w, Math.round(origin.x + dx / step))),
      y: Math.max(0, Math.round(origin.y + dy / GRID_ROW_STEP)), w: origin.w, h: origin.h };
}
// Pin the user's rectangle. Push collisions down in their original spatial order,
// retaining all other x coordinates and intentional empty space.
export function gridPlace(rects: GridRect[], active: number, target: GridRect): GridRect[] {
  validateGridRect(target);
  if (active < 0 || active >= rects.length) { throw new Error('Card no longer belongs to this board'); }
  const result = rects.map((rect: GridRect): GridRect => ({ x: rect.x, y: rect.y, w: rect.w, h: rect.h }));
  result[active] = { x: target.x, y: target.y, w: target.w, h: target.h };
  const placed: GridRect[] = [result[active]];
  const order = rects.map((_rect: GridRect, index: number) => index).filter((index: number) => index !== active)
    .sort((a: number, b: number) => rects[a].y - rects[b].y || rects[a].x - rects[b].x || a - b);
  order.forEach((index: number) => {
    const rect = result[index];
    let collisions = placed.filter((other: GridRect) => gridOverlap(rect, other));
    while (collisions.length) {
      rect.y = Math.max(...collisions.map((other: GridRect) => other.y + other.h));
      collisions = placed.filter((other: GridRect) => gridOverlap(rect, other));
    }
    placed.push(rect);
  });
  return result;
}
export function gridHeight(vp: number): number { return Math.max(2, Math.min(GRID_MAX_ROWS, Math.ceil((vp + GRID_GAP) / GRID_ROW_STEP))); }
export function gridVacancy(rects: GridRect[], w: number = 5, h: number = 8): GridRect {
  const rows = [0].concat(rects.map((rect: GridRect) => rect.y + rect.h)).sort((a: number, b: number) => a - b);
  for (const y of rows) {
    for (let x = 0; x <= GRID_COLUMNS - w; x++) {
      const candidate: GridRect = { x: x, y: y, w: w, h: h };
      validateGridRect(candidate);
      if (!rects.some((rect: GridRect) => gridOverlap(rect, candidate))) { return candidate; }
    }
  }
  throw new Error('No valid grid placement');
}
