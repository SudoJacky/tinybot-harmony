import { display, UIContext, window } from '@kit.ArkUI';
import { Diagnostics } from '../model/Diagnostics';

// Keep a small margin above the 200/250/300 ms full-screen UX minimums.
const LARGE_SCREEN_DURATION: number = 320;

function transitionWindow(ui: UIContext): window.WindowProperties {
  const name = ui.getWindowName();
  if (!name) { throw new Error('The transition window is unavailable.'); }
  return window.findWindow(name).getWindowProperties();
}

export function fullscreenTransitionDuration(ui: UIContext): number {
  try {
    const displayId = transitionWindow(ui).displayId;
    const screen = displayId === undefined ? display.getDefaultDisplaySync() : display.getDisplayByIdSync(displayId);
    if ([screen.width, screen.height, screen.xDPI, screen.yDPI].some((value) => !Number.isFinite(value) || value <= 0)) {
      Diagnostics.log('warn', 'navigation', 'transition_screen_failed', { width: screen.width, height: screen.height });
      return LARGE_SCREEN_DURATION;
    }
    const diagonal = Math.hypot(screen.width / screen.xDPI, screen.height / screen.yDPI);
    if (diagonal < 8.5) { return 220; }
    return diagonal <= 12 ? 270 : LARGE_SCREEN_DURATION;
  } catch (error) {
    Diagnostics.log('warn', 'navigation', 'transition_screen_failed', undefined, error as Error);
    return LARGE_SCREEN_DURATION;
  }
}

export interface PreviewFullscreenMotion { x: number; y: number; scale: number; duration: number; }

export function previewFullscreenMotion(ui: UIContext, anchorId: string, animated: boolean): PreviewFullscreenMotion | undefined {
  if (!animated) { return undefined; }
  const duration = fullscreenTransitionDuration(ui);
  let scale = 0.92;
  let x = 0;
  let y = 0;
  try {
    const windowRect = transitionWindow(ui).windowRect;
    const components = ui.getComponentUtils();
    const card = components.getRectangleById(anchorId);
    const chat = components.getRectangleById('message-list');
    const left = Math.max(0, card.windowOffset.x);
    const right = Math.min(windowRect.width, card.windowOffset.x + card.size.width);
    const top = Math.max(0, card.windowOffset.y, chat.windowOffset.y);
    const bottom = Math.min(windowRect.height, card.windowOffset.y + card.size.height,
      chat.windowOffset.y + chat.size.height);
    if (right > left && bottom > top) {
      // Keep the page proportional as it expands from the visible part of the card.
      scale = Math.max(0.72, Math.min(0.96, (right - left) / windowRect.width, (bottom - top) / windowRect.height));
      x = ui.px2vp((left + right - windowRect.width) / 2);
      y = ui.px2vp((top + bottom - windowRect.height) / 2);
    }
  } catch (error) {
    Diagnostics.log('warn', 'navigation', 'transition_screen_failed', undefined, error as Error);
  }
  return { x: x, y: y, scale: scale, duration: duration };
}
