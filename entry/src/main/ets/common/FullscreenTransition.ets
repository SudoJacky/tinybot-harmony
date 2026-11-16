import { display, window } from '@kit.ArkUI';
import { Diagnostics } from '../model/Diagnostics';

// Keep a small margin above the 200/250/300 ms full-screen UX minimums.
const LARGE_SCREEN_DURATION: number = 320;

export function fullscreenTransitionDuration(ui: UIContext): number {
  try {
    const name = ui.getWindowName();
    if (!name) { throw new Error('The transition window is unavailable.'); }
    const displayId = window.findWindow(name).getWindowProperties().displayId;
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
