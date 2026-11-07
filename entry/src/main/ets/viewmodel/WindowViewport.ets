import { Diagnostics } from '../model/Diagnostics';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { UiRect } from '../model/AdaptiveUi';

// Window-owned keyboard/gesture insets, observed by chat and sheet footers.
@Observed
export class WindowViewport {
  keyboardHeight: number = 0;
  bottom: number = 0;
  keyboard: UiRect = { x: 0, y: 0, width: 0, height: 0 };
  onKeyboard: (shown: boolean) => void = () => {};
  onGeometry: () => void = () => {};
  private host?: window.Window;
  private ui?: UIContext;
  private active: boolean = false;
  private keyboardListener: (height: number) => void = () => {};
  private areaListener: (options: window.AvoidAreaOptions) => void = () => {};
  private keyboardChanged(height: number): void {
    const wasShown = this.keyboardHeight > 0;
    this.keyboardHeight = height;
    if (this.host) { this.keyboardArea(this.host.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD)); }
    if (wasShown !== (height > 0)) { this.onKeyboard(height > 0); }
  }
  private areaChanged(options: window.AvoidAreaOptions): void {
    if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR && this.ui) {
      this.bottom = this.ui.px2vp(options.area.bottomRect.height);
    }
    if (options.type === window.AvoidAreaType.TYPE_KEYBOARD) { this.keyboardArea(options.area); }
  }
  private keyboardArea(area: window.AvoidArea): void {
    if (!this.ui) { return; }
    const rect = [area.bottomRect, area.topRect, area.leftRect, area.rightRect]
      .filter((item: window.Rect) => !!item && item.width > 0 && item.height > 0)
      .sort((a: window.Rect, b: window.Rect) => b.width * b.height - a.width * a.height)[0];
    this.keyboard = rect ? { x: this.ui.px2vp(rect.left), y: this.ui.px2vp(rect.top),
      width: this.ui.px2vp(rect.width), height: this.ui.px2vp(rect.height) } : { x: 0, y: 0, width: 0, height: 0 };
    Diagnostics.log('info', 'appearance', 'keyboard_geometry', { width: this.keyboard.width, height: this.keyboard.height });
    this.onGeometry();
  }
  async observe(ui: UIContext): Promise<void> {
    this.active = true; this.ui = ui;
    try {
      const host = await window.getLastWindow(ui.getHostContext() as common.UIAbilityContext);
      if (!this.active) { return; }
      this.host = host;
      this.bottom = ui.px2vp(host.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height);
      this.keyboardChanged(host.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD).bottomRect.height);
      // Capture the @Observed proxy here, not the raw instance in a field initializer.
      this.keyboardListener = (height: number): void => { this.keyboardChanged(height); };
      this.areaListener = (options: window.AvoidAreaOptions): void => { this.areaChanged(options); };
      host.on('keyboardHeightChange', this.keyboardListener);
      host.on('avoidAreaChange', this.areaListener);
    } catch (error) {
      Diagnostics.log('error', 'appearance', 'insets_failed', undefined, error as Error);
    }
  }
  dispose(): void {
    this.active = false;
    if (this.host) {
      this.host.off('keyboardHeightChange', this.keyboardListener);
      this.host.off('avoidAreaChange', this.areaListener);
      this.host = undefined;
    }
  }
}
