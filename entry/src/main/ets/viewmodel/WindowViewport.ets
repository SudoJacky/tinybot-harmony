import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

// Window-owned keyboard/gesture insets, observed by chat and sheet footers.
@Observed
export class WindowViewport {
  keyboardHeight: number = 0;
  bottom: number = 0;
  onKeyboard: (shown: boolean) => void = () => {};
  private host?: window.Window;
  private ui?: UIContext;
  private active: boolean = false;
  private keyboardListener: (height: number) => void = () => {};
  private areaListener: (options: window.AvoidAreaOptions) => void = () => {};
  private keyboardChanged(height: number): void {
    const wasShown = this.keyboardHeight > 0;
    this.keyboardHeight = height;
    if (wasShown !== (height > 0)) { this.onKeyboard(height > 0); }
  }
  private areaChanged(options: window.AvoidAreaOptions): void {
    if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR && this.ui) {
      this.bottom = this.ui.px2vp(options.area.bottomRect.height);
    }
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
      hilog.error(0x0000, 'TinybotViewport', 'Unable to observe window insets: %{public}s', (error as Error).message);
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
