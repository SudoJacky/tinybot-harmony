import { AnimatorResult, curves } from '@kit.ArkUI';
import { t } from '../model/I18n';
import { Radius } from './Theme';
import { SwipeRowMotion as Swipe } from './SwipeRowMotion';

// Native implementation of a shared reveal drawer; no web component/runtime is used.
// A full swipe requests the same confirmation as the delete button, never deletes early.
@Component
export struct SwipeRow {
  @BuilderParam content: () => void;
  rowKey: string = '';
  label: string = '';
  radius: number = Radius.lg;
  @Prop @Watch('syncOpen') activeRow: string = '';
  @Prop @Watch('syncDisabled') disabled: boolean = false;
  onOpen: (key: string) => void = () => {};
  onDelete: () => void = () => {};
  onShare?: () => void;
  onExport?: () => void;
  @State private reveal: number = 0;
  @State private rowWidth: number = 0;
  @State private rowHeight: number = 1;
  private origin: number = 0;
  @State private dragging: boolean = false;
  private animator?: AnimatorResult;

  aboutToDisappear(): void { this.stop(); }
  private stop(): void { this.animator?.cancel(); this.animator = undefined; }
  private syncOpen(): void {
    if (this.activeRow !== this.rowKey) this.settle(false);
  }
  private syncDisabled(): void { if (this.disabled) { this.dragging = false; this.close(); } }
  private close(): void {
    this.settle(false);
    if (this.activeRow === this.rowKey) this.onOpen('');
  }
  private settle(open: boolean): void {
    this.stop();
    const from = this.reveal; const to = open ? Math.min(Swipe.drawer, this.rowWidth) : 0;
    if (Math.abs(from - to) < 0.1) { this.reveal = to; return; }
    const spring = curves.interpolatingSpring(0, 1, 230, 25);
    const animator = this.getUIContext().createAnimator({ duration: 280,
      easing: 'linear', delay: 0, fill: 'forwards',
      direction: 'normal', iterations: 1, begin: 0, end: 1 });
    animator.onFrame = (progress: number) => {
      this.reveal = Math.max(0, Math.min(this.rowWidth, from + (to - from) * spring.interpolate(progress)));
    };
    animator.onFinish = () => { this.reveal = to; this.animator = undefined; };
    this.animator = animator; animator.play();
  }
  private start(event: GestureEvent): void {
    if (this.disabled) return;
    this.stop(); this.origin = this.reveal; this.dragging = true;
    this.move(event);
  }
  private move(event: GestureEvent): void {
    if (this.disabled || !this.dragging) return;
    this.reveal = Swipe.reveal(this.origin - event.offsetX, this.rowWidth);
  }
  private end(event: GestureEvent): void {
    if (!this.dragging) return;
    this.move(event); this.dragging = false;
    if (this.disabled) { this.close(); return; }
    if (Swipe.armed(this.reveal, this.rowWidth) && event.velocityX <= 450) { this.requestDelete(); return; }
    const open = Swipe.staysOpen(this.reveal, event.velocityX);
    this.onOpen(open ? this.rowKey : ''); this.settle(open);
  }
  private requestDelete(): void {
    if (this.disabled || this.dragging) return;
    this.onOpen(''); this.close(); this.onDelete();
  }
  @Builder
  actionsMenu() {
    Menu() {
      if (this.onShare) {
        MenuItem({ content: t('分享') }).enabled(!this.disabled).onClick(() => this.onShare?.())
      }
      if (this.onExport) {
        MenuItem({ content: t('导出到文件') }).enabled(!this.disabled).onClick(() => this.onExport?.())
      }
      MenuItem({ content: t('删除') }).contentFontColor($r('app.color.danger'))
        .enabled(!this.disabled).onClick(() => this.requestDelete())
    }
  }
  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.trash')).fontSize(21).fontColor([$r('app.color.on_danger')])
            .scale({ x: Swipe.armed(this.reveal, this.rowWidth) ? 1.16 : 1,
              y: Swipe.armed(this.reveal, this.rowWidth) ? 1.16 : 1 })
            .animation({ duration: 140, curve: Curve.EaseOut })
          Text(t('删除')).fontSize(12).fontColor($r('app.color.on_danger'))
        }.opacity(Math.min(1, this.reveal / 48)).width('100%')
      }.id('swipe-delete-' + this.rowKey).width(Math.max(1, this.reveal)).height(this.rowHeight)
      .position({ x: Math.max(0, this.rowWidth - this.reveal), y: 0 })
      .backgroundColor($r('app.color.danger')).borderRadius(this.radius)
      .enabled(!this.disabled && this.reveal >= 32).opacity(this.reveal > 0 ? 1 : 0)
      .accessibilityLevel(this.reveal >= 32 ? 'auto' : 'no-hide-descendants')
      .accessibilityText(t('删除') + ' ' + this.label).onClick(() => this.requestDelete())
      Column() { this.content() }
        .width('100%').translate({ x: -this.reveal })
        .onAreaChange((_old: Area, area: Area) => { this.rowHeight = Number(area.height); })
      // Add a tap-to-close cover only after release. Changing the content's hit test
      // during the pan would cancel the recognizer which owns that gesture.
      if (!this.dragging && this.reveal > 1) {
        Column().width(Math.max(0, this.rowWidth - this.reveal)).height(this.rowHeight)
          .position({ x: 0, y: 0 }).backgroundColor(Color.Transparent)
          .accessibilityLevel('no').onClick(() => this.close())
      }
    }.id('swipe-row-' + this.rowKey).width('100%').borderRadius(this.radius).clip(true)
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      if (this.rowWidth > 0 && Math.abs(width - this.rowWidth) > 1) this.close();
      this.rowWidth = width;
    })
    .onVisibleAreaChange([0], (visible: boolean) => { if (!visible) { this.stop(); this.reveal = 0; this.dragging = false; } })
    .bindContextMenu(this.actionsMenu, ResponseType.LongPress)
    .priorityGesture(PanGesture({ fingers: 1, isFingerCountLimited: true, direction: PanDirection.Horizontal, distance: 12 })
      .onActionStart((event: GestureEvent) => this.start(event))
      .onActionUpdate((event: GestureEvent) => this.move(event))
      .onActionEnd((event: GestureEvent) => this.end(event))
      .onActionCancel(() => { this.dragging = false; this.close(); }))
  }
}
