import { KeyCode, pointer } from '@kit.InputKit';
import { AppearanceStyle } from './AppearanceStyle';
import { Motion } from './Theme';

// Touch-sized column divider. The strip is invisible at rest (the frame already
// draws a 0.5 vp seam) and shows an accent grip while the finger holds it, so a
// drag never moves the panel without feedback. A hardware keyboard gets the same
// control: the seam can be focused and nudged with the arrow keys.
@Component
export struct PaneDivider {
  @StorageProp('tinybot.appearance.style') private appearance: AppearanceStyle = new AppearanceStyle();
  @Prop label: string = '';
  @Prop desktop: boolean = false;
  @Prop collapseArmed: boolean = false;
  compId: string = '';
  @State private active: boolean = false;
  @State private hover: boolean = false;
  @State private focused: boolean = false;
  onResizeStart: () => void = () => {};
  onResize: (dx: number) => void = () => {};
  onResizeEnd: (cancelled: boolean) => void = () => {};
  onReset: () => void = () => {};

  aboutToDisappear(): void {
    if (this.desktop && (this.hover || this.active)) { this.getUIContext().getCursorController().restoreDefault(); }
  }

  private finish(cancelled: boolean): void {
    if (!this.active) { return; }
    this.active = false;
    if (this.desktop && !this.hover) { this.getUIContext().getCursorController().restoreDefault(); }
    this.onResizeEnd(cancelled);
  }

  // One arrow press is one committed step, so the next press starts from the
  // width the previous one produced.
  private step(dx: number): void {
    this.onResizeStart();
    this.onResize(dx);
    this.onResizeEnd(false);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // A resting grip stays faintly visible on touch screens, where there is no
      // hover pass to reveal the seam; a pointer, focus or a held finger strengthens it.
      Column().width(this.collapseArmed ? 5 : 3).height(56).borderRadius(3).backgroundColor(this.appearance.accent)
        .opacity(this.collapseArmed ? 1 : this.active || this.focused ? 0.9 : this.hover ? 0.5 : 0.16)
        .animation({ duration: Motion.fast, curve: Motion.standard })
    }.id(this.compId).width(12).height('100%')
    .backgroundColor(Color.Transparent)
    .onHover((hover: boolean) => {
      this.hover = hover;
      if (!this.desktop) { return; }
      const cursor = this.getUIContext().getCursorController();
      if (hover) { cursor.setCursor(pointer.PointerStyle.WEST_EAST); }
      else if (!this.active) { cursor.restoreDefault(); }
    })
    .focusable(true).focusOnTouch(false)
    .onFocus(() => { this.focused = true; })
    .onBlur(() => { this.focused = false; })
    .onKeyEvent((event: KeyEvent) => {
      if (event.type !== KeyType.Down) { return; }
      if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT) { this.step(-16); event.stopPropagation(); }
      else if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT) { this.step(16); event.stopPropagation(); }
      else if (this.desktop && event.keyCode === KeyCode.KEYCODE_ENTER) { this.onReset(); event.stopPropagation(); }
    })
    .accessibilityText(this.label)
    .gesture(GestureGroup(GestureMode.Exclusive,
      PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 4 })
      .onActionStart(() => { this.active = true; this.onResizeStart(); })
      .onActionUpdate((event: GestureEvent) => { if (this.active) { this.onResize(event.offsetX); } })
      .onActionEnd((event: GestureEvent) => { if (this.active) { this.onResize(event.offsetX); this.finish(false); } })
      .onActionCancel(() => this.finish(true)),
      TapGesture({ count: 2 }).onAction(() => { if (this.desktop) { this.onReset(); } })))
  }
}
