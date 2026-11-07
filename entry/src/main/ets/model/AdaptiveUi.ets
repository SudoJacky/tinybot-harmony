// Logical window units, shared by phone, split-screen and tablet surfaces.
export interface UiRect { x: number; y: number; width: number; height: number; }
export class AdaptiveUi {
  static readonly formWidth: number = 640;
  static readonly readingWidth: number = 680;
  static readonly choiceWidth: number = 480;
  static compactComposer(width: number): boolean { return width > 0 && width < 520; }
  static keyboardInset(content: UiRect, keyboard: UiRect): number {
    if (keyboard.width <= 0 || keyboard.height <= 0 || keyboard.x >= content.x + content.width ||
      keyboard.x + keyboard.width <= content.x || keyboard.y >= content.y + content.height ||
      keyboard.y + keyboard.height <= content.y) { return 0; }
    return Math.max(0, Math.min(content.height - 160, content.y + content.height - keyboard.y + 12));
  }
}
