export interface UiShape {
  id: string; kind: string; x: number; y: number; width?: number; height?: number;
  x2?: number; y2?: number; radius?: number; text?: string; color?: string; action?: string;
}
export interface UiScene { width: number; height: number; shapes: UiShape[]; }
export function parseUiScene(text: string): UiScene {
  if (text.length > 16000) { throw new Error('Interactive UI: scene exceeds 16,000 characters'); }
  const scene = JSON.parse(text) as UiScene;
  if (!scene || Object.keys(scene).some((key) => !['width', 'height', 'shapes'].includes(key)) || !Number.isFinite(scene.width) || !Number.isFinite(scene.height) || scene.width < 100 || scene.width > 2000 ||
    scene.height < 100 || scene.height > 2000 || scene.width / scene.height < 0.5 || scene.width / scene.height > 3 ||
    !Array.isArray(scene.shapes) || scene.shapes.length > 100) { throw new Error('Interactive UI: invalid scene dimensions or shapes'); }
  const ids = new Set<string>();
  for (const shape of scene.shapes) {
    if (!shape || Object.keys(shape).some((key) => !['id', 'kind', 'x', 'y', 'width', 'height', 'x2', 'y2', 'radius', 'text', 'color', 'action'].includes(key)) || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(shape.id) || ids.has(shape.id) ||
      !['rect', 'circle', 'line', 'text'].includes(shape.kind) || !Number.isFinite(shape.x) || !Number.isFinite(shape.y) ||
      shape.x < 0 || shape.x > scene.width || shape.y < 0 || shape.y > scene.height ||
      (shape.color !== undefined && !/^#[0-9a-fA-F]{6}$/.test(shape.color)) ||
      (shape.action !== undefined && (!/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(shape.action) || !shape.text))) { throw new Error('Interactive UI: invalid scene shape'); }
    ids.add(shape.id);
    for (const number of [shape.width, shape.height, shape.radius, shape.x2, shape.y2]) {
      if (number !== undefined && (!Number.isFinite(number) || number < 0 || number > 2000)) { throw new Error('Interactive UI: invalid shape geometry'); }
    }
    if (shape.kind === 'rect' && (!shape.width || !shape.height || shape.x + shape.width > scene.width || shape.y + shape.height > scene.height)) { throw new Error('Interactive UI: rectangle outside scene'); }
    if (shape.kind === 'circle' && (!shape.radius || shape.x - shape.radius < 0 || shape.x + shape.radius > scene.width || shape.y - shape.radius < 0 || shape.y + shape.radius > scene.height)) { throw new Error('Interactive UI: circle outside scene'); }
    if (shape.kind === 'line' && (shape.x2 === undefined || shape.y2 === undefined || shape.x2 > scene.width || shape.y2 > scene.height)) { throw new Error('Interactive UI: invalid line endpoint'); }
    if ((shape.kind === 'text' && typeof shape.text !== 'string') || (shape.text !== undefined && (typeof shape.text !== 'string' || shape.text.length > 200))) { throw new Error('Interactive UI: invalid shape label'); }
  }
  return scene;
}
